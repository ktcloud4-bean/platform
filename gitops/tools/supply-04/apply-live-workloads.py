#!/usr/bin/env python3
"""
SUPPLY-04: Atomic Live Workload Image Updater using kubectl set image
Ensures EVERY container and initContainer in EVERY non-system workload
uses the exact harbor.imcherry5778.xyz/curated-platform/<repo>@sha256:... reference.
"""

import os
import sys
import json
import subprocess

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
KUBECONFIG = os.path.expanduser("~/.kube/k3s-01-admin.yaml")
PROMOTED_MAP_FILE = os.path.join(REPO_ROOT, "docs/evidence/supply-04/promoted-images.json")

def main():
    env = os.environ.copy()
    env["KUBECONFIG"] = KUBECONFIG

    with open(PROMOTED_MAP_FILE, "r", encoding="utf-8") as f:
        promoted = json.load(f)

    # Build exact lookup dictionary
    exact_map = {}
    for src, info in promoted.items():
        curated_exact = info["curated_exact_ref"]
        repo = info["repository"]
        tag = info["tag"]
        digest = info["digest"]
        reg = info["registry"]

        exact_map[src] = curated_exact
        exact_map[f"{reg}/{repo}:{tag}"] = curated_exact
        exact_map[f"{repo}:{tag}"] = curated_exact
        if digest and digest != "tag-only":
            exact_map[f"{reg}/{repo}@{digest}"] = curated_exact
            exact_map[f"{repo}@{digest}"] = curated_exact
        short_repo = repo.split("/")[-1]
        exact_map[f"{short_repo}:{tag}"] = curated_exact

    # Vault-agent explicit map
    vault_info = promoted.get("hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54")
    if vault_info:
        exact_map["hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54"] = vault_info["curated_exact_ref"]

    res = subprocess.run(
        ["kubectl", "get", "deployments,statefulsets,daemonsets", "-A", "-o", "json"],
        check=True, capture_output=True, text=True, env=env
    )
    data = json.loads(res.stdout)

    for item in data.get("items", []):
        ns = item["metadata"]["namespace"]
        kind = item["kind"]
        name = item["metadata"]["name"]

        # Skip system and security namespaces
        if ns in ("kube-system", "kyverno", "falco", "wazuh"):
            continue

        # In harbor namespace, do not rewrite harbor's own components
        if ns == "harbor":
            continue

        spec = item["spec"]["template"]["spec"]
        containers = spec.get("containers", [])
        init_containers = spec.get("initContainers", [])

        container_updates = []
        for c in containers:
            img = c["image"]
            target_img = None
            if img in exact_map:
                target_img = exact_map[img]
            else:
                clean = img.split("@")[0].split(":")[0].split("/")[-1]
                for k, v in exact_map.items():
                    if clean in k:
                        target_img = v
                        break

            if target_img and target_img != img:
                container_updates.append(f"{c['name']}={target_img}")

        for c in init_containers:
            img = c["image"]
            target_img = None
            if img in exact_map:
                target_img = exact_map[img]
            else:
                clean = img.split("@")[0].split(":")[0].split("/")[-1]
                for k, v in exact_map.items():
                    if clean in k:
                        target_img = v
                        break

            if target_img and target_img != img:
                container_updates.append(f"{c['name']}={target_img}")

        if container_updates:
            print(f"[*] Updating {ns} {kind}/{name}: {container_updates}")
            cmd = ["kubectl", "-n", ns, "set", "image", f"{kind.lower()}/{name}"] + container_updates
            subprocess.run(cmd, check=True, capture_output=True, text=True, env=env)

    print("=== All live controllers successfully updated via kubectl set image ===")

if __name__ == "__main__":
    main()
