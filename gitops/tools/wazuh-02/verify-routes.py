#!/usr/bin/env python3
"""WAZUH-02 Pomerium browser 세션과 Dashboard의 D30·A90 검색을 비밀 없이 검증한다."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


WAZUH_URL = "https://wazuh.imcherry5778.xyz"
WAZUH_HOSTS = {"wazuh.imcherry5778.xyz"}
REPRESENTATIVE_SID = "2029054"
D30_INDEX_PATTERN = "wazuh-alerts-4.x-*"
A90_INDEX_PATTERN = "wazuh-alerts-4.x-audit-*"
CURRENT_STAGE = "initialization"


class VerificationHTTPError(RuntimeError):
    pass


def load_pomerium_browser(repo_root: Path):
    module_path = repo_root / "gitops/tools/pom-01/browser-session.py"
    spec = importlib.util.spec_from_file_location("wazuh02_pomerium_browser", module_path)
    if not spec or not spec.loader:
        raise RuntimeError("POM-01 browser verifier를 불러올 수 없다")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.EXPECTED_HOSTS = set(module.EXPECTED_HOSTS) | WAZUH_HOSTS
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


def expect_status(opener, url: str, expected: int, label: str, *, headers=None):
    status, final_url, body = request(opener, url, headers=headers)
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


def dashboard_login(opener, password_file: Path):
    """Pomerium 통과 뒤 OpenSearch Dashboards 자체 보안(admin 계정)에 로그인한다."""
    require_secret_file(password_file)
    password = password_file.read_text(encoding="utf-8").strip()
    global CURRENT_STAGE
    CURRENT_STAGE = "dashboard-security-login"
    status, final_url, body = request(
        opener,
        f"{WAZUH_URL}/auth/login",
        method="POST",
        payload={"username": "admin", "password": password},
        headers={"osd-xsrf": "true"},
    )
    if status != 200:
        raise VerificationHTTPError(
            f"Dashboard security login expected HTTP 200, got {status} at {final_url}: {body[:200]!r}"
        )


def console_search(opener, index_pattern: str, query_string: str):
    global CURRENT_STAGE
    CURRENT_STAGE = f"discover-search:{index_pattern}"
    encoded = urllib.parse.urlencode({"path": f"{index_pattern}/_search", "method": "GET"})
    status, final_url, body = request(
        opener,
        f"{WAZUH_URL}/api/console/proxy?{encoded}",
        method="POST",
        payload={"query": {"query_string": {"query": query_string}}, "size": 1},
        headers={"osd-xsrf": "true"},
    )
    if status != 200:
        raise VerificationHTTPError(
            f"Discover search on {index_pattern} expected HTTP 200, got {status} at {final_url}: {body[:200]!r}"
        )
    return json.loads(body)


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
    parser.add_argument("--dashboard-password-file", required=True, type=Path)
    args = parser.parse_args()
    browser = load_pomerium_browser(args.repo_root)
    for secret_file in (
        args.privileged_password_file,
        args.privileged_totp_file,
        args.deny_password_file,
        args.deny_totp_file,
    ):
        require_secret_file(Path(secret_file))

    # `/app/login`은 OpenSearch Dashboards 자체 인증 없이도 응답하는 정적 로그인 페이지라
    # Pomerium Route 통과 여부만 판정하는 probe로 쓴다. `/api/status`는 Dashboard 자체
    # 보안 플러그인이 세션 없이 401을 반환해 Pomerium 통과 여부와 구분할 수 없었다.
    CURRENT_STAGE = "platform-privileged-route-session"
    privileged_opener = login(
        browser,
        args.connect_ip,
        f"{WAZUH_URL}/app/login",
        args.privileged_username,
        args.privileged_password_file,
        args.privileged_totp_file,
    )

    CURRENT_STAGE = "unaffiliated-route-session"
    deny_opener = login(
        browser,
        args.connect_ip,
        f"{WAZUH_URL}/app/login",
        args.deny_username,
        args.deny_password_file,
        args.deny_totp_file,
        expected_status=403,
    )
    expect_status(deny_opener, f"{WAZUH_URL}/", 403, "Wazuh Dashboard unaffiliated")

    dashboard_login(privileged_opener, args.dashboard_password_file)

    d30 = console_search(
        privileged_opener, D30_INDEX_PATTERN, f"data.alert.signature_id:{REPRESENTATIVE_SID}*"
    )
    if not d30.get("hits", {}).get("hits"):
        raise RuntimeError(
            f"D30 index에서 sid {REPRESENTATIVE_SID} 대표 event를 Dashboard로 찾지 못했다"
        )
    a90 = console_search(privileged_opener, A90_INDEX_PATTERN, "rule.id:[100100 TO 100109]")
    if not a90.get("hits", {}).get("hits"):
        raise RuntimeError("A90 index에서 audit rule 범위 문서를 Dashboard로 찾지 못했다")

    CURRENT_STAGE = "complete"
    print(
        "WAZUH-02 browser: platform-privileged=allow, unaffiliated=deny, "
        f"D30 sid={REPRESENTATIVE_SID} found, A90 rule.id[100100-100109] found"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        detail = str(error) if isinstance(error, (VerificationHTTPError, RuntimeError)) else ""
        print(
            f"WAZUH-02 browser failed: stage={CURRENT_STAGE}, type={type(error).__name__}, "
            f"status={status} {detail}",
            file=sys.stderr,
        )
        raise SystemExit(1)
