#!/usr/bin/env bash
# GITOPS-02의 Pomerium route, Argo CD 자체 OIDC·RBAC, OPNsense alias와
# Traefik/HelmChartConfig 불변을 검증한다.
set -Eeuo pipefail

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
: "${OPN_ENV:?저장소 밖 OPNsense env 파일이 필요하다}"

readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly root_target_revision=${GITOPS02_ROOT_TARGET_REVISION:-main}
readonly pomerium_target_revision=${GITOPS02_POMERIUM_TARGET_REVISION:-main}
readonly no_group_username=headlamp-no-group
readonly no_group_password_file=${GITOPS02_NOGROUP_PASSWORD_FILE:-${KC01_SECRET_DIR}/headlamp-no-group-password}
readonly no_group_totp_file=${GITOPS02_NOGROUP_TOTP_FILE:-${KC01_SECRET_DIR}/headlamp-no-group-totp}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

for command_name in curl jq python3 ssh; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "필수 명령이 없다: ${command_name}" >&2
    exit 1
  }
done
for required in daily-password daily-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "KC-01 검증 입력이 없다: ${required}" >&2
    exit 1
  }
done
for required_file in "${no_group_password_file}" "${no_group_totp_file}"; do
  [[ -f "${required_file}" && ! -L "${required_file}" && -s "${required_file}" ]] || {
    echo "무group 검증 입력이 regular non-empty file이 아니다." >&2
    exit 1
  }
done
[[ -f "${OPN_ENV}" && ! -L "${OPN_ENV}" ]] || {
  echo "OPNsense env 입력이 일반 파일이 아니다." >&2
  exit 1
}
python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]).version == 4
PY

echo "GITOPS-02: Keycloak client, OPNsense alias, k3s·Argo·Traefik 기준선을 확인한다."
KC01_SECRET_DIR="${KC01_SECRET_DIR}" KC01_CONNECT_IP="${connect_ip}" \
  "${repo_root}/gitops/tools/gitops-02/provision-keycloak-client.sh" --check
"${repo_root}/gitops/tools/gitops-02/opnsense-alias.py" --env-file "${OPN_ENV}" check
"${repo_root}/infra/opnsense/scripts/check-drift.sh" --env-file "${OPN_ENV}"

ssh "${ssh_options[@]}" "${k3s_host}" \
  'sudo -n systemctl is-active --quiet k3s && sudo -n /usr/local/bin/k3s kubectl get --raw=/readyz | grep -Fx ok >/dev/null'
remote_kubectl get node -o json | jq -e '
    .items | length == 1 and
    ([.[0].status.conditions[] | select(.type == "Ready") | .status] == ["True"]) and
    ([.[0].status.conditions[] | select(.type == "DiskPressure") | .status] == ["False"])
  ' >/dev/null

argo_state=$(remote_kubectl -n argocd get application platform-root pomerium \
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
  "platform-root|Synced|Healthy|${root_target_revision}" \
  "pomerium|Synced|Healthy|${pomerium_target_revision}"; do
  grep -Fxq "${expected}" <<<"${argo_state}" || {
    echo "Argo 상태 불일치: ${expected}" >&2
    exit 1
  }
done

traefik_hcc_rv_before=$(remote_kubectl -n kube-system get helmchartconfig traefik -o jsonpath='{.metadata.resourceVersion}')
traefik_uid_before=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.uid}')
traefik_restarts_before=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')

echo "GITOPS-02: TLS hostname, HTTP redirect를 확인한다."
curl --silent --show-error --fail \
  --resolve "argo.imcherry5778.xyz:443:${connect_ip}" \
  "https://argo.imcherry5778.xyz/" >/dev/null
printf '' | openssl s_client -connect "${connect_ip}:443" \
  -servername argo.imcherry5778.xyz 2>/dev/null \
  | openssl x509 -noout -checkhost argo.imcherry5778.xyz >/dev/null
