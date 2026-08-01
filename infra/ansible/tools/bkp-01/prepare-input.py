#!/usr/bin/env python3
"""BKP-01 S3 credential과 recovery public-key 입력을 값 출력 없이 만든다."""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
from pathlib import Path


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def validate_gpg_recipient(fingerprint: str) -> str:
    if not re.fullmatch(r"[0-9A-F]{40,64}", fingerprint):
        raise SystemExit("GPG recipient는 대문자 hexadecimal full fingerprint여야 합니다")
    listing = run(["gpg", "--batch", "--with-colons", "--list-keys", fingerprint]).stdout
    encryption_capable = any(
        line.split(":", maxsplit=12)[11].lower().find("e") >= 0
        for line in listing.splitlines()
        if line.startswith(("pub:", "sub:")) and len(line.split(":")) > 11
    )
    if not encryption_capable:
        raise SystemExit("지정한 GPG key에 encryption capability가 없습니다")
    exported = run(["gpg", "--batch", "--armor", "--export", fingerprint]).stdout
    if "BEGIN PGP PUBLIC KEY BLOCK" not in exported:
        raise SystemExit("GPG public key export에 실패했습니다")
    return exported


def validate_ca(path: Path, host: str) -> str:
    if not path.is_file():
        raise SystemExit(f"S3 CA certificate가 없습니다: {path}")
    run(["openssl", "x509", "-in", str(path), "-noout", "-checkend", "0"])
    run(["openssl", "x509", "-in", str(path), "-noout", "-checkhost", host])
    pem = path.read_text(encoding="utf-8")
    if "BEGIN CERTIFICATE" not in pem:
        raise SystemExit("S3 CA 입력이 PEM certificate가 아닙니다")
    return pem


def write_exclusive(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    if path.parent.stat().st_mode & 0o077:
        raise SystemExit(f"입력 디렉터리 권한이 너무 넓습니다: {path.parent}")
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--gpg-recipient", required=True)
    parser.add_argument("--s3-ca-file", type=Path, required=True)
    parser.add_argument("--s3-host", required=True)
    parser.add_argument("--s3-port", type=int, default=8333)
    parser.add_argument("--s3-region", default="us-east-1")
    args = parser.parse_args()

    if args.s3_port < 1 or args.s3_port > 65535:
        raise SystemExit("S3 port 범위가 잘못됐습니다")
    fingerprint = args.gpg_recipient.upper()
    payload: dict[str, object] = {
        "bucket": "bkp-01-k3s-datastore",
        "prefix": "cluster-k3s-01",
        "endpoint": {
            "host": args.s3_host,
            "port": args.s3_port,
            "region": args.s3_region,
            "ca_pem": validate_ca(args.s3_ca_file, args.s3_host),
        },
        "gpg": {
            "recipient": fingerprint,
            "public_key": validate_gpg_recipient(fingerprint),
        },
        "bootstrap": {
            "access_key": f"BKP01BOOT{secrets.token_hex(8).upper()}",
            "secret_key": secrets.token_urlsafe(48),
        },
        "backup": {
            "access_key": f"BKP01BACKUP{secrets.token_hex(8).upper()}",
            "secret_key": secrets.token_urlsafe(48),
        },
    }
    os.umask(0o177)
    write_exclusive(args.output, payload)
    print(f"BKP-01 입력 생성 완료: {args.output} (mode 0600, 값 미출력)")


if __name__ == "__main__":
    main()
