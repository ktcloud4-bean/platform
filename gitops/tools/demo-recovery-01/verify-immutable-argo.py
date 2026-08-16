#!/usr/bin/env python3
"""DEMO-RECOVERY-01을 immutable SHA에서 검증하고 literal main으로 복구한다."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time


SSH = [
    "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=/home/imcherry/.ssh/known_hosts",
    "rocky@k3s-01.imcherry5778.xyz",
]
KUBECTL = ["sudo", "-n", "/usr/local/bin/k3s", "kubectl"]
ROOT = "platform-root"
CHILD = "demo-onprem"
POLICY_CHILD = "policy-baseline"
RELATED = ("velero", POLICY_CHILD)
LOCKS = (Path("/tmp/ktcloud4-bean-argo-root.lock"), Path("/tmp/argo-root.lock"))


class SafeError(RuntimeError):
    pass


class Remote:
    def kubectl(self, *args: str, check: bool = True) -> str:
        result = subprocess.run(
            [*SSH, shlex.join([*KUBECTL, *args])], stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, check=False,
        )
        if check and result.returncode:
            raise SafeError("remote kubectl request failed")
        return result.stdout

    def app(self, name: str) -> dict:
        try:
            value = json.loads(self.kubectl("-n", "argocd", "get", "application", name, "-o", "json"))
        except json.JSONDecodeError as error:
            raise SafeError(f"Argo {name} response is invalid") from error
        if not isinstance(value, dict):
            raise SafeError(f"Argo {name} response is invalid")
        return value

    def patch(self, name: str, patch_type: str, value: object, check: bool = True) -> None:
        self.kubectl("-n", "argocd", "patch", "application", name, f"--type={patch_type}",
                     "--patch", json.dumps(value, separators=(",", ":")), check=check)

    def refresh(self, name: str, check: bool = True) -> None:
        self.kubectl("-n", "argocd", "annotate", "application", name,
                     "argocd.argoproj.io/refresh=hard", "--overwrite", check=check)


def state(value: dict) -> tuple[str, str, str, str]:
    return (
        str(value.get("spec", {}).get("source", {}).get("targetRevision", "")),
        str(value.get("status", {}).get("sync", {}).get("status", "")),
        str(value.get("status", {}).get("health", {}).get("status", "")),
        str(value.get("status", {}).get("sync", {}).get("revision", "")),
    )


def wait(remote: Remote, name: str, target: str, revision: str, attempts: int = 90) -> None:
    last = ("", "", "", "")
    for _ in range(attempts):
        last = state(remote.app(name))
        if last == (target, "Synced", "Healthy", revision):
            return
        time.sleep(5)
    raise SafeError(f"Argo {name} did not converge: {last}")


def ensure_task_pvc_absent(remote: Remote) -> None:
    raw = remote.kubectl("-n", "demo-onprem", "get", "pvc", "demo-recovery-data", "-o", "json", check=False)
    if not raw.strip():
        return
    try:
        pvc = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SafeError("task PVC response is invalid") from error
    request = pvc.get("spec", {}).get("resources", {}).get("requests", {}).get("storage")
    labels = pvc.get("metadata", {}).get("labels", {})
    if request != "512Mi" or labels.get("app.kubernetes.io/part-of") != "demo-recovery-01":
        raise SafeError("unexpected PVC blocks task cleanup")
    for _ in range(36):
        pods = json.loads(remote.kubectl("-n", "demo-onprem", "get", "pod", "-o", "json"))
        mounted = any(
            volume.get("persistentVolumeClaim", {}).get("claimName") == "demo-recovery-data"
            for pod in pods.get("items", [])
            for volume in pod.get("spec", {}).get("volumes", [])
        )
        if not mounted:
            remote.kubectl("-n", "demo-onprem", "delete", "pvc", "demo-recovery-data", "--wait=true")
            if remote.kubectl("-n", "demo-onprem", "get", "pvc", "demo-recovery-data", check=False).strip():
                raise SafeError("task PVC remains after exact cleanup")
            print("DEMO_RECOVERY_ORPHAN_PVC_CLEANUP=PASS pvc=demo-recovery-data", flush=True)
            return
        time.sleep(5)
    raise SafeError("task PVC is still mounted after main rollback")


def restore(remote: Remote, main_sha: str) -> None:
    remote.patch(CHILD, "merge", {"spec": {"source": {"targetRevision": "main"}}}, check=False)
    remote.refresh(CHILD, check=False)
    remote.patch(POLICY_CHILD, "merge", {"spec": {"source": {"targetRevision": "main"}}}, check=False)
    remote.refresh(POLICY_CHILD, check=False)
    remote.patch(ROOT, "merge", {"spec": {"source": {"targetRevision": "main"}}}, check=False)
    remote.patch(ROOT, "json", [{"op": "remove", "path": "/spec/ignoreDifferences"}], check=False)
    remote.refresh(ROOT, check=False)
    wait(remote, CHILD, "main", main_sha)
    wait(remote, ROOT, "main", main_sha)
    for name in RELATED:
        wait(remote, name, "main", main_sha)
    ensure_task_pvc_absent(remote)


def execute(task_sha: str, main_sha: str, tool_dir: Path) -> None:
    handles = []
    try:
        for path in LOCKS:
            handle = path.open("w", encoding="utf-8")
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise SafeError(f"required lock is held: {path.name}") from error
            handles.append(handle)
        remote = Remote()
        if state(remote.app(ROOT)) != ("main", "Synced", "Healthy", main_sha):
            raise SafeError("platform-root is not the recorded literal main baseline")
        child = state(remote.app(CHILD))
        if child[0:3] != ("main", "Synced", "Healthy"):
            raise SafeError("demo-onprem is not a main Synced/Healthy baseline")
        for name in RELATED:
            if state(remote.app(name)) != ("main", "Synced", "Healthy", main_sha):
                raise SafeError(f"{name} is not the recorded literal main baseline")
        capacity = subprocess.run([str(tool_dir / "verify-capacity.sh")], check=False)
        if capacity.returncode:
            raise SafeError("capacity preflight failed")
        ignored = [{
            "group": "argoproj.io", "kind": "Application", "name": CHILD,
            "jsonPointers": ["/spec/source/targetRevision"],
        }, {
            "group": "argoproj.io", "kind": "Application", "name": POLICY_CHILD,
            "jsonPointers": ["/spec/source/targetRevision"],
        }]
        changed = False
        try:
            remote.patch(ROOT, "json", [{"op": "add", "path": "/spec/ignoreDifferences", "value": ignored}])
            changed = True
            remote.patch(ROOT, "merge", {"spec": {"source": {"targetRevision": task_sha}}})
            remote.refresh(ROOT)
            wait(remote, ROOT, task_sha, task_sha)
            remote.patch(CHILD, "merge", {"spec": {"source": {"targetRevision": task_sha}}})
            remote.refresh(CHILD)
            wait(remote, CHILD, task_sha, task_sha)
            remote.patch(POLICY_CHILD, "merge", {"spec": {"source": {"targetRevision": task_sha}}})
            remote.refresh(POLICY_CHILD)
            wait(remote, POLICY_CHILD, task_sha, task_sha)
            env = dict(os.environ)
            env["DEMORECOVERY01_TASK_SHA"] = task_sha
            env["DEMORECOVERY01_MAIN_SHA"] = main_sha
            result = subprocess.run([str(tool_dir / "verify-live.sh")], env=env, check=False)
            if result.returncode:
                raise SafeError("scoped live verification failed")
            print(f"DEMO_RECOVERY_ARGO_IMMUTABLE=PASS root={task_sha} child={CHILD}", flush=True)
        finally:
            if changed:
                restore(remote, main_sha)
                print(f"DEMO_RECOVERY_ARGO_RESTORE=PASS main={main_sha}", flush=True)
    finally:
        for handle in reversed(handles):
            handle.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task-sha", required=True)
    parser.add_argument("--main-sha", required=True)
    args = parser.parse_args()
    if not all(len(value) == 40 and all(char in "0123456789abcdef" for char in value)
               for value in (args.task_sha, args.main_sha)):
        print("DEMO_RECOVERY=FAIL reason=full lowercase SHA is required", file=sys.stderr)
        return 2
    try:
        execute(args.task_sha, args.main_sha, Path(__file__).resolve().parent)
    except SafeError as error:
        print(f"DEMO_RECOVERY=FAIL reason={error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
