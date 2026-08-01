#!/usr/bin/env python3
"""BKP-01 격리 VM에서만 SQLite/token 음성·양성 복원을 실행한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Any


DATA_DIR = Path("/var/lib/rancher/k3s")
KUBECONFIG = Path("/etc/rancher/k3s/k3s.yaml")
SENTINEL = Path("/etc/bkp01-restore-drill.json")
K3S = Path("/usr/local/bin/k3s")


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def guard(expected_hostname: str) -> dict[str, Any]:
    current = os.uname().nodename.split(".", maxsplit=1)[0]
    if not re.fullmatch(r"bkp01-restore-[a-z0-9-]+", expected_hostname):
        raise SystemExit("임시 restore hostname 형식이 아닙니다")
    if current != expected_hostname or current.startswith("k3s-01"):
        raise SystemExit("라이브 또는 예상 밖 host에서 restore를 거부합니다")
    if not SENTINEL.is_file() or SENTINEL.stat().st_mode & 0o077:
        raise SystemExit("root-only BKP-01 restore sentinel이 없습니다")
    with SENTINEL.open(encoding="utf-8") as stream:
        sentinel = json.load(stream)
    if sentinel.get("task") != "BKP-01" or sentinel.get("hostname") != expected_hostname:
        raise SystemExit("BKP-01 restore sentinel 내용이 현재 host와 다릅니다")
    isolation = run(["nft", "list", "table", "inet", "bkp01_isolation"], check=False)
    if isolation.returncode != 0 or "policy drop" not in isolation.stdout:
        raise SystemExit("BKP-01 network isolation enforcement가 없습니다")
    return sentinel


def reset_data(staging: Path, include_token: bool) -> dict[str, Any]:
    if DATA_DIR != Path("/var/lib/rancher/k3s"):
        raise SystemExit("restore data-dir guard 실패")
    run(["systemctl", "stop", "k3s"], check=False)
    killall = Path("/usr/local/bin/k3s-killall.sh")
    if killall.is_file():
        run([str(killall)], check=False)
    if DATA_DIR.exists():
        shutil.rmtree(DATA_DIR)
    database_dir = DATA_DIR / "server" / "db"
    database_dir.mkdir(mode=0o700, parents=True)
    database_source = staging / "server" / "db" / "state.db"
    token_source = staging / "server" / "token"
    shutil.copyfile(database_source, database_dir / "state.db")
    os.chmod(database_dir / "state.db", 0o600)
    if include_token:
        shutil.copyfile(token_source, DATA_DIR / "server" / "token")
        os.chmod(DATA_DIR / "server" / "token", 0o600)
    KUBECONFIG.unlink(missing_ok=True)
    return {
        "database_sha256": sha256_file(database_dir / "state.db"),
        "token_included": include_token,
    }


def wait_for_negative(timeout: int) -> dict[str, Any]:
    cursor_result = run(
        ["journalctl", "-u", "k3s", "-n", "0", "--show-cursor", "--no-pager"],
        check=False,
    )
    cursor = ""
    for line in cursor_result.stdout.splitlines():
        if line.startswith("-- cursor: "):
            cursor = line.removeprefix("-- cursor: ").strip()
    run(["systemctl", "start", "k3s"], check=False)
    deadline = time.monotonic() + timeout
    pattern = re.compile(
        r"failed.*(decrypt|token|bootstrap)|"
        r"bootstrap.*(decrypt|token|password)|"
        r"cipher: message authentication failed|"
        r"unable to load bootstrap",
        re.IGNORECASE,
    )
    matched = False
    excerpt_class = ""
    while time.monotonic() < deadline:
        ready = run([str(K3S), "kubectl", "get", "--raw=/readyz"], check=False)
        if ready.returncode == 0 and ready.stdout.strip() == "ok":
            raise SystemExit("server token 없는 음성 시험에서 API가 예상 밖으로 준비됐습니다")
        journal_command = ["journalctl", "-u", "k3s", "--no-pager", "-n", "120"]
        if cursor:
            journal_command.extend(["--after-cursor", cursor])
        journal = run(journal_command, check=False)
        for line in journal.stdout.splitlines():
            if pattern.search(line):
                matched = True
                excerpt_class = "token/bootstrap decryption failure"
                break
        if matched:
            break
        time.sleep(2)
    run(["systemctl", "stop", "k3s"], check=False)
    if not matched:
        raise SystemExit("server token 없는 실패의 token/bootstrap 근거를 찾지 못했습니다")
    return {"api_ready": False, "failure_class": excerpt_class}


def kubectl_json(arguments: list[str]) -> dict[str, Any]:
    result = run([str(K3S), "kubectl", *arguments, "-o", "json"])
    return json.loads(result.stdout)


def wait_for_positive(timeout: int, manifest: dict[str, Any]) -> dict[str, Any]:
    run(["systemctl", "start", "k3s"], check=False)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready = run([str(K3S), "kubectl", "get", "--raw=/readyz"], check=False)
        if ready.returncode == 0 and ready.stdout.strip() == "ok":
            break
        time.sleep(2)
    else:
        raise SystemExit("올바른 token 복원 뒤 Kubernetes API가 준비되지 않았습니다")

    restored: list[dict[str, str]] = []
    for expected in manifest["api_proof"]:
        arguments = []
        if expected["namespace"]:
            arguments.extend(["-n", expected["namespace"]])
        arguments.extend(["get", expected["resource"], expected["name"]])
        payload = kubectl_json(arguments)
        actual_hash = canonical_hash(payload.get(expected["section"]))
        if payload["metadata"]["uid"] != expected["uid"]:
            raise SystemExit(f"복원 API UID 불일치: {expected['resource']}/{expected['name']}")
        if actual_hash != expected["section_sha256"]:
            raise SystemExit(f"복원 API spec/data 불일치: {expected['resource']}/{expected['name']}")
        restored.append(
            {
                "resource": expected["resource"],
                "name": expected["name"],
                "uid": expected["uid"],
            }
        )
    restores = kubectl_json(["-n", "velero", "get", "restores.velero.io"])
    if restores.get("items"):
        raise SystemExit("격리 복원 cluster에 Velero Restore CR이 존재합니다")
    connection = sqlite3.connect(
        "file:/var/lib/rancher/k3s/server/db/state.db?mode=ro",
        uri=True,
        timeout=30,
    )
    try:
        quick_check = connection.execute("PRAGMA quick_check").fetchone()[0]
    finally:
        connection.close()
    if quick_check != "ok":
        raise SystemExit("복원 뒤 SQLite quick_check가 ok가 아닙니다")
    return {
        "api_ready": True,
        "quick_check": quick_check,
        "restored_api_objects": restored,
        "velero_restore_objects": 0,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("without-token", "with-token"), required=True)
    parser.add_argument("--staging", type=Path, required=True)
    parser.add_argument("--expected-hostname", required=True)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise SystemExit("BKP-01 restore는 root로 실행해야 합니다")
    sentinel = guard(args.expected_hostname)
    manifest_path = args.staging / "manifest.json"
    with manifest_path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("format") != "bkp-01-k3s-sqlite-v1":
        raise SystemExit("알 수 없는 BKP-01 archive format입니다")
    database = args.staging / "server" / "db" / "state.db"
    token = args.staging / "server" / "token"
    if sha256_file(database) != manifest["database"]["sha256"]:
        raise SystemExit("staging SQLite SHA-256이 manifest와 다릅니다")
    if sha256_file(token) != manifest["server_token"]["sha256"]:
        raise SystemExit("staging server token SHA-256이 manifest와 다릅니다")

    include_token = args.mode == "with-token"
    reset = reset_data(args.staging, include_token)
    result = (
        wait_for_positive(args.timeout, manifest)
        if include_token
        else wait_for_negative(args.timeout)
    )
    print(
        json.dumps(
            {
                "task": sentinel["task"],
                "vmid": sentinel["vmid"],
                "mode": args.mode,
                "reset": reset,
                "result": result,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
