#!/usr/bin/env python3
"""WAZUH-02-FIX-03 browser proof for the Dashboard scoped Manager API token."""

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
CURRENT_STAGE = "initialization"


def require_secret_file(path: Path) -> None:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise RuntimeError(f"secret input is not a mode 0600 regular file: {path.name}")


def load_pomerium_browser(repo_root: Path):
    module_path = repo_root / "gitops/tools/pom-01/browser-session.py"
    spec = importlib.util.spec_from_file_location("wazuh02fix03_pomerium_browser", module_path)
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


def request_status_only(opener, url: str, *, payload: dict, headers: dict):
    http_request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers | {"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with opener.open(http_request, timeout=30) as response:
            return response.status, response.geturl()
    except urllib.error.HTTPError as error:
        return error.code, error.geturl()


def find_host(value):
    if isinstance(value, dict):
        if isinstance(value.get("id"), str) and value["id"]:
            return value
        for child in value.values():
            found = find_host(child)
            if found:
                return found
    if isinstance(value, list):
        for child in value:
            found = find_host(child)
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
    opener = browser.build_opener(http.cookiejar.CookieJar(), args.connect_ip)

    CURRENT_STAGE = "pomerium-entry"
    status, final_url, _ = browser.login(
        opener, START_URL, args.username, str(args.password_file), str(args.totp_file)
    )
    if status != 200 or urllib.parse.urlsplit(final_url).hostname != "wazuh.imcherry5778.xyz":
        raise RuntimeError(f"Pomerium entry failed: HTTP {status}")

    CURRENT_STAGE = "keycloak-oidc"
    status, final_url, _ = request(
        opener,
        f"{WAZUH_URL}/auth/openid/login?{urllib.parse.urlencode({'redirectHash': 'false', 'nextUrl': '/app/wz-home'})}",
    )
    final = urllib.parse.urlsplit(final_url)
    if status != 200 or final.hostname != "wazuh.imcherry5778.xyz" or final.path != "/app/wz-home":
        raise RuntimeError(f"Keycloak OIDC did not return Wazuh: HTTP {status}")

    CURRENT_STAGE = "server-api-host"
    status, final_url, body = request(opener, f"{WAZUH_URL}/hosts/apis")
    if status != 200 or urllib.parse.urlsplit(final_url).hostname != "wazuh.imcherry5778.xyz":
        raise RuntimeError(f"Server API host lookup failed: HTTP {status}")
    host = find_host(json.loads(body))
    if not host or host.get("run_as") is not False:
        raise RuntimeError("Server API host run_as is not false")

    # This endpoint uses ServerAPIClient.asScoped.authenticate(). It is the
    # same token path behind the Overview API-version check. Do not read its
    # response because it contains a short-lived token.
    CURRENT_STAGE = "scoped-manager-token"
    status, final_url = request_status_only(
        opener,
        f"{WAZUH_URL}/api/login",
        payload={"idHost": host["id"], "force": True},
        headers={"osd-xsrf": "true"},
    )
    if status != 200 or urllib.parse.urlsplit(final_url).hostname != "wazuh.imcherry5778.xyz":
        raise RuntimeError(f"scoped Manager API token failed: HTTP {status}")

    CURRENT_STAGE = "complete"
    print("WAZUH-02-FIX-03 browser=PASS run_as=false scoped-manager-token=issued")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(
            f"WAZUH-02-FIX-03 browser=FAIL stage={CURRENT_STAGE} "
            f"type={type(error).__name__} detail={error}",
            file=sys.stderr,
        )
        raise SystemExit(1)
