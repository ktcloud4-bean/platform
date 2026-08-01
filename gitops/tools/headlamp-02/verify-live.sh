#!/usr/bin/env bash
# HEADLAMP-02의 browser OIDC, Pomerium route, Kubernetes RBAC와 정리 경계를 검증한다.
set -Eeuo pipefail

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
: "${OPN_ENV:?저장소 밖 OPNsense env 파일이 필요하다}"

readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly preflight_only=${HEADLAMP02_PREFLIGHT_ONLY:-0}
readonly no_group_username=headlamp-no-group
readonly no_group_password_file=${KC01_NOGROUP_PASSWORD_FILE:-${KC01_SECRET_DIR}/headlamp-no-group-password}
readonly no_group_totp_file=${KC01_NOGROUP_TOTP_FILE:-${KC01_SECRET_DIR}/headlamp-no-group-totp}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

case "${preflight_only}" in
  0|1) ;;
  *)
    echo "HEADLAMP02_PREFLIGHT_ONLY는 0 또는 1이어야 한다." >&2
    exit 2
    ;;
esac

# 이 도구가 사용하는 kubectl 경로와 모든 인수는 고정 문자열이다. 외부 입력을 원격
# shell command로 조합하지 않아 명령 주입과 ShellCheck의 client-side expansion
# 혼동을 피한다.
remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

remote_vault_status() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl -n vault exec vault-0 -- vault status -format=json
}

assert_remote_absent() {
  local description=$1
  shift
  set +e
  remote_kubectl "$@" >/dev/null 2>&1
  local status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    echo "남아 있으면 안 되는 자원이 존재한다: ${description}" >&2
    exit 1
  fi
  if [[ "${status}" -ne 1 ]]; then
    echo "부재 확인 자체가 실패했다: ${description} (ssh/kubectl exit=${status})" >&2
    exit 1
  fi
}

for command_name in curl jq node openssl python3 ssh; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "필수 명령이 없다: ${command_name}" >&2
    exit 1
  }
done
for required in \
  daily-password daily-totp privileged-password privileged-totp verify-client-secret; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "KC-01 외부 검증 입력이 없다: ${required}" >&2
    exit 1
  }
done
for required_file in "${no_group_password_file}" "${no_group_totp_file}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" && -s "${required_file}" ]] || {
    echo "무group 검증 입력이 regular non-empty file이 아니다." >&2
    exit 1
  }
  [[ "$(stat -c %a "${required_file}")" == 600 ]] || {
    echo "무group 검증 입력은 mode 0600이어야 한다." >&2
    exit 1
  }
done
[[ -f "${OPN_ENV}" && ! -L "${OPN_ENV}" ]] || {
  echo "OPNsense env 입력이 일반 파일이 아니다." >&2
  exit 1
}
[[ "$(stat -c %a "${OPN_ENV}")" == 600 ]] || {
  echo "OPNsense env 입력은 mode 0600이어야 한다." >&2
  exit 1
}
python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]).version == 4
PY

echo "HEADLAMP-02: Keycloak client, Unbound alias, k3s·Vault·Argo 기준선을 확인한다."
K3S_HOST="${k3s_host}" K3S_SSH_KNOWN_HOSTS="${known_hosts}" \
  "${repo_root}/gitops/tools/headlamp-02/check-break-glass.sh"
K3S_HOST="${k3s_host}" K3S_SSH_KNOWN_HOSTS="${known_hosts}" \
  "${repo_root}/gitops/tools/headlamp-02/check-capacity.sh"
KC01_SECRET_DIR="${KC01_SECRET_DIR}" KC01_CONNECT_IP="${connect_ip}" \
  "${repo_root}/gitops/tools/headlamp-02/provision-no-group-user.sh" --check
KC01_SECRET_DIR="${KC01_SECRET_DIR}" KC01_CONNECT_IP="${connect_ip}" \
  "${repo_root}/gitops/tools/headlamp-02/provision-keycloak-client.sh" --check
"${repo_root}/gitops/tools/headlamp-02/opnsense-alias.py" --env-file "${OPN_ENV}" check
"${repo_root}/infra/opnsense/scripts/check-drift.sh" --env-file "${OPN_ENV}"

ssh "${ssh_options[@]}" "${k3s_host}" \
  'sudo -n systemctl is-active --quiet k3s && sudo -n /usr/local/bin/k3s kubectl get --raw=/readyz | grep -Fx ok >/dev/null'
