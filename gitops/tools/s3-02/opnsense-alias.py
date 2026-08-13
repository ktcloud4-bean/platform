#!/usr/bin/env python3
"""S3-02 Unbound object-admin alias 한 건만 지원 API로 조회·적용·rollback한다."""

import argparse
import base64
import json
import os
from pathlib import Path
import ssl
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request


EXPECTED_HOST = {
    "enabled": "1",
    "hostname": "k3s-01",
    "domain": "imcherry5778.xyz",
    "rr": "A",
    "server": "10.10.20.10",
}
EXPECTED_ALIAS = {
    "enabled": "1",
    "hostname": "object-admin",
    "domain": "imcherry5778.xyz",
    "description": "SeaweedFS admin 웹 UI Pomerium Route alias (S3-02)",
}


def load_env(path: Path) -> dict[str, str]:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise RuntimeError("env file must be a regular non-symlink file")
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise RuntimeError("env file must be owned by the caller with group/other mode 0")
    values = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if not key.startswith("OPN_"):
            continue
        if key not in {"OPN_KEY", "OPN_SECRET", "OPN_URL", "OPN_CACERT"}:
            raise RuntimeError(f"unsupported OPN setting at line {number}: {key}")
        if key in values:
            raise RuntimeError(f"duplicate OPN setting at line {number}: {key}")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key] = value
    for required in ("OPN_KEY", "OPN_SECRET"):
        if not values.get(required):
            raise RuntimeError(f"missing {required}")
    values.setdefault("OPN_URL", "https://opnsense.imcherry5778.xyz")
    parsed = urllib.parse.urlsplit(values["OPN_URL"])
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError("OPN_URL must be a credential-free HTTPS origin")
    return values


class Client:
    def __init__(self, values: dict[str, str]):
        self.base = values["OPN_URL"].rstrip("/")
        token = base64.b64encode(
            f"{values['OPN_KEY']}:{values['OPN_SECRET']}".encode("utf-8")
        ).decode("ascii")
        self.headers = {
            "Authorization": f"Basic {token}",
            "Content-Type": "application/json",
        }
        self.context = ssl.create_default_context()
        if values.get("OPN_CACERT"):
            ca_path = Path(values["OPN_CACERT"])
            if not ca_path.is_file():
                raise RuntimeError("OPN_CACERT is not a readable file")
            self.context.load_verify_locations(cafile=str(ca_path))

    def post(self, path: str, payload=None):
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=json.dumps(payload or {}).encode("utf-8"),
            headers=self.headers,
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=30, context=self.context) as response:
            return response.status, json.load(response)


def rows(client: Client, kind: str):
    status, body = client.post(f"/api/unbound/settings/search_{kind}")
    if status != 200 or not isinstance(body.get("rows"), list):
        raise RuntimeError(f"invalid search_{kind} response")
    return body["rows"]


def exact_match(row: dict, expected: dict) -> bool:
    return all(str(row.get(key, "")) == value for key, value in expected.items())


def preflight(client: Client):
    hosts = [row for row in rows(client, "host_override") if exact_match(row, EXPECTED_HOST)]
    if len(hosts) != 1 or not hosts[0].get("uuid"):
        raise RuntimeError("expected live k3s-01 A host override is not unique")
    host_uuid = hosts[0]["uuid"]
    aliases = [
        row
        for row in rows(client, "host_alias")
        if row.get("hostname") == EXPECTED_ALIAS["hostname"]
        and row.get("domain") == EXPECTED_ALIAS["domain"]
    ]
    if len(aliases) > 1:
        raise RuntimeError("object-admin alias is not unique")
    return host_uuid, aliases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", required=True, type=Path)
    parser.add_argument("mode", choices=("check", "apply", "rollback"))
    args = parser.parse_args()
    client = Client(load_env(args.env_file))
    host_uuid, aliases = preflight(client)

    if args.mode == "check":
        if not aliases:
            print("S3-02 Unbound: k3s-01 precondition=match, object-admin alias=absent")
            return
        alias = aliases[0]
        if alias.get("host") != host_uuid or not exact_match(alias, EXPECTED_ALIAS):
            raise RuntimeError("existing object-admin alias differs from the S3-02 declaration")
        print(
            "S3-02 Unbound: k3s-01 precondition=match, "
            f"object-admin alias=match, uuid={alias['uuid']}"
        )
        return

    if args.mode == "apply":
        if aliases:
            alias = aliases[0]
            if alias.get("host") != host_uuid or not exact_match(alias, EXPECTED_ALIAS):
                raise RuntimeError("existing object-admin alias differs; refusing to overwrite")
            print(f"S3-02 Unbound: object-admin alias already matches, uuid={alias['uuid']}")
            return
        payload = {"alias": {**EXPECTED_ALIAS, "host": host_uuid}}
        status, body = client.post("/api/unbound/settings/add_host_alias", payload)
        if status != 200 or body.get("result") != "saved" or not body.get("uuid"):
            raise RuntimeError("add_host_alias did not return saved with a UUID")
        alias_uuid = body["uuid"]
        status, body = client.post("/api/unbound/service/reconfigure")
        if status != 200 or body.get("status") not in {"ok", "done"}:
            raise RuntimeError("Unbound reconfigure did not succeed")
        host_uuid_after, aliases_after = preflight(client)
        if host_uuid_after != host_uuid or len(aliases_after) != 1:
            raise RuntimeError("object-admin alias verification count mismatch")
        alias = aliases_after[0]
        if (
            alias.get("uuid") != alias_uuid
            or alias.get("host") != host_uuid
            or not exact_match(alias, EXPECTED_ALIAS)
        ):
            raise RuntimeError("saved object-admin alias differs from the declaration")
        print(f"S3-02 Unbound: object-admin alias applied, uuid={alias_uuid}")
        return

    if not aliases:
        raise RuntimeError("rollback target object-admin alias is absent")
    alias = aliases[0]
    if alias.get("host") != host_uuid or not exact_match(alias, EXPECTED_ALIAS):
        raise RuntimeError("rollback target differs from the exact S3-02 alias")
    alias_uuid = alias.get("uuid")
    if not alias_uuid:
        raise RuntimeError("rollback target UUID is missing")
    status, body = client.post(f"/api/unbound/settings/del_host_alias/{alias_uuid}")
    if status != 200 or body.get("result") not in {"deleted", "saved"}:
        raise RuntimeError("del_host_alias did not succeed")
    status, body = client.post("/api/unbound/service/reconfigure")
    if status != 200 or body.get("status") not in {"ok", "done"}:
        raise RuntimeError("Unbound reconfigure did not succeed")
    _, aliases_after = preflight(client)
    if aliases_after:
        raise RuntimeError("object-admin alias still exists after rollback")
    print(f"S3-02 Unbound: object-admin alias rolled back, uuid={alias_uuid}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        print(
            f"S3-02 Unbound failed: {type(error).__name__}: {error}",
            file=sys.stderr,
        )
        raise SystemExit(1)
