#!/usr/bin/env python3
"""
SUPPLY-03: Harbor Upstream Proxy Cache Provisioner
Configures exact upstream registry endpoints and proxy cache projects in Harbor
based on SUPPLY-02 inventory.
"""

import os
import sys
import json
import base64
import ssl
import subprocess
import urllib.request
import urllib.error
from typing import Dict, Any, List, Optional

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
KUBECONFIG = os.path.expanduser("~/.kube/k3s-01-admin.yaml")
VAULT_TOKEN_FILE = os.path.expanduser("~/secrets/ktcloud4-bean/vault-root.token")
HARBOR_ENV_FILE = os.path.expanduser("~/secrets/ktcloud4-bean/harbor/env")

UPSTREAM_REGISTRIES = [
    {
        "name": "dockerhub-endpoint",
        "type": "docker-hub",
        "url": "https://hub.docker.com",
        "project": "proxy-dockerhub",
        "description": "Docker Hub Upstream Proxy Cache"
    },
    {
        "name": "quay-endpoint",
        "type": "docker-registry",
        "url": "https://quay.io",
        "project": "proxy-quay",
        "description": "Quay.io Upstream Proxy Cache"
    },
    {
        "name": "ghcr-endpoint",
        "type": "github-ghcr",
        "url": "https://ghcr.io",
        "project": "proxy-ghcr",
        "description": "GitHub Container Registry Upstream Proxy Cache"
    },
    {
        "name": "gitea-endpoint",
        "type": "docker-registry",
        "url": "https://docker.gitea.com",
        "project": "proxy-gitea",
        "description": "Gitea Container Registry Upstream Proxy Cache"
    },
    {
        "name": "kyverno-endpoint",
        "type": "github-ghcr",
        "url": "https://ghcr.io",
        "project": "proxy-kyverno",
        "description": "Kyverno Upstream Proxy Cache (GHCR backend)"
    },
    {
        "name": "k8s-endpoint",
        "type": "docker-registry",
        "url": "https://registry.k8s.io",
        "project": "proxy-k8s",
        "description": "Kubernetes Official Registry Upstream Proxy Cache"
    },
    {
        "name": "public-ecr-endpoint",
        "type": "docker-registry",
        "url": "https://public.ecr.aws",
        "project": "proxy-public-ecr",
        "description": "AWS Public ECR Upstream Proxy Cache"
    }
]

def get_vault_token() -> str:
    if os.path.exists(VAULT_TOKEN_FILE):
        with open(VAULT_TOKEN_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    return ""

def get_harbor_admin_password() -> str:
    token = get_vault_token()
    env = os.environ.copy()
    env["KUBECONFIG"] = KUBECONFIG
    if token:
        try:
            res = subprocess.run(
                ["kubectl", "-n", "vault", "exec", "vault-0", "--",
                 "sh", "-c", f"env VAULT_TOKEN={token} vault kv get -field=admin_password kv/harbor/runtime"],
                capture_output=True, text=True, check=True, env=env
            )
            return res.stdout.strip()
        except Exception:
            pass

    # Fallback to local env file if available
    if os.path.exists(HARBOR_ENV_FILE):
        with open(HARBOR_ENV_FILE, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("HARBOR_ADMIN_PASSWORD="):
                    return line.split("=", 1)[1].strip()

    raise RuntimeError("Harbor admin password could not be retrieved from Vault or env file")

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

    def request(self, method: str, path: str, payload: Any = None, expected_status: tuple = (200, 201)) -> Tuple[int, Any]:
        url = self.base_url + path
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=data, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=30) as resp:
                status = resp.status
                body = resp.read().decode("utf-8")
                res_data = json.loads(body) if body else None
                if status not in expected_status:
                    raise RuntimeError(f"Harbor API {method} {path} returned unexpected status {status}")
                return status, res_data
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8") if e.fp else ""
            if e.code in expected_status:
                res_data = json.loads(body) if body else None
                return e.code, res_data
            raise RuntimeError(f"Harbor API {method} {path} failed with HTTP {e.code}: {body}") from None

    def list_registries(self) -> List[Dict[str, Any]]:
        status, data = self.request("GET", "/api/v2.0/registries", expected_status=(200,))
        return data or []

    def create_registry(self, name: str, reg_type: str, url: str, description: str = "") -> int:
        payload = {
            "name": name,
            "type": reg_type,
            "url": url,
            "description": description,
            "insecure": False
        }
        status, data = self.request("POST", "/api/v2.0/registries", payload=payload, expected_status=(201, 409))
        if status == 409:
            # Already exists, find ID
            regs = self.list_registries()
            for r in regs:
                if r.get("name") == name:
                    return r.get("id")
        # Fetch newly created ID
        regs = self.list_registries()
        for r in regs:
            if r.get("name") == name:
                return r.get("id")
        raise RuntimeError(f"Failed to resolve registry ID for {name}")

    def list_projects(self) -> List[Dict[str, Any]]:
        status, data = self.request("GET", "/api/v2.0/projects?page_size=100", expected_status=(200,))
        return data or []

    def create_proxy_project(self, project_name: str, registry_id: int) -> int:
        payload = {
            "project_name": project_name,
            "registry_id": registry_id,
            "metadata": {
                "public": "false",
                "enable_content_trust": "false",
                "prevent_vul": "false"
            }
        }
        status, data = self.request("POST", "/api/v2.0/projects", payload=payload, expected_status=(201, 409))
        if status == 409:
            # Already exists
            projects = self.list_projects()
            for p in projects:
                if p.get("name") == project_name:
                    return p.get("project_id")
        projects = self.list_projects()
        for p in projects:
            if p.get("name") == project_name:
                return p.get("project_id")
        raise RuntimeError(f"Failed to resolve project ID for {project_name}")

def provision():
    admin_pass = get_harbor_admin_password()
    base_url = "http://127.0.0.1:18443"
    client = HarborClient(base_url, admin_pass)

    print("=== Harbor Upstream Proxy Cache Provisioning ===")
    results = []

    for item in UPSTREAM_REGISTRIES:
        reg_name = item["name"]
        reg_type = item["type"]
        reg_url = item["url"]
        proj_name = item["project"]
        desc = item["description"]

        print(f"[*] Provisioning registry endpoint '{reg_name}' ({reg_url}) -> project '{proj_name}'...")
        reg_id = client.create_registry(reg_name, reg_type, reg_url, desc)
        proj_id = client.create_proxy_project(proj_name, reg_id)
        print(f"    [+] Endpoint ID: {reg_id}, Project ID: {proj_id}")
        results.append({
            "registry_name": reg_name,
            "registry_id": reg_id,
            "registry_type": reg_type,
            "registry_url": reg_url,
            "project_name": proj_name,
            "project_id": proj_id
        })

    out_file = os.path.join(REPO_ROOT, "docs/evidence/supply-03/proxy-cache-state.json")
    os.makedirs(os.path.dirname(out_file), exist_ok=True)
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2)

    print(f"=== Successfully provisioned {len(results)} proxy cache endpoints/projects -> {out_file} ===")

if __name__ == "__main__":
    provision()
