#!/usr/bin/env bash
# GITOPS-02: Argo CD 자체 OIDC id_token 하나로 조회(get) allow와
# sync/delete/repositories deny를 같은 세션에서 연속 검증한다. Pomerium을
# 거치지 않고 k3s-01 loopback port-forward로 argocd-server에 직접 접속해
# Argo 자체 RBAC만 판정한다. delete 대상은 실재하지 않는 이름을 써서
# 정책에 결함이 있어도 실제 Application을 지우지 않는다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법:
  ./gitops/tools/gitops-02/argocd-rbac-check.sh <token-header-file> <k3s-ssh-target> <known-hosts>

<token-header-file>는 "Authorization: Bearer <id_token>" 한 줄을 담은 mode 0600 파일이다.
EOF
}

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

token_header_file=$1
k3s_host=$2
known_hosts=$3

[[ -s "${token_header_file}" && "$(stat -c %a "${token_header_file}")" == 600 ]] || {
  echo "token header 파일이 없거나 mode 0600이 아니다." >&2
  exit 1
}

ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)
readonly remote_header=/tmp/gitops-02-bearer.header
readonly local_port=28443

cleanup_remote_header() {
  # shellcheck disable=SC2029  # remote_header is a fixed constant path, not user input
  ssh "${ssh_options[@]}" "${k3s_host}" "rm -f ${remote_header}" >/dev/null 2>&1 || true
}
trap cleanup_remote_header EXIT

umask 077
# shellcheck disable=SC2029  # remote_header is a fixed constant path, not user input
ssh "${ssh_options[@]}" "${k3s_host}" \
  "umask 077; cat > ${remote_header}" < "${token_header_file}"

results_file=$(mktemp)
trap 'rm -f "${results_file}"' EXIT
ssh "${ssh_options[@]}" "${k3s_host}" bash -s -- "${remote_header}" "${local_port}" <<'REMOTE' >"${results_file}"
set -Eeuo pipefail
header_file=$1
port=$2
sudo -n /usr/local/bin/k3s kubectl -n argocd port-forward svc/argocd-server "${port}:443" --address=127.0.0.1 \
  >/tmp/gitops-02-pf.log 2>&1 &
pf_pid=$!
cleanup() {
  kill "${pf_pid}" >/dev/null 2>&1 || true
  wait "${pf_pid}" 2>/dev/null || true
  rm -f /tmp/gitops-02-pf.log "${header_file}"
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 40); do
  if curl --silent --show-error --fail --max-time 2 -k "https://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
[[ "${ready}" -eq 1 ]] || { echo "port-forward not ready" >&2; exit 1; }

apps_status=$(curl --silent -k --max-time 10 -o /tmp/gitops-02-apps.json -w '%{http_code}' \
  -H "@${header_file}" -H 'Content-Type: application/json' \
  "https://127.0.0.1:${port}/api/v1/applications")
sync_status=$(curl --silent -k --max-time 10 -o /dev/null -w '%{http_code}' \
  -X POST -H "@${header_file}" -H 'Content-Type: application/json' -d '{}' \
  "https://127.0.0.1:${port}/api/v1/applications/platform-root/sync")
delete_status=$(curl --silent -k --max-time 10 -o /dev/null -w '%{http_code}' \
  -X DELETE -H "@${header_file}" -H 'Content-Type: application/json' \
  "https://127.0.0.1:${port}/api/v1/applications/gitops-02-nonexistent-canary")
repos_status=$(curl --silent -k --max-time 10 -o /tmp/gitops-02-repos.json -w '%{http_code}' \
  -H "@${header_file}" -H 'Content-Type: application/json' \
  "https://127.0.0.1:${port}/api/v1/repositories")
repos_item_count=$(jq '.items // [] | length' /tmp/gitops-02-repos.json)

printf 'apps_status=%s\n' "${apps_status}"
printf 'sync_status=%s\n' "${sync_status}"
printf 'delete_status=%s\n' "${delete_status}"
printf 'repos_status=%s\n' "${repos_status}"
printf 'repos_item_count=%s\n' "${repos_item_count}"
cat /tmp/gitops-02-apps.json
rm -f /tmp/gitops-02-repos.json
rm -f /tmp/gitops-02-apps.json
REMOTE

apps_status=$(grep '^apps_status=' "${results_file}" | cut -d= -f2)
sync_status=$(grep '^sync_status=' "${results_file}" | cut -d= -f2)
delete_status=$(grep '^delete_status=' "${results_file}" | cut -d= -f2)
repos_status=$(grep '^repos_status=' "${results_file}" | cut -d= -f2)
repos_item_count=$(grep '^repos_item_count=' "${results_file}" | cut -d= -f2)
apps_json=$(sed -n '6,$p' "${results_file}")

[[ "${apps_status}" == 200 ]] || { echo "GET applications expected 200, got ${apps_status}" >&2; exit 1; }
[[ "${sync_status}" == 403 ]] || { echo "POST sync expected 403, got ${sync_status}" >&2; exit 1; }
[[ "${delete_status}" == 403 ]] || { echo "DELETE application expected 403, got ${delete_status}" >&2; exit 1; }
# ListRepositories never 403s (it filters per-repo RBAC and returns 200 with a
# possibly empty list); repo credential access denial shows up as item_count=0,
# not as an HTTP status.
[[ "${repos_status}" == 200 ]] || { echo "GET repositories expected 200, got ${repos_status}" >&2; exit 1; }
[[ "${repos_item_count}" == 0 ]] || {
  echo "GET repositories expected 0 visible repos for role:gitops-viewer, got ${repos_item_count}" >&2
  exit 1
}

echo "${apps_json}" | jq -e '
  [.items[]? | [.metadata.name, (.status.sync.status // ""), (.status.health.status // "")] | join("|")]
  as $rows |
  ($rows | any(. == "platform-root|Synced|Healthy")) and
  ($rows | any(startswith("pomerium|Synced|Healthy")))
' >/dev/null || {
  echo "applications 목록에 platform-root·pomerium Synced/Healthy가 없다." >&2
  exit 1
}

echo "GITOPS-02: Argo 자체 RBAC 검증 통과 (applications get=200, sync=403, delete=403, repositories get=200/items=0)"
