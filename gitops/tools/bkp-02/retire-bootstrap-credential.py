#!/usr/bin/env python3
"""bucket 생성용 일회성 credential을 canonical 입력에서 원자적으로 제거한다."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()

    if args.input.stat().st_mode & 0o077:
        raise SystemExit("credential 입력은 mode 0600이어야 합니다")
    with args.input.open(encoding="utf-8") as stream:
        source = json.load(stream)
    if "bootstrap" not in source:
        raise SystemExit("bootstrap credential이 이미 제거됐습니다")
    del source["bootstrap"]

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".bkp-02-", suffix=".json", dir=args.input.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(source, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, args.input)
    finally:
        if temporary.exists():
            temporary.unlink()
    print(f"bootstrap credential 제거 완료: {args.input} (값 미출력)")


if __name__ == "__main__":
    main()
