#!/usr/bin/env python3
"""BKP-01 live k3s inventory를 저장소 밖 mode 0600으로 생성한다."""

from __future__ import annotations

import argparse
import ipaddress
import os
import re
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", default="rocky")
    args = parser.parse_args()

    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", args.name):
        raise SystemExit("inventory name 형식이 잘못됐습니다")
    try:
        ipaddress.ip_address(args.host)
    except ValueError:
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", args.host):
            raise SystemExit("inventory host 형식이 잘못됐습니다")
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", args.user):
        raise SystemExit("inventory user 형식이 잘못됐습니다")

    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(args.output.parent, 0o700)
    descriptor = os.open(args.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(
            "all:\n"
            "  children:\n"
            "    k3s_servers:\n"
            "      hosts:\n"
            f"        {args.name}:\n"
            f"          ansible_host: {args.host}\n"
            f"          ansible_user: {args.user}\n"
        )
    print(f"BKP-01 inventory 생성 완료: {args.output} (mode 0600)")


if __name__ == "__main__":
    main()
