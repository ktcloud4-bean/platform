#!/usr/bin/env python3
"""WAZUH-02-FIX-02 browser proof for the native Keycloak OIDC selection UI.

The verifier uses only the privileged Keycloak protected inputs. It first reaches
the Wazuh login selector through Pomerium, asserts the native multi-auth mode,
chooses the same OIDC endpoint the Keycloak button uses, and then checks the
already-stored Wazuh records and Server API connection.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import importlib.util
import json
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


WAZUH_URL = "https://wazuh.imcherry5778.xyz"
START_URL = f"{WAZUH_URL}/app/wz-home"
D30_INDEX_PATTERN = "wazuh-alerts-4.x-*"
A90_INDEX_PATTERN = "wazuh-alerts-4.x-audit-*"
REPRESENTATIVE_SID = "2029054"
CURRENT_STAGE = "initialization"


def require_secret_file(path: Path) -> None:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise RuntimeError(f"secret input is not a mode 0600 regular file: {path.name}")


def load_pomerium_browser(repo_root: Path):
    module_path = repo_root / "gitops/tools/pom-01/browser-session.py"
    spec = importlib.util.spec_from_file_location("wazuh02fix02_pomerium_browser", module_path)
    if not spec or not spec.loader:
        raise RuntimeError("POM-01 browser verifier를 불러올 수 없다")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.EXPECTED_HOSTS = set(module.EXPECTED_HOSTS) | {"wazuh.imcherry5778.xyz"}
    return module


def request(opener, url: str, *, method: str = "GET", payload=None, headers=None):
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


def require_wazuh_response(status: int, final_url: str, body: bytes, stage: str):
    if status != 200 or urllib.parse.urlsplit(final_url).hostname != "wazuh.imcherry5778.xyz":
        raise RuntimeError(f"{stage} failed: HTTP {status}")
    try:
        decoded = json.loads(body)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{stage} returned non-JSON") from error
    return decoded


def console_search(opener, index_pattern: str, query_string: str) -> dict:
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
    return require_wazuh_response(status, final_url, body, "Dashboard OIDC query")


def first_host_id(value) -> str | None:
    if isinstance(value, dict):
        value_id = value.get("id")
        if isinstance(value_id, str) and value_id:
            return value_id
        for child in value.values():
            found = first_host_id(child)
            if found:
                return found
    if isinstance(value, list):
        for child in value:
            found = first_host_id(child)
            if found:
                return found
    return None


def main() -> None:
    global CURRENT_STAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--connect-ip", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", type=Path, required=True)
    parser.add_argument("--totp-file", type=Path, required=True)
    args = parser.parse_args()
    require_secret_file(args.password_file)
    require_secret_file(args.totp_file)

    browser = load_pomerium_browser(args.repo_root)
    cookie_jar = http.cookiejar.CookieJar()
    opener = browser.build_opener(cookie_jar, args.connect_ip)

    CURRENT_STAGE = "pomerium-entry"
    status, final_url, _ = browser.login(
        opener,
        START_URL,
        args.username,
        str(args.password_file),
        str(args.totp_file),
    )
    if status != 200 or urllib.parse.urlsplit(final_url).hostname != "wazuh.imcherry5778.xyz":
        raise RuntimeError(f"Pomerium entry did not return its Wazuh route: HTTP {status}")

    CURRENT_STAGE = "oauth-selector"
    status, final_url, body = request(opener, f"{WAZUH_URL}/api/authtype")
    auth_type = require_wazuh_response(status, final_url, body, "native OAuth selector")
    if auth_type.get("authtype") != ["basicauth", "openid"]:
        raise RuntimeError("native OAuth selector does not offer basicauth and openid")

    # This is the native selector's Keycloak OIDC action, not an unsolicited
    # automatic redirect. Keycloak may reuse the Pomerium-created IdP session.
    CURRENT_STAGE = "keycloak-button"
    native_oidc_query = urllib.parse.urlencode(
        {"redirectHash": "false", "nextUrl": "/app/wz-home"}
    )
    status, final_url, _ = request(
        opener, f"{WAZUH_URL}/auth/openid/login?{native_oidc_query}"
    )
    final = urllib.parse.urlsplit(final_url)
    if status != 200 or final.hostname != "wazuh.imcherry5778.xyz" or final.path != "/app/wz-home":
        raise RuntimeError(f"Keycloak button did not return its Wazuh route: HTTP {status}")

    d30 = console_search(
        opener, D30_INDEX_PATTERN, f"data.alert.signature_id:{REPRESENTATIVE_SID}*"
    )
    if not d30.get("hits", {}).get("hits"):
        raise RuntimeError(f"D30 index lacks existing sid {REPRESENTATIVE_SID} through OIDC session")
    a90 = console_search(opener, A90_INDEX_PATTERN, "rule.id:[100100 TO 100109]")
    if not a90.get("hits", {}).get("hits"):
        raise RuntimeError("A90 index lacks existing audit event through OIDC session")

    CURRENT_STAGE = "server-api"
    status, final_url, body = request(opener, f"{WAZUH_URL}/hosts/apis")
    hosts = require_wazuh_response(status, final_url, body, "Server API entry lookup")
    host_id = first_host_id(hosts)
    if not host_id:
        raise RuntimeError("Server API entry has no id")
    status, final_url, body = request(
        opener,
        f"{WAZUH_URL}/api/check-api",
        method="POST",
        payload={"id": host_id, "forceRefresh": True},
        headers={"osd-xsrf": "true"},
    )
    require_wazuh_response(status, final_url, body, "Server API check")

    CURRENT_STAGE = "complete"
    print(
        "WAZUH-02-FIX-02 browser=PASS selector=basicauth+openid "
        "keycloak-button=allow D30/A90=found server-api=online"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(
            f"WAZUH-02-FIX-02 browser=FAIL stage={CURRENT_STAGE} "
            f"type={type(error).__name__} detail={error}",
            file=sys.stderr,
        )
        raise SystemExit(1)
