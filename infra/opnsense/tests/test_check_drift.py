import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


COMPONENT_DIR = Path(__file__).resolve().parents[1]
SCRIPT = COMPONENT_DIR / "scripts" / "check-drift.sh"
COMMITTED = COMPONENT_DIR / "config.xml"


class CheckDriftCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.temp = Path(self.tempdir.name)
        self.bin_dir = self.temp / "bin"
        self.bin_dir.mkdir()
        self.curl_log = self.temp / "curl.args"

        fake_curl = self.bin_dir / "curl"
        fake_curl.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                : > "$FAKE_CURL_LOG"
                if [[ -v OPN_KEY || -v OPN_SECRET ]]; then
                  printf '%s\n' 'ENV_SECRET_EXPORTED' >> "$FAKE_CURL_LOG"
                fi
                output=""
                while [ "$#" -gt 0 ]; do
                  printf '%s\n' "$1" >> "$FAKE_CURL_LOG"
                  if [ "$1" = "-o" ]; then
                    [ "$#" -ge 2 ] || exit 90
                    output=$2
                    printf '%s\n' "$2" >> "$FAKE_CURL_LOG"
                    shift 2
                  else
                    shift
                  fi
                done
                [ -n "$output" ] || exit 91
                cp "$FAKE_CURL_PAYLOAD" "$output"
                """
            ),
            encoding="utf-8",
        )
        fake_curl.chmod(
            fake_curl.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        )

        self.base_env = os.environ.copy()
        self.base_env["PATH"] = f"{self.bin_dir}:{self.base_env['PATH']}"
        self.base_env["FAKE_CURL_LOG"] = str(self.curl_log)
        self.base_env["FAKE_CURL_PAYLOAD"] = str(COMMITTED)
        for key in ("OPN_KEY", "OPN_SECRET", "OPN_URL", "OPN_CACERT"):
            self.base_env.pop(key, None)

    def make_env_file(self, contents: str, mode: int = 0o600) -> Path:
        env_file = self.temp / "credentials.env"
        env_file.write_text(contents, encoding="utf-8")
        env_file.chmod(mode)
        return env_file

    def run_script(
        self, *args: str, extra_env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        env = self.base_env.copy()
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=COMPONENT_DIR.parents[1],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def curl_args(self) -> list[str]:
        return self.curl_log.read_text(encoding="utf-8").splitlines()

    def test_env_file_loads_only_opn_keys_and_verifies_tls(self) -> None:
        env_file = self.make_env_file(
            "\n".join(
                (
                    "OPN_KEY=synthetic-api-key",
                    "OPN_SECRET=synthetic-api-secret",
                    "CLOUDFLARE_API_TOKEN=must-not-be-exported",
                    "",
                )
            )
        )

        result = self.run_script("--env-file", str(env_file))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TLS 인증서 검증 활성화", result.stdout)
        self.assertIn("드리프트 없음", result.stdout)
        args = self.curl_args()
        self.assertNotIn("-k", args)
        self.assertNotIn("ENV_SECRET_EXPORTED", args)
        auth_config = Path(args[args.index("--config") + 1])
        self.assertFalse(auth_config.exists())
        self.assertIn(
            "https://opnsense.imcherry5778.xyz/api/core/backup/download/this",
            args,
        )
        combined = result.stdout + result.stderr + "\n".join(args)
        self.assertNotIn("synthetic-api-key", combined)
        self.assertNotIn("synthetic-api-secret", combined)
        self.assertNotIn("must-not-be-exported", combined)

    def test_connect_ip_keeps_hostname_verification(self) -> None:
        env_file = self.make_env_file(
            "OPN_KEY=synthetic-api-key\nOPN_SECRET=synthetic-api-secret\n"
        )

        result = self.run_script(
            "--env-file", str(env_file), "--connect-ip", "192.0.2.1"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hostname 검증 유지", result.stdout)
        args = self.curl_args()
        self.assertNotIn("-k", args)
        self.assertIn("--resolve", args)
        self.assertIn("opnsense.imcherry5778.xyz:443:192.0.2.1", args)

    def test_exported_credentials_are_not_inherited_by_curl(self) -> None:
        env_file = self.make_env_file("CLOUDFLARE_API_TOKEN=ignored\n")

        result = self.run_script(
            "--env-file",
            str(env_file),
            extra_env={
                "OPN_KEY": "synthetic-exported-key",
                "OPN_SECRET": "synthetic-exported-secret",
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.curl_args()
        self.assertNotIn("ENV_SECRET_EXPORTED", args)
        combined = result.stdout + result.stderr + "\n".join(args)
        self.assertNotIn("synthetic-exported-key", combined)
        self.assertNotIn("synthetic-exported-secret", combined)

    def test_insecure_is_explicit_and_warns(self) -> None:
        env_file = self.make_env_file(
            "OPN_KEY=synthetic-api-key\nOPN_SECRET=synthetic-api-secret\n"
        )

        result = self.run_script("--env-file", str(env_file), "--insecure")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TLS 인증서 검증이 비활성화", result.stderr)
        self.assertIn("-k", self.curl_args())

    def test_insecure_cannot_update_snapshot(self) -> None:
        env_file = self.make_env_file(
            "OPN_KEY=synthetic-api-key\nOPN_SECRET=synthetic-api-secret\n"
        )

        result = self.run_script(
            "--env-file", str(env_file), "--insecure", "--update"
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("--insecure 상태에서는 --update할 수 없습니다", result.stderr)
        self.assertFalse(self.curl_log.exists())

    def test_env_file_rejects_group_or_other_permissions(self) -> None:
        env_file = self.make_env_file(
            "OPN_KEY=synthetic-api-key\nOPN_SECRET=synthetic-api-secret\n",
            mode=0o644,
        )

        result = self.run_script("--env-file", str(env_file))

        self.assertEqual(result.returncode, 2)
        self.assertIn("group/other 권한을 제거", result.stderr)
        self.assertFalse(self.curl_log.exists())

    def test_env_file_rejects_unknown_opn_key(self) -> None:
        env_file = self.make_env_file(
            "OPN_KEY=synthetic-api-key\n"
            "OPN_SECRET=synthetic-api-secret\n"
            "OPN_SECRT=typo\n"
        )

        result = self.run_script("--env-file", str(env_file))

        self.assertEqual(result.returncode, 2)
        self.assertIn("허용되지 않은 OPN_*", result.stderr)
        self.assertFalse(self.curl_log.exists())

    def test_missing_credentials_stops_before_network(self) -> None:
        env_file = self.make_env_file("# intentionally empty\n")

        result = self.run_script("--env-file", str(env_file))

        self.assertEqual(result.returncode, 2)
        self.assertIn("OPN_KEY / OPN_SECRET이 필요", result.stderr)
        self.assertFalse(self.curl_log.exists())


if __name__ == "__main__":
    unittest.main()
