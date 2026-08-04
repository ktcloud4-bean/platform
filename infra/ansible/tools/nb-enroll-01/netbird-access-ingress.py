#!/usr/bin/env python3
"""NB-ENROLL-01: /platform-users device group의 split DNS·exact ingress route를
OPNsense NetBird routing peer(k3s-01/Unbound exact host resource) 위에 선언한다.

Warpgate가 subnet route 대신 NetBird direct peer로 등록된 EDGE-01 패턴을 따르되,
여기서는 목적지 호스트(k3s-01) 자체에 agent를 설치하지 않고 OPNsense를 Network
Router로 써서 정확히 두 개의 /32 Resource(k3s-01 ingress, Unbound DNS)만 노출한다.
"""

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

ROUTER_GROUP = "nb-enroll-01-router"
INGRESS_GROUP = "nb-enroll-01-ingress"
DNS_GROUP = "nb-enroll-01-dns"
PLATFORM_USERS_GROUP = "/platform-users"
NETWORK_NAME = "NB-ENROLL-01 access ingress"
POLICY_NAMES = (
    "NB-ENROLL-01 TCP 443",
    "NB-ENROLL-01 DNS UDP 53",
    "NB-ENROLL-01 DNS TCP 53",
)
NAMESERVER_GROUP_NAME = "NB-ENROLL-01 access split DNS"
SETUP_KEY_NAME = "NB-ENROLL-01 OPNsense router registration"


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
                host, fixed_ip=self.fixed_ip, expected_host=self.expected_host, **kwargs
            )

        return self.do_open(connection, request, context=self._context)


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=(
            "plan",
            "create-router-key",
            "delete-router-key",
            "apply",
            "rollback",
        ),
    )
    parser.add_argument("--browser-login-script", required=True)
    parser.add_argument("--issuer-base", required=True)
    parser.add_argument("--issuer-connect-ip", required=True)
    parser.add_argument("--netbird-url", required=True)
    parser.add_argument("--netbird-connect-ip", required=True)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    parser.add_argument("--router-peer-name", default="opnsense.imcherry5778.xyz")
    parser.add_argument("--ingress-address", default="10.10.20.10/32")
    # OPNsense 자신(라우팅 peer 겸 목적지)을 향한 Resource는 PF state는 생성되지만
    # 로컬 소켓까지 패킷이 전달되지 않는 FreeBSD/userspace WireGuard 한계를
    # 라이브에서 재현·확인했다(pfctl state SINGLE:NO_TRAFFIC, Unbound query log
    # 0건). 그래서 DNS 목적지는 OPNsense 자신이 아니라 netbird-01(다른 호스트)의
    # dnsmasq 릴레이로 둔다 - k3s-01 ingress와 동일한 "다른 호스트로의 라우팅"
    # 패턴이라 정상 동작을 실측했다.
    parser.add_argument("--dns-address", default="10.10.40.10/32")
    parser.add_argument("--dns-nameserver-ip", default="10.10.40.10")
    # NB-ENROLL-01-FIX-01: Pomerium의 authenticate_service_url(k3s-01.imcherry5778.xyz)을
    # 포함해 모든 서비스 로그인 리다이렉트가 access 하나만으로는 해석되지 않아 zone
    # 전체로 넓혔다. netbird-01의 dnsmasq relay는 처음부터 zone 전체를 forward하므로
    # 이 값은 client 측 domain match만 넓히면 된다.
    parser.add_argument("--dns-domain", default="imcherry5778.xyz")
    parser.add_argument("--setup-key-out")
    return parser.parse_args()


