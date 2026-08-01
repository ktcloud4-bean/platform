#!/usr/bin/env python3
"""BKP-02 전용 S3와 Kopia credential 입력을 원문 출력 없이 생성한다."""

from __future__ import annotations

import argparse
import json
import os
import secrets
from pathlib import Path


def write_exclusive(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.stat().st_mode & 0o077:
        raise SystemExit(f"입력 디렉터리 권한이 너무 넓습니다: {path.parent}")
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    os.umask(0o177)
    payload: dict[str, object] = {
        "bucket": "bkp-02-velero",
        "prefix": "cluster-k3s-01",
        "bootstrap": {
            "access_key": f"BKP02BOOT{secrets.token_hex(8).upper()}",
            "secret_key": secrets.token_urlsafe(48),
        },
        "velero": {
            "access_key": f"BKP02VELERO{secrets.token_hex(8).upper()}",
            "secret_key": secrets.token_urlsafe(48),
        },
        "repository_password": secrets.token_urlsafe(48),
    }
    write_exclusive(args.output, payload)
    print(f"credential 입력 생성 완료: {args.output} (mode 0600, 값 미출력)")


if __name__ == "__main__":
    main()
