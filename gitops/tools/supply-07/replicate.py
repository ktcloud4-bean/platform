#!/usr/bin/env python3
"""
SUPPLY-07: Harbor to AWS ECR Replicator
Uses the least-privileged IAM replicator credentials (from Vault kv/harbor/ecr-replicator)
to copy candidate images, Cosign signatures, and CycloneDX SBOMs from Harbor to ECR.
"""
import os
import sys
import json
import base64
import subprocess
import tempfile
import urllib.request
import time
from typing import Dict, Any, List

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
KUBECONFIG = os.path.expanduser("~/.kube/k3s-01-admin.yaml")
VAULT_TOKEN_FILE = os.path.expanduser("~/secrets/ktcloud4-bean/vault-root.token")

ACCOUNT_ID = "465137780685"
REGION = "ap-northeast-2"
ECR_REGISTRY = f"{ACCOUNT_ID}.dkr.ecr.{REGION}.amazonaws.com"
HARBOR_REGISTRY = "harbor.imcherry5778.xyz"
COMPONENTS = ["frontend", "employee-service", "hr-service"]


def get_vault_token() -> str:
    if os.path.exists(VAULT_TOKEN_FILE):
        with open(VAULT_TOKEN_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    return ""


def get_vault_secret(path: str, field: str) -> str:
    token = get_vault_token()
    env = os.environ.copy()
    env["KUBECONFIG"] = KUBECONFIG
    res = subprocess.run(
        ["kubectl", "-n", "vault", "exec", "vault-0", "--",
         "sh", "-c", f"env VAULT_TOKEN={token} vault kv get -field={field} {path}"],
        capture_output=True, text=True, check=True, env=env
    )
    return res.stdout.strip()


def get_ecr_auth_token(access_key: str, secret_key: str) -> str:
    env = os.environ.copy()
    env["AWS_ACCESS_KEY_ID"] = access_key
    env["AWS_SECRET_ACCESS_KEY"] = secret_key
    env["AWS_DEFAULT_REGION"] = REGION
    res = subprocess.run(
        ["aws", "ecr", "get-login-password", "--region", REGION],
        capture_output=True, text=True, check=True, env=env
    )
    return res.stdout.strip()


def replicate():
    print("=== SUPPLY-07 Harbor to ECR Replicator ===")
    harbor_admin_pass = get_vault_secret("kv/harbor/runtime", "admin_password")
    access_key = get_vault_secret("kv/harbor/ecr-replicator", "access_key_id")
    secret_key = get_vault_secret("kv/harbor/ecr-replicator", "secret_access_key")
    
    ecr_pass = get_ecr_auth_token(access_key, secret_key)
    
    # Configure Docker config with both Harbor and ECR auth
    tmp_dcfg = tempfile.mkdtemp(prefix="repl_dcfg_")
    harbor_b64 = base64.b64encode(f"admin:{harbor_admin_pass}".encode()).decode()
    ecr_b64 = base64.b64encode(f"AWS:{ecr_pass}".encode()).decode()
    
    auth_config = {
        "auths": {
            HARBOR_REGISTRY: {"auth": harbor_b64},
            ECR_REGISTRY: {"auth": ecr_b64}
        }
    }
    with open(os.path.join(tmp_dcfg, "config.json"), "w") as f:
        json.dump(auth_config, f)
        
    env = os.environ.copy()
    env["DOCKER_CONFIG"] = tmp_dcfg
    
    # Port forward for Harbor Core API
    pf = subprocess.Popen(["kubectl", "-n", "harbor", "port-forward", "svc/harbor-core", "38080:80"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    time.sleep(2)
    base_url = "http://127.0.0.1:38080/api/v2.0"
    headers = {"Authorization": f"Basic {harbor_b64}", "Content-Type": "application/json"}
    
    replicated_records = {}
    
    try:
        for comp in COMPONENTS:
            repo_name = f"hr-system-prod-{comp}"
            src_repo = f"{HARBOR_REGISTRY}/hr-system-prod/{repo_name}"
            dst_repo = f"{ECR_REGISTRY}/{repo_name}"
            
            # Fetch artifacts via Harbor API
            req = urllib.request.Request(f"{base_url}/projects/hr-system-prod/repositories/{repo_name}/artifacts", headers=headers)
            with urllib.request.urlopen(req) as resp:
                artifacts = json.loads(resp.read().decode())
                
            # Filter image artifacts with release tag
            release_art = None
            for art in artifacts:
                tags = [t.get("name") for t in art.get("tags") or []]
                for tag in tags:
                    if tag.startswith("sha-"):
                        release_art = (art, tag)
                        break
                if release_art:
                    break
                    
            if not release_art:
                raise RuntimeError(f"No release artifact found for {repo_name} in Harbor!")
                
            art_meta, release_tag = release_art
            digest = art_meta["digest"]
            all_tags = [t.get("name") for t in art_meta.get("tags") or []]
            
            print(f"\n[*] Component: {comp}")
            print(f"    Harbor Source: {src_repo}@{digest}")
            print(f"    Release Tag:   {release_tag}")
            print(f"    All Tags:      {all_tags}")
            
            # 1. Copy image with release tag to ECR
            print(f"    [1/4] Copying image with tag '{release_tag}' -> ECR...")
            subprocess.run([
                "skopeo", "copy", "--all", "--src-tls-verify=false",
                f"docker://{src_repo}:{release_tag}",
                f"docker://{dst_repo}:{release_tag}"
            ], check=True, env=env)
            
            # 2. Copy image by digest to ECR
            print(f"    [2/4] Copying image by exact digest '{digest}' -> ECR...")
            subprocess.run([
                "skopeo", "copy", "--all", "--src-tls-verify=false",
                f"docker://{src_repo}@{digest}",
                f"docker://{dst_repo}@{digest}"
            ], check=True, env=env)
            
            # 3. Copy Cosign Signature Artifact (.sig)
            sig_tag = digest.replace(":", "-") + ".sig"
            print(f"    [3/4] Copying Cosign signature '{sig_tag}' -> ECR...")
            subprocess.run([
                "skopeo", "copy", "--all", "--src-tls-verify=false",
                f"docker://{src_repo}:{sig_tag}",
                f"docker://{dst_repo}:{sig_tag}"
            ], check=True, env=env)
            
            # 4. Discover and copy OCI 1.1 CycloneDX SBOM referrers
            print(f"    [4/4] Discovering and copying CycloneDX SBOM referrers...")
            oras_res = subprocess.run([
                "oras", "discover", "--distribution-spec", "v1.1-referrers-api",
                "--format", "json", f"{src_repo}@{digest}"
            ], capture_output=True, text=True, check=True, env=env)
            ref_data = json.loads(oras_res.stdout)
            manifests = ref_data.get("manifests", [])
            print(f"    Found {len(manifests)} OCI referrers in Harbor.")
            for m in manifests:
                ref_digest = m.get("digest")
                art_type = m.get("artifactType")
                print(f"      Copying referrer ({art_type}) @ {ref_digest} -> ECR...")
                subprocess.run([
                    "skopeo", "copy", "--all", "--src-tls-verify=false",
                    f"docker://{src_repo}@{ref_digest}",
                    f"docker://{dst_repo}@{ref_digest}"
                ], check=True, env=env)
                
                # Copy signature on SBOM if exists
                sbom_sig = ref_digest.replace(":", "-") + ".sig"
                try:
                    subprocess.run([
                        "skopeo", "copy", "--all", "--src-tls-verify=false",
                        f"docker://{src_repo}:{sbom_sig}",
                        f"docker://{dst_repo}:{sbom_sig}"
                    ], capture_output=True, check=True, env=env)
                    print(f"      [+] Copied signature for SBOM ({sbom_sig})")
                except Exception:
                    pass
                    
            replicated_records[comp] = {
                "digest": digest,
                "tag": release_tag,
                "ecr_ref": f"{dst_repo}@{digest}"
            }
            print(f"[+] Replicated {comp} successfully: {dst_repo}@{digest}")

        print("\n=== All Components Replicated Successfully ===")
        for k, v in replicated_records.items():
            print(f"{k}: {v['ecr_ref']}")
    finally:
        pf.terminate()


if __name__ == "__main__":
    replicate()
