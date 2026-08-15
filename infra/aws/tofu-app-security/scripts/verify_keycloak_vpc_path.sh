#!/usr/bin/env bash
# AWS-SEC-03 Keycloak CIEM /admin route를 immutable Argo SHA에서 검증하고 main으로 복귀한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly main_revision=${AWSSEC03_MAIN_REVISION:?시작 main SHA가 필요하다}
readonly config_revision=${AWSSEC03_CONFIG_REVISION:?Keycloak 설정 SHA가 필요하다}
readonly root_revision=${AWSSEC03_ROOT_REVISION:?immutable root pointer SHA가 필요하다}
readonly session_function=${AWSSEC03_SESSION_FUNCTION:-hr-system-prod-ciem-keycloak-session-revoke}
readonly session_secret=${AWSSEC03_SESSION_SECRET:-hr-system-prod-ciem-keycloak-session}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  echo "AWS-SEC-03 Keycloak 검증 실패 단계=$1 원인=$2" >&2
  exit 1
}

for revision in "$main_revision" "$config_revision" "$root_revision"; do
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || fail preflight 'immutable SHA 형식이 아니다.'
done
[[ -f $known_hosts && ! -L $known_hosts ]] || fail preflight '인증된 k3s known_hosts 파일이 없다.'

exec 9>/tmp/ktcloud4-bean-argo-root.lock
flock -n 9 || fail lock '다른 ARGO-ROOT 작업이 실행 중이다.'

remote_kubectl() {
  ssh "${ssh_options[@]}" "$k3s_host" sudo -n /usr/local/bin/k3s kubectl "$@"
}

patch_root_revision() {
  local revision=$1
  ssh "${ssh_options[@]}" "$k3s_host" bash -s -- "$revision" <<'REMOTE'
set -Eeuo pipefail
revision=$1
sudo -n /usr/local/bin/k3s kubectl -n argocd patch applications.argoproj.io platform-root --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"$revision\"}}}"
REMOTE
}

main_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root keycloak -o json \
    | jq -e --arg main "$main_revision" '
      ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root |
      ([.items[] | select(.metadata.name == "keycloak")][0] // {}) as $keycloak |
      $root.spec.source.targetRevision == "main" and
      $root.status.sync.revision == $main and
      $root.status.sync.status == "Synced" and
      $root.status.health.status == "Healthy" and
      $keycloak.spec.source.targetRevision == "main" and
      $keycloak.status.sync.revision == $main and
      $keycloak.status.sync.status == "Synced" and
      $keycloak.status.health.status == "Healthy"
    ' >/dev/null
}

immutable_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root keycloak -o json \
    | jq -e --arg expected_root "$root_revision" --arg expected_config "$config_revision" '
      ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root |
      ([.items[] | select(.metadata.name == "keycloak")][0] // {}) as $keycloak |
      $root.spec.source.targetRevision == $expected_root and
      $root.status.sync.revision == $expected_root and
      $root.status.sync.status == "Synced" and
      $root.status.health.status == "Healthy" and
      $keycloak.spec.source.targetRevision == $expected_config and
      $keycloak.status.sync.revision == $expected_config and
      $keycloak.status.sync.status == "Synced" and
      $keycloak.status.health.status == "Healthy"
    ' >/dev/null
}

wait_for() {
  local expected=$1
  for _ in $(seq 1 36); do
    if [[ $expected == main ]] && main_state_matches 2>/dev/null; then return 0; fi
    if [[ $expected == immutable ]] && immutable_state_matches 2>/dev/null; then return 0; fi
    sleep 5
  done
  return 1
}

verify_route() {
  local ingress middleware
  ingress=$(remote_kubectl -n keycloak get ingress keycloak-ciem-vpc-admin -o json)
  middleware=$(remote_kubectl -n keycloak get middleware.traefik.io sso-ciem-vpc-admin -o json)
  python3 -c '
import json
import sys

ingress = json.loads(sys.argv[1])
middleware = json.loads(sys.argv[2])
paths = ingress.get("spec", {}).get("rules", [{}])[0].get("http", {}).get("paths", [])
path_ok = paths == [{
    "path": "/admin", "pathType": "Prefix",
    "backend": {"service": {"name": "keycloak", "port": {"name": "http"}}},
}]
ok = (
    ingress.get("spec", {}).get("ingressClassName") == "traefik"
    and ingress.get("spec", {}).get("rules", [{}])[0].get("host") == "sso.imcherry5778.xyz"
    and path_ok
    and ingress.get("metadata", {}).get("annotations", {}).get("traefik.ingress.kubernetes.io/router.middlewares")
       == "keycloak-sso-ciem-vpc-admin@kubernetescrd"
    and middleware.get("spec", {}).get("ipAllowList", {}).get("sourceRange") == ["10.20.10.0/24", "10.20.20.0/24"]
)
raise SystemExit(0 if ok else 1)
' "$ingress" "$middleware"
}

verify_session_path() {
  python3 - "$session_secret" "$session_function" <<'PY'
import json
import subprocess
import sys
import tempfile
from pathlib import Path

secret_id, function_name = sys.argv[1:]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    credentials_path = root / "credentials.json"
    event_path = root / "event.json"
    result_path = root / "result.json"
    invoke_path = root / "invoke.json"

    with credentials_path.open("w", encoding="utf-8") as output:
        subprocess.run(
            ["aws", "secretsmanager", "get-secret-value", "--secret-id", secret_id, "--query", "SecretString", "--output", "text"],
            check=True,
            stdout=output,
        )
    credentials = json.loads(credentials_path.read_text(encoding="utf-8"))
    if credentials.get("client_id") != "aws-ciem-session-revoke" or not credentials.get("client_secret"):
        raise RuntimeError("Keycloak session credential shape is invalid")

    event_path.write_text(
        json.dumps({"username": "aws-sec-03-session-probe", "credentials": credentials}),
        encoding="utf-8",
    )
    with invoke_path.open("w", encoding="utf-8") as output:
        subprocess.run(
            ["aws", "lambda", "invoke", "--function-name", function_name, "--invocation-type", "RequestResponse", "--payload", f"fileb://{event_path}", str(result_path)],
            check=True,
            stdout=output,
        )
    invoke = json.loads(invoke_path.read_text(encoding="utf-8"))
    result = json.loads(result_path.read_text(encoding="utf-8"))
    if invoke.get("StatusCode") != 200 or invoke.get("FunctionError") or result != {"statusCode": 200, "result": "user_not_found"}:
        raise RuntimeError("Keycloak session Lambda probe failed")
PY
}

root_patched=false
restore() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ $root_patched == true ]]; then
    patch_root_revision main >/dev/null || status=1
    wait_for main || status=1
  fi
  exit "$status"
}
trap restore EXIT INT TERM HUP

main_state_matches || fail preflight 'platform-root/keycloak가 시작 main에서 Synced/Healthy가 아니다.'
patch_root_revision "$root_revision" >/dev/null
root_patched=true
wait_for immutable || fail immutable 'platform-root/keycloak가 immutable SHA에서 Synced/Healthy가 아니다.'
verify_route || fail route 'CIEM /admin route 또는 source allowlist가 선언과 다르다.'
verify_session_path || fail session 'Keycloak VPC session Lambda probe가 실패했다.'
echo "AWS-SEC-03 Argo=PASS root=$root_revision keycloak=$config_revision route=admin-vpc-exact session=vgw-private"
