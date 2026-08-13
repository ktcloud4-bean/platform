#!/usr/bin/env python3
"""SOAR-01 immutable Argo root/child SHA 검증 후 literal main으로 복구한다."""

from __future__ import annotations

import argparse
import fcntl
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time


SSH = [
    "ssh",
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=/home/imcherry/.ssh/known_hosts",
    "rocky@k3s-01.imcherry5778.xyz",
]
KUBECTL = ["sudo", "-n", "/usr/local/bin/k3s", "kubectl"]
ROOT = "platform-root"
CHILDREN = ("shuffle", "wazuh")


class SafeError(RuntimeError):
    pass


class Remote:
    def kubectl(self, *args: str, check: bool = True) -> str:
        command = shlex.join([*KUBECTL, *args])
        result = subprocess.run(
            [*SSH, command],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if check and result.returncode:
            raise SafeError("Argo kubectl request failed")
        return result.stdout

    def application(self, name: str) -> dict:
        try:
            result = json.loads(self.kubectl("-n", "argocd", "get", "application", name, "-o", "json"))
        except json.JSONDecodeError as error:
            raise SafeError(f"Argo {name} response format is invalid") from error
        if not isinstance(result, dict):
            raise SafeError(f"Argo {name} response format is invalid")
        return result

    def patch(self, name: str, patch_type: str, value: object, check: bool = True) -> None:
        self.kubectl(
            "-n",
            "argocd",
            "patch",
            "application",
            name,
            f"--type={patch_type}",
            "--patch",
            json.dumps(value, separators=(",", ":")),
            check=check,
        )

    def refresh(self, name: str, check: bool = True) -> None:
        self.kubectl(
            "-n",
            "argocd",
            "annotate",
            "application",
            name,
            "argocd.argoproj.io/refresh=hard",
            "--overwrite",
            check=check,
        )


def state(application: dict) -> tuple[str, str, str, str]:
    source = application.get("spec", {}).get("source", {})
    status = application.get("status", {})
    return (
        str(source.get("targetRevision", "")),
        str(status.get("sync", {}).get("status", "")),
        str(status.get("health", {}).get("status", "")),
        str(status.get("sync", {}).get("revision", "")),
    )


def wait_application(remote: Remote, name: str, revision: str, attempts: int = 72) -> None:
    last = ("", "", "", "")
    for _ in range(attempts):
        last = state(remote.application(name))
        if last == (revision, "Synced", "Healthy", revision):
            return
        time.sleep(5)
    raise SafeError(
        f"Argo {name} did not reach immutable Synced/Healthy state "
        f"(target={last[0] or 'none'} sync={last[1] or 'none'} health={last[2] or 'none'} revision={last[3] or 'none'})"
    )


def wait_literal_main(remote: Remote, name: str, main_sha: str, attempts: int = 72) -> None:
    last = ("", "", "", "")
    for _ in range(attempts):
        last = state(remote.application(name))
        if last == ("main", "Synced", "Healthy", main_sha):
            return
        time.sleep(5)
    raise SafeError(
        f"Argo {name} did not return to literal main Synced/Healthy "
        f"(target={last[0] or 'none'} sync={last[1] or 'none'} health={last[2] or 'none'} revision={last[3] or 'none'})"
    )


def restore(remote: Remote, main_sha: str) -> None:
    for child in CHILDREN:
        remote.patch(child, "merge", {"spec": {"source": {"targetRevision": "main"}}}, check=False)
        remote.refresh(child, check=False)
    remote.patch(ROOT, "merge", {"spec": {"source": {"targetRevision": "main"}}}, check=False)
    remote.patch(ROOT, "json", [{"op": "remove", "path": "/spec/ignoreDifferences"}], check=False)
    remote.refresh(ROOT, check=False)
    for name in (ROOT, *CHILDREN):
        wait_literal_main(remote, name, main_sha)


def run(task_sha: str, main_sha: str, hold_seconds: int) -> None:
    lock_path = Path("/tmp/argo-root.lock")
    with lock_path.open("w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SafeError("ARGO-ROOT lock is already owned") from error
        remote = Remote()
        current = remote.application(ROOT)
        current_target, _sync, _health, current_revision = state(current)
        if current_target != "main" or current_revision != main_sha or current.get("spec", {}).get("ignoreDifferences"):
            raise SafeError("platform-root is not the recorded literal main baseline")
        ignored_children = [
            {
                "group": "argoproj.io",
                "kind": "Application",
                "name": child,
                "jsonPointers": ["/spec/source/targetRevision"],
            }
            for child in CHILDREN
        ]
        changed = False
        try:
            remote.patch(ROOT, "json", [{"op": "add", "path": "/spec/ignoreDifferences", "value": ignored_children}])
            changed = True
            remote.patch(ROOT, "merge", {"spec": {"source": {"targetRevision": task_sha}}})
            remote.refresh(ROOT)
            wait_application(remote, ROOT, task_sha)
            for child in CHILDREN:
                remote.patch(child, "merge", {"spec": {"source": {"targetRevision": task_sha}}})
                remote.refresh(child)
            for child in CHILDREN:
                wait_application(remote, child, task_sha)
            print(f"ArgoImmutable=PASS root={task_sha} children=shuffle,wazuh")
            if hold_seconds:
                print(f"ArgoHold=PASS seconds={hold_seconds}")
                time.sleep(hold_seconds)
        finally:
            if changed:
                restore(remote, main_sha)
                print(f"ArgoRestore=PASS main={main_sha}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-sha", required=True)
    parser.add_argument("--main-sha", required=True)
    parser.add_argument("--hold-seconds", type=int, default=0)
    args = parser.parse_args()
    if len(args.task_sha) != 40 or len(args.main_sha) != 40:
        print("ArgoImmutable=FAIL reason=full 40-character SHA is required", file=sys.stderr)
        return 2
    if not 0 <= args.hold_seconds <= 900:
        print("ArgoImmutable=FAIL reason=hold must be between 0 and 900 seconds", file=sys.stderr)
        return 2
    try:
        run(args.task_sha, args.main_sha, args.hold_seconds)
    except SafeError as error:
        print(f"ArgoImmutable=FAIL reason={error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
