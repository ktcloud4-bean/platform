#!/usr/bin/env python3
"""REG-01 사람 입력의 유일한 파일을 새로 만든다. 기존 파일은 덮어쓰지 않는다."""

from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import secrets
import subprocess


def token_hex(characters: int) -> str:
    return secrets.token_hex(characters // 2)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output
    if output.exists() or output.is_symlink():
        raise SystemExit(f"기존 경로를 덮어쓰지 않습니다: {output}")
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(output.parent, 0o700)

    registry_password = token_hex(32)
    htpasswd = subprocess.run(
        ["htpasswd", "-niB", "harbor_registry_user"],
        input=registry_password + "\n",
        text=True,
        check=True,
        capture_output=True,
    ).stdout.strip()
    token_key = subprocess.run(
        ["openssl", "genrsa", "-traditional", "4096"],
        check=True,
        capture_output=True,
    ).stdout
    values = {
        "HARBOR_DB_PASSWORD": token_hex(48),
        "HARBOR_ADMIN_PASSWORD": token_hex(32),
        "HARBOR_CORE_SECRET": token_hex(16),
        "HARBOR_JOBSERVICE_SECRET": token_hex(16),
        "HARBOR_REGISTRY_HTTP_SECRET": token_hex(16),
        "HARBOR_REGISTRY_PASSWORD": registry_password,
        "HARBOR_REGISTRY_HTPASSWD_B64": base64.b64encode(htpasswd.encode()).decode(),
        "HARBOR_CSRF_KEY": token_hex(32),
        "HARBOR_SECRET_KEY": token_hex(16),
        "HARBOR_TOKEN_PRIVATE_KEY_B64": base64.b64encode(token_key).decode(),
        "HARBOR_S3_ACCESS_KEY": "REG01" + token_hex(16).upper(),
        "HARBOR_S3_SECRET_KEY": token_hex(48),
        "HARBOR_S3_BOOTSTRAP_ACCESS_KEY": "REG01BOOT" + token_hex(12).upper(),
        "HARBOR_S3_BOOTSTRAP_SECRET_KEY": token_hex(48),
    }

    os.umask(0o177)
    descriptor = os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")
    print(f"생성 완료: {output} (mode 0600, 값 미출력)")


if __name__ == "__main__":
    main()
