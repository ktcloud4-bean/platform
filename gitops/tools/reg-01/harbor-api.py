#!/usr/bin/env python3
"""REG-01 완료 증거용 Harbor API 조작. 비밀과 응답 본문은 출력하지 않는다."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import ssl
import stat
import time
import urllib.error
import urllib.parse
import urllib.request


EVIDENCE_PROJECT = "reg01-evidence"
DENIED_PROJECT = "reg01-denied"


def private_values(path: Path) -> dict[str, str]:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("REG-01 env는 symlink가 아닌 mode 0600 파일이어야 한다")
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


class Client:
    def __init__(self, username: str, password: str, base_url: str):
        encoded = base64.b64encode(f"{username}:{password}".encode()).decode()
        self.headers = {"Authorization": f"Basic {encoded}", "Content-Type": "application/json"}
        self.context = ssl.create_default_context()
        self.base_url = base_url.rstrip("/")

    def request(self, method: str, path: str, payload=None, expected=(200,)):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(self.base_url + path, data=data, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30, context=self.context) as response:
                body = response.read()
                if response.status not in expected:
                    raise RuntimeError(f"Harbor API {method} {path}: HTTP {response.status}")
                return response.status, response.headers, json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            error.read()
            if error.code in expected:
                return error.code, error.headers, None
            raise RuntimeError(f"Harbor API {method} {path}: HTTP {error.code}") from None


def write_private(path: Path, value: object) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream)
        stream.write("\n")


def setup(client: Client, state: Path) -> None:
    for project in (EVIDENCE_PROJECT, DENIED_PROJECT):
        status, _, _ = client.request(
            "GET", f"/projects/{project}", expected=(200, 404)
        )
        if status != 404:
            raise SystemExit(f"기존 검증 project가 남아 있다: {project}")
        client.request("POST", "/projects", {"project_name": project, "public": False}, (201,))
    _, _, project = client.request("GET", f"/projects/{EVIDENCE_PROJECT}")
    robot_request = {
        "name": "reg01-evidence",
        "description": "REG-01 one-shot push/pull evidence",
        "level": "project",
        "disable": False,
        "duration": 1,
        "permissions": [
            {
                "kind": "project",
                "namespace": EVIDENCE_PROJECT,
                "access": [
                    {"resource": "repository", "action": "pull", "effect": "allow"},
                    {"resource": "repository", "action": "push", "effect": "allow"},
                ],
            }
        ],
    }
    _, _, robot = client.request("POST", "/robots", robot_request, (201,))
    if not robot or not robot.get("name") or not robot.get("secret"):
        raise SystemExit("Harbor robot 생성 응답에 credential이 없다")
    write_private(
        state,
        {
            "project_id": project["project_id"],
            "robot_name": robot["name"],
            "robot_secret": robot["secret"],
        },
    )
    print("Harbor 검증 project 2개와 project-scoped push/pull robot 생성 완료")


def retention(client: Client, state: Path) -> None:
    current = json.loads(state.read_text(encoding="utf-8"))
    policy = {
        "algorithm": "or",
        "rules": [
            {
                "priority": 1,
                "disabled": False,
                "action": "retain",
                "template": "latestPushedK",
                "params": {"latestPushedK": 1},
                "tag_selectors": [
                    {"kind": "doublestar", "decoration": "matches", "pattern": "**"}
                ],
                "scope_selectors": {
                    "repository": [
                        {"kind": "doublestar", "decoration": "repoMatches", "pattern": "retention"}
                    ]
                },
            }
        ],
        "trigger": {"kind": "Schedule", "settings": {"cron": "0 0 0 * * *"}},
        "scope": {"level": "project", "ref": current["project_id"]},
    }
    _, headers, _ = client.request("POST", "/retentions", policy, (201,))
    location = headers.get("Location", "")
    policy_id = int(location.rstrip("/").split("/")[-1])
    client.request("POST", f"/retentions/{policy_id}/executions", {"dry_run": False}, (200, 201))
    execution_id = None
    for _ in range(60):
        _, _, executions = client.request(
            "GET", f"/retentions/{policy_id}/executions?page=1&page_size=10"
        )
        if executions:
            execution_id = executions[0]["id"]
            status = executions[0]["status"].lower()
            if status in {"succeed", "success"}:
                break
            if status in {"failed", "error", "stopped"}:
                raise SystemExit(f"retention execution 실패: {status}")
        time.sleep(2)
    else:
        raise SystemExit("retention execution 완료 대기 timeout")
    if execution_id is None:
        raise SystemExit("retention execution이 생성되지 않았다")
    _, _, artifacts = client.request(
        "GET", f"/projects/{EVIDENCE_PROJECT}/repositories/retention/artifacts?with_tag=true"
    )
    tags = {tag["name"] for artifact in artifacts for tag in (artifact.get("tags") or [])}
    if tags != {"keep"}:
        raise SystemExit(f"retention 실제 결과가 다르다: tag={sorted(tags)}")
    print(f"retention 실제 실행 성공: execution={execution_id}, removed=remove, retained=keep")


def cleanup(client: Client) -> None:
    for project in (EVIDENCE_PROJECT, DENIED_PROJECT):
        status, _, repositories = client.request(
            "GET", f"/projects/{project}/repositories?page=1&page_size=100", expected=(200, 404)
        )
        if status == 200:
            for repository in repositories or []:
                prefix = f"{project}/"
                name = repository.get("name", "")
                if not name.startswith(prefix):
                    raise SystemExit(f"검증 project 밖 repository 응답을 거부한다: {name}")
                encoded = urllib.parse.quote(name.removeprefix(prefix), safe="")
                client.request(
                    "DELETE",
                    f"/projects/{project}/repositories/{encoded}",
                    expected=(200, 202, 404),
                )
        client.request("DELETE", f"/projects/{project}", expected=(200, 202, 404))
    print("Harbor 검증 project/robot/policy 정리 요청 완료")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:18443/api/v2.0")
    parser.add_argument("operation", choices=("setup", "retention", "cleanup"))
    args = parser.parse_args()
    values = private_values(args.env_file)
    client = Client("admin", values["HARBOR_ADMIN_PASSWORD"], args.base_url)
    if args.operation == "setup":
        if args.state_file is None:
            raise SystemExit("setup에는 --state-file이 필요하다")
        setup(client, args.state_file)
    elif args.operation == "retention":
        if args.state_file is None:
            raise SystemExit("retention에는 --state-file이 필요하다")
        retention(client, args.state_file)
    else:
        cleanup(client)


if __name__ == "__main__":
    main()
