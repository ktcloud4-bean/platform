#!/usr/bin/env python3
"""EDGE-01 one-off setup key and exact recovery peer lifecycle."""

import argparse
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import stat
import sys
import urllib.parse
import urllib.request


STAGE = "initialization"
CLIENT_GROUP = "edge-recovery-clients"
WARGATE_GROUP = "edge-recovery-warpgate"
WARGATE_KEY_NAME = "EDGE-01 Warpgate registration"
VERIFIER_KEY_NAME = "EDGE-01 verifier registration"
WARGATE_PEER_NAME = "warpgate-edge"
VERIFIER_PEER_NAME = "edge-01-verifier"


def load_policy_module():
    source = Path(__file__).with_name("netbird-recovery-policy.py")
    spec = importlib.util.spec_from_file_location("edge01_netbird_policy", source)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load EDGE-01 NetBird API helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


POLICY = load_policy_module()


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=(
            "create-warpgate-key",
            "delete-warpgate-key",
            "create-verifier-key",
            "delete-verifier-key",
            "peer-state",
            "delete-warpgate-peer",
            "delete-verifier-peer",
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
    parser.add_argument("--state-dir")
    return parser.parse_args()


def api_client(args):
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
    bearer = POLICY.bearer_header(args)
    opener = urllib.request.build_opener(
        POLICY.FixedAddressHTTPSHandler(args.netbird_connect_ip, netbird.hostname)
    )
    return opener, bearer


def state_paths(path, purpose):
    if not path:
        raise RuntimeError("setup key lifecycle requires --state-dir")
    directory = Path(path)
    if not directory.is_dir():
        raise RuntimeError("setup key state directory is missing")
    if stat.S_IMODE(directory.stat().st_mode) & 0o077:
        raise RuntimeError("setup key state directory must be owner-only")
    return (
        directory / f"netbird-{purpose}-setup-key",
        directory / f"netbird-{purpose}-setup-key.json",
    )


def write_exclusive(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(content)


def exact_group(groups, name):
    group = POLICY.one(groups, name, "group")
    if not group:
        raise RuntimeError(f"required NetBird group missing: {name}")
    return group


def create_key(opener, base, bearer, args, purpose):
    group_name = WARGATE_GROUP if purpose == "warpgate" else CLIENT_GROUP
    key_name = WARGATE_KEY_NAME if purpose == "warpgate" else VERIFIER_KEY_NAME
    ephemeral = purpose == "verifier"
    key_path, metadata_path = state_paths(args.state_dir, purpose)
    if key_path.exists() or metadata_path.exists():
        raise RuntimeError("setup key state file already exists")

    groups = POLICY.api(opener, base, bearer, "GET", "/api/groups")
    setup_keys = POLICY.api(opener, base, bearer, "GET", "/api/setup-keys")
    group = exact_group(groups, group_name)
    if POLICY.one(setup_keys, key_name, "setup key"):
        raise RuntimeError(f"setup key name already exists: {key_name}")

    created = POLICY.api(
        opener,
        base,
        bearer,
        "POST",
        "/api/setup-keys",
        {
            "name": key_name,
            "type": "one-off",
            "expires_in": 86400,
            "auto_groups": [group["id"]],
            "usage_limit": 1,
            "ephemeral": ephemeral,
            "allow_extra_dns_labels": False,
        },
    )
    if not isinstance(created, dict) or not created.get("id") or not created.get("key"):
        raise RuntimeError("setup key create response is incomplete")
    metadata = {
        "id": created["id"],
        "purpose": purpose,
        "name": key_name,
        "group_id": group["id"],
        "ephemeral": ephemeral,
    }
    try:
        write_exclusive(key_path, f"{created['key']}\n")
        write_exclusive(
            metadata_path,
            json.dumps(metadata, separators=(",", ":"), sort_keys=True) + "\n",
        )
    except Exception:
        POLICY.api(
            opener,
            base,
            bearer,
            "DELETE",
            f"/api/setup-keys/{created['id']}",
        )
        for path in (key_path, metadata_path):
            if path.exists() and path.is_file() and not path.is_symlink():
                path.unlink()
        raise
    print(f"changed=true purpose={purpose}")


def load_metadata(path, purpose):
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("setup key metadata file is missing or unsafe")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise RuntimeError("setup key metadata file must be mode 0600")
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("purpose") != purpose or not value.get("id"):
        raise RuntimeError("setup key metadata purpose or ID is invalid")
    return value


def delete_key(opener, base, bearer, args, purpose):
    expected_name = WARGATE_KEY_NAME if purpose == "warpgate" else VERIFIER_KEY_NAME
    expected_ephemeral = purpose == "verifier"
    key_path, metadata_path = state_paths(args.state_dir, purpose)
    metadata = load_metadata(metadata_path, purpose)
    setup_keys = POLICY.api(opener, base, bearer, "GET", "/api/setup-keys")
    matches = [item for item in setup_keys if item.get("id") == metadata["id"]]
    if len(matches) > 1:
        raise RuntimeError("duplicate setup key ID")
    if matches:
        current = matches[0]
        expected = {
            "name": expected_name,
            "type": "one-off",
            "usage_limit": 1,
            "ephemeral": expected_ephemeral,
            "auto_groups": [metadata["group_id"]],
        }
        actual = {key: current.get(key) for key in expected}
        if actual != expected:
            raise RuntimeError("refusing to delete changed setup key")
        POLICY.api(
            opener,
            base,
            bearer,
            "DELETE",
            f"/api/setup-keys/{metadata['id']}",
        )
    for path in (key_path, metadata_path):
        if path.exists():
            if not path.is_file() or path.is_symlink():
                raise RuntimeError("refusing to delete unsafe setup key state path")
            path.unlink()
    print(f"changed={'true' if matches else 'false'} purpose={purpose}")


def edge_peer(peers, name):
    matches = [peer for peer in peers if peer.get("name") == name]
    if len(matches) > 1:
        raise RuntimeError(f"duplicate peer: {name}")
    return matches[0] if matches else None


def peer_summary(peer):
    groups = sorted(group.get("name") for group in peer.get("groups") or [])
    flags = peer.get("local_flags") or {}
    return {
        "name": peer.get("name"),
        "connected": peer.get("connected") is True,
        "ip": peer.get("ip"),
        "ephemeral": peer.get("ephemeral") is True,
        "groups": groups,
        "version": peer.get("version"),
        "local_flags": {
            "disable_client_routes": flags.get("disable_client_routes") is True,
            "disable_server_routes": flags.get("disable_server_routes") is True,
            "disable_dns": flags.get("disable_dns") is True,
            "disable_firewall": flags.get("disable_firewall") is True,
            "block_inbound": flags.get("block_inbound") is True,
        },
    }


def peer_state(opener, base, bearer):
    peers = POLICY.api(opener, base, bearer, "GET", "/api/peers")
    result = []
    for name in (WARGATE_PEER_NAME, VERIFIER_PEER_NAME):
        peer = edge_peer(peers, name)
        if peer:
            result.append(peer_summary(peer))
    print(json.dumps({"peers": result}, ensure_ascii=False, sort_keys=True))


def delete_peer(opener, base, bearer, purpose):
    name = WARGATE_PEER_NAME if purpose == "warpgate" else VERIFIER_PEER_NAME
    group_name = WARGATE_GROUP if purpose == "warpgate" else CLIENT_GROUP
    expected_ephemeral = purpose == "verifier"
    peers = POLICY.api(opener, base, bearer, "GET", "/api/peers")
    peer = edge_peer(peers, name)
    if not peer:
        print(f"changed=false purpose={purpose}")
        return
    actual_groups = {group.get("name") for group in peer.get("groups") or []}
    if group_name not in actual_groups or actual_groups - {"All", group_name}:
        raise RuntimeError("refusing to delete peer with unexpected group membership")
    if (peer.get("ephemeral") is True) != expected_ephemeral:
        raise RuntimeError("refusing to delete peer with unexpected ephemeral state")
    POLICY.api(opener, base, bearer, "DELETE", f"/api/peers/{peer['id']}")
    print(f"changed=true purpose={purpose}")


def main():
    global STAGE
    args = arguments()
    STAGE = "owner OIDC login"
    opener, bearer = api_client(args)
    base = args.netbird_url
    STAGE = args.mode
    if args.mode == "create-warpgate-key":
        create_key(opener, base, bearer, args, "warpgate")
    elif args.mode == "delete-warpgate-key":
        delete_key(opener, base, bearer, args, "warpgate")
    elif args.mode == "create-verifier-key":
        create_key(opener, base, bearer, args, "verifier")
    elif args.mode == "delete-verifier-key":
        delete_key(opener, base, bearer, args, "verifier")
    elif args.mode == "peer-state":
        peer_state(opener, base, bearer)
    elif args.mode == "delete-warpgate-peer":
        delete_peer(opener, base, bearer, "warpgate")
    else:
        delete_peer(opener, base, bearer, "verifier")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        print(
            f"EDGE-01 NetBird asset failed: stage={STAGE}, "
            f"type={type(error).__name__}, status={status}",
            file=sys.stderr,
        )
        raise SystemExit(1)
