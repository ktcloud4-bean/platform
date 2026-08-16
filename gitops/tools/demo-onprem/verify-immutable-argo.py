#!/usr/bin/env python3
"""DEMO-ONPREM-01을 immutable SHA에서 검증하고 literal main으로 복구한다."""

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
CHANGED = ("demo-onprem", "pomerium", "wazuh")
RELATED = ("crowdsec", "falco", "shuffle", "kyverno", "policy-baseline")
LOCKS = (
    Path("/tmp/ktcloud4-bean-argo-root.lock"),
    Path("/tmp/argo-root.lock"),
    Path("/tmp/iam-01-provision.lock"),
    Path("/tmp/ktcloud4-bean-vault-config.lock"),
)
STATE_DIR = Path("/tmp/demo-onprem-01-state")


class SafeError(RuntimeError):
    pass


class Remote:
    def kubectl(self, *args: str, check: bool = True, hide_stderr: bool = True) -> str:
        result = subprocess.run(
            [*SSH, shlex.join([*KUBECTL, *args])], stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL if hide_stderr else None, text=True, check=False,
        )
        if check and result.returncode:
            raise SafeError(f"remote kubectl failed: {args[0] if args else 'unknown'}")
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
    source = value.get("spec", {}).get("source", {})
    status = value.get("status", {})
    return (
        str(source.get("targetRevision", "")), str(status.get("sync", {}).get("status", "")),
        str(status.get("health", {}).get("status", "")), str(status.get("sync", {}).get("revision", "")),
    )


def wait(remote: Remote, name: str, target: str, revision: str, *, healthy: bool = True, attempts: int = 100) -> None:
    last = ("", "", "", "")
    for _ in range(attempts):
        try:
            last = state(remote.app(name))
        except SafeError:
            time.sleep(4)
            continue
        expected = last[0] == target and last[1] == "Synced" and last[3] == revision
        if expected and (not healthy or last[2] == "Healthy"):
            return
        time.sleep(4)
    raise SafeError(f"Argo {name} did not converge target={last[0]} sync={last[1]} health={last[2]} revision={last[3]}")


def restart_wazuh(remote: Remote) -> None:
    remote.kubectl("-n", "wazuh", "rollout", "restart", "statefulset/wazuh-manager-master")
    remote.kubectl("-n", "wazuh", "rollout", "status", "statefulset/wazuh-manager-master", "--timeout=420s")


def check_soar_hook(remote: Remote) -> None:
    code = """import os,stat
path='/wazuh/runtime/soar01-hook-url'
target='wazuh-'+'integratord'
pids=[]
for name in os.listdir('/proc'):
    if not name.isdigit():
        continue
    try:
        command=open(f'/proc/{name}/cmdline','rb').read().replace(b'\\0',b' ').decode(errors='ignore')
    except OSError:
        continue
    if target in command:
        pids.append(name)
if len(pids)!=1:
    raise SystemExit(1)
status=open(f'/proc/{pids[0]}/status',encoding='utf-8').read().splitlines()
uid=int(next(line for line in status if line.startswith('Uid:')).split()[1])
groups={int(value) for value in next(line for line in status if line.startswith('Groups:')).split()[1:]}
groups.add(int(next(line for line in status if line.startswith('Gid:')).split()[1]))
info=os.stat(path)
readable=(info.st_uid==uid and info.st_mode&stat.S_IRUSR) or (info.st_gid in groups and info.st_mode&stat.S_IRGRP) or info.st_mode&stat.S_IROTH
raise SystemExit(0 if readable and info.st_size>0 else 1)
"""
    remote.kubectl(
        "-n", "wazuh", "exec", "statefulset/wazuh-manager-master", "-c", "wazuh-manager",
        "--", "/var/ossec/framework/python/bin/python3", "-c", code,
    )
    print("DEMO_SOAR_HOOK=PASS integratord=readable capability=masked", flush=True)


def run_demo(tool_dir: Path, session: int, action: str, env: dict[str, str], *, check: bool = True) -> None:
    result = subprocess.run([str(tool_dir / "demo.sh"), f"session{session}", action], env=env, check=False)
    if check and result.returncode:
        raise SafeError(f"session{session} {action} failed")


def reset_demo(tool_dir: Path, env: dict[str, str]) -> None:
    for session in (4, 3, 2, 1):
        run_demo(tool_dir, session, "reset", env, check=False)


def prepare_state() -> None:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = STATE_DIR.lstat()
    if STATE_DIR.is_symlink() or metadata.st_mode & 0o077:
        raise SafeError("demo state directory must be mode 0700")
    for name in ("window", "supply-negative.out", "identity-reset-complete"):
        (STATE_DIR / name).unlink(missing_ok=True)


