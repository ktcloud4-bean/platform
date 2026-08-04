#!/usr/bin/env python3
"""NB-02 전용 Keycloak client를 Admin API로 최소 권한 선언에 맞춘다."""

import argparse
import ast
import http.client
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


REALM = "platform"
RECOVERY_REALM = "master"
RECOVERY_CLIENT = "kc-recovery"
RECOVERY_USER = "imcherry-kc-recovery"
STAGE = "initialization"
GROUP_MAPPER = {
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "consentRequired": False,
    "config": {
        "claim.name": "groups",
        "full.path": "true",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
    },
}


class FixedAddressHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, *, fixed_ip: str, expected_host: str, **kwargs):
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host
        super().__init__(host, **kwargs)

    def connect(self):
        if self.host != self.expected_host:
            raise OSError("fixed-address request left the issuer host")
        self.sock = self._create_connection((self.fixed_ip, self.port), self.timeout, self.source_address)
        if self._tunnel_host:
            self._tunnel()
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.expected_host)


class FixedAddressHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, fixed_ip: str, expected_host: str):
        super().__init__()
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host

    def https_open(self, request):
        def connection(host, **kwargs):
            return FixedAddressHTTPSConnection(
                host, fixed_ip=self.fixed_ip, expected_host=self.expected_host, **kwargs
            )

        return self.do_open(connection, request, context=self._context)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser-login-script", required=True)
    parser.add_argument("--issuer-base", required=True)
    parser.add_argument("--connect-ip", required=True)
    parser.add_argument("--recovery-password-file", required=True)
    parser.add_argument("--recovery-totp-file", required=True)
    parser.add_argument("--secret-vars-file", required=True)
    parser.add_argument("--dashboard-url", required=True)
    parser.add_argument("--public-client-id", required=True)
    parser.add_argument("--management-client-id", required=True)
    return parser.parse_args()


def api(opener, issuer_base, bearer, method, path, payload=None):
    url = f"{issuer_base}{path}"
    headers = {"Authorization": bearer}
    data = None
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with opener.open(request, timeout=20) as response:
        raw = response.read()
        return json.loads(raw) if raw else None, response.headers


def client_payload(client_id, dashboard_url, public):
    base = {
        "clientId": client_id,
        "name": "NB-02 NetBird OIDC public client" if public else "NB-02 NetBird management service client",
        "description": "NB-02 전용; NET-04 및 향후 플랫폼 정책에서 재검토",
        "enabled": True,
        "protocol": "openid-connect",
        "publicClient": public,
        "clientAuthenticatorType": "none" if public else "client-secret",
        "standardFlowEnabled": public,
        "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": False,
        "serviceAccountsEnabled": not public,
        "frontchannelLogout": False,
        "fullScopeAllowed": False,
        "attributes": {},
    }
    if public:
        base.update(
            {
                "redirectUris": [
                    f"{dashboard_url}/nb-auth",
                    f"{dashboard_url}/nb-silent-auth",
                    "http://localhost:53000/*",
                ],
                "webOrigins": [dashboard_url],
                "attributes": {
                    "pkce.code.challenge.method": "S256",
                    "oauth2.device.authorization.grant.enabled": "true",
                    "post.logout.redirect.uris": f"{dashboard_url}/*",
                },
            }
        )
    return base


def audience_mapper(client_id):
    return {
        "name": "netbird-audience",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-audience-mapper",
        "consentRequired": False,
        "config": {
            "included.client.audience": client_id,
            "id.token.claim": "false",
            "access.token.claim": "true",
            "userinfo.token.claim": "false",
            "introspection.token.claim": "true",
        },
    }


def find_client(opener, issuer_base, bearer, client_id):
    clients, _ = api(
        opener,
        issuer_base,
        bearer,
        "GET",
        f"/admin/realms/{REALM}/clients?clientId={urllib.parse.quote(client_id)}",
    )
    matches = [client for client in clients if client.get("clientId") == client_id]
    if len(matches) > 1:
        raise RuntimeError(f"duplicate clientId: {client_id}")
    return matches[0] if matches else None


def upsert_client(opener, issuer_base, bearer, desired):
    existing = find_client(opener, issuer_base, bearer, desired["clientId"])
    changed = False
    if existing is None:
        _, headers = api(opener, issuer_base, bearer, "POST", f"/admin/realms/{REALM}/clients", desired)
        location = headers.get("Location", "")
        client_uuid = location.rsplit("/", 1)[-1]
        if not client_uuid:
            raise RuntimeError("created client UUID missing")
        changed = True
    else:
        client_uuid = existing["id"]
        current, _ = api(opener, issuer_base, bearer, "GET", f"/admin/realms/{REALM}/clients/{client_uuid}")
        # Keycloak은 redirectUris/webOrigins의 순서를 보장하지 않는다. 순서 차이로
        # 매 Ansible 실행이 client PUT을 반복하지 않도록 집합으로 비교한다.
        unordered = {"redirectUris", "webOrigins"}
        different = any(
            set(current.get(key, [])) != set(value)
            if key in unordered
            else current.get(key) != value
            for key, value in desired.items()
            if key != "attributes"
        ) or any(current.get("attributes", {}).get(key) != value for key, value in desired["attributes"].items())
        if different:
            merged_attributes = dict(current.get("attributes", {}))
            merged_attributes.update(desired["attributes"])
            current.update(desired)
            current["attributes"] = merged_attributes
            api(opener, issuer_base, bearer, "PUT", f"/admin/realms/{REALM}/clients/{client_uuid}", current)
            changed = True
    return client_uuid, changed


