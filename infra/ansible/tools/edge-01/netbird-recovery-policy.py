#!/usr/bin/env python3
"""EDGE-01 NetBird Warpgate recovery groups and least-privilege policy."""

import argparse
import http.client
import ipaddress
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request


STAGE = "initialization"
CLIENT_GROUP = "edge-recovery-clients"
WARGATE_GROUP = "edge-recovery-warpgate"
POLICY_NAME = "EDGE-01 Warpgate recovery"
POLICY_DESCRIPTION = "NetBird recovery clients to Warpgate HTTPS TCP 8888 only"
RULE_NAME = "EDGE-01 TCP 8888"


class FixedAddressHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, *, fixed_ip: str, expected_host: str, **kwargs):
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host
        super().__init__(host, **kwargs)

    def connect(self):
        if self.host != self.expected_host:
            raise OSError("fixed-address request left the NetBird host")
        self.sock = self._create_connection(
            (self.fixed_ip, self.port), self.timeout, self.source_address
        )
        if self._tunnel_host:
            self._tunnel()
        self.sock = self._context.wrap_socket(
            self.sock, server_hostname=self.expected_host
        )


class FixedAddressHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, fixed_ip: str, expected_host: str):
        super().__init__()
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host

    def https_open(self, request):
        def connection(host, **kwargs):
            return FixedAddressHTTPSConnection(
                host,
                fixed_ip=self.fixed_ip,
                expected_host=self.expected_host,
                **kwargs,
            )

        return self.do_open(connection, request, context=self._context)


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("plan", "apply", "rollback"))
    parser.add_argument("--browser-login-script", required=True)
    parser.add_argument("--issuer-base", required=True)
    parser.add_argument("--issuer-connect-ip", required=True)
    parser.add_argument("--netbird-url", required=True)
    parser.add_argument("--netbird-connect-ip", required=True)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    parser.add_argument("--snapshot-file")
    return parser.parse_args()


