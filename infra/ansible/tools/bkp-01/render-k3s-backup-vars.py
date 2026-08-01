#!/usr/bin/env python3
"""BKP-01 canonical 입력을 k3s backup Ansible extra-vars로 렌더한다."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.input.stat().st_mode & 0o077:
        raise SystemExit("BKP-01 input은 mode 0600이어야 합니다")
    with args.input.open(encoding="utf-8") as stream:
        source = json.load(stream)
    if source.get("bucket") != "bkp-01-k3s-datastore":
        raise SystemExit("BKP-01 canonical bucket이 아닙니다")
    endpoint = source["endpoint"]
    gpg = source["gpg"]
    backup = source["backup"]
    payload = {
        "k3s_datastore_backup_bucket": source["bucket"],
        "k3s_datastore_backup_prefix": source["prefix"],
        "k3s_datastore_backup_s3_host": endpoint["host"],
        "k3s_datastore_backup_s3_port": endpoint["port"],
        "k3s_datastore_backup_s3_region": endpoint["region"],
        "k3s_datastore_backup_s3_ca_pem": endpoint["ca_pem"],
        "k3s_datastore_backup_s3_access_key": backup["access_key"],
        "k3s_datastore_backup_s3_secret_key": backup["secret_key"],
        "k3s_datastore_backup_gpg_recipient": gpg["recipient"],
        "k3s_datastore_backup_gpg_public_key": gpg["public_key"],
    }
    os.umask(0o177)
    descriptor = os.open(args.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2)
        stream.write("\n")
    print(f"k3s backup Ansible 입력 생성 완료: {args.output} (값 미출력)")


if __name__ == "__main__":
    main()