def upsert_mapper(opener, issuer_base, bearer, client_uuid, desired):
    mappers, _ = api(opener, issuer_base, bearer, "GET", f"/admin/realms/{REALM}/clients/{client_uuid}/protocol-mappers/models")
    matching = [mapper for mapper in mappers if mapper.get("name") == desired["name"]]
    if len(matching) > 1:
        raise RuntimeError(f"duplicate protocol mapper: {desired['name']}")
    if not matching:
        api(opener, issuer_base, bearer, "POST", f"/admin/realms/{REALM}/clients/{client_uuid}/protocol-mappers/models", desired)
        return True
    current = matching[0]
    # Keycloak은 mapper에 introspection 같은 기본 config 값을 추가한다. 이
    # 역할이 소유하는 선언값만 비교해 불필요한 PUT을 피하면서, 필요한 claim
    # 값은 계속 강제한다.
    comparable = ("protocol", "protocolMapper", "consentRequired")
    differs = any(current.get(key) != desired[key] for key in comparable) or any(
        current.get("config", {}).get(key) != value for key, value in desired["config"].items()
    )
    if differs:
        current.update(desired)
        api(opener, issuer_base, bearer, "PUT", f"/admin/realms/{REALM}/clients/{client_uuid}/protocol-mappers/models/{current['id']}", current)
        return True
    return False


def ensure_service_roles(opener, issuer_base, bearer, client_uuid):
    realm_management = find_client(opener, issuer_base, bearer, "realm-management")
    if realm_management is None:
        raise RuntimeError("realm-management client missing")
    service_user, _ = api(opener, issuer_base, bearer, "GET", f"/admin/realms/{REALM}/clients/{client_uuid}/service-account-user")
    assigned, _ = api(
        opener, issuer_base, bearer, "GET", f"/admin/realms/{REALM}/users/{service_user['id']}/role-mappings/clients/{realm_management['id']}"
    )
    available, _ = api(
        opener, issuer_base, bearer, "GET", f"/admin/realms/{REALM}/users/{service_user['id']}/role-mappings/clients/{realm_management['id']}/available"
    )
    required = {"view-users", "query-users", "query-groups"}
    present = {role["name"] for role in assigned}
    missing = [role for role in available if role["name"] in required - present]
    changed = False
    if missing:
        api(
            opener,
            issuer_base,
            bearer,
            "POST",
            f"/admin/realms/{REALM}/users/{service_user['id']}/role-mappings/clients/{realm_management['id']}",
            missing,
        )
        changed = True
    if not required <= present:
        # POST 후 현재 표현을 다시 읽어, Keycloak이 거부한 role을 성공으로
        # 오인하지 않는다.
        assigned, _ = api(
            opener,
            issuer_base,
            bearer,
            "GET",
            f"/admin/realms/{REALM}/users/{service_user['id']}/role-mappings/clients/{realm_management['id']}",
        )
        present = {role["name"] for role in assigned}
        if not required <= present:
            raise RuntimeError("required realm-management service-account roles unavailable")

    # fullScopeAllowed=false에서는 service account에 role을 부여한 것만으로
    # client-credentials token에 realm-management role이 포함되지 않는다.
    # 같은 세 role만 client scope mapping에도 명시한다.
    scoped, _ = api(
        opener,
        issuer_base,
        bearer,
        "GET",
        f"/admin/realms/{REALM}/clients/{client_uuid}/scope-mappings/clients/{realm_management['id']}",
    )
    scoped_names = {role["name"] for role in scoped}
    scope_available, _ = api(
        opener,
        issuer_base,
        bearer,
        "GET",
        f"/admin/realms/{REALM}/clients/{client_uuid}/scope-mappings/clients/{realm_management['id']}/available",
    )
    missing_scope = [role for role in scope_available if role["name"] in required - scoped_names]
    if missing_scope:
        api(
            opener,
            issuer_base,
            bearer,
            "POST",
            f"/admin/realms/{REALM}/clients/{client_uuid}/scope-mappings/clients/{realm_management['id']}",
            missing_scope,
        )
        changed = True
    scoped, _ = api(
        opener,
        issuer_base,
        bearer,
        "GET",
        f"/admin/realms/{REALM}/clients/{client_uuid}/scope-mappings/clients/{realm_management['id']}",
    )
    if not required <= {role["name"] for role in scoped}:
        raise RuntimeError("required realm-management client scope roles unavailable")
    return changed


