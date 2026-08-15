#!/usr/bin/env python3
"""
SUPPLY-04: GitOps Image Rewrite Tool
Rewrites all workload images in gitops/apps/ to harbor.imcherry5778.xyz/curated-platform/<app>@sha256:...
Preserves system exceptions (kube-system, kyverno, falco, wazuh).
"""

import os
import sys
import json
import re
from pathlib import Path

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
PROMOTED_MAP_FILE = os.path.join(REPO_ROOT, "docs/evidence/supply-04/promoted-images.json")

def main():
    with open(PROMOTED_MAP_FILE, "r", encoding="utf-8") as f:
        promoted = json.load(f)

    # Build replacement mapping
    # 1. Exact src_image -> curated_image_pinned
    # 2. repo:tag -> curated_image_pinned
    # 3. repo@digest -> curated_image_pinned
    replacements = {}
    for src_ref, info in promoted.items():
        curated_exact = info["curated_exact_ref"]
        curated_pinned = info["curated_image_pinned"]
        repo = info["repository"]
        tag = info["tag"]
        digest = info["digest"]
        reg = info["registry"]

        replacements[src_ref] = curated_exact
        if tag and tag != "none":
            replacements[f"{repo}:{tag}"] = curated_exact
            replacements[f"{reg}/{repo}:{tag}"] = curated_exact
        if digest and digest != "tag-only":
            replacements[f"{repo}@{digest}"] = curated_exact
            replacements[f"{reg}/{repo}@{digest}"] = curated_exact
            if ":" in digest:
                replacements[f"{repo}:{tag}@{digest}"] = curated_exact
                replacements[f"{reg}/{repo}:{tag}@{digest}"] = curated_exact

    # Add special cases if needed (e.g. vault-agent hashicorp/vault:2.0.3)
    vault_info = promoted.get("hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54")
    if vault_info:
        replacements["hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54"] = vault_info["curated_exact_ref"]

    apps_dir = os.path.join(REPO_ROOT, "gitops/apps")
    target_files = []
    for root, dirs, files in os.walk(apps_dir):
        # Exclude kube-system, kyverno, falco, wazuh (system exceptions)
        rel_path = os.path.relpath(root, apps_dir)
        top_app = rel_path.split(os.sep)[0]
        if top_app in ("kyverno", "kyverno-eks", "falco", "wazuh"):
            continue

        for f in files:
            if f.endswith((".yaml", ".yml", ".env")):
                target_files.append(os.path.join(root, f))

    print(f"=== Scanning {len(target_files)} YAML/ENV files in gitops/apps/ ===")

    modified_files = []
    # Sort replacements by descending string length to avoid partial replacements
    sorted_replacements = sorted(replacements.items(), key=lambda x: len(x[0]), reverse=True)

    for fpath in target_files:
        with open(fpath, "r", encoding="utf-8") as f:
            content = f.read()

        orig_content = content
        for old_str, new_str in sorted_replacements:
            if old_str in content:
                content = content.replace(old_str, new_str)

        if content != orig_content:
            with open(fpath, "w", encoding="utf-8") as f:
                f.write(content)
            rel = os.path.relpath(fpath, REPO_ROOT)
            print(f"[+] Modified {rel}")
            modified_files.append(rel)

    print(f"=== Total {len(modified_files)} files modified ===")

if __name__ == "__main__":
    main()
