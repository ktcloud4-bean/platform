#!/usr/bin/env python3
"""실행 중 k3s SQLite와 server token을 암호화해 전용 S3에 백업한다."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from s3_sigv4 import Endpoint, Identity, S3Client


DATASTORE = Path("/var/lib/rancher/k3s/server/db/state.db")
TOKEN = Path("/var/lib/rancher/k3s/server/token")
K3S = Path("/usr/local/bin/k3s")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def systemd_state() -> dict[str, str]:
    result = run(
        [
            "systemctl",
            "show",
            "k3s",
            "--property=ActiveState,SubState,MainPID,NRestarts,ActiveEnterTimestampMonotonic",
        ]
    )
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    if values.get("ActiveState") != "active" or values.get("SubState") != "running":
        raise SystemExit("k3s가 active/running이 아니므로 온라인 백업을 중단합니다")
    return values


def check_secret_file(path: Path) -> os.stat_result:
    information = os.stat(path, follow_symlinks=False)
    if not stat.S_ISREG(information.st_mode):
        raise SystemExit(f"필수 입력이 일반 파일이 아닙니다: {path}")
    if information.st_uid != 0 or information.st_gid != 0:
        raise SystemExit(f"필수 입력이 root:root 소유가 아닙니다: {path}")
    if stat.S_IMODE(information.st_mode) & 0o077:
        raise SystemExit(f"필수 입력 권한이 너무 넓습니다: {path}")
    return information


def stable_file_identity(information: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        information.st_dev,
        information.st_ino,
        information.st_size,
        information.st_mtime_ns,
        information.st_ctime_ns,
    )


def sqlite_quick_check(path: Path, *, read_only: bool) -> tuple[str, int]:
    target = f"file:{path}?mode=ro" if read_only else str(path)
    connection = sqlite3.connect(target, uri=read_only, timeout=30)
    try:
        if read_only:
            connection.execute("PRAGMA query_only=ON")
        result = connection.execute("PRAGMA quick_check").fetchall()
        page_count = int(connection.execute("PRAGMA page_count").fetchone()[0])
    finally:
        connection.close()
    message = ",".join(str(row[0]) for row in result)
    if result != [("ok",)]:
        raise SystemExit(f"SQLite quick_check 실패: {message}")
    return message, page_count


def online_backup(source: Path, destination: Path) -> tuple[str, int]:
    source_connection = sqlite3.connect(
        f"file:{source}?mode=ro",
        uri=True,
        timeout=30,
    )
    destination_connection = sqlite3.connect(str(destination), timeout=30)
    try:
        source_connection.execute("PRAGMA query_only=ON")
        source_connection.backup(destination_connection, pages=256, sleep=0.05)
    finally:
        destination_connection.close()
        source_connection.close()
    os.chmod(destination, 0o600)
    return sqlite_quick_check(destination, read_only=True)


def kubectl_json(arguments: list[str]) -> dict[str, Any]:
    result = run([str(K3S), "kubectl", *arguments, "-o", "json"])
    return json.loads(result.stdout)


def api_proof() -> list[dict[str, str]]:
    targets = [
        ("namespaces", None, "velero", "spec"),
        ("configmaps", "kube-system", "coredns", "data"),
        (
            "customresourcedefinitions.apiextensions.k8s.io",
            None,
            "backups.velero.io",
            "spec",
        ),
        ("applications.argoproj.io", "argocd", "platform-root", "spec"),
        ("deployments.apps", "velero", "velero", "spec"),
    ]
    proof: list[dict[str, str]] = []
    for resource, namespace, name, section in targets:
        arguments = []
        if namespace is not None:
            arguments.extend(["-n", namespace])
        arguments.extend(["get", resource, name])
        payload = kubectl_json(arguments)
        proof.append(
            {
                "resource": resource,
                "namespace": namespace or "",
                "name": name,
                "uid": payload["metadata"]["uid"],
                "section": section,
                "section_sha256": canonical_hash(payload.get(section)),
            }
        )
    return proof


def path_covers(candidate: str, target: str) -> bool:
    candidate_path = os.path.normpath(candidate)
    target_path = os.path.normpath(target)
    try:
        return os.path.commonpath([candidate_path, target_path]) == candidate_path
    except ValueError:
        return False


def velero_boundary() -> dict[str, Any]:
    daemonset = kubectl_json(["-n", "velero", "get", "daemonsets.apps", "node-agent"])
    host_paths = sorted(
        volume["hostPath"]["path"]
        for volume in daemonset["spec"]["template"]["spec"].get("volumes", [])
        if "hostPath" in volume
    )
    protected_paths = [str(DATASTORE), str(TOKEN)]
    covered = {
        target: any(path_covers(candidate, target) for candidate in host_paths)
        for target in protected_paths
    }
    if any(covered.values()):
        raise SystemExit("Velero node-agent가 BKP-01 server 경로를 mount한 예상 밖 상태입니다")
    restores = kubectl_json(["-n", "velero", "get", "restores.velero.io"])
    bsl = kubectl_json(
        ["-n", "velero", "get", "backupstoragelocations.velero.io", "default"]
    )
    return {
        "node_agent_host_paths": host_paths,
        "k3s_server_paths_covered": covered,
        "restore_objects": len(restores.get("items", [])),
        "backup_storage_location": {
            "bucket": bsl.get("spec", {}).get("objectStorage", {}).get("bucket", ""),
            "prefix": bsl.get("spec", {}).get("objectStorage", {}).get("prefix", ""),
            "phase": bsl.get("status", {}).get("phase", ""),
        },
    }


def encrypt_tar(
    working: Path,
    output: Path,
    public_key: Path,
    recipient: str,
) -> None:
    with tempfile.TemporaryDirectory(prefix="gnupg-", dir=working) as home_name:
        home = Path(home_name)
        os.chmod(home, 0o700)
        run(
            [
                "gpg",
                "--homedir",
                str(home),
                "--batch",
                "--quiet",
                "--import",
                str(public_key),
            ]
        )
        process = subprocess.Popen(
            [
                "gpg",
                "--homedir",
                str(home),
                "--batch",
                "--quiet",
                "--trust-model",
                "always",
                "--recipient",
                recipient,
                "--output",
                str(output),
                "--encrypt",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if process.stdin is None:
            raise SystemExit("GPG stdin 생성에 실패했습니다")
        try:
            with tarfile.open(fileobj=process.stdin, mode="w|") as archive:
                archive.add(working / "state.db", arcname="server/db/state.db")
                archive.add(working / "server-token", arcname="server/token")
                archive.add(working / "manifest.json", arcname="manifest.json")
        finally:
            with contextlib.suppress(BrokenPipeError):
                process.stdin.close()
        error = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
        return_code = process.wait()
        if return_code != 0:
            raise SystemExit(f"GPG 암호화 실패(rc={return_code}, 상세 미출력)") from RuntimeError(
                error
            )
    os.chmod(output, 0o600)


def load_config(path: Path) -> dict[str, Any]:
    check_secret_file(path)
    with path.open(encoding="utf-8") as stream:
        config = json.load(stream)
    required = [
        "bucket",
        "prefix",
        "s3_host",
        "s3_port",
        "s3_region",
        "s3_access_key",
        "s3_secret_key",
        "s3_ca_file",
        "gpg_recipient",
        "gpg_public_key_file",
    ]
    missing = [name for name in required if not config.get(name)]
    if missing:
        raise SystemExit("BKP-01 config 필수 항목이 없습니다: " + ",".join(missing))
    return config


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise SystemExit("BKP-01 backup은 root로 실행해야 합니다")
    config = load_config(args.config)
    token_before = check_secret_file(TOKEN)
    if not DATASTORE.is_file():
        raise SystemExit("k3s SQLite datastore가 없습니다")

    state_dir = Path(config.get("state_dir", "/var/lib/k3s-datastore-backup"))
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)
    lock_path = state_dir / "backup.lock"
    lock_descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_descriptor, "r+") as lock_stream:
        try:
            fcntl.flock(lock_stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SystemExit("다른 BKP-01 backup 실행이 진행 중입니다") from error

        before = systemd_state()
        source_check, source_pages = sqlite_quick_check(DATASTORE, read_only=True)
        created = datetime.now(timezone.utc)
        backup_id = created.strftime("%Y%m%dT%H%M%SZ")
        key = f"{config['prefix'].rstrip('/')}/{backup_id}/k3s-sqlite-server-token.tar.gpg"

        with tempfile.TemporaryDirectory(prefix="work-", dir=state_dir) as working_name:
            working = Path(working_name)
            os.chmod(working, 0o700)
            database_copy = working / "state.db"
            backup_check, backup_pages = online_backup(DATASTORE, database_copy)
            token_copy = working / "server-token"
            with TOKEN.open("rb") as source, token_copy.open("xb") as destination:
                os.chmod(token_copy, 0o600)
                shutil.copyfileobj(source, destination)
            token_after = check_secret_file(TOKEN)
            if stable_file_identity(token_before) != stable_file_identity(token_after):
                raise SystemExit("온라인 backup 중 server token 파일이 바뀌었습니다")

            proof = api_proof()
            boundary = velero_boundary()
            after_copy = systemd_state()
            service_unchanged = all(
                before.get(name) == after_copy.get(name)
                for name in ("MainPID", "NRestarts", "ActiveEnterTimestampMonotonic")
            )
            if not service_unchanged:
                raise SystemExit("온라인 backup 중 k3s service identity가 바뀌었습니다")

            manifest = {
                "format": "bkp-01-k3s-sqlite-v1",
                "created_at": created.isoformat(),
                "source_hostname": os.uname().nodename,
                "k3s_version": run([str(K3S), "--version"]).stdout.splitlines()[0],
                "database": {
                    "path": str(DATASTORE),
                    "bytes": database_copy.stat().st_size,
                    "sha256": sha256_file(database_copy),
                    "source_quick_check": source_check,
                    "source_pages": source_pages,
                    "backup_quick_check": backup_check,
                    "backup_pages": backup_pages,
                },
                "server_token": {
                    "path": str(TOKEN),
                    "bytes": token_copy.stat().st_size,
                    "sha256": sha256_file(token_copy),
                },
                "api_proof": proof,
                "velero_boundary": boundary,
                "k3s_service": {
                    "before": before,
                    "after_online_copy": after_copy,
                    "unchanged": service_unchanged,
                },
            }
            manifest_path = working / "manifest.json"
            descriptor = os.open(manifest_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(manifest, stream, indent=2, sort_keys=True)
                stream.write("\n")

            encrypted = working / "backup.tar.gpg"
            encrypt_tar(
                working,
                encrypted,
                Path(config["gpg_public_key_file"]),
                str(config["gpg_recipient"]),
            )
            encrypted_bytes = encrypted.read_bytes()
            encrypted_sha256 = hashlib.sha256(encrypted_bytes).hexdigest()

            client = S3Client(
                Endpoint(
                    host=str(config["s3_host"]),
                    port=int(config["s3_port"]),
                    region=str(config["s3_region"]),
                    ca_file=Path(config["s3_ca_file"]),
                ),
                Identity(
                    access_key=str(config["s3_access_key"]),
                    secret_key=str(config["s3_secret_key"]),
                ),
            )
            client.put_object(str(config["bucket"]), key, encrypted_bytes)
            head = client.head_object(str(config["bucket"]), key)
            downloaded = client.get_object(str(config["bucket"]), key)
            if hashlib.sha256(downloaded).hexdigest() != encrypted_sha256:
                raise SystemExit("S3 재다운로드 SHA-256이 업로드 원본과 다릅니다")
            objects = client.list_objects(str(config["bucket"]), f"{config['prefix'].rstrip('/')}/")
            if (key, len(encrypted_bytes)) not in objects:
                raise SystemExit("업로드한 backup object가 S3 LIST 결과에 없습니다")

            final_state = systemd_state()
            if any(
                before.get(name) != final_state.get(name)
                for name in ("MainPID", "NRestarts", "ActiveEnterTimestampMonotonic")
            ):
                raise SystemExit("S3 검증 뒤 k3s service identity가 바뀌었습니다")

            # BKP-12: freshness health-check용 last-success.epoch 원자적 기록
            success_epoch_path = state_dir / "last-success.epoch"
            temp_epoch_path = working / "last-success.epoch.tmp"
            temp_epoch_path.write_text(f"{int(created.timestamp())}\n", encoding="utf-8")
            os.chmod(temp_epoch_path, 0o600)
            shutil.move(str(temp_epoch_path), str(success_epoch_path))

            summary = {
                "backup_id": backup_id,
                "bucket": config["bucket"],
                "key": key,
                "encrypted_bytes": len(encrypted_bytes),
                "encrypted_sha256": encrypted_sha256,
                "database_bytes": database_copy.stat().st_size,
                "database_sha256": manifest["database"]["sha256"],
                "source_quick_check": source_check,
                "backup_quick_check": backup_check,
                "s3_content_length": int(head.headers.get("content-length", "0")),
                "api_objects": [f"{item['resource']}/{item['name']}" for item in proof],
                "velero_restore_objects": boundary["restore_objects"],
                "velero_server_paths_covered": boundary["k3s_server_paths_covered"],
                "k3s_service_unchanged": True,
            }
            print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