def api(opener, base, bearer, method, path, payload=None):
    data = None
    headers = {"Authorization": bearer, "Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(f"{base}{path}", data=data, headers=headers, method=method)
    with opener.open(request, timeout=20) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def bearer_header(args):
    with tempfile.TemporaryDirectory(prefix="nb-enroll-01-") as temporary:
        header_file = Path(temporary) / "header"
        try:
            subprocess.run(
                [
                    sys.executable,
                    args.browser_login_script,
                    "--issuer", args.issuer_base,
                    "--realm", "platform",
                    "--client-id", args.client_id,
                    "--redirect-uri", "http://localhost:53000/",
                    "--username", args.username,
                    "--password-file", args.password_file,
                    "--totp-file", args.totp_file,
                    "--header-file", str(header_file),
                    "--connect-ip", args.issuer_connect_ip,
                    "--capture-callback",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        except subprocess.CalledProcessError as error:
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


def ensure_group(opener, base, bearer, name):
    groups = api(opener, base, bearer, "GET", "/api/groups")
    existing = one(groups, name, "group")
    if existing:
        return existing, False
    created = api(opener, base, bearer, "POST", "/api/groups", {"name": name, "peers": [], "resources": []})
    return created, True


def find_peer(opener, base, bearer, name):
    peers = api(opener, base, bearer, "GET", "/api/peers")
    matches = [peer for peer in peers if peer.get("name") == name]
    if len(matches) > 1:
        raise RuntimeError(f"duplicate peer: {name}")
    return matches[0] if matches else None


def add_peer_to_group(opener, base, bearer, group, peer_id):
    current_ids = {p["id"] if isinstance(p, dict) else p for p in (group.get("peers") or [])}
    if peer_id in current_ids:
        return False
    current_ids.add(peer_id)
    api(
        opener, base, bearer, "PUT", f"/api/groups/{group['id']}",
        {"name": group["name"], "peers": sorted(current_ids), "resources": [r.get("id", r) if isinstance(r, dict) else r for r in (group.get("resources") or [])]},
    )
    return True


def ensure_network(opener, base, bearer, name, description):
    networks = api(opener, base, bearer, "GET", "/api/networks")
    existing = one(networks, name, "network")
    if existing:
        return existing, False
    created = api(opener, base, bearer, "POST", "/api/networks", {"name": name, "description": description})
    return created, True


def ensure_resource(opener, base, bearer, network_id, name, description, address, group_id):
    resources = api(opener, base, bearer, "GET", f"/api/networks/{network_id}/resources") or []
    existing = one(resources, name, "resource")
    desired = {"name": name, "description": description, "address": address, "enabled": True, "groups": [group_id]}
    if existing is None:
        created = api(opener, base, bearer, "POST", f"/api/networks/{network_id}/resources", desired)
        return created, True
    current_group_ids = sorted(g["id"] if isinstance(g, dict) else g for g in (existing.get("groups") or []))
    if existing.get("address") != address or existing.get("enabled") is not True or current_group_ids != [group_id]:
        updated = api(opener, base, bearer, "PUT", f"/api/networks/{network_id}/resources/{existing['id']}", desired)
        return updated, True
    return existing, False


def ensure_router(opener, base, bearer, network_id, router_group_id):
    routers = api(opener, base, bearer, "GET", f"/api/networks/{network_id}/routers") or []
    desired = {"peer_groups": [router_group_id], "metric": 9999, "masquerade": True, "enabled": True}
    if not routers:
        created = api(opener, base, bearer, "POST", f"/api/networks/{network_id}/routers", desired)
        return created, True
    existing = routers[0]
    current_groups = sorted(existing.get("peer_groups") or [])
    if (
        current_groups != [router_group_id]
        or existing.get("metric") != 9999
        or existing.get("masquerade") is not True
        or existing.get("enabled") is not True
    ):
        updated = api(opener, base, bearer, "PUT", f"/api/networks/{network_id}/routers/{existing['id']}", desired)
        return updated, True
    return existing, False


def rule_payload(name, description, protocol, ports, source_group_id, dest_group_id):
    return {
        "name": name,
        "description": description,
        "enabled": True,
        "action": "accept",
        "bidirectional": False,
        "protocol": protocol,
        "ports": ports,
        "port_ranges": [],
        "authorized_groups": {},
        "sources": [source_group_id],
        "destinations": [dest_group_id],
    }


def comparable_rule(rule):
    def group_id(item):
        return item["id"] if isinstance(item, dict) else item

    return {
        "enabled": rule.get("enabled") is True,
        "action": rule.get("action"),
        "bidirectional": rule.get("bidirectional") is True,
        "protocol": rule.get("protocol"),
        "ports": sorted(rule.get("ports") or []),
        "sources": sorted(group_id(item) for item in (rule.get("sources") or [])),
        "destinations": sorted(group_id(item) for item in (rule.get("destinations") or [])),
    }


# NetBird 이 버전의 POST /api/policies는 여러 rule을 한 번에 보내도 실제로는
# 하나만 저장한다(라이브 확인: 두 번째 rule의 sources가 null로 드롭됨). EDGE-01의
# 기존 policy도 모두 rule 1개였으므로, 같은 제약을 policy 1개당 rule 1개로 우회한다.
def ensure_single_rule_policy(opener, base, bearer, policy_name, description, protocol, ports, source_group_id, dest_group_id):
    policies = api(opener, base, bearer, "GET", "/api/policies")
    existing = one(policies, policy_name, "policy")
    rule = rule_payload(policy_name, description, protocol, ports, source_group_id, dest_group_id)
    desired = {
        "name": policy_name,
        "description": description,
        "enabled": True,
        "source_posture_checks": [],
        "rules": [rule],
    }
    if existing is None:
        api(opener, base, bearer, "POST", "/api/policies", desired)
        return True
    current_rules = existing.get("rules") or []
    if len(current_rules) != 1 or comparable_rule(current_rules[0]) != comparable_rule(rule) or existing.get("enabled") is not True:
        api(opener, base, bearer, "PUT", f"/api/policies/{existing['id']}", desired)
        return True
    return False


def ensure_policies(opener, base, bearer, source_group_id, ingress_group_id, dns_group_id):
    changed = False
    changed |= ensure_single_rule_policy(
        opener, base, bearer, POLICY_NAMES[0], "platform-users to k3s-01 ingress",
        "tcp", ["443"], source_group_id, ingress_group_id,
    )
    changed |= ensure_single_rule_policy(
        opener, base, bearer, POLICY_NAMES[1], "platform-users split DNS",
        "udp", ["53"], source_group_id, dns_group_id,
    )
    changed |= ensure_single_rule_policy(
        opener, base, bearer, POLICY_NAMES[2], "platform-users split DNS fallback",
        "tcp", ["53"], source_group_id, dns_group_id,
    )
    return changed


def ensure_nameserver_group(opener, base, bearer, domain, nameserver_ip, group_id):
    groups = api(opener, base, bearer, "GET", "/api/dns/nameservers")
    existing = one(groups, NAMESERVER_GROUP_NAME, "nameserver group")
    desired = {
        "name": NAMESERVER_GROUP_NAME,
        "description": "NB-ENROLL-01 access split DNS via OPNsense Unbound",
        "nameservers": [{"ip": nameserver_ip, "ns_type": "udp", "port": 53}],
        "enabled": True,
        "groups": [group_id],
        "primary": False,
        "domains": [domain],
        "search_domains_enabled": False,
    }
    if existing is None:
        api(opener, base, bearer, "POST", "/api/dns/nameservers", desired)
        return True
    same = (
        existing.get("domains") == [domain]
        and existing.get("nameservers") == desired["nameservers"]
        and existing.get("groups") == [group_id]
        and existing.get("enabled") is True
        and existing.get("primary") is False
    )
    if not same:
        api(opener, base, bearer, "PUT", f"/api/dns/nameservers/{existing['id']}", desired)
        return True
    return False


def create_router_key(opener, base, bearer, router_group):
    setup_keys = api(opener, base, bearer, "GET", "/api/setup-keys")
    existing = [k for k in setup_keys if k.get("name") == SETUP_KEY_NAME and k.get("revoked") is not True and k.get("used_times", 0) < 1]
    if existing:
        raise RuntimeError("an unused NB-ENROLL-01 router setup key already exists; delete it first")
    created = api(
        opener, base, bearer, "POST", "/api/setup-keys",
        {
            "name": SETUP_KEY_NAME,
            "type": "one-off",
            "expires_in": 86400,
            "auto_groups": [router_group["id"]],
            "usage_limit": 1,
            "ephemeral": False,
        },
    )
    return created


def delete_router_key(opener, base, bearer):
    setup_keys = api(opener, base, bearer, "GET", "/api/setup-keys")
    changed = False
    for key in setup_keys:
        if key.get("name") == SETUP_KEY_NAME and key.get("revoked") is not True:
            api(opener, base, bearer, "DELETE", f"/api/setup-keys/{key['id']}")
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
    ipaddress.ip_network(args.ingress_address, strict=True)
    ipaddress.ip_network(args.dns_address, strict=True)
    ipaddress.ip_address(args.dns_nameserver_ip)

    STAGE = "owner OIDC login"
    bearer = bearer_header(args)
    opener = urllib.request.build_opener(FixedAddressHTTPSHandler(args.netbird_connect_ip, netbird.hostname))

    if args.mode == "create-router-key":
        STAGE = "router group ensure"
        router_group, _ = ensure_group(opener, args.netbird_url, bearer, ROUTER_GROUP)
        STAGE = "router key create"
        created = create_router_key(opener, args.netbird_url, bearer, router_group)
        if args.setup_key_out:
            target = Path(args.setup_key_out)
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(created["key"] + "\n")
            os.chmod(target, 0o600)
        print(f"created router setup key id={created['id']}")
        return

    if args.mode == "delete-router-key":
        STAGE = "router key delete"
        changed = delete_router_key(opener, args.netbird_url, bearer)
        print(f"changed={'true' if changed else 'false'}")
        return

    STAGE = "read current state"
    groups = api(opener, args.netbird_url, bearer, "GET", "/api/groups")
    platform_users = one(groups, PLATFORM_USERS_GROUP, "group")
    if platform_users is None:
        raise RuntimeError("required JWT-managed group /platform-users is missing")
    router_peer = find_peer(opener, args.netbird_url, bearer, args.router_peer_name)

    if args.mode == "plan":
        actions = []
        if router_peer is None:
            actions.append(f"peer not yet connected: {args.router_peer_name}")
        for name in (ROUTER_GROUP, INGRESS_GROUP, DNS_GROUP):
            if one(groups, name, "group") is None:
                actions.append(f"create-group:{name}")
        networks = api(opener, args.netbird_url, bearer, "GET", "/api/networks")
        if one(networks, NETWORK_NAME, "network") is None:
            actions.append(f"create-network:{NETWORK_NAME}")
        policies = api(opener, args.netbird_url, bearer, "GET", "/api/policies")
        for policy_name in POLICY_NAMES:
            if one(policies, policy_name, "policy") is None:
                actions.append(f"create-policy:{policy_name}")
        nameserver_groups = api(opener, args.netbird_url, bearer, "GET", "/api/dns/nameservers")
        if one(nameserver_groups, NAMESERVER_GROUP_NAME, "nameserver group") is None:
            actions.append(f"create-nameserver-group:{NAMESERVER_GROUP_NAME}")
        print(json.dumps({"actions": actions}, ensure_ascii=False))
        return

    if args.mode == "apply":
        if router_peer is None:
            raise RuntimeError(f"router peer '{args.router_peer_name}' is not connected yet; configure OPNsense NetBird client first")
        changed = False
        STAGE = "ensure groups"
        router_group, c = ensure_group(opener, args.netbird_url, bearer, ROUTER_GROUP)
        changed |= c
        ingress_group, c = ensure_group(opener, args.netbird_url, bearer, INGRESS_GROUP)
        changed |= c
        dns_group, c = ensure_group(opener, args.netbird_url, bearer, DNS_GROUP)
        changed |= c
        STAGE = "add router peer to group"
        router_group_full = api(opener, args.netbird_url, bearer, "GET", f"/api/groups/{router_group['id']}")
        changed |= add_peer_to_group(opener, args.netbird_url, bearer, router_group_full, router_peer["id"])

        STAGE = "ensure network"
        network, c = ensure_network(opener, args.netbird_url, bearer, NETWORK_NAME, "NB-ENROLL-01 exact host resources reachable via OPNsense router peer")
        changed |= c

        STAGE = "ensure resources"
        _, c = ensure_resource(opener, args.netbird_url, bearer, network["id"], "k3s-01 ingress", "k3s-01 Traefik HTTPS exact host", args.ingress_address, ingress_group["id"])
        changed |= c
        _, c = ensure_resource(opener, args.netbird_url, bearer, network["id"], "Unbound DNS", "OPNsense Unbound exact host for split DNS", args.dns_address, dns_group["id"])
        changed |= c

        STAGE = "ensure router"
        _, c = ensure_router(opener, args.netbird_url, bearer, network["id"], router_group["id"])
        changed |= c

        STAGE = "ensure policies"
        changed |= ensure_policies(opener, args.netbird_url, bearer, platform_users["id"], ingress_group["id"], dns_group["id"])

        STAGE = "ensure nameserver group"
        changed |= ensure_nameserver_group(opener, args.netbird_url, bearer, args.dns_domain, args.dns_nameserver_ip, platform_users["id"])

        print(f"changed={'true' if changed else 'false'}")
        return

    if args.mode == "rollback":
        changed = False
        STAGE = "rollback policies"
        policies = api(opener, args.netbird_url, bearer, "GET", "/api/policies")
        for policy_name in POLICY_NAMES:
            policy = one(policies, policy_name, "policy")
            if policy:
                api(opener, args.netbird_url, bearer, "DELETE", f"/api/policies/{policy['id']}")
                changed = True
        STAGE = "rollback nameserver group"
        nameserver_groups = api(opener, args.netbird_url, bearer, "GET", "/api/dns/nameservers")
        nsg = one(nameserver_groups, NAMESERVER_GROUP_NAME, "nameserver group")
        if nsg:
            api(opener, args.netbird_url, bearer, "DELETE", f"/api/dns/nameservers/{nsg['id']}")
            changed = True
        STAGE = "rollback network"
        networks = api(opener, args.netbird_url, bearer, "GET", "/api/networks")
        network = one(networks, NETWORK_NAME, "network")
        if network:
            routers = api(opener, args.netbird_url, bearer, "GET", f"/api/networks/{network['id']}/routers")
            for router in routers:
                api(opener, args.netbird_url, bearer, "DELETE", f"/api/networks/{network['id']}/routers/{router['id']}")
            resources = api(opener, args.netbird_url, bearer, "GET", f"/api/networks/{network['id']}/resources")
            for resource in resources:
                api(opener, args.netbird_url, bearer, "DELETE", f"/api/networks/{network['id']}/resources/{resource['id']}")
            api(opener, args.netbird_url, bearer, "DELETE", f"/api/networks/{network['id']}")
            changed = True
        STAGE = "rollback groups"
        groups = api(opener, args.netbird_url, bearer, "GET", "/api/groups")
        for name in (INGRESS_GROUP, DNS_GROUP, ROUTER_GROUP):
            group = one(groups, name, "group")
            if group and not (group.get("peers") or group.get("resources")):
                api(opener, args.netbird_url, bearer, "DELETE", f"/api/groups/{group['id']}")
                changed = True
        print(f"changed={'true' if changed else 'false'}")
        return


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        detail = ""
        try:
            if hasattr(error, "read"):
                detail = error.read().decode("utf-8", errors="replace")[:300]
        except Exception:
            pass
        print(
            f"NB-ENROLL-01 provisioning failed: stage={STAGE}, type={type(error).__name__}, status={status} {detail}",
            file=sys.stderr,
        )
        raise SystemExit(1)