redirect_headers=$(mktemp)
trap 'rm -f "${redirect_headers}"' EXIT
http_status=$(curl --silent --show-error --output /dev/null \
  --resolve "argo.imcherry5778.xyz:80:${connect_ip}" \
  --dump-header "${redirect_headers}" --write-out '%{http_code}' \
  http://argo.imcherry5778.xyz/)
[[ "${http_status}" == 301 ]]
grep -Eiq '^location: https://argo\.imcherry5778\.xyz/' "${redirect_headers}"

echo "GITOPS-02: Pomerium claim/groups allow/deny와 Argo API 401(Pomerium-only 세션)을 확인한다."
wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/gitops-02/pomerium-boundary-check.py" \
  --connect-ip "${connect_ip}" \
  --username imcherry \
  --password-file "${KC01_SECRET_DIR}/daily-password" \
  --totp-file "${KC01_SECRET_DIR}/daily-totp" \
  --expect allow

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/gitops-02/pomerium-boundary-check.py" \
  --connect-ip "${connect_ip}" \
  --username "${no_group_username}" \
  --password-file "${no_group_password_file}" \
  --totp-file "${no_group_totp_file}" \
  --expect deny

echo "GITOPS-02: Argo CD 자체 OIDC id_token으로 get allow·sync/delete/repositories deny를 확인한다."
umask 077
token_header=$(mktemp)
trap 'rm -f "${redirect_headers}" "${token_header}"' EXIT
wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer https://sso.imcherry5778.xyz \
  --realm platform \
  --client-id argocd \
  --redirect-uri https://argo.imcherry5778.xyz/auth/callback \
  --username imcherry \
  --password-file "${KC01_SECRET_DIR}/daily-password" \
  --totp-file "${KC01_SECRET_DIR}/daily-totp" \
  --header-file "${token_header}" \
  --connect-ip "${connect_ip}" \
  --capture-callback \
  --token-claim id_token >/dev/null
"${repo_root}/gitops/tools/gitops-02/argocd-rbac-check.sh" "${token_header}" "${k3s_host}" "${known_hosts}"

echo "GITOPS-02: Traefik/HelmChartConfig 불변, 잔여 port-forward·임시 파일 부재를 확인한다."
traefik_hcc_rv_after=$(remote_kubectl -n kube-system get helmchartconfig traefik -o jsonpath='{.metadata.resourceVersion}')
traefik_uid_after=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.uid}')
traefik_restarts_after=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
[[ "${traefik_hcc_rv_before}" == "${traefik_hcc_rv_after}" ]] || {
  echo "HelmChartConfig/traefik resourceVersion이 바뀌었다: ${traefik_hcc_rv_before} -> ${traefik_hcc_rv_after}" >&2
  exit 1
}
[[ "${traefik_uid_before}" == "${traefik_uid_after}" && "${traefik_restarts_before}" == "${traefik_restarts_after}" ]] || {
  echo "Traefik Pod UID 또는 restart count가 바뀌었다." >&2
  exit 1
}
listener=$(ssh "${ssh_options[@]}" "${k3s_host}" "sudo -n ss -H -lnt '( sport = :28443 )'")
[[ -z "${listener}" ]] || {
  echo "GITOPS-02 loopback port-forward listener가 남아 있다." >&2
  exit 1
}
remaining=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "find /tmp -maxdepth 1 -type f \\( -name 'gitops-02-*' \\) -print -quit")
[[ -z "${remaining}" ]] || {
  echo "GITOPS-02 임시 파일이 k3s-01에 남아 있다: ${remaining}" >&2
  exit 1
}

echo "GITOPS-02: Git 추적 파일의 JWT 원문 부재를 확인한다."
if git -C "${repo_root}" grep -En 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' -- . >/dev/null 2>&1; then
  echo "Git 추적 파일에서 JWT 형식 원문을 찾았다." >&2
  exit 1
fi

echo "GITOPS-02: Pomerium/Argo OIDC·RBAC/OPNsense alias/Traefik 불변/비밀 비노출 live 검증 통과"
