#!/usr/bin/env python3
"""BOARD-DEMO-01의 새 Pomerium route와 database health만 검증한다."""

import argparse
import importlib.util
import json
from pathlib import Path
import urllib.parse


BOARD_URL = "https://board.imcherry5778.xyz/health"
BOARD_HOST = "board.imcherry5778.xyz"


def load_browser(repo_root: Path):
    module_path = repo_root / "gitops/tools/pom-01/browser-session.py"
    spec = importlib.util.spec_from_file_location("board_demo_browser", module_path)
    if not spec or not spec.loader:
        raise RuntimeError("POM-01 browser verifier를 불러올 수 없다")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.EXPECTED_HOSTS = set(module.EXPECTED_HOSTS) | {BOARD_HOST}
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--connect-ip", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    args = parser.parse_args()

    browser = load_browser(args.repo_root)
    cookie_jar = browser.http.cookiejar.CookieJar()
    opener = browser.build_opener(cookie_jar, args.connect_ip)
    status, final_url, body = browser.login(
        opener, BOARD_URL, args.username, args.password_file, args.totp_file
    )
    if status != 200 or final_url != BOARD_URL:
        actual = urllib.parse.urlsplit(final_url)
        raise RuntimeError(
            f"board Pomerium route expected HTTP 200 at {BOARD_HOST}/health, "
            f"got HTTP {status} at {actual.hostname}{actual.path}"
        )
    if json.loads(body) != {"status": "ok", "db": "ok"}:
        raise RuntimeError("board health 응답이 PostgreSQL ready 상태가 아니다")
    print("BOARD-DEMO-01 Pomerium /platform-users route와 DB health 통과")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # 이 verifier가 만드는 오류는 host/path·HTTP 상태 또는 고정 health 문구만 담는다.
        # login form/body, cookie, password, TOTP와 Vault 값을 출력하지 않는다.
        print(
            f"BOARD-DEMO-01 route failed: {type(error).__name__}: {error}",
            flush=True,
        )
        raise SystemExit(1)
