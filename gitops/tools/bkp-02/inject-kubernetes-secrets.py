#!/usr/bin/env python3
"""BKP-02 credential을 SSH stdin으로 Kubernetes Secret에 주입한다."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path, required=True)
    parser.add_argument("--host", default="10.10.20.10")
    parser.add_argument("--user", default="rocky")
    args = parser.parse_args()

    if args.input.stat().st_mode & 0o077:
        raise SystemExit("credential 입력은 mode 0600이어야 합니다")
    with args.input.open(encoding="utf-8") as stream:
        source = json.load(stream)
    velero = source["velero"]
    cloud = (
        "[default]\n"
        f"aws_access_key_id={velero['access_key']}\n"
        f"aws_secret_access_key={velero['secret_key']}\n"
    )
    resources = {
        "apiVersion": "v1",
        "kind": "List",
        "items": [
            {
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": {
                    "name": "velero",
                    "labels": {
                        "app.kubernetes.io/part-of": "platform-gitops",
                        "pod-security.kubernetes.io/enforce": "privileged",
                        "pod-security.kubernetes.io/audit": "privileged",
                        "pod-security.kubernetes.io/warn": "privileged",
                    },
                },
            },
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": "bkp-02-s3-credentials", "namespace": "velero"},
                "type": "Opaque",
                "immutable": True,
                "stringData": {"cloud": cloud},
            },
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {"name": "velero-repo-credentials", "namespace": "velero"},
                "type": "Opaque",
                "immutable": True,
                "stringData": {"repository-password": source["repository_password"]},
            },
        ],
    }

    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ControlMaster=no",
        "-o",
        "ControlPath=none",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={args.known_hosts}",
        f"{args.user}@{args.host}",
        "sudo /usr/local/bin/k3s kubectl apply -f -",
    ]
    result = subprocess.run(
        command,
        input=json.dumps(resources),
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise SystemExit(f"Kubernetes Secret 주입 실패: {result.stderr.strip()}")
    allowed = ("namespace/velero", "secret/bkp-02-s3-credentials", "secret/velero-repo-credentials")
    for line in result.stdout.splitlines():
        if line.startswith(allowed):
            print(line)
    print("Secret 주입 완료 (값과 base64 미출력)")


if __name__ == "__main__":
    main()
