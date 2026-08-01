from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
FILES = ROOT / "infra" / "ansible" / "roles" / "k3s_datastore_backup" / "files"
TOOLS = ROOT / "infra" / "ansible" / "tools" / "bkp-01"
sys.path.insert(0, str(FILES))


def load_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError(f"module load 실패: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


backup = load_module("test_k3s_datastore_backup", FILES / "k3s_datastore_backup.py")
proxmox = load_module("test_proxmox_restore_vm", TOOLS / "proxmox-restore-vm.py")
s3 = load_module("test_s3_sigv4", FILES / "s3_sigv4.py")


def private_json(path: Path, payload: dict[str, object]) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream)


class OnlineBackupTests(unittest.TestCase):
    def test_secret_file_check_uses_non_following_stat(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            secret = Path(temporary) / "secret"
            secret.write_text("test", encoding="utf-8")
            secret.chmod(0o600)
            if os.geteuid() == 0:
                self.assertEqual(backup.check_secret_file(secret).st_size, 4)
            else:
                with self.assertRaisesRegex(SystemExit, "root:root"):
                    backup.check_secret_file(secret)

    def test_online_backup_captures_consistent_wal_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.db"
            destination = Path(temporary) / "destination.db"
            connection = sqlite3.connect(source)
            try:
                self.assertEqual(connection.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
                connection.execute("CREATE TABLE proof(id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
                connection.executemany(
                    "INSERT INTO proof(value) VALUES (?)",
                    [(f"row-{index}",) for index in range(1000)],
                )
                connection.commit()
                quick_check, pages = backup.online_backup(source, destination)
                self.assertEqual(quick_check, "ok")
                self.assertGreater(pages, 0)
                connection.execute("INSERT INTO proof(value) VALUES ('after-snapshot')")
                connection.commit()
            finally:
                connection.close()
            restored = sqlite3.connect(destination)
            try:
                self.assertEqual(restored.execute("PRAGMA quick_check").fetchone()[0], "ok")
                self.assertEqual(restored.execute("SELECT count(*) FROM proof").fetchone()[0], 1000)
            finally:
                restored.close()

    def test_velero_path_coverage_detects_parent_mount(self) -> None:
        target = "/var/lib/rancher/k3s/server/db/state.db"
        self.assertTrue(backup.path_covers("/", target))
        self.assertTrue(backup.path_covers("/var/lib/rancher/k3s", target))
        self.assertFalse(backup.path_covers("/var/lib/kubelet/pods", target))


class IdentityRenderTests(unittest.TestCase):
    def test_render_preserves_bkp02_and_adds_bkp01(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            bkp01 = directory / "bkp01.json"
            bkp02 = directory / "bkp02.json"
            output = directory / "output.json"
            private_json(
                bkp01,
                {
                    "bucket": "bkp-01-k3s-datastore",
                    "bootstrap": {"access_key": "A" * 20, "secret_key": "B" * 48},
                    "backup": {"access_key": "C" * 20, "secret_key": "D" * 48},
                },
            )
            private_json(
                bkp02,
                {
                    "bucket": "bkp-02-velero",
                    "velero": {"access_key": "E" * 20, "secret_key": "F" * 48},
                },
            )
            subprocess.run(
                [
                    sys.executable,
                    str(TOOLS / "render-seaweedfs-vars.py"),
                    "--bkp-01-input",
                    str(bkp01),
                    "--bkp-02-input",
                    str(bkp02),
                    "--phase",
                    "bootstrap",
                    "--output",
                    str(output),
                ],
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )
            payload = json.loads(output.read_text(encoding="utf-8"))
            names = [identity["name"] for identity in payload["seaweedfs_s3_identities"]]
            self.assertEqual(
                names,
                ["bkp-02-velero", "bkp-01-bucket-bootstrap", "bkp-01-k3s-datastore"],
            )
            self.assertEqual(oct(output.stat().st_mode & 0o777), "0o600")

    def test_retire_bootstrap_keeps_backup_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "input.json"
            private_json(
                source,
                {
                    "bucket": "bkp-01-k3s-datastore",
                    "bootstrap": {"access_key": "A", "secret_key": "B"},
                    "backup": {"access_key": "C", "secret_key": "D"},
                },
            )
            subprocess.run(
                [sys.executable, str(TOOLS / "retire-bootstrap-credential.py"), "--input", str(source)],
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )
            payload = json.loads(source.read_text(encoding="utf-8"))
            self.assertNotIn("bootstrap", payload)
            self.assertIn("backup", payload)
            self.assertEqual(oct(source.stat().st_mode & 0o777), "0o600")


class GuardTests(unittest.TestCase):
    @staticmethod
    def arguments(**overrides: object) -> argparse.Namespace:
        values: dict[str, object] = {
            "vmid": 9901,
            "name": "bkp01-restore-20260801",
            "address": "10.10.20.250/24",
            "gateway": "10.10.20.1",
            "vlan": 20,
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_restore_target_guard_accepts_experimental_address(self) -> None:
        proxmox.validate(self.arguments())

    def test_restore_target_guard_rejects_service_vmid(self) -> None:
        with self.assertRaises(SystemExit):
            proxmox.validate(self.arguments(vmid=120))

    def test_restore_target_guard_rejects_non_experimental_address(self) -> None:
        with self.assertRaises(SystemExit):
            proxmox.validate(self.arguments(address="10.10.20.10/24"))

    def test_qga_address_requires_expected_ip_and_mac(self) -> None:
        interfaces = [
            {
                "hardware-address": "bc:24:11:aa:bb:cc",
                "ip-addresses": [{"ip-address": "10.10.20.250"}],
            }
        ]
        self.assertTrue(
            proxmox.qga_has_address(interfaces, "10.10.20.250", "BC:24:11:AA:BB:CC")
        )
        self.assertFalse(
            proxmox.qga_has_address(interfaces, "10.10.20.251", "BC:24:11:AA:BB:CC")
        )
        self.assertFalse(
            proxmox.qga_has_address(interfaces, "10.10.20.250", "BC:24:11:00:00:00")
        )

    def test_qm_config_value_reads_exact_key(self) -> None:
        config = "name: bkp01-restore-20260801\nciupgrade: 0\n"
        self.assertEqual(proxmox.config_value(config, "ciupgrade"), "0")
        self.assertEqual(proxmox.config_value(config, "upgrade"), "")

    def test_s3_error_never_includes_response_body(self) -> None:
        response = s3.Response(403, {}, b"sensitive response body")
        with self.assertRaisesRegex(s3.S3Error, "응답 본문 미출력") as caught:
            s3.S3Client.require(response, {200}, "negative control")
        self.assertNotIn("sensitive", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