def restore(remote: Remote, main_sha: str) -> None:
    for child in ("pomerium", "wazuh"):
        remote.patch(child, "merge", {"spec": {"source": {"targetRevision": "main"}}}, check=False)
        remote.refresh(child, check=False)
    remote.patch(ROOT, "merge", {"spec": {"source": {"targetRevision": "main"}}}, check=False)
    remote.patch(ROOT, "json", [{"op": "remove", "path": "/spec/ignoreDifferences"}], check=False)
    remote.refresh(ROOT, check=False)
    for _ in range(100):
        absent = remote.kubectl("-n", "argocd", "get", "application", "demo-onprem", check=False) == ""
        namespace_absent = remote.kubectl("get", "namespace", "demo-onprem", check=False) == ""
        if absent and namespace_absent:
            break
        time.sleep(4)
    else:
        raise SafeError("demo-onprem temporary Application/namespace was not pruned")
    remote.kubectl("-n", "argocd", "delete", "appproject", "demo-onprem",
                   "--ignore-not-found", "--wait=true", check=False)
    for name in (ROOT, "pomerium", "wazuh"):
        wait(remote, name, "main", main_sha)
    restart_wazuh(remote)


def execute(task_sha: str, main_sha: str, tool_dir: Path) -> None:
    handles = []
    try:
        for path in LOCKS:
            handle = path.open("w", encoding="utf-8")
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise SafeError(f"required lock is already owned: {path.name}") from error
            handles.append(handle)
        remote = Remote()
        prepare_state()
        baseline = remote.app(ROOT)
        if state(baseline) != ("main", "Synced", "Healthy", main_sha) or baseline.get("spec", {}).get("ignoreDifferences"):
            raise SafeError("platform-root is not the recorded literal main baseline")
        for name in RELATED:
            wait(remote, name, "main", main_sha)
        ignored = [{
            "group": "argoproj.io", "kind": "Application", "name": name,
            "jsonPointers": ["/spec/source/targetRevision"],
        } for name in CHANGED]
        changed = False
        env = dict(os.environ)
        env["DEMO_IDENTITY_LOCK_HELD"] = "1"
        try:
            remote.patch(ROOT, "json", [{"op": "add", "path": "/spec/ignoreDifferences", "value": ignored}])
            changed = True
            remote.patch(ROOT, "merge", {"spec": {"source": {"targetRevision": task_sha}}})
            remote.refresh(ROOT)
            wait(remote, ROOT, task_sha, task_sha, healthy=False)
            for child in CHANGED:
                remote.patch(child, "merge", {"spec": {"source": {"targetRevision": task_sha}}})
                remote.refresh(child)
            for child in CHANGED:
                wait(remote, child, task_sha, task_sha)
            wait(remote, ROOT, task_sha, task_sha)
            restart_wazuh(remote)
            check_soar_hook(remote)
            print(f"DEMO_ARGO_IMMUTABLE=PASS root={task_sha} children={','.join(CHANGED)}", flush=True)
            # 사람 승인 대기 전에 독립적인 나머지 세션을 모두 판정한다.
            for session in (1, 2, 4, 3):
                for action in ("attack", "control", "evidence", "reset"):
                    run_demo(tool_dir, session, action, env)
            reset_demo(tool_dir, env)
            for kind, name in (
                ("pod", "demo-onprem-attacker"),
                ("networkpolicy", "demo-onprem-transient-lateral-block"),
                ("pod", "demo-onprem-supply-positive"),
                ("pod", "demo-onprem-supply-negative"),
            ):
                if remote.kubectl("-n", "demo-onprem", "get", kind, name, check=False).strip():
                    raise SafeError(f"transient attack resource remains: {kind}/{name}")
            for name in RELATED:
                wait(remote, name, "main", main_sha)
            print("DEMO_LIVE=PASS sessions=4 transient_attack_resources=0", flush=True)
        finally:
            reset_demo(tool_dir, env)
            if changed:
                restore(remote, main_sha)
                print(f"DEMO_ARGO_RESTORE=PASS root=main revision={main_sha}", flush=True)
    finally:
        for handle in reversed(handles):
            handle.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task-sha", required=True)
    parser.add_argument("--main-sha", required=True)
    args = parser.parse_args()
    if not all(len(value) == 40 and all(c in "0123456789abcdef" for c in value) for value in (args.task_sha, args.main_sha)):
        print("DEMO_LIVE=FAIL reason=full lowercase SHA is required", file=sys.stderr)
        return 2
    try:
        execute(args.task_sha, args.main_sha, Path(__file__).resolve().parent)
    except SafeError as error:
        print(f"DEMO_LIVE=FAIL reason={error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
