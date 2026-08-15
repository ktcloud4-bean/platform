#!/usr/bin/env python3
"""
SUPPLY-06: Harbor to AWS ECR Scheduled Replication Provisioner
Configures AWS ECR registry endpoint and scheduled replication policies in Harbor.
"""
import os
import sys
import json
import base64
import ssl
import subprocess
import urllib.request
import urllib.error
from typing import Dict, Any, List, Optional, Tuple

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
KUBECONFIG = os.path.expanduser("~/.kube/k3s-01-admin.yaml")
VAULT_TOKEN_FILE = os.path.expanduser("~/secrets/ktcloud4-bean/vault-root.token")
HARBOR_ENV_FILE = os.path.expanduser("~/secrets/ktcloud4-bean/harbor/env")

ACCOUNT_ID = "465137780685"
REGION = "ap-northeast-2"
ECR_URL = f"https://{ACCOUNT_ID}.dkr.ecr.{REGION}.amazonaws.com"
ECR_ENDPOINT_NAME = "aws-ecr-endpoint"
REPLICATION_POLICY_NAME = "harbor-to-ecr-hr-system"
TARGET_PROJECT = "hr-system-prod"


def get_vault_token() -> str:
    if os.path.exists(VAULT_TOKEN_FILE):
        with open(VAULT_TOKEN_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    return ""


def get_vault_secret(path: str, field: str) -> str:
    token = get_vault_token()
    env = os.environ.copy()
    env["KUBECONFIG"] = KUBECONFIG
    if token:
        res = subprocess.run(
            ["kubectl", "-n", "vault", "exec", "vault-0", "--",
             "sh", "-c", f"env VAULT_TOKEN={token} vault kv get -field={field} {path}"],
            capture_output=True, text=True, check=True, env=env
        )
        return res.stdout.strip()
    raise RuntimeError(f"Cannot get vault secret {path} {field}")


def get_harbor_admin_password() -> str:
    try:
        return get_vault_secret("kv/harbor/runtime", "admin_password")
    except Exception:
        pass
    if os.path.exists(HARBOR_ENV_FILE):
        with open(HARBOR_ENV_FILE, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("HARBOR_ADMIN_PASSWORD="):
                    return line.split("=", 1)[1].strip()
    raise RuntimeError("Harbor admin password could not be retrieved")


def get_ecr_credentials() -> Tuple[str, str]:
    access_key = get_vault_secret("kv/harbor/ecr-replicator", "access_key_id")
    secret_key = get_vault_secret("kv/harbor/ecr-replicator", "secret_access_key")
    return access_key, secret_key


class HarborClient:
    def __init__(self, base_url: str, admin_pass: str):
        self.base_url = base_url.rstrip("/")
        encoded = base64.b64encode(f"admin:{admin_pass}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {encoded}",
            "Content-Type": "application/json"
        }
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE

    def request(self, method: str, path: str, payload: Any = None, expected_status: tuple = (200, 201, 204)) -> Tuple[int, Any]:
        url = self.base_url + path
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=data, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=30) as resp:
                status = resp.status
                body = resp.read().decode("utf-8")
                res_data = json.loads(body) if body else None
                if status not in expected_status:
                    raise RuntimeError(f"Harbor API {method} {path} returned unexpected status {status}: {body}")
                return status, res_data
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8") if e.fp else ""
            if e.code in expected_status:
                res_data = json.loads(body) if body else None
                return e.code, res_data
            raise RuntimeError(f"Harbor API HTTPError {e.code} on {method} {path}: {body}") from e


def get_k8s_port_forward():
    # Use kubectl port-forward for Harbor Core API
    env = os.environ.copy()
    env["KUBECONFIG"] = KUBECONFIG
    proc = subprocess.Popen(
        ["kubectl", "-n", "harbor", "port-forward", "svc/harbor-core", "38080:80"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env
    )
    import time
    time.sleep(2)
    return proc


def ensure_project(client: HarborClient, project_name: str):
    status, projects = client.request("GET", f"/api/v2.0/projects?name={project_name}")
    found = any(p["name"] == project_name for p in (projects or []))
    if not found:
        print(f"Creating Harbor project: {project_name}")
        client.request("POST", "/api/v2.0/projects", {
            "project_name": project_name,
            "metadata": {"public": "false"}
        }, expected_status=(201, 409))
    else:
        print(f"Harbor project '{project_name}' already exists.")


def ensure_ecr_registry_endpoint(client: HarborClient, access_key: str, secret_key: str) -> int:
    status, registries = client.request("GET", "/api/v2.0/registries")
    target = next((r for r in (registries or []) if r["name"] == ECR_ENDPOINT_NAME), None)
    
    # Ping test payload
    ping_payload = {
        "name": ECR_ENDPOINT_NAME,
        "type": "aws-ecr",
        "url": ECR_URL,
        "credential": {
            "type": "secret",
            "access_key": access_key,
            "access_secret": secret_key
        },
        "insecure": False
    }
    
    print("Testing Harbor ECR Registry Endpoint ping...")
    client.request("POST", "/api/v2.0/registries/ping", ping_payload, expected_status=(200,))
    print("ECR Registry Endpoint Ping SUCCESS!")

    reg_payload = {
        "name": ECR_ENDPOINT_NAME,
        "type": "aws-ecr",
        "url": ECR_URL,
        "description": "AWS ECR Destination Replication Endpoint (SUPPLY-06)",
        "credential": {
            "type": "secret",
            "access_key": access_key,
            "access_secret": secret_key
        },
        "insecure": False
    }

    if target:
        reg_id = target["id"]
        print(f"Updating existing ECR Registry Endpoint (id={reg_id})...")
        client.request("PUT", f"/api/v2.0/registries/{reg_id}", reg_payload, expected_status=(200, 204))
    else:
        print("Creating new ECR Registry Endpoint...")
        status, _ = client.request("POST", "/api/v2.0/registries", reg_payload, expected_status=(201,))
        # Re-fetch ID
        _, registries = client.request("GET", "/api/v2.0/registries")
        target = next(r for r in registries if r["name"] == ECR_ENDPOINT_NAME)
        reg_id = target["id"]

    return reg_id


def ensure_replication_policy(client: HarborClient, registry_id: int):
    status, policies = client.request("GET", "/api/v2.0/replication/policies")
    target = next((p for p in (policies or []) if p["name"] == REPLICATION_POLICY_NAME), None)

    policy_payload = {
        "name": REPLICATION_POLICY_NAME,
        "description": "Scheduled replication of trusted releases to AWS ECR (SUPPLY-06)",
        "src_resource": None,
        "dest_registry": {"id": registry_id},
        "dest_namespace": "",
        "dest_namespace_replace_count": 1,
        "trigger": {
            "type": "scheduled",
            "trigger_settings": {
                "cron": "0 0 * * * *"
            }
        },
        "filters": [
            {
                "type": "name",
                "value": f"{TARGET_PROJECT}/**"
            }
        ],
        "replicate_deletion": False,
        "override": True,
        "enabled": True
    }

    if target:
        policy_id = target["id"]
        print(f"Updating existing Replication Policy '{REPLICATION_POLICY_NAME}' (id={policy_id})...")
        client.request("PUT", f"/api/v2.0/replication/policies/{policy_id}", policy_payload, expected_status=(200, 204))
    else:
        print(f"Creating new Replication Policy '{REPLICATION_POLICY_NAME}'...")
        client.request("POST", "/api/v2.0/replication/policies", policy_payload, expected_status=(201,))
    print("Replication policy successfully configured.")


def main():
    print("=== SUPPLY-06 Harbor ECR Replication Provisioner ===")
    admin_pass = get_harbor_admin_password()
    access_key, secret_key = get_ecr_credentials()

    pf = get_k8s_port_forward()
    try:
        client = HarborClient("http://127.0.0.1:38080", admin_pass)
        ensure_project(client, TARGET_PROJECT)
        reg_id = ensure_ecr_registry_endpoint(client, access_key, secret_key)
        ensure_replication_policy(client, reg_id)
        print("=== Provisioning Completed Successfully! ===")
    finally:
        pf.terminate()
        pf.wait()


if __name__ == "__main__":
    main()
