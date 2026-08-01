#!/usr/bin/env python3
"""OpenTofu state 밖 BKP-01 임시 restore VM을 정확한 guard로 생성·제거한다."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any


SERVICE_VMIDS = {120, 130, 140, 150, 151, 9000}


def command_text(arguments: list[str]) -> str:
    return " ".join(shlex.quote(value) for value in arguments)


class Remote:
    def __init__(self, host: str, known_hosts: Path) -> None:
        self.base = [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            host,
        ]

    def run(
        self,
        arguments: list[str],
        *,
        check: bool = True,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [*self.base, command_text(arguments)],
            check=check,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


def validate(args: argparse.Namespace) -> None:
    if args.vmid in SERVICE_VMIDS or args.vmid < 100:
        raise SystemExit("서비스/template VMID 또는 잘못된 VMID는 임시 restore에 사용할 수 없습니다")
    if not re.fullmatch(r"bkp01-restore-[a-z0-9-]+", args.name):
        raise SystemExit("VM 이름은 bkp01-restore- prefix여야 합니다")
    address = ipaddress.ip_interface(args.address)
    if address.version != 4 or address.network.prefixlen != 24:
        raise SystemExit("restore VM은 IPv4 /24 실험 주소를 사용해야 합니다")
    if address.ip.packed[-1] < 200 or address.ip.packed[-1] > 254:
        raise SystemExit("ip-plan의 실험·이전용 .200-.254 주소만 허용합니다")
    gateway = ipaddress.ip_address(args.gateway)
    if gateway not in address.network:
        raise SystemExit("restore VM gateway가 같은 subnet이 아닙니다")
    if args.vlan != int(str(address.ip).split(".")[2]):
        raise SystemExit("VLAN과 주소의 세 번째 octet이 다릅니다")


def qga_network(remote: Remote, vmid: int) -> list[dict[str, Any]]:
    result = remote.run(["qm", "guest", "cmd", str(vmid), "network-get-interfaces"])
    payload = json.loads(result.stdout)
    if not isinstance(payload, list):
        raise RuntimeError("QGA network interface 응답이 list가 아닙니다")
    return payload


def qga_has_address(
    interfaces: list[dict[str, Any]],
    expected_ip: str,
    expected_mac: str,
) -> bool:
    for interface in interfaces:
        if str(interface.get("hardware-address", "")).lower() != expected_mac.lower():
            continue
        addresses = interface.get("ip-addresses", [])
        if any(address.get("ip-address") == expected_ip for address in addresses):
            return True
    return False


def config_value(config: str, key: str) -> str:
    prefix = f"{key}: "
    for line in config.splitlines():
        if line.startswith(prefix):
            return line.removeprefix(prefix)
    return ""


def scan_ed25519_host_key(address: str) -> str:
    result = subprocess.run(
        ["ssh-keyscan", "-T", "5", "-t", "ed25519", address],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    keys = {
        " ".join(line.split()[1:3])
        for line in result.stdout.splitlines()
        if len(line.split()) >= 3 and line.split()[1] == "ssh-ed25519"
    }
    if len(keys) != 1:
        raise SystemExit("임시 VM의 ED25519 SSH host key가 정확히 하나가 아닙니다")
    return next(iter(keys))


def agent_public_key() -> str:
    result = subprocess.run(
        ["ssh-add", "-L"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    keys = [line for line in result.stdout.splitlines() if line.startswith("ssh-ed25519 ")]
    if len(keys) != 1:
        raise SystemExit("SSH agent의 ED25519 public key가 정확히 하나여야 합니다")
    return keys[0] + "\n"


def write_private(path: Path, text: str) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(text)


def create(args: argparse.Namespace) -> None:
    validate(args)
    remote = Remote(args.proxmox_host, args.known_hosts)
    if remote.run(["qm", "status", str(args.vmid)], check=False).returncode == 0:
        raise SystemExit("대상 VMID가 이미 존재합니다")
    before_hash = remote.run(["sha256sum", "/etc/network/interfaces"]).stdout.split()[0]
    state_dir: Path = args.state_dir
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(state_dir, 0o700)
    sentinel = {"task": "BKP-01", "vmid": args.vmid, "hostname": args.name}
    state = {
        **sentinel,
        "address": args.address,
        "gateway": args.gateway,
        "vlan": args.vlan,
        "template_vmid": args.template_vmid,
        "proxmox_network_sha256": before_hash,
    }
    write_private(state_dir / "state.json", json.dumps(state, indent=2, sort_keys=True) + "\n")

    public_key_path = f"/run/bkp01-{args.vmid}.pub"
    remote.run(
        ["sh", "-c", f"umask 077; cat > {shlex.quote(public_key_path)}"],
        input_text=agent_public_key(),
    )
    try:
        remote.run(
            [
                "qm",
                "clone",
                str(args.template_vmid),
                str(args.vmid),
                "--name",
                args.name,
                "--full",
                "1",
                "--storage",
                "local-lvm",
                "--description",
                "BKP-01 ephemeral isolated restore drill; outside OpenTofu state",
            ]
        )
        remote.run(
            [
                "qm",
                "set",
                str(args.vmid),
                "--cores",
                "2",
                "--memory",
                "2048",
                "--balloon",
                "0",
                "--agent",
                "enabled=1",
                "--onboot",
                "0",
                "--net0",
                f"virtio,bridge=vmbr0,tag={args.vlan},firewall=1",
                "--ciuser",
                "rocky",
                "--ciupgrade",
                "0",
                "--sshkeys",
                public_key_path,
                "--ipconfig0",
                f"ip={args.address},gw={args.gateway}",
                "--nameserver",
                args.gateway,
                "--searchdomain",
                args.search_domain,
            ]
        )
    finally:
        remote.run(["unlink", public_key_path], check=False)

    remote.run(["qm", "start", str(args.vmid)])
    deadline = time.monotonic() + 240
    expected_ip = str(ipaddress.ip_interface(args.address).ip)
    vm_config = remote.run(["qm", "config", str(args.vmid)]).stdout
    if config_value(vm_config, "ciupgrade") not in {"0", ""}:
        raise SystemExit("임시 VM cloud-init package upgrade가 꺼지 않았습니다")
    net0 = config_value(vm_config, "net0")
    mac_match = re.search(r"(?:^|,)virtio=([0-9A-Fa-f:]{17})(?:,|$)", net0)
    if mac_match is None:
        raise SystemExit("임시 VM net0의 virtio MAC을 확인할 수 없습니다")
    expected_mac = mac_match.group(1)
    while time.monotonic() < deadline:
        if remote.run(["qm", "guest", "cmd", str(args.vmid), "ping"], check=False).returncode == 0:
            try:
                interfaces = qga_network(remote, args.vmid)
            except (RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError):
                interfaces = []
            if qga_has_address(interfaces, expected_ip, expected_mac):
                break
        time.sleep(2)
    else:
        raise SystemExit("QGA에서 승인한 임시 VM IP·MAC이 준비되지 않았습니다")

    restore_known_hosts = state_dir / "known_hosts"
    guest_key = scan_ed25519_host_key(expected_ip)
    write_private(restore_known_hosts, f"{expected_ip} {guest_key}\n")
    ssh_base = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=8",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={restore_known_hosts}",
        f"rocky@{expected_ip}",
    ]
    while time.monotonic() < deadline:
        try:
            result = subprocess.run(
                [*ssh_base, "sudo -n cloud-init status"],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=12,
            )
        except subprocess.TimeoutExpired:
            result = None
        if result is not None and result.returncode == 0 and result.stdout.strip() == "status: done":
            break
        if result is not None and "status: error" in result.stdout:
            raise SystemExit("cloud-init이 error 상태로 끝났습니다 (상세 미출력)")
        time.sleep(2)
    else:
        raise SystemExit("strict SSH 또는 cloud-init이 준비되지 않았습니다")

    host_key_check = subprocess.run(
        [*ssh_base, "sudo -n cat /etc/ssh/ssh_host_ed25519_key.pub"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if " ".join(host_key_check.stdout.split()[:2]) != guest_key:
        raise SystemExit("strict SSH 연결 뒤 guest host key 재대조가 실패했습니다")
    hostname_check = subprocess.run(
        [*ssh_base, "hostname -s"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout.strip()
    if hostname_check != args.name:
        raise SystemExit("임시 VM strict SSH hostname이 승인한 이름과 다릅니다")

    inventory = state_dir / "inventory.yml"
    ssh_common_args = (
        "-o BatchMode=yes -o StrictHostKeyChecking=yes "
        f"-o UserKnownHostsFile={restore_known_hosts}"
    )
    write_private(
        inventory,
        "all:\n"
        "  vars:\n"
        f"    ansible_ssh_common_args: {json.dumps(ssh_common_args)}\n"
        "  children:\n"
        "    rocky_baseline:\n"
        "      hosts:\n"
        "        bkp01-restore:\n"
        f"          ansible_host: {ipaddress.ip_interface(args.address).ip}\n"
        "          ansible_user: rocky\n"
        "    k3s_servers:\n"
        "      hosts:\n"
        "        bkp01-restore:\n"
        f"          ansible_host: {ipaddress.ip_interface(args.address).ip}\n"
        "          ansible_user: rocky\n",
    )
    subprocess.run(
        [*ssh_base, "sudo -n install -d -o root -g root -m 0700 /etc/bkp01-restore"],
        check=True,
        text=True,
    )
    subprocess.run(
        [
            *ssh_base,
            "sudo -n sh -c 'umask 077; cat > /etc/bkp01-restore-drill.json'",
        ],
        check=True,
        input=json.dumps(sentinel, sort_keys=True) + "\n",
        text=True,
    )
    after_hash = remote.run(["sha256sum", "/etc/network/interfaces"]).stdout.split()[0]
    if before_hash != after_hash:
        raise SystemExit("임시 VM 생성 중 Proxmox 영속 network config가 바뀌었습니다")
    print(json.dumps({"created": True, **state, "state_dir": str(state_dir)}, sort_keys=True))


def destroy(args: argparse.Namespace) -> None:
    validate(args)
    state_path = args.state_dir / "state.json"
    if state_path.stat().st_mode & 0o077:
        raise SystemExit("restore VM state file 권한이 너무 넓습니다")
    with state_path.open(encoding="utf-8") as stream:
        state: dict[str, Any] = json.load(stream)
    if state.get("task") != "BKP-01" or state.get("vmid") != args.vmid or state.get("hostname") != args.name:
        raise SystemExit("삭제 대상과 BKP-01 state가 정확히 일치하지 않습니다")

    remote = Remote(args.proxmox_host, args.known_hosts)
    config = remote.run(["qm", "config", str(args.vmid)])
    live_name = ""
    for line in config.stdout.splitlines():
        if line.startswith("name: "):
            live_name = line.removeprefix("name: ")
    if live_name != args.name:
        raise SystemExit("라이브 VM 이름이 승인한 BKP-01 임시 이름과 다릅니다")
    if remote.run(["qm", "status", str(args.vmid)]).stdout.strip().endswith("running"):
        remote.run(["qm", "shutdown", str(args.vmid), "--timeout", "60"], check=False)
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline:
            if remote.run(["qm", "status", str(args.vmid)]).stdout.strip().endswith("stopped"):
                break
            time.sleep(2)
        else:
            remote.run(["qm", "stop", str(args.vmid), "--timeout", "30"])
    remote.run(
        [
            "qm",
            "destroy",
            str(args.vmid),
            "--purge",
            "1",
            "--destroy-unreferenced-disks",
            "1",
        ]
    )
    if remote.run(["qm", "status", str(args.vmid)], check=False).returncode == 0:
        raise SystemExit("BKP-01 임시 VM 삭제 뒤 VMID가 남았습니다")
    network_hash = remote.run(["sha256sum", "/etc/network/interfaces"]).stdout.split()[0]
    if network_hash != state["proxmox_network_sha256"]:
        raise SystemExit("BKP-01 정리 뒤 Proxmox 영속 network config hash가 다릅니다")
    for name in ("known_hosts", "inventory.yml", "state.json"):
        (args.state_dir / name).unlink(missing_ok=True)
    args.state_dir.rmdir()
    print(json.dumps({"removed": True, "vmid": args.vmid, "hostname": args.name}, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("operation", choices=("create", "destroy"))
    result.add_argument("--proxmox-host", default="root@proxmox-01.imcherry5778.xyz")
    result.add_argument("--known-hosts", type=Path, required=True)
    result.add_argument("--state-dir", type=Path, required=True)
    result.add_argument("--vmid", type=int, required=True)
    result.add_argument("--name", required=True)
    result.add_argument("--template-vmid", type=int, default=9000)
    result.add_argument("--address", required=True)
    result.add_argument("--gateway", required=True)
    result.add_argument("--vlan", type=int, required=True)
    result.add_argument("--search-domain", required=True)
    return result


def main() -> None:
    args = parser().parse_args()
    if args.operation == "create":
        create(args)
    else:
        destroy(args)


if __name__ == "__main__":
    main()