remote_kubectl get node -o json | jq -e '
    .items | length == 1 and
    ([.[0].status.conditions[] | select(.type == "Ready") | .status] == ["True"]) and
    ([.[0].status.conditions[] | select(.type == "DiskPressure") | .status] == ["False"])
  ' >/dev/null
remote_vault_status | jq -e '
    .initialized == true and .sealed == false
  ' >/dev/null

# ssh는 원격 명령 인수를 다시 조합한다. 공백을 포함한 JSONPath를 전달하지 않고
# JSON 한 개를 받은 뒤 local jq가 안정적인 pipe 구분 상태 행을 만든다.
argo_state=$(remote_kubectl -n argocd get application platform-root headlamp pomerium keycloak vault \
  -o json | jq -r '
    .items[]
    | [
        .metadata.name,
        (.status.sync.status // ""),
        (.status.health.status // ""),
        (.spec.source.targetRevision // "")
      ]
    | join("|")
  ')
for expected in \
  'platform-root|Synced|Healthy|main' \
  'headlamp|Synced|Healthy|main' \
  'pomerium|Synced|Healthy|main' \
  'keycloak|Synced|Healthy|main' \
  'vault|Synced|Healthy|main'; do
  grep -Fxq "${expected}" <<<"${argo_state}" || {
    echo "Argo 상태 불일치: ${expected}" >&2
    exit 1
  }
done

if [[ "${preflight_only}" == 1 ]]; then
  echo "HEADLAMP-02: Keycloak·OPNsense·k3s·Argo 사전검증 통과"
  exit 0
fi

echo "HEADLAMP-02: TLS hostname, HTTP redirect와 browser OIDC/RBAC를 확인한다."
curl --silent --show-error --fail \
  --resolve "headlamp.imcherry5778.xyz:443:${connect_ip}" \
  "https://headlamp.imcherry5778.xyz/" >/dev/null
printf '' | openssl s_client -connect "${connect_ip}:443" \
  -servername headlamp.imcherry5778.xyz 2>/dev/null \
  | openssl x509 -noout -checkhost headlamp.imcherry5778.xyz >/dev/null
set +e
curl --silent --show-error \
  --resolve "wrong-headlamp-02.imcherry5778.xyz:443:${connect_ip}" \
  "https://wrong-headlamp-02.imcherry5778.xyz/" >/dev/null 2>&1
wrong_hostname_status=$?
set -e
[[ "${wrong_hostname_status}" -eq 60 ]] || {
  echo "잘못된 Headlamp TLS hostname의 curl 종료코드가 60이 아니다: ${wrong_hostname_status}" >&2
  exit 1
}
redirect_headers=$(mktemp)
trap 'rm -f "${redirect_headers}"' EXIT
http_status=$(curl --silent --show-error --output /dev/null \
  --resolve "headlamp.imcherry5778.xyz:80:${connect_ip}" \
  --dump-header "${redirect_headers}" --write-out '%{http_code}' \
  http://headlamp.imcherry5778.xyz/)
[[ "${http_status}" == 301 ]]
grep -Eiq '^location: https://headlamp\.imcherry5778\.xyz/' "${redirect_headers}"

# KC-01은 MFA 누락 400과 두 기존 identity의 groups claim을 이미 token 원문 없이 판정한다.
KC01_SECRET_DIR="${KC01_SECRET_DIR}" KC01_CONNECT_IP="${connect_ip}" K3S_HOST="${k3s_host}" \
  "${repo_root}/gitops/tools/kc-01/verify-live.sh"

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
K3S_HOST="${k3s_host}" K3S_SSH_KNOWN_HOSTS="${known_hosts}" \
  node "${repo_root}/gitops/tools/headlamp-02/browser-verify.js" \
    --connect-ip "${connect_ip}" \
    --username imcherry \
    --password-file "${KC01_SECRET_DIR}/daily-password" \
    --totp-file "${KC01_SECRET_DIR}/daily-totp" \
    --group /platform-users \
    --kind daily \
    --wrong-audience-secret-file "${KC01_SECRET_DIR}/verify-client-secret" \
    --check-expiry true

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
K3S_HOST="${k3s_host}" K3S_SSH_KNOWN_HOSTS="${known_hosts}" \
  node "${repo_root}/gitops/tools/headlamp-02/browser-verify.js" \
    --connect-ip "${connect_ip}" \
    --username imcherry-admin \
    --password-file "${KC01_SECRET_DIR}/privileged-password" \
    --totp-file "${KC01_SECRET_DIR}/privileged-totp" \
    --group /platform-privileged \
    --kind privileged

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
K3S_HOST="${k3s_host}" K3S_SSH_KNOWN_HOSTS="${known_hosts}" \
  node "${repo_root}/gitops/tools/headlamp-02/browser-verify.js" \
    --connect-ip "${connect_ip}" \
    --username "${no_group_username}" \
    --password-file "${no_group_password_file}" \
    --totp-file "${no_group_totp_file}" \
    --wrong-audience-secret-file "${KC01_SECRET_DIR}/verify-client-secret" \
    --kind no-group

echo "HEADLAMP-02: bootstrap prune, runtime SA, ServiceAccount token Secret과 임시 listener를 확인한다."
remote_kubectl -n headlamp get deployment headlamp -o json | jq -e '
    .spec.template.spec.automountServiceAccountToken == false and
    .spec.template.spec.serviceAccountName == "headlamp" and
    ([.spec.template.spec.containers[0].args[]] | index("-unsafe-use-service-account-token") | not) and
    ([.spec.template.spec.containers[0].args[]] | index("-oidc-client-id=headlamp")) and
    ([.spec.template.spec.containers[0].args[]] | index("-oidc-use-pkce=true"))
  ' >/dev/null
for denied in \
  'get pods --all-namespaces' \
  'get pods/log --all-namespaces' \
  'create pods/exec --all-namespaces' \
  'create deployments.apps --all-namespaces'; do
  read -r verb resource scope <<<"${denied}"
  actual=$(remote_kubectl auth can-i "${verb}" "${resource}" "${scope}" --as=system:serviceaccount:headlamp:headlamp)
  [[ "${actual}" == no ]] || {
    echo "Headlamp runtime ServiceAccount 예상 밖 권한: ${denied}=${actual}" >&2
    exit 1
  }
done
assert_remote_absent 'bootstrap ServiceAccount headlamp-reader' -n headlamp get serviceaccount headlamp-reader
for resource in clusterrole/headlamp-reader clusterrolebinding/headlamp-reader; do
  assert_remote_absent "bootstrap RBAC ${resource}" get "${resource}"
done
legacy_token_secret_count=$(remote_kubectl get secrets -A -o json \
  | jq '[.items[] | select(.type == "kubernetes.io/service-account-token")] | length')
[[ "${legacy_token_secret_count}" -eq 0 ]] || {
  echo "장기 ServiceAccount token Secret이 존재한다: ${legacy_token_secret_count}" >&2
  exit 1
}
listener=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "sudo -n ss -H -lnt '( sport = :18446 )'")
[[ -z "${listener}" ]] || {
    echo "HEADLAMP-01 loopback port-forward listener가 남아 있다." >&2
    exit 1
  }

echo "HEADLAMP-02: Git과 Headlamp/Pomerium Pod log의 token·JWT 원문 부재를 확인한다."
if git -C "${repo_root}" grep -En 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' -- . >/dev/null 2>&1; then
  echo "Git 추적 파일에서 JWT 형식 원문을 찾았다." >&2
  exit 1
fi
log_file=$(mktemp)
trap 'rm -f "${redirect_headers}" "${log_file}"' EXIT
remote_kubectl -n headlamp logs -l app.kubernetes.io/name=headlamp --all-containers=true --prefix=true --tail=-1 >"${log_file}"
remote_kubectl -n pomerium logs -l app.kubernetes.io/part-of=platform-gitops --all-containers=true --prefix=true --tail=-1 >>"${log_file}"
if grep -Eq 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "${log_file}"; then
  echo "Headlamp 또는 Pomerium Pod log에서 JWT 형식 원문을 찾았다." >&2
  exit 1
fi
find /tmp -maxdepth 1 -type f \( -name 'headlamp-02-*' -o -name 'headlamp-02-*.header' \) -print -quit | grep -q . && {
  echo "HEADLAMP-02 임시 token/header 파일이 남아 있다." >&2
  exit 1
} || true

echo "HEADLAMP-02: OIDC/Pomerium/RBAC/bootstrap/비밀 비노출 live 검증 통과"
