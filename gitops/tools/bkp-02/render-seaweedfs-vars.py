#!/usr/bin/env python3
"""저장소 밖 BKP-02 입력을 Ansible용 mode 0600 JSON으로 렌더한다."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def read_private(path: Path) -> dict[str, object]:
    if path.stat().st_mode & 0o077:
        raise SystemExit(f"credential 입력은 mode 0600이어야 합니다: {path}")
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def credential(identity: dict[str, str]) -> dict[str, str]:
    return {
        "accessKey": identity["access_key"],
        "secretKey": identity["secret_key"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--phase", choices=("bootstrap", "final"), required=True)
    args = parser.parse_args()

    source = read_private(args.input)
    bucket = source["bucket"]
    identities: list[dict[str, object]] = []
    if args.phase == "bootstrap":
        identities.append(
            {
                "name": "bkp-02-bucket-bootstrap",
                "credentials": [credential(source["bootstrap"])],
                "actions": [f"Admin:{bucket}"],
            }
        )
    identities.append(
        {
            "name": "bkp-02-velero",
            "credentials": [credential(source["velero"])],
            "actions": [
                f"Read:{bucket}",
                f"List:{bucket}",
                f"Write:{bucket}",
            ],
        }
    )

    os.umask(0o177)
    descriptor = os.open(args.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump({"seaweedfs_s3_identities": identities}, stream, indent=2)
        stream.write("\n")
    print(f"{args.phase} Ansible 입력 생성 완료: {args.output} (값 미출력)")


if __name__ == "__main__":
    main()
