#!/usr/bin/env python3
"""WAZUH-02-FIX-01 Indexer native OIDC security configuration synchronizer.

The OpenSearch Security configuration is stored in the Indexer security index,
not in a mounted config file.  This script first reads the live single config
document, rejects an unexpected shape, and writes a one-type securityadmin
input that preserves every unrelated authentication domain.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from copy import deepcopy
from pathlib import Path


MODE = os.environ.get("WAZUH_OIDC_MODE", "apply")
if MODE not in {"apply", "rollback"}:
    raise SystemExit("WAZUH_OIDC_MODE must be apply or rollback")

WORK = Path("/work")
RENDERED = WORK / "securityconfig.json"
RENDERED_READY = WORK / "rendered"
SECURITYADMIN_DONE = WORK / "securityadmin.done"
BASE_URL = "https://indexer.wazuh.svc.cluster.local:9200"
SECURITY_CONFIG_PATH = "/_plugins/_security/api/securityconfig"
ROLE_MAPPING_PATH = "/_plugins/_security/api/rolesmapping/all_access"
EXPECTED_ISSUER = "https://sso.imcherry5778.xyz/realms/platform"
EXPECTED_DISCOVERY = f"{EXPECTED_ISSUER}/.well-known/openid-configuration"
EXPECTED_OIDC_DOMAIN = {
    "http_enabled": True,
    "transport_enabled": False,
    "order": 1,
    "http_authenticator": {
        "type": "openid",
        "challenge": False,
        "config": {
            "subject_key": "preferred_username",
            "roles_key": "wazuh_roles",
            "openid_connect_url": EXPECTED_DISCOVERY,
            "required_audience": "wazuh",
        },
    },
    "authentication_backend": {"type": "noop"},
}


def fail(message: str) -> None:
    raise RuntimeError(message)


def tls_context() -> ssl.SSLContext:
    context = ssl.create_default_context(cafile="/vault/secrets/root-ca.pem")
    context.load_cert_chain(
        certfile="/vault/secrets/admin.pem",
        keyfile="/vault/secrets/admin-key.pem",
    )
    return context


def api_request(path: str, method: str = "GET", payload: object | None = None) -> object:
    body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
    request = urllib.request.Request(
        f"{BASE_URL}{path}", data=body, method=method,
        headers={} if body is None else {"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, context=tls_context(), timeout=20) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        fail(f"Indexer Security API {method} {path} returned HTTP {error.code}")
    except urllib.error.URLError as error:
        fail(f"Indexer Security API {method} {path} transport failed: {error.reason}")
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        fail(f"Indexer Security API {method} {path} returned non-JSON: {error.msg}")


def normalized_oidc_domain(value: object) -> object:
    """Normalize OpenSearch Security REST defaults before a bounded comparison."""
    if not isinstance(value, dict):
        return value
    normalized = deepcopy(value)
    normalized.setdefault("transport_enabled", False)
    backend = normalized.get("authentication_backend")
    if isinstance(backend, dict):
        backend.setdefault("config", {})
    return normalized


def exact_oidc_domain(value: object) -> bool:
    return normalized_oidc_domain(value) == normalized_oidc_domain(EXPECTED_OIDC_DOMAIN)


def load_security_config() -> dict[str, object]:
    document = api_request(SECURITY_CONFIG_PATH)
    if not isinstance(document, dict):
        fail("securityconfig response is not an object")
    config = document.get("config")
    if not isinstance(config, dict):
        fail("securityconfig.config is absent")
    dynamic = config.get("dynamic")
    if not isinstance(dynamic, dict):
        fail("securityconfig.config.dynamic is absent")
    authc = dynamic.get("authc")
    if not isinstance(authc, dict):
        fail("securityconfig.config.dynamic.authc is absent")
    basic = authc.get("basic_internal_auth_domain")
    if not isinstance(basic, dict):
        fail("basic_internal_auth_domain is absent")
    authenticator = basic.get("http_authenticator")
    backend = basic.get("authentication_backend")
    if not isinstance(authenticator, dict) or not isinstance(backend, dict):
        fail("basic_internal_auth_domain has unexpected structure")
    if authenticator.get("type") != "basic" or backend.get("type") != "intern":
        fail("basic_internal_auth_domain is not the expected internal-basic domain")
    if authenticator.get("challenge") not in {True, False}:
        fail("basic_internal_auth_domain.challenge is not boolean")
    return document


def render_security_config() -> None:
    document = load_security_config()
    config = deepcopy(document["config"])
    assert isinstance(config, dict)
    # The Security REST API omits `_meta`, while the actual on-disk config.yml
    # in Wazuh 4.14.7 declares this fixed type/version. Preserve metadata if a
    # future API returns it; otherwise provide only that verified file contract.
    metadata = config.pop("_meta", {"type": "config", "config_version": 2})
    if not isinstance(metadata, dict) or metadata.get("type") != "config" or metadata.get("config_version") != 2:
        fail("securityconfig metadata is not the expected config v2 contract")
    dynamic = config["dynamic"]
    assert isinstance(dynamic, dict)
    authc = dynamic["authc"]
    assert isinstance(authc, dict)
    basic = authc["basic_internal_auth_domain"]
    assert isinstance(basic, dict)
    basic_authenticator = basic["http_authenticator"]
    assert isinstance(basic_authenticator, dict)

    existing = authc.get("openid_auth_domain")
    if existing is not None and not exact_oidc_domain(existing):
        fail("openid_auth_domain exists but does not match the WAZUH-02-FIX-01 declaration")
    other_order_one = [
        name for name, domain in authc.items()
        if name != "openid_auth_domain" and isinstance(domain, dict) and domain.get("order") == 1
    ]
    if other_order_one:
        fail("OIDC auth domain order 1 is already owned by " + ",".join(sorted(other_order_one)))

    if MODE == "apply":
        authc["openid_auth_domain"] = deepcopy(EXPECTED_OIDC_DOMAIN)
    else:
        if existing is not None:
            del authc["openid_auth_domain"]

    # REST returns {"config": {"_meta": ..., "dynamic": ...}}, whereas
    # securityadmin -t config accepts the on-disk config.yml shape with `_meta`
    # at its root.  Do not pass the REST envelope straight through.
    securityadmin_document = {"_meta": metadata, "config": config}
    WORK.mkdir(mode=0o770, exist_ok=True)
    temporary = WORK / "securityconfig.json.tmp"
    temporary.write_text(json.dumps(securityadmin_document, sort_keys=True, separators=(",", ":")) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(RENDERED)
    os.chmod(RENDERED, 0o640)
    RENDERED_READY.touch(mode=0o600, exist_ok=True)
    print(f"WazuhOidcSecurity=RENDERED mode={MODE}")


def wait_for_securityadmin() -> None:
    for _ in range(120):
        if SECURITYADMIN_DONE.exists():
            return
        time.sleep(1)
    fail("securityadmin completion marker timed out")


def update_role_mapping() -> None:
    wait_for_securityadmin()
    response = api_request(ROLE_MAPPING_PATH)
    if not isinstance(response, dict) or not isinstance(response.get("all_access"), dict):
        fail("all_access role mapping is absent")
    mapping = deepcopy(response["all_access"])
    assert isinstance(mapping, dict)
    backend_roles = mapping.get("backend_roles")
    if not isinstance(backend_roles, list) or not all(isinstance(item, str) for item in backend_roles):
        fail("all_access.backend_roles is not a string list")
    if "admin" not in backend_roles:
        fail("all_access.backend_roles no longer contains the existing admin role")

    wanted = sorted(set(backend_roles) | {"wazuh-admin"})
    if MODE == "rollback":
        wanted = [item for item in wanted if item != "wazuh-admin"]
    if wanted != backend_roles:
        mapping["backend_roles"] = wanted
        api_request(ROLE_MAPPING_PATH, method="PUT", payload=mapping)

    verified = api_request(ROLE_MAPPING_PATH)
    if not isinstance(verified, dict) or not isinstance(verified.get("all_access"), dict):
        fail("all_access role mapping verification failed")
    result_roles = verified["all_access"].get("backend_roles")
    if result_roles != wanted:
        fail("all_access role mapping differs after update")
    print(f"WazuhOidcRoleMapping=PASS mode={MODE} role=wazuh-admin")


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"render", "role-mapping"}:
        raise SystemExit("usage: sync-oidc-security.py render|role-mapping")
    if sys.argv[1] == "render":
        render_security_config()
    else:
        update_role_mapping()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # failure text is intentionally metadata-only
        print(f"WazuhOidcSecurity=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1)
