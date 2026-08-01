#!/usr/bin/env python3
"""BKP-02 identity를 보존하며 BKP-01 SeaweedFS identity 입력을 렌더한다."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


def read_private(path: Path) -> dict[str, Any]:
    if path.stat().st_mode & 0o077:
        raise SystemExit(f"credential 입력은 mode 0600이어야 합니다: {path}")
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def credential(value: dict[str, str]) -> dict[str, str]:
    return {"accessKey": value["access_key"], "secretKey": value["secret_key"]}


def write_exclusive(path: Path, payload: dict[str, object]) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2)
        stream.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bkp-01-input", type=Path, required=True)
    parser.add_argument("--bkp-02-input", type=Path, required=True)
    parser.add_argument("--phase", choices=("bootstrap", "final"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    bkp01 = read_private(args.bkp_01_input)
    bkp02 = read_private(args.bkp_02_input)
    if bkp01.get("bucket") != "bkp-01-k3s-datastore":
        raise SystemExit("BKP-01 canonical bucket이 아닙니다")
    if bkp02.get("bucket") != "bkp-02-velero" or "velero" not in bkp02:
        raise SystemExit("보존할 BKP-02 final identity 입력이 올바르지 않습니다")

    identities: list[dict[str, object]] = [
        {
            "name": "bkp-02-velero",
            "credentials": [credential(bkp02["velero"])],
            "actions": [
                "Read:bkp-02-velero",
                "List:bkp-02-velero",
                "Write:bkp-02-velero",
            ],
        }
    ]
    if args.phase == "bootstrap":
        if "bootstrap" not in bkp01:
            raise SystemExit("bootstrap phase인데 BKP-01 bootstrap credential이 없습니다")
        identities.append(
            {
                "name": "bkp-01-bucket-bootstrap",
                "credentials": [credential(bkp01["bootstrap"])],
                "actions": ["Admin:bkp-01-k3s-datastore"],
            }
        )
    identities.append(
        {
            "name": "bkp-01-k3s-datastore",
            "credentials": [credential(bkp01["backup"])],
            "actions": [
                "Read:bkp-01-k3s-datastore",
                "List:bkp-01-k3s-datastore",
                "Write:bkp-01-k3s-datastore",
            ],
        }
    )
    os.umask(0o177)
    write_exclusive(args.output, {"seaweedfs_s3_identities": identities})
    print(f"{args.phase} SeaweedFS 입력 생성 완료: {args.output} (값 미출력)")


if __name__ == "__main__":
    main()
