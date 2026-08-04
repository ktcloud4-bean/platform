#!/usr/bin/env python3
"""SOAR-DASH-01 Pomerium 브라우저 세션과 Shuffle 자체 admin 로그인을 비밀 없이 검증한다."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


SHUFFLE_URL = "https://shuffle.imcherry5778.xyz"
SHUFFLE_HOSTS = {"shuffle.imcherry5778.xyz"}
CURRENT_STAGE = "initialization"


class VerificationHTTPError(RuntimeError):
    pass


def load_pomerium_browser(repo_root: Path):
    module_path = repo_root / "gitops/tools/pom-01/browser-session.py"
    spec = importlib.util.spec_from_file_location("soar_dash_01_pomerium_browser", module_path)
    if not spec or not spec.loader:
        raise RuntimeError("POM-01 browser verifier를 불러올 수 없다")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.EXPECTED_HOSTS = set(module.EXPECTED_HOSTS) | SHUFFLE_HOSTS
    return module


def require_secret_file(path: Path):
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise RuntimeError(f"secret input is not a mode 0600 regular file: {path.name}")


def request(opener, url: str, *, method="GET", payload=None, headers=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request_headers = dict(headers or {})
    if payload is not None:
        request_headers["Content-Type"] = "application/json"
    http_request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
    try:
        with opener.open(http_request, timeout=30) as response:
            return response.status, response.geturl(), response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.geturl(), error.read()


def expect_status(opener, url: str, expected: int, label: str):
    status, final_url, body = request(opener, url)
    if status != expected or final_url != url:
        raise RuntimeError(f"{label} expected HTTP {expected}, got {status} at {final_url}")
    return body


def login(
    browser,
    connect_ip: str,
    url: str,
    username: str,
    password_file: str,
    totp_file: str,
    *,
    expected_status=200,
):
    cookie_jar = browser.http.cookiejar.CookieJar()
    opener = browser.build_opener(cookie_jar, connect_ip)
    try:
        status, final_url, _ = browser.login(opener, url, username, password_file, totp_file)
    except urllib.error.HTTPError as error:
        parsed = urllib.parse.urlsplit(error.geturl())
        raise VerificationHTTPError(
            f"Pomerium login HTTP {error.code} at {parsed.hostname}{parsed.path}"
        ) from error
    except Exception as error:
        browser_stage = getattr(browser, "CURRENT_STAGE", "unknown")
        raise VerificationHTTPError(
            f"Pomerium login failed at browser stage={browser_stage}, type={type(error).__name__}"
        ) from error
    if status != expected_status or final_url != url:
        expected = urllib.parse.urlsplit(url)
        actual = urllib.parse.urlsplit(final_url)
        raise VerificationHTTPError(
            "Pomerium login expected "
            f"HTTP {expected_status} at {expected.hostname}{expected.path}, got "
            f"HTTP {status} at {actual.hostname}{actual.path}"
        )
    return opener


def shuffle_admin_login(opener, username: str, password_file: Path):
    """Pomerium 통과 뒤 Shuffle 자체 REST API(SHUFFLE_DEFAULT_USERNAME 부트스트랩 계정)에 로그인한다."""
    require_secret_file(password_file)
    password = password_file.read_text(encoding="utf-8").strip()
    global CURRENT_STAGE
    CURRENT_STAGE = "shuffle-admin-login"
    status, final_url, body = request(
        opener,
        f"{SHUFFLE_URL}/api/v1/login",
        method="POST",
        payload={"username": username, "password": password},
    )
    if status != 200:
        raise VerificationHTTPError(
            f"Shuffle admin login expected HTTP 200, got {status} at {final_url}: {body[:200]!r}"
        )
    parsed = json.loads(body)
    if parsed.get("success") is not True:
        raise VerificationHTTPError(f"Shuffle admin login body did not report success: {body[:200]!r}")


def main():
    global CURRENT_STAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--connect-ip", required=True)
    parser.add_argument("--privileged-username", required=True)
    parser.add_argument("--privileged-password-file", required=True)
    parser.add_argument("--privileged-totp-file", required=True)
    parser.add_argument("--deny-username", required=True)
    parser.add_argument("--deny-password-file", required=True)
    parser.add_argument("--deny-totp-file", required=True)
    parser.add_argument("--shuffle-admin-username", required=True)
    parser.add_argument("--shuffle-admin-password-file", required=True, type=Path)
    args = parser.parse_args()
    browser = load_pomerium_browser(args.repo_root)
    for secret_file in (
        args.privileged_password_file,
        args.privileged_totp_file,
        args.deny_password_file,
        args.deny_totp_file,
    ):
        require_secret_file(Path(secret_file))

    CURRENT_STAGE = "platform-privileged-route-session"
    privileged_opener = login(
        browser,
        args.connect_ip,
        f"{SHUFFLE_URL}/",
        args.privileged_username,
        args.privileged_password_file,
        args.privileged_totp_file,
    )

    CURRENT_STAGE = "unaffiliated-route-session"
    deny_opener = login(
        browser,
        args.connect_ip,
        f"{SHUFFLE_URL}/",
        args.deny_username,
        args.deny_password_file,
        args.deny_totp_file,
        expected_status=403,
    )
    expect_status(deny_opener, f"{SHUFFLE_URL}/", 403, "Shuffle frontend unaffiliated")

    shuffle_admin_login(privileged_opener, args.shuffle_admin_username, args.shuffle_admin_password_file)

    CURRENT_STAGE = "complete"
    print(
        "SOAR-DASH-01 browser: platform-privileged=allow, unaffiliated=deny, "
        f"Shuffle admin login({args.shuffle_admin_username})=success"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        detail = str(error) if isinstance(error, (VerificationHTTPError, RuntimeError)) else ""
        print(
            f"SOAR-DASH-01 browser failed: stage={CURRENT_STAGE}, type={type(error).__name__}, "
            f"status={status} {detail}",
            file=sys.stderr,
        )
        raise SystemExit(1)