def api(opener, base, bearer, method, path, payload=None):
    data = None
    headers = {"Authorization": bearer, "Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        f"{base}{path}", data=data, headers=headers, method=method
    )
    with opener.open(request, timeout=20) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def bearer_header(args):
    with tempfile.TemporaryDirectory(prefix="edge01-netbird-policy-") as temporary:
        header_file = Path(temporary) / "header"
        try:
            subprocess.run(
                [
                    sys.executable,
                    args.browser_login_script,
                    "--issuer",
                    args.issuer_base,
                    "--realm",
                    "platform",
                    "--client-id",
                    args.client_id,
                    "--redirect-uri",
                    "http://localhost:53000/",
                    "--username",
                    args.username,
                    "--password-file",
                    args.password_file,
                    "--totp-file",
                    args.totp_file,
                    "--header-file",
                    str(header_file),
                    "--connect-ip",
                    args.issuer_connect_ip,
                    "--capture-callback",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        except subprocess.CalledProcessError as error:
            # browser-login.py의 stderr는 token·cookie를 제거한 stage/status만 낸다.
            detail = (error.stderr or "").strip().splitlines()
            if detail:
                print(detail[-1], file=sys.stderr)
            raise
        header = header_file.read_text(encoding="utf-8").strip()
        if not header.startswith("Authorization: Bearer "):
            raise RuntimeError("owner OIDC login did not return bearer header")
        return header.partition(":")[2].strip()


def one(items, name, kind):
    matches = [item for item in items if item.get("name") == name]
    if len(matches) > 1:
        raise RuntimeError(f"duplicate {kind}: {name}")
    return matches[0] if matches else None


def group_id(item):
    if isinstance(item, str):
        return item
    if isinstance(item, dict):
        return item.get("id")
    return None


def rule_payload(rule, include_id=True):
    payload = {
        "name": rule.get("name"),
        "description": rule.get("description", ""),
        "enabled": rule.get("enabled") is True,
        "action": rule.get("action"),
        "bidirectional": rule.get("bidirectional") is True,
        "protocol": rule.get("protocol"),
        "ports": rule.get("ports") or [],
        "port_ranges": rule.get("port_ranges") or [],
        "authorized_groups": rule.get("authorized_groups") or {},
        "sources": [group_id(item) for item in (rule.get("sources") or [])],
        "destinations": [
            group_id(item) for item in (rule.get("destinations") or [])
        ],
    }
    if include_id and rule.get("id"):
        payload["id"] = rule["id"]
    return payload


def policy_payload(policy, enabled=None):
    policy_enabled = (
        policy.get("enabled") is True if enabled is None else bool(enabled)
    )
    return {
        "name": policy.get("name"),
        "description": policy.get("description", ""),
        "enabled": policy_enabled,
        "source_posture_checks": policy.get("source_posture_checks") or [],
        "rules": [rule_payload(rule) for rule in policy.get("rules") or []],
    }


def desired_policy(client_group_id, warpgate_group_id):
    return {
        "name": POLICY_NAME,
        "description": POLICY_DESCRIPTION,
        "enabled": True,
        "source_posture_checks": [],
        "rules": [
            {
                "name": RULE_NAME,
                "description": "",
                "enabled": True,
                "action": "accept",
                "bidirectional": False,
                "protocol": "tcp",
                "ports": ["8888"],
                "port_ranges": [],
                "authorized_groups": {},
                "sources": [client_group_id],
                "destinations": [warpgate_group_id],
            }
        ],
    }


def comparable(policy):
    value = policy_payload(policy)
    for rule in value["rules"]:
        rule.pop("id", None)
    return value


def validate_default(policy, all_group_id):
    if not isinstance(policy.get("enabled"), bool):
        raise RuntimeError("Default policy enabled state is invalid")
    rules = policy.get("rules") or []
    if len(rules) != 1:
        raise RuntimeError("Default policy shape changed")
    rule = rule_payload(rules[0], include_id=False)
    expected = {
        "name": "Default",
        "description": rule["description"],
        "enabled": True,
        "action": "accept",
        "bidirectional": True,
        "protocol": "all",
        "ports": [],
        "port_ranges": [],
        "authorized_groups": {},
        "sources": [all_group_id],
        "destinations": [all_group_id],
    }
    if rule != expected:
        raise RuntimeError("Default policy semantics changed")


def write_snapshot(path, groups, policies):
    destination = Path(path)
    parent = destination.parent
    if not parent.is_dir():
        raise RuntimeError("snapshot parent directory is missing")
    parent_mode = stat.S_IMODE(parent.stat().st_mode)
    if parent_mode & 0o077:
        raise RuntimeError("snapshot parent directory must be owner-only")

    selected_groups = [
        group
        for group in groups
        if group.get("name") in {"All", CLIENT_GROUP, WARGATE_GROUP}
    ]
    selected_policies = [
        policy
        for policy in policies
        if policy.get("name") in {"Default", POLICY_NAME}
    ]
    payload = {
        "groups": selected_groups,
        "policies": selected_policies,
    }
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")


def plan(groups, policies):
    all_group = one(groups, "All", "group")
    default = one(policies, "Default", "policy")
    if not all_group or not default:
        raise RuntimeError("required NetBird defaults missing")
    validate_default(default, all_group["id"])
    actions = []
    client_group = one(groups, CLIENT_GROUP, "group")
    warpgate_group = one(groups, WARGATE_GROUP, "group")
    if client_group is None:
        actions.append(f"create-group:{CLIENT_GROUP}")
    if warpgate_group is None:
        actions.append(f"create-group:{WARGATE_GROUP}")
    edge_policy = one(policies, POLICY_NAME, "policy")
    if edge_policy is None:
        actions.append(f"create-policy:{POLICY_NAME}")
    elif client_group and warpgate_group and comparable(edge_policy) != comparable(
        desired_policy(client_group["id"], warpgate_group["id"])
    ):
        actions.append(f"reconcile-policy:{POLICY_NAME}")
    if default.get("enabled") is True:
        actions.append("disable-policy:Default")
    return actions


def ensure_group(opener, base, bearer, groups, name):
    existing = one(groups, name, "group")
    if existing:
        return existing, False
    created = api(
        opener,
        base,
        bearer,
        "POST",
        "/api/groups",
        {"name": name, "peers": [], "resources": []},
    )
    return created, True


def apply(opener, base, bearer, groups, policies):
    all_group = one(groups, "All", "group")
    default = one(policies, "Default", "policy")
    if not all_group or not default:
        raise RuntimeError("required NetBird defaults missing")
    validate_default(default, all_group["id"])
    changed = False
    client_group, created = ensure_group(
        opener, base, bearer, groups, CLIENT_GROUP
    )
    changed |= created
    if created:
        groups.append(client_group)
    warpgate_group, created = ensure_group(
        opener, base, bearer, groups, WARGATE_GROUP
    )
    changed |= created
    if created:
        groups.append(warpgate_group)

    desired = desired_policy(client_group["id"], warpgate_group["id"])
    existing = one(policies, POLICY_NAME, "policy")
    if existing is None:
        api(opener, base, bearer, "POST", "/api/policies", desired)
        changed = True
    elif comparable(existing) != comparable(desired):
        api(
            opener,
            base,
            bearer,
            "PUT",
            f"/api/policies/{existing['id']}",
            desired,
        )
        changed = True

    if default.get("enabled") is True:
        api(
            opener,
            base,
            bearer,
            "PUT",
            f"/api/policies/{default['id']}",
            policy_payload(default, enabled=False),
        )
        changed = True
    return changed


def rollback(opener, base, bearer, groups, policies):
    all_group = one(groups, "All", "group")
    default = one(policies, "Default", "policy")
    if not all_group or not default:
        raise RuntimeError("required NetBird defaults missing")
    validate_default(default, all_group["id"])
    edge_policy = one(policies, POLICY_NAME, "policy")
    if edge_policy:
        client_group = one(groups, CLIENT_GROUP, "group")
        warpgate_group = one(groups, WARGATE_GROUP, "group")
        if not client_group or not warpgate_group:
            raise RuntimeError("edge policy groups are missing")
        desired = desired_policy(client_group["id"], warpgate_group["id"])
        if comparable(edge_policy) != comparable(desired):
            raise RuntimeError("refusing to delete changed edge policy")
    for name in (CLIENT_GROUP, WARGATE_GROUP):
        group = one(groups, name, "group")
        if group and ((group.get("peers") or []) or (group.get("resources") or [])):
            raise RuntimeError(f"refusing to delete non-empty group: {name}")

    changed = False
    if default.get("enabled") is not True:
        api(
            opener,
            base,
            bearer,
            "PUT",
            f"/api/policies/{default['id']}",
            policy_payload(default, enabled=True),
        )
        changed = True
    if edge_policy:
        api(
            opener,
            base,
            bearer,
            "DELETE",
            f"/api/policies/{edge_policy['id']}",
        )
        changed = True
    for name in (CLIENT_GROUP, WARGATE_GROUP):
        group = one(groups, name, "group")
        if not group:
            continue
        api(opener, base, bearer, "DELETE", f"/api/groups/{group['id']}")
        changed = True
    return changed


def main():
    global STAGE
    args = arguments()
    issuer = urllib.parse.urlsplit(args.issuer_base)
    netbird = urllib.parse.urlsplit(args.netbird_url)
    if issuer.scheme != "https" or not issuer.hostname:
        raise RuntimeError("issuer must be an HTTPS origin")
    if netbird.scheme != "https" or not netbird.hostname:
        raise RuntimeError("NetBird URL must be an HTTPS origin")
    for address in (args.issuer_connect_ip, args.netbird_connect_ip):
        if ipaddress.ip_address(address).version != 4:
            raise RuntimeError("fixed addresses must be IPv4")
    for path in (args.browser_login_script, args.password_file, args.totp_file):
        if not Path(path).is_file():
            raise RuntimeError("required credential input missing")

    STAGE = "owner OIDC login"
    bearer = bearer_header(args)
    opener = urllib.request.build_opener(
        FixedAddressHTTPSHandler(args.netbird_connect_ip, netbird.hostname)
    )
    STAGE = "NetBird policy read"
    groups = api(opener, args.netbird_url, bearer, "GET", "/api/groups")
    policies = api(opener, args.netbird_url, bearer, "GET", "/api/policies")
    if not isinstance(groups, list) or not isinstance(policies, list):
        raise RuntimeError("NetBird policy response is incomplete")

    if args.mode == "plan":
        if args.snapshot_file:
            write_snapshot(args.snapshot_file, groups, policies)
        print(json.dumps({"actions": plan(groups, policies)}, ensure_ascii=False))
        return
    STAGE = f"NetBird policy {args.mode}"
    changed = (
        apply(opener, args.netbird_url, bearer, groups, policies)
        if args.mode == "apply"
        else rollback(opener, args.netbird_url, bearer, groups, policies)
    )
    print(f"changed={'true' if changed else 'false'}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        print(
            f"EDGE-01 NetBird policy failed: stage={STAGE}, "
            f"type={type(error).__name__}, status={status}",
            file=sys.stderr,
        )
        raise SystemExit(1)
