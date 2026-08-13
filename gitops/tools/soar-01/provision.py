#!/usr/bin/env python3
"""SOAR-01의 read-only Shuffle 승인 흐름을 안전하게 등록·되돌린다.

보호 입력·세션 cookie·hook URL·Vault token은 출력하지 않는다. 이 도구가 만드는
workflow와 app만 이름으로 식별해 삭제하며, 자동 대응 API나 외부 알림 채널은 호출하지
않는다.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import hmac
import http.cookiejar
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid


REPO_ROOT = Path(__file__).resolve().parents[3]
SECRET_ROOT = Path(os.environ.get("KTC_SECRET_ROOT", "/home/imcherry/secrets/ktcloud4-bean"))
SSH = [
    "ssh",
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=/home/imcherry/.ssh/known_hosts",
    "rocky@k3s-01.imcherry5778.xyz",
]
WORKFLOW_NAME = "SOAR-01 Wazuh read-only approval"
APP_NAME = "SOAR-01 Local Enrichment"
APP_VERSION = "1.0.0"
PUBLIC_SHUFFLE_URL = "https://shuffle.imcherry5778.xyz"
OPERATOR = "imcherry5778"
ROLE_GROUPS = {"/soar-readers", "/soar-operators", "/platform-privileged"}
VAULT_PATH = "/v1/kv/data/wazuh/manager"
VAULT_KEY = "soar01_hook_url"


class SafeError(RuntimeError):
    """보호 입력·응답을 포함하지 않는 판정 오류."""


def require_secret(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise SafeError(f"protected input is missing: {path.name}") from error
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise SafeError(f"protected input must be a mode 0600 regular file: {path.name}")


def read_secret(path: Path) -> str:
    require_secret(path)
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise SafeError(f"protected input is empty: {path.name}")
    return value


def totp(seed: str) -> str:
    normalized = "".join(seed.split()).upper()
    try:
        key = base64.b32decode(normalized + "=" * (-len(normalized) % 8), casefold=True)
    except Exception as error:
        raise SafeError("Shuffle recovery TOTP input is invalid") from error
    remaining = 30 - int(time.time()) % 30
    if remaining < 4:
        time.sleep(remaining + 1)
    counter = int(time.time() // 30)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = (struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
    return f"{code:06d}"


def wait_for_fresh_totp_window() -> None:
    """외부 browser-login이 직전 코드 재사용을 시도하지 않도록 다음 slot만 사용한다."""
    time.sleep(31 - int(time.time()) % 30)


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise SafeError(f"module load failed: {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Tunnel:
    def __init__(self, namespace: str, service: str, target_port: int, forward_port: int):
        self.namespace = namespace
        self.service = service
        self.target_port = target_port
        self.forward_port = forward_port
        self.local_port = self._free_port()
        self.process: subprocess.Popen[bytes] | None = None

    @staticmethod
    def _free_port() -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return int(sock.getsockname()[1])

    def _cleanup_remote_forward(self) -> None:
        """이 도구가 소유한 정확한 service/port-forward만 종료한다."""
        listing = subprocess.run(
            SSH + ["ps -eo pid=,args="],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        marker = (
            f"kubectl -n {self.namespace} port-forward svc/{self.service} "
            f"{self.forward_port}:{self.target_port} --address 127.0.0.1"
        )
        pids = []
        for line in listing.stdout.splitlines():
            parts = line.strip().split(maxsplit=1)
            if len(parts) == 2 and parts[0].isdigit() and marker in parts[1]:
                pids.append(parts[0])
        if pids:
            subprocess.run(
                SSH + ["sudo -n kill " + " ".join(pids)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

    def __enter__(self) -> str:
        self._cleanup_remote_forward()
        remote = (
            "sudo -n /usr/local/bin/k3s kubectl "
            f"-n {self.namespace} port-forward svc/{self.service} "
            f"{self.forward_port}:{self.target_port} --address 127.0.0.1"
        )
        command = SSH[:-1] + ["-L", f"{self.local_port}:127.0.0.1:{self.forward_port}", SSH[-1], remote]
        self.process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # kubectl port-forward가 local listener를 먼저 열고 upstream stream을 나중에
        # 붙인다. 여기서 빈 TCP 연결로 readiness를 재면 그 연결 자체가 reset되어
        # 판정 오염이 생긴다. 프로세스가 1초 동안 살아 있는지만 확인하고, 실제 API
        # 요청 하나를 각 caller의 정상 판정으로 쓴다. SSH와 apiserver stream이 붙는
        # 관측 최장 초기 지연(약 2초)에 맞춰 3초만 기다린다.
        time.sleep(3)
        if self.process.poll() is not None:
            raise SafeError(f"{self.service} port-forward exited before becoming ready")
        return f"http://127.0.0.1:{self.local_port}"

    def __exit__(self, _exc_type, _exc, _traceback) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                self.process.wait(timeout=5)
        if self.process is not None and self.process.poll() is None:
            self.process.kill()
        self._cleanup_remote_forward()


def http_json(
    opener: urllib.request.OpenerDirector,
    method: str,
    url: str,
    payload: object | None = None,
    expected: tuple[int, ...] = (200,),
    headers: dict[str, str] | None = None,
) -> object | None:
    body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request_headers = {"Accept": "application/json"}
    if payload is not None:
        request_headers["Content-Type"] = "application/json"
    if headers:
        request_headers.update(headers)
    request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    try:
        with opener.open(request, timeout=30) as response:
            status = response.status
            response_body = response.read()
    except urllib.error.HTTPError as error:
        status = error.code
        response_body = error.read()
    except (urllib.error.URLError, OSError) as error:
        raise SafeError(f"HTTP request could not reach declared internal endpoint: {method}") from error
    if status not in expected:
        raise SafeError(f"HTTP request returned unexpected status: {method} HTTP {status}")
    if not response_body:
        return None
    try:
        return json.loads(response_body)
    except json.JSONDecodeError as error:
        raise SafeError(f"HTTP request returned invalid JSON: {method}") from error


class ShuffleAdmin:
    def __init__(self, base: str):
        self.base = base
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )

    def login(self) -> None:
        password = read_secret(SECRET_ROOT / "shuffle/default-admin-password")
        seed = read_secret(SECRET_ROOT / "iam-01/shuffle-admin-totp")
        response = http_json(
            self.opener,
            "POST",
            f"{self.base}/api/v1/login",
            {"username": "soar-dash-01-admin", "password": password, "mfa_code": totp(seed)},
        )
        if not isinstance(response, dict) or response.get("success") is not True:
            raise SafeError("Shuffle recovery login was not accepted")

    def request(self, method: str, path: str, payload: object | None = None, expected=(200,)) -> object | None:
        return http_json(self.opener, method, f"{self.base}{path}", payload, expected)

    def apps(self) -> list[dict]:
        response = self.request("GET", "/api/v1/apps")
        if not isinstance(response, list):
            raise SafeError("Shuffle app list response format is invalid")
        return [item for item in response if isinstance(item, dict)]

    def workflows(self) -> list[dict]:
        response = self.request("GET", "/api/v1/workflows?truncate=false")
        if not isinstance(response, list):
            raise SafeError("Shuffle workflow list response format is invalid")
        return [item for item in response if isinstance(item, dict)]


def exactly_one(items: list[dict], label: str) -> dict | None:
    if len(items) > 1:
        raise SafeError(f"multiple {label} records exist; refusing to choose a target")
    return items[0] if items else None


def owned_app(admin: ShuffleAdmin) -> dict | None:
    return exactly_one(
        [item for item in admin.apps() if item.get("name") == APP_NAME and item.get("app_version") == APP_VERSION],
        "SOAR-01 app",
    )


def owned_workflow(admin: ShuffleAdmin) -> dict | None:
    return exactly_one(
        [item for item in admin.workflows() if item.get("name") == WORKFLOW_NAME], "SOAR-01 workflow"
    )


def workflow_by_id(admin: ShuffleAdmin, workflow_id: str) -> dict | None:
    """이름 목록 cache와 무관하게 이번 생성 요청의 workflow만 고른다."""
    matches = [item for item in admin.workflows() if item.get("id") == workflow_id]
    return exactly_one(matches, "SOAR-01 workflow ID")


def is_persisted_workflow(admin: ShuffleAdmin, workflow: dict) -> bool:
    """목록 cache가 아닌 workflow 단건 API로 실제 저장 상태를 확인한다."""
    workflow_id = workflow.get("id")
    if not isinstance(workflow_id, str) or not workflow_id:
        return False
    response = admin.request("GET", f"/api/v1/workflows/{workflow_id}", expected=(200, 400, 401, 404))
    return isinstance(response, dict) and response.get("id") == workflow_id and response.get("name") == WORKFLOW_NAME


def owned_live_workflow(admin: ShuffleAdmin) -> dict | None:
    """목록 cache에 남은 삭제 workflow가 rollback과 재생성을 막지 않게 한다."""
    live: list[dict] = []
    for workflow in [item for item in admin.workflows() if item.get("name") == WORKFLOW_NAME]:
        if is_persisted_workflow(admin, workflow):
            live.append(workflow)
    return exactly_one(live, "live SOAR-01 workflow")


def app_definition() -> dict:
    return {
        "name": APP_NAME,
        "app_version": APP_VERSION,
        "description": "Kubernetes 안에서만 IPv4, URL, SHA-256을 추출하는 read-only 보강 앱",
        "environment": "Shuffle",
        "contact_info": {"name": "Platform Security"},
        "authentication": {"required": False},
        "actions": [
            {
                "name": "extract_indicators",
                "label": "오프라인 지표 보강",
                "description": "alert 본문에서 지표만 추출하며 네트워크·shell·Kubernetes API를 호출하지 않는다.",
                "app_name": APP_NAME,
                "app_version": APP_VERSION,
                "environment": "Shuffle",
                "auth_not_required": True,
                "parameters": [],
            }
        ],
    }


def workflow_definition(app: dict) -> dict:
    webhook_id = str(uuid.uuid4())
    action_id = str(uuid.uuid4())
    approval_id = str(uuid.uuid4())
    return {
        "name": WORKFLOW_NAME,
        "description": "Wazuh alert 수신 후 오프라인 보강만 수행하고 사람의 명시적 승인 입력에서 멈춘다.",
        "execution_environment": "onprem",
        "start": action_id,
        "actions": [
            {
                "id": action_id,
                "name": "extract_indicators",
                "label": "오프라인 지표 보강",
                "description": "읽기 전용 추출",
                "app_name": APP_NAME,
                "app_version": APP_VERSION,
                "app_id": app["id"],
                "environment": "Shuffle",
                "auth_not_required": True,
                "is_valid": True,
                "parameters": [],
                "position": {"x": 420, "y": 180},
            }
        ],
        "triggers": [
            {
                "id": webhook_id,
                "name": "Webhook",
                "label": "Wazuh alert 수신",
                "description": "Wazuh custom integration 전용 내부 webhook",
                "app_name": "Webhook",
                "environment": "Shuffle",
                "trigger_type": "WEBHOOK",
                "is_valid": True,
                "parameters": [],
                "position": {"x": 120, "y": 180},
            },
            {
                "id": approval_id,
                "name": "User Input",
                "label": "사람 승인 (read-only)",
                "description": "자동 격리·차단·계정 변경 없이 검토/승인 또는 중단을 기다린다.",
                "app_name": "User Input",
                "environment": "Shuffle",
                "trigger_type": "USERINPUT",
                "is_valid": True,
                "parameters": [
                    {
                        "name": "alertinfo",
                        "value": "## Wazuh 보강 완료\\n\\n자동 대응은 수행하지 않습니다. 결과를 검토하고 승인 또는 중단을 선택하세요.",
                    },
                    {"name": "options", "value": "true"},
                    {"name": "type", "value": "manual"},
                    {"name": "email", "value": ""},
                    {"name": "sms", "value": ""},
                    {"name": "subflow", "value": ""},
                    # upstream User Input은 이 값이 있으면 BASE_URL보다 우선해 Form URL을 만든다.
                    {"name": "backend_url", "value": PUBLIC_SHUFFLE_URL},
                ],
                "position": {"x": 720, "y": 180},
            },
        ],
        "branches": [
            {"id": str(uuid.uuid4()), "source_id": webhook_id, "destination_id": action_id},
            {"id": str(uuid.uuid4()), "source_id": action_id, "destination_id": approval_id},
        ],
    }


def find_nodes(workflow: dict) -> tuple[dict, dict, dict]:
    actions = [item for item in workflow.get("actions", []) if item.get("name") == "extract_indicators"]
    webhook = [item for item in workflow.get("triggers", []) if item.get("trigger_type") == "WEBHOOK"]
    approval = [
        item
        for item in workflow.get("triggers", [])
        if item.get("trigger_type") == "USERINPUT" and item.get("app_name") == "User Input"
    ]
    action = exactly_one(actions, "SOAR-01 enrichment action")
    hook = exactly_one(webhook, "SOAR-01 webhook trigger")
    user_input = exactly_one(approval, "SOAR-01 human approval trigger")
    if not action or not hook or not user_input or not all(item.get("id") for item in (action, hook, user_input)):
        raise SafeError("SOAR-01 workflow node structure is invalid")
    return action, hook, user_input


def vault_opener() -> tuple[urllib.request.OpenerDirector, dict[str, str]]:
    token = read_secret(SECRET_ROOT / "vault-root.token")
    # VAULT-01 공개 leaf의 원본은 각 consumer가 mount하는 Wazuh trust bundle이다.
    # SAN에 127.0.0.1도 있어 local SSH port-forward TLS 검증을 약화하지 않는다.
    cert = REPO_ROOT / "gitops/apps/wazuh/files/vault.crt"
    if not cert.is_file():
        raise SafeError("declared Vault CA file is missing")
    context = ssl.create_default_context(cafile=cert)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
    return opener, {"X-Vault-Token": token}


def vault_hook(value: str | None) -> bool:
    with Tunnel("vault", "vault", 8200, 18200) as http_base:
        opener, headers = vault_opener()
        https_base = http_base.replace("http://", "https://", 1)
        current = http_json(opener, "GET", f"{https_base}{VAULT_PATH}", headers=headers)
        if not isinstance(current, dict) or not isinstance(current.get("data"), dict):
            raise SafeError("Vault KV response format is invalid")
        inner = current["data"].get("data")
        if not isinstance(inner, dict):
            raise SafeError("Vault KV data format is invalid")
        updated = dict(inner)
        if value is None:
            changed = VAULT_KEY in updated
            updated.pop(VAULT_KEY, None)
        else:
            changed = updated.get(VAULT_KEY) != value
            updated[VAULT_KEY] = value
        if changed:
            http_json(opener, "PUT", f"{https_base}{VAULT_PATH}", {"data": updated}, expected=(200, 204), headers=headers)
        verify = http_json(opener, "GET", f"{https_base}{VAULT_PATH}", headers=headers)
        try:
            exists = VAULT_KEY in verify["data"]["data"]
        except (KeyError, TypeError) as error:
            raise SafeError("Vault KV verification format is invalid") from error
        if exists != (value is not None):
            raise SafeError("Vault KV verification did not reach requested state")
        return exists


def restart_wazuh_manager() -> None:
    """Vault Agent init template가 바뀐 hook capability만 다시 렌더하게 한다."""
    restart = subprocess.run(
        SSH + [
            "sudo -n /usr/local/bin/k3s kubectl -n wazuh rollout restart "
            "statefulset/wazuh-manager-master"
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if restart.returncode:
        raise SafeError("Wazuh manager restart request failed")
    status = subprocess.run(
        SSH + [
            "sudo -n /usr/local/bin/k3s kubectl -n wazuh rollout status "
            "statefulset/wazuh-manager-master --timeout=180s"
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if status.returncode:
        raise SafeError("Wazuh manager did not become ready after hook capability refresh")


def restart_shuffle_backend() -> None:
    """Shuffle가 영속화한 Dashboard 객체를 새 cache에서 다시 읽는다."""
    restart = subprocess.run(
        SSH + [
            "sudo -n /usr/local/bin/k3s kubectl -n shuffle rollout restart "
            "deployment/shuffle-backend"
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if restart.returncode:
        raise SafeError("Shuffle backend restart request failed during Dashboard cache refresh")
    status = subprocess.run(
        SSH + [
            "sudo -n /usr/local/bin/k3s kubectl -n shuffle rollout status "
            "deployment/shuffle-backend --timeout=180s"
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if status.returncode:
        raise SafeError("Shuffle backend did not become ready after Dashboard cache refresh")


def wait_for_dashboard_absence(admin: ShuffleAdmin) -> None:
    """Delete 직후 Dashboard 목록 cache가 비워질 때까지 짧게 기다린다."""
    for _ in range(12):
        if not owned_live_workflow(admin) and not owned_app(admin):
            return
        time.sleep(5)
    raise SafeError("SOAR-01 rollback did not remove its exact Dashboard objects")


def keycloak_groups(apply: bool) -> list[str]:
    iam_path = REPO_ROOT / "gitops/tools/iam-01/provision.py"
    iam = load_module("soar01_iam", iam_path)
    with tempfile.TemporaryDirectory(prefix="soar01-kc-") as directory:
        wait_for_fresh_totp_window()
        try:
            kc = iam.KeycloakAdmin(REPO_ROOT, SECRET_ROOT, "10.10.20.10", Path(directory))
        except subprocess.CalledProcessError as error:
            raise SafeError("Keycloak recovery browser login failed") from error
        groups, _ = kc.request("GET", "groups?max=200")
        by_path = iam.flatten_groups(groups)
        if not ROLE_GROUPS.issubset(by_path):
            raise SafeError("declared Shuffle Keycloak groups are incomplete")
        users, _ = kc.request("GET", f"users?username={OPERATOR}&exact=true")
        if not isinstance(users, list) or len(users) != 1 or not users[0].get("id"):
            raise SafeError("SOAR-01 operator Keycloak user is not unique")
        user_id = users[0]["id"]
        memberships, _ = kc.request("GET", f"users/{user_id}/groups?max=200")
        paths = {item.get("path") for item in memberships if item.get("path")}
        roles = sorted(paths & ROLE_GROUPS)
        if len(roles) > 1 or "/platform-privileged" in roles:
            raise SafeError("SOAR-01 operator has overlapping Shuffle roles; refusing to change membership")
        if apply:
            readers = by_path["/soar-readers"]["id"]
            operators = by_path["/soar-operators"]["id"]
            if "/soar-readers" in paths:
                kc.request("DELETE", f"users/{user_id}/groups/{readers}", expected=(204,))
            if "/soar-operators" not in paths:
                kc.request("PUT", f"users/{user_id}/groups/{operators}", expected=(204,))
            memberships, _ = kc.request("GET", f"users/{user_id}/groups?max=200")
            paths = {item.get("path") for item in memberships if item.get("path")}
            roles = sorted(paths & ROLE_GROUPS)
        if apply and roles != ["/soar-operators"]:
            raise SafeError("SOAR-01 operator must have exactly the /soar-operators Shuffle role")
        return roles


def keycloak_restore_reader() -> None:
    """SOAR-01 시작 기준선(reader 하나)으로만 되돌린다."""
    iam_path = REPO_ROOT / "gitops/tools/iam-01/provision.py"
    iam = load_module("soar01_iam_rollback", iam_path)
    with tempfile.TemporaryDirectory(prefix="soar01-kc-") as directory:
        wait_for_fresh_totp_window()
        try:
            kc = iam.KeycloakAdmin(REPO_ROOT, SECRET_ROOT, "10.10.20.10", Path(directory))
        except subprocess.CalledProcessError as error:
            raise SafeError("Keycloak recovery browser login failed") from error
        groups, _ = kc.request("GET", "groups?max=200")
        by_path = iam.flatten_groups(groups)
        if not ROLE_GROUPS.issubset(by_path):
            raise SafeError("declared Shuffle Keycloak groups are incomplete")
        users, _ = kc.request("GET", f"users?username={OPERATOR}&exact=true")
        if not isinstance(users, list) or len(users) != 1 or not users[0].get("id"):
            raise SafeError("SOAR-01 operator Keycloak user is not unique")
        user_id = users[0]["id"]
        memberships, _ = kc.request("GET", f"users/{user_id}/groups?max=200")
        paths = {item.get("path") for item in memberships if item.get("path")}
        roles = paths & ROLE_GROUPS
        if len(roles) > 1 or "/platform-privileged" in roles:
            raise SafeError("SOAR-01 rollback found overlapping Shuffle roles; refusing to choose membership")
        if "/soar-operators" in paths:
            kc.request("DELETE", f"users/{user_id}/groups/{by_path['/soar-operators']['id']}", expected=(204,))
        if "/soar-readers" not in paths:
            kc.request("PUT", f"users/{user_id}/groups/{by_path['/soar-readers']['id']}", expected=(204,))
        memberships, _ = kc.request("GET", f"users/{user_id}/groups?max=200")
        final_roles = sorted({item.get("path") for item in memberships if item.get("path")} & ROLE_GROUPS)
        if final_roles != ["/soar-readers"]:
            raise SafeError("SOAR-01 rollback did not restore exactly the reader Shuffle role")


def status() -> None:
    roles = keycloak_groups(False)
    with Tunnel("shuffle", "shuffle-backend", 5001, 18081) as base:
        admin = ShuffleAdmin(base)
        admin.login()
        app = owned_app(admin)
        workflow = owned_live_workflow(admin)
    hook_present = None
    # read-only Vault state check avoids rewriting the KV while reporting status.
    with Tunnel("vault", "vault", 8200, 18200) as http_base:
        opener, headers = vault_opener()
        response = http_json(opener, "GET", f"{http_base.replace('http://', 'https://', 1)}{VAULT_PATH}", headers=headers)
        try:
            hook_present = VAULT_KEY in response["data"]["data"]
        except (KeyError, TypeError) as error:
            raise SafeError("Vault KV status response format is invalid") from error
    print(f"SOAR01Role={'operator' if roles == ['/soar-operators'] else 'reader' if roles == ['/soar-readers'] else 'unexpected'}")
    print(f"SOAR01App={'present' if app else 'absent'}")
    print(f"SOAR01Workflow={'present' if workflow else 'absent'}")
    print(f"SOAR01VaultHook={'present' if hook_present else 'absent'}")


def apply() -> None:
    with Tunnel("shuffle", "shuffle-backend", 5001, 18081) as base:
        admin = ShuffleAdmin(base)
        admin.login()
        if owned_app(admin) or owned_live_workflow(admin):
            raise SafeError("SOAR-01 app or workflow already exists; run check or rollback first")
        admin.request("PUT", "/api/v1/apps", app_definition(), expected=(200,))
        app = owned_app(admin)
        if not app or not app.get("id"):
            raise SafeError("SOAR-01 app creation was not visible in the exact app list")
        created = admin.request("POST", "/api/v1/workflows", workflow_definition(app), expected=(200,))
        if not isinstance(created, dict) or not created.get("id"):
            raise SafeError("SOAR-01 workflow creation response is invalid")
        workflow_id = created["id"]

    # Shuffle는 새 workflow의 action/trigger ID를 생성해 저장한다. POST 응답은
    # 저장 전 ID를 남길 수 있으므로, hook 결합 전 새 backend cache에서 다시 읽는다.
    restart_shuffle_backend()
    with Tunnel("shuffle", "shuffle-backend", 5001, 18081) as base:
        admin = ShuffleAdmin(base)
        admin.login()
        workflow = workflow_by_id(admin, workflow_id)
        if not workflow or workflow.get("id") != workflow_id:
            raise SafeError("SOAR-01 persisted workflow was not visible after cache refresh")
        action, webhook, _approval = find_nodes(workflow)
        admin.request(
            "POST",
            "/api/v1/hooks",
            {
                "type": "webhook",
                "description": "Wazuh custom-soar01 read-only alert receiver",
                "id": webhook["id"],
                "name": "SOAR-01 Wazuh webhook",
                "workflow": workflow_id,
                "start": action["id"],
                "environment": "Shuffle",
                "auth": "",
                "custom_response": "",
                "version": "",
            },
            expected=(200,),
        )
        hook_url = f"http://shuffle-backend.shuffle.svc.cluster.local:5001/api/v1/hooks/webhook_{webhook['id']}"
    vault_hook(hook_url)
    restart_wazuh_manager()
    keycloak_groups(True)
    print("SOAR01Apply=PASS")


def rollback() -> None:
    # First make the Wazuh integration fail closed, then stop and remove only the owned Shuffle objects.
    vault_hook(None)
    restart_wazuh_manager()
    with Tunnel("shuffle", "shuffle-backend", 5001, 18081) as base:
        admin = ShuffleAdmin(base)
        admin.login()
        workflow = owned_live_workflow(admin)
        app = owned_app(admin)
        if workflow:
            _action, webhook, _approval = find_nodes(workflow)
            # Hook GET은 이 Shuffle 버전에 없으므로, 우리 trigger UUID의 삭제 요청만 정확히 보낸다.
            admin.request("DELETE", f"/api/v1/hooks/{webhook['id']}/delete", expected=(200, 401, 404))
            admin.request("DELETE", f"/api/v1/workflows/{workflow['id']}", expected=(200,))
        if app:
            admin.request("DELETE", f"/api/v1/apps/{app['id']}", expected=(200,))
    restart_shuffle_backend()
    with Tunnel("shuffle", "shuffle-backend", 5001, 18081) as base:
        admin = ShuffleAdmin(base)
        admin.login()
        wait_for_dashboard_absence(admin)
    keycloak_restore_reader()
    print("SOAR01Rollback=PASS")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "apply", "rollback", "role-check", "role-apply"))
    args = parser.parse_args()
    try:
        if args.command == "check":
            status()
        elif args.command == "apply":
            apply()
        elif args.command == "rollback":
            rollback()
        elif args.command == "role-check":
            roles = keycloak_groups(False)
            print(f"SOAR01Role={'operator' if roles == ['/soar-operators'] else 'reader' if roles == ['/soar-readers'] else 'unexpected'}")
        else:
            keycloak_groups(True)
            print("SOAR01RoleApply=PASS")
    except SafeError as error:
        print(f"SOAR01=FAIL reason={error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
