#!/usr/bin/env python3
"""
SUPPLY-04: Definitive Live Workload JSON Replacer
Fetches full JSON of every Deployment, StatefulSet, DaemonSet, replaces container & initContainer images,
and applies via kubectl replace.
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

    # Build exact matching dictionary
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
            exact_map[f"{reg}/{repo}:{tag}@{digest}"] = curated_exact
            exact_map[f"{repo}:{tag}@{digest}"] = curated_exact
        short_repo = repo.split("/")[-1]
        exact_map[f"{short_repo}:{tag}"] = curated_exact
        if digest and digest != "tag-only":
            exact_map[f"{short_repo}@{digest}"] = curated_exact

    # Explicit known exceptions
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

        spec = item.get("spec", {}).get("template", {}).get("spec", {})
        containers = spec.get("containers", [])
        init_containers = spec.get("initContainers", [])

        changed = False

        for c in containers:
            img = c.get("image", "")
            target_img = exact_map.get(img)
            if not target_img:
                clean = img.split("@")[0].split(":")[0].split("/")[-1]
                for k, v in exact_map.items():
                    if clean == k.split("@")[0].split(":")[0].split("/")[-1]:
                        target_img = v
                        break

            if target_img and target_img != img:
                print(f"[{ns}/{kind}/{name}] container '{c['name']}': {img} -> {target_img}")
                c["image"] = target_img
                changed = True

        for c in init_containers:
            img = c.get("image", "")
            target_img = exact_map.get(img)
            if not target_img:
                clean = img.split("@")[0].split(":")[0].split("/")[-1]
                for k, v in exact_map.items():
                    if clean == k.split("@")[0].split(":")[0].split("/")[-1]:
                        target_img = v
                        break

            if target_img and target_img != img:
                print(f"[{ns}/{kind}/{name}] initContainer '{c['name']}': {img} -> {target_img}")
                c["image"] = target_img
                changed = True

        if changed:
            p = subprocess.Popen(["kubectl", "replace", "-f", "-"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            out, err = p.communicate(input=json.dumps(item))
            if p.returncode != 0:
                print(f"[!] Replace failed for {ns}/{kind}/{name}: {err.strip()}")
            else:
                print(f"[+] Replaced {ns}/{kind}/{name}")

    print("=== All workload JSON replaced successfully ===")

if __name__ == "__main__":
    main()
