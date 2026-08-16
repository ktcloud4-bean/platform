#!/usr/bin/env python3
"""DEMO-AWS-HR-01의 합성 employee 포털 read-only 200만 확인한다."""

from __future__ import annotations

import argparse
import http.cookiejar
import importlib.util
import json
import stat
import sys
from pathlib import Path


WWW_URL = "https://www.imcherry5778.xyz"
SYNTHETIC_USERNAME = "quality-06-employee"


class SafeError(RuntimeError):
    pass


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location("demo_aws_hr_browser", path)
    if spec is None or spec.loader is None:
        raise SafeError("browser helper load failed")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_private(path: Path) -> Path:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink() or metadata.st_mode & 0o077:
        raise SafeError(f"secret input must be a mode 0600 regular file: {path.name}")
    if not path.read_text(encoding="utf-8").strip():
        raise SafeError(f"secret input is empty: {path.name}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--secret-dir", type=Path, required=True)
    parser.add_argument("--connect-ip", default="10.10.20.10")
    args = parser.parse_args()

    secret_dir = args.secret_dir
    directory = secret_dir.lstat()
    if not stat.S_ISDIR(directory.st_mode) or secret_dir.is_symlink() or directory.st_mode & 0o077:
        raise SafeError("synthetic secret directory must be a mode 0700 directory")
    password_file = require_private(secret_dir / "quality-06-employee-password")
    totp_file = require_private(secret_dir / "quality-06-employee-totp")

    repo_root = Path(__file__).resolve().parents[3]
    browser = load_module(repo_root / "gitops/tools/pom-01/browser-session.py")
    browser.EXPECTED_HOSTS.update({"www.imcherry5778.xyz", "admin.imcherry5778.xyz"})
    jar = http.cookiejar.CookieJar()
    opener = browser.build_opener(jar, args.connect_ip)
    status, final_url, _ = browser.login(
        opener, f"{WWW_URL}/", SYNTHETIC_USERNAME, str(password_file), str(totp_file)
    )
    if status != 200 or final_url != f"{WWW_URL}/":
        raise SafeError(f"synthetic employee portal login failed: HTTP {status}")

    history_status, _, _, history_body = browser.get_response(
        opener, f"{WWW_URL}/api/employee/me/history"
    )
    if history_status != 200:
        raise SafeError(f"synthetic employee read-only history failed: HTTP {history_status}")
    if not isinstance(json.loads(history_body), list):
        raise SafeError("synthetic employee history response is not a list")
    print("DEMO_AWS_HR_PORTAL=PASS identity=synthetic read_only=200")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"DEMO_AWS_HR_PORTAL=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1)
