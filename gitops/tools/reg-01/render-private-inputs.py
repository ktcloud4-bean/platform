#!/usr/bin/env python3
"""REG-01 env를 Vault/Ansible용 일시 JSON으로 렌더한다."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import stat
import subprocess


REQUIRED = {
    "HARBOR_DB_PASSWORD",
    "HARBOR_ADMIN_PASSWORD",
    "HARBOR_CORE_SECRET",
    "HARBOR_JOBSERVICE_SECRET",
    "HARBOR_REGISTRY_HTTP_SECRET",
    "HARBOR_REGISTRY_PASSWORD",
    "HARBOR_REGISTRY_HTPASSWD_B64",
    "HARBOR_CSRF_KEY",
    "HARBOR_SECRET_KEY",
    "HARBOR_TOKEN_PRIVATE_KEY_B64",
    "HARBOR_S3_ACCESS_KEY",
    "HARBOR_S3_SECRET_KEY",
    "HARBOR_S3_BOOTSTRAP_ACCESS_KEY",
    "HARBOR_S3_BOOTSTRAP_SECRET_KEY",
}


def load_env(path: Path) -> dict[str, str]:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise SystemExit("REG-01 env는 symlink가 아닌 일반 파일이어야 한다")
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("REG-01 env는 호출자 소유 mode 0600이어야 한다")
    values: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"REG-01 env {number}행 형식 오류")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"HARBOR_[A-Z0-9_]+", key) or key not in REQUIRED:
            raise SystemExit(f"REG-01 env {number}행의 허용되지 않은 key")
        if key in values or not value:
            raise SystemExit(f"REG-01 env {number}행의 중복 또는 빈 값")
        values[key] = value
    if values.keys() != REQUIRED:
        raise SystemExit(f"REG-01 env key 불일치: missing={sorted(REQUIRED - values.keys())}")
    if len(values["HARBOR_CORE_SECRET"]) != 16 or len(values["HARBOR_JOBSERVICE_SECRET"]) != 16:
        raise SystemExit("Harbor core/jobservice secret은 정확히 16자여야 한다")
    if len(values["HARBOR_REGISTRY_HTTP_SECRET"]) != 16 or len(values["HARBOR_SECRET_KEY"]) != 16:
        raise SystemExit("Harbor registry/secret key는 정확히 16자여야 한다")
    if len(values["HARBOR_CSRF_KEY"]) != 32:
        raise SystemExit("Harbor CSRF key는 정확히 32자여야 한다")
    return values


def private_json(path: Path, value: object) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream)
        stream.write("\n")


def normalize_rsa_private_key(encoded: str) -> str:
    """Harbor가 요구하는 PKCS#1 PEM으로 바꾸되 RSA 공개키 불변을 확인한다."""
    try:
        source = base64.b64decode(encoded, validate=True)
        normalized = subprocess.run(
            ["openssl", "pkey", "-traditional"],
            input=source,
            check=True,
            capture_output=True,
        ).stdout
        source_public = subprocess.run(
            ["openssl", "pkey", "-pubout"],
            input=source,
            check=True,
            capture_output=True,
        ).stdout
        normalized_public = subprocess.run(
            ["openssl", "pkey", "-pubout"],
            input=normalized,
            check=True,
            capture_output=True,
        ).stdout
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit("Harbor token RSA private key 형식이 유효하지 않다") from error
    if source_public != normalized_public:
        raise SystemExit("Harbor token RSA PEM 정규화에서 공개키가 바뀌었다")
    if not normalized.startswith(b"-----BEGIN RSA PRIVATE KEY-----\n"):
        raise SystemExit("Harbor token key가 PKCS#1 PEM으로 정규화되지 않았다")
    return normalized.decode()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    values = load_env(args.env_file)
    args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.umask(0o177)
    runtime = {
        "core_secret": values["HARBOR_CORE_SECRET"],
        "jobservice_secret": values["HARBOR_JOBSERVICE_SECRET"],
        "admin_password": values["HARBOR_ADMIN_PASSWORD"],
        "db_password": values["HARBOR_DB_PASSWORD"],
        "registry_http_secret": values["HARBOR_REGISTRY_HTTP_SECRET"],
        "registry_password": values["HARBOR_REGISTRY_PASSWORD"],
        "registry_htpasswd": base64.b64decode(
            values["HARBOR_REGISTRY_HTPASSWD_B64"], validate=True
        ).decode(),
        "csrf_key": values["HARBOR_CSRF_KEY"],
        "secret_key": values["HARBOR_SECRET_KEY"],
        "token_private_key": normalize_rsa_private_key(
            values["HARBOR_TOKEN_PRIVATE_KEY_B64"]
        ),
        "s3_access_key": values["HARBOR_S3_ACCESS_KEY"],
        "s3_secret_key": values["HARBOR_S3_SECRET_KEY"],
    }
    s3 = {
        "harbor_s3_bucket": "harbor-registry",
        "harbor_s3_access_key": values["HARBOR_S3_ACCESS_KEY"],
        "harbor_s3_secret_key": values["HARBOR_S3_SECRET_KEY"],
        "harbor_s3_bootstrap_access_key": values["HARBOR_S3_BOOTSTRAP_ACCESS_KEY"],
        "harbor_s3_bootstrap_secret_key": values["HARBOR_S3_BOOTSTRAP_SECRET_KEY"],
    }
    private_json(args.output_dir / "vault-runtime.json", runtime)
    private_json(args.output_dir / "postgres-vars.json", {"pg_harbor_password": values["HARBOR_DB_PASSWORD"]})
    private_json(args.output_dir / "s3-vars.json", s3)
    print("REG-01 일시 입력 3개 생성 완료 (값 미출력)")


if __name__ == "__main__":
    main()