def read_secret_vars(path):
    values = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, value = line.split(":", 1)
        try:
            values[key.strip()] = json.loads(value.strip())
        except json.JSONDecodeError:
            values[key.strip()] = ast.literal_eval(value.strip())
    for key in ("netbird_auth_secret", "netbird_encryption_key"):
        if not isinstance(values.get(key), str) or len(values[key]) < 32:
            raise RuntimeError(f"required external secret missing: {key}")
    return values


def write_secret_vars(path, values):
    target = Path(path)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    content = "".join(f"{key}: {json.dumps(values[key])}\n" for key in sorted(values))
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(content)
    os.chmod(target, 0o600)


def main():
    global STAGE
    args = parse_args()
    issuer = urllib.parse.urlsplit(args.issuer_base)
    if issuer.scheme != "https" or not issuer.hostname:
        raise RuntimeError("issuer base must be an HTTPS URL")
    if ipaddress.ip_address(args.connect_ip).version != 4:
        raise RuntimeError("connect IP must be IPv4")
    for path in (args.browser_login_script, args.recovery_password_file, args.recovery_totp_file, args.secret_vars_file):
        if not Path(path).is_file():
            raise RuntimeError(f"required external file missing: {path}")

    with tempfile.TemporaryDirectory(prefix="nb02-kc-") as temp_dir:
        header_file = Path(temp_dir) / "admin.header"
        # Keycloak은 같은 TOTP code의 재사용을 거부한다. 직전 검증이나 Ansible
        # 재실행과 겹치지 않도록 다음 30초 구간에서만 복구 로그인을 시작한다.
        time.sleep(31 - int(time.time()) % 30)
        STAGE = "recovery-login"
        subprocess.run(
            [
                sys.executable, args.browser_login_script,
                "--issuer", args.issuer_base, "--realm", RECOVERY_REALM,
                "--client-id", RECOVERY_CLIENT,
                "--redirect-uri", f"{args.issuer_base}/realms/master/account/",
                "--username", RECOVERY_USER,
                "--password-file", args.recovery_password_file,
                "--totp-file", args.recovery_totp_file,
                "--header-file", str(header_file),
                "--connect-ip", args.connect_ip,
                "--expect-realm-role", "admin",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        header_name, separator, bearer = header_file.read_text(encoding="utf-8").strip().partition(":")
        if header_name.lower() != "authorization" or not separator or not bearer.strip().startswith("Bearer "):
            raise RuntimeError("recovery login did not produce a bearer header")
        bearer = bearer.strip()
        opener = urllib.request.build_opener(FixedAddressHTTPSHandler(args.connect_ip, issuer.hostname))
        STAGE = "public-client"
        public_uuid, changed_public = upsert_client(opener, args.issuer_base, bearer, client_payload(args.public_client_id, args.dashboard_url, True))
        STAGE = "public-groups-mapper"
        changed_groups = upsert_mapper(opener, args.issuer_base, bearer, public_uuid, GROUP_MAPPER)
        STAGE = "public-audience-mapper"
        changed_audience = upsert_mapper(opener, args.issuer_base, bearer, public_uuid, audience_mapper(args.public_client_id))
        STAGE = "management-client"
        management_uuid, changed_management = upsert_client(opener, args.issuer_base, bearer, client_payload(args.management_client_id, args.dashboard_url, False))
        STAGE = "management-roles"
        changed_roles = ensure_service_roles(opener, args.issuer_base, bearer, management_uuid)
        STAGE = "management-secret"
        secret, _ = api(opener, args.issuer_base, bearer, "GET", f"/admin/realms/{REALM}/clients/{management_uuid}/client-secret")
        values = read_secret_vars(args.secret_vars_file)
        changed_secret = values.get("netbird_keycloak_management_client_secret") != secret.get("value")
        values["netbird_keycloak_management_client_secret"] = secret["value"]
        STAGE = "secret-vars"
        write_secret_vars(args.secret_vars_file, values)
    changed = any((changed_public, changed_groups, changed_audience, changed_management, changed_roles, changed_secret))
    changed_parts = {
        "public": changed_public,
        "groups_mapper": changed_groups,
        "audience_mapper": changed_audience,
        "management": changed_management,
        "roles": changed_roles,
        "secret_ref": changed_secret,
    }
    print(
        f"changed={'true' if changed else 'false'} "
        + " ".join(f"{name}={'true' if value else 'false'}" for name, value in changed_parts.items())
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"NB-02 Keycloak client provisioning failed: stage={STAGE}, type={type(error).__name__}", file=sys.stderr)
        raise SystemExit(1)
