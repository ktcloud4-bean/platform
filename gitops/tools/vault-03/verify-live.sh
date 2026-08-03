#!/usr/bin/env bash
# VAULT-03: Vault OIDC auth·policy 격리, Pomerium 미경유 Ingress·backend TLS 신뢰,
# Pomerium 정지 중 복구 독립성, root token·port-forward break-glass, audit, DNS alias,
# Traefik 불변, Argo 상태를 한 세션에서 검증한다. Keycloak client·Vault OIDC 구성·DNS
# alias의 실제 적용(--apply)은 이 스크립트가 아니라 그 전 단계에서 이미 끝났다고 가정하고
# 여기서는 --check/read-only 확인과 기능 검증만 한다.
set -Eeuo pipefail

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
: "${VAULT_ROOT_TOKEN_FILE:?저장소 밖 Vault root token 파일이 필요하다}"
: "${OPN_ENV:?저장소 밖 OPNsense env 파일이 필요하다}"

readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly root_target_revision=${VAULT03_ROOT_TARGET_REVISION:-main}
readonly vault_target_revision=${VAULT03_VAULT_TARGET_REVISION:-main}
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

for command_name in curl jq python3 ssh openssl base64; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "필수 명령이 없다: ${command_name}" >&2
    exit 1
  }
done
for required in privileged-password privileged-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "KC-01 검증 입력이 없다: ${required}" >&2
    exit 1
  }
done
[[ -r "${VAULT_ROOT_TOKEN_FILE}" && "$(stat -c %a "${VAULT_ROOT_TOKEN_FILE}")" == 600 ]] || {
  echo "Vault root token 파일이 없거나 mode 0600이 아니다." >&2
  exit 1
}
[[ -f "${OPN_ENV}" && ! -L "${OPN_ENV}" ]] || {
  echo "OPNsense env 입력이 일반 파일이 아니다." >&2
  exit 1
}
python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]).version == 4
PY

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM
vault_cacert_file=${temp_dir}/vault-ingress-ca.crt
vault_token_header=${temp_dir}/vault-token.header

echo "VAULT-03: Keycloak client, OPNsense alias, k3s·Argo 기준선을 확인한다."
"${repo_root}/gitops/tools/vault-03/opnsense-alias.py" --env-file "${OPN_ENV}" check
"${repo_root}/infra/opnsense/scripts/check-drift.sh" --env-file "${OPN_ENV}"

ssh "${ssh_options[@]}" "${k3s_host}" \
  'sudo -n systemctl is-active --quiet k3s && sudo -n /usr/local/bin/k3s kubectl get --raw=/readyz | grep -Fx ok >/dev/null'
remote_kubectl get node -o json | jq -e '
    .items | length == 1 and
    ([.[0].status.conditions[] | select(.type == "Ready") | .status] == ["True"]) and
    ([.[0].status.conditions[] | select(.type == "DiskPressure") | .status] == ["False"])
  ' >/dev/null

argo_state=$(remote_kubectl -n argocd get application platform-root vault \
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
  "vault|Synced|Healthy|${vault_target_revision}"; do
  grep -Fxq "${expected}" <<<"${argo_state}" || {
    echo "Argo 상태 불일치: ${expected}" >&2
    exit 1
  }
done

echo "VAULT-03: ServersTransport·backend TLS 신뢰 선언을 확인한다(insecureSkipVerify 미사용)."
remote_kubectl -n vault get serverstransport vault-backend-tls -o json | jq -e '
  .spec.rootCAsSecrets == ["vault-ingress-ca"] and
  .spec.serverName == "vault.vault.svc.cluster.local" and
  (.spec.insecureSkipVerify // false) == false
' >/dev/null
remote_kubectl -n vault get secret vault-ingress-ca -o json \
  | jq -r '.data["tls.ca"]' | base64 -d >"${vault_cacert_file}"
[[ -s "${vault_cacert_file}" ]]
openssl x509 -in "${vault_cacert_file}" -noout -subject >/dev/null

traefik_hcc_rv_before=$(remote_kubectl -n kube-system get helmchartconfig traefik -o jsonpath='{.metadata.resourceVersion}')
traefik_uid_before=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.uid}')
traefik_restarts_before=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')

echo "VAULT-03: Pomerium을 경유하지 않는 표준 Ingress와 backend TLS 신뢰 왕복을 확인한다."
health_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "vault.imcherry5778.xyz:443:${connect_ip}" \
  "https://vault.imcherry5778.xyz/v1/sys/health?standbyok=true")
[[ "${health_status}" == 200 ]] || {
  echo "Vault Ingress health 응답이 200이 아니다: ${health_status}" >&2
  exit 1
}
printf '' | openssl s_client -connect "${connect_ip}:443" \
  -servername vault.imcherry5778.xyz 2>/dev/null \
  | openssl x509 -noout -checkhost vault.imcherry5778.xyz >/dev/null

echo "VAULT-03: root token break-glass가 살아있는지 확인한다(폐기하지 않는다)."
root_lookup_json=$({ cat "${VAULT_ROOT_TOKEN_FILE}"; cat <<'REMOTE'
vault token lookup -format=json
REMOTE
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "sudo -n /usr/local/bin/k3s kubectl -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'")
jq -e '.data.policies == ["root"]' <<<"${root_lookup_json}" >/dev/null || {
  echo "root token lookup이 실패했거나 root policy가 아니다." >&2
  exit 1
}

echo "VAULT-03: port-forward break-glass가 살아있는지 확인한다."
ssh "${ssh_options[@]}" "${k3s_host}" "umask 077; cat >/tmp/vault03-ca.crt" <"${vault_cacert_file}"
pf_output=$(ssh "${ssh_options[@]}" "${k3s_host}" bash -s <<'REMOTE'
set -Eeuo pipefail
sudo -n /usr/local/bin/k3s kubectl -n vault port-forward svc/vault 28200:8200 --address=127.0.0.1 \
  >/tmp/vault03-pf.log 2>&1 &
pf_pid=$!
cleanup() { kill "${pf_pid}" >/dev/null 2>&1 || true; wait "${pf_pid}" 2>/dev/null || true; rm -f /tmp/vault03-pf.log /tmp/vault03-ca.crt; }
trap cleanup EXIT
ready=0
for _ in $(seq 1 40); do
  if curl --silent --show-error --fail --max-time 2 --cacert /tmp/vault03-ca.crt \
    --resolve vault.vault.svc.cluster.local:28200:127.0.0.1 \
    "https://vault.vault.svc.cluster.local:28200/v1/sys/health?standbyok=true" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
[[ "${ready}" -eq 1 ]] && echo "PORT_FORWARD_OK"
REMOTE
)
grep -Fxq "PORT_FORWARD_OK" <<<"${pf_output}" || {
  echo "port-forward break-glass 확인에 실패했다." >&2
  exit 1
}

echo "VAULT-03: Pomerium replica를 0으로 내린 창에서 Vault UI OIDC 로그인·policy 격리·audit를 확인한다."
pomerium_replicas_before=$(remote_kubectl -n pomerium get deployment pomerium -o jsonpath='{.spec.replicas}')
[[ "${pomerium_replicas_before}" -ge 1 ]] || {
  echo "Pomerium 사전 replica 수를 확인할 수 없다." >&2
  exit 1
}
restore_pomerium() {
  remote_kubectl -n pomerium scale deployment pomerium --replicas="${pomerium_replicas_before}" >/dev/null 2>&1 || true
}
trap 'restore_pomerium; cleanup' EXIT INT TERM

remote_kubectl -n pomerium scale deployment pomerium --replicas=0 >/dev/null
for _ in $(seq 1 60); do
  ready=$(remote_kubectl -n pomerium get deployment pomerium -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [[ -z "${ready}" || "${ready}" == 0 ]] && break
  sleep 2
done
ready=$(remote_kubectl -n pomerium get deployment pomerium -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
[[ -z "${ready}" || "${ready}" == 0 ]] || {
  echo "Pomerium이 예상대로 0 replica가 되지 않았다." >&2
  exit 1
}

audit_since=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/vault-03/vault-oidc-login.py" \
  --vault-addr https://vault.imcherry5778.xyz \
  --role ui-viewer \
  --redirect-uri https://vault.imcherry5778.xyz/ui/vault/auth/oidc/oidc/callback \
  --username imcherry-admin \
  --password-file "${KC01_SECRET_DIR}/privileged-password" \
  --totp-file "${KC01_SECRET_DIR}/privileged-totp" \
  --header-file "${vault_token_header}" \
  --connect-ip "${connect_ip}" | tee "${temp_dir}/login.out"
grep -q 'vault-ui-operator' "${temp_dir}/login.out" || {
  echo "로그인한 token에 vault-ui-operator policy가 없다." >&2
  exit 1
}
echo "VAULT-03: Pomerium이 0 replica인 상태에서 Vault UI OIDC 로그인 성공(복구 독립성 실증)."

vault_token=$(sed -n 's/^X-Vault-Token: //p' "${vault_token_header}")
[[ -n "${vault_token}" ]]

kv_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "vault.imcherry5778.xyz:443:${connect_ip}" \
  --header "@${vault_token_header}" \
  "https://vault.imcherry5778.xyz/v1/kv/data/keycloak/runtime")
[[ "${kv_status}" == 200 ]] || {
  echo "자기 policy 경로(kv/data/keycloak/runtime) 조회가 200이 아니다: ${kv_status}" >&2
  exit 1
}
mounts_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "vault.imcherry5778.xyz:443:${connect_ip}" \
  --header "@${vault_token_header}" \
  "https://vault.imcherry5778.xyz/v1/sys/mounts")
[[ "${mounts_status}" == 403 ]] || {
  echo "sys/mounts 조회가 403이 아니다: ${mounts_status}" >&2
  exit 1
}
token_create_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --resolve "vault.imcherry5778.xyz:443:${connect_ip}" \
  --header "@${vault_token_header}" \
  --request POST --data '{}' \
  "https://vault.imcherry5778.xyz/v1/auth/token/create")
[[ "${token_create_status}" == 403 ]] || {
  echo "auth/token/create 조회가 403이 아니다: ${token_create_status}" >&2
  exit 1
}
echo "VAULT-03: 자기 policy 경로 200, sys/mounts·auth/token/create 403 확인 완료."

restore_pomerium
trap cleanup EXIT INT TERM
for _ in $(seq 1 60); do
  ready=$(remote_kubectl -n pomerium get deployment pomerium -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [[ "${ready}" == "${pomerium_replicas_before}" ]] && break
  sleep 2
done
[[ "${ready}" == "${pomerium_replicas_before}" ]] || {
  echo "Pomerium이 원래 replica 수로 복구되지 않았다." >&2
  exit 1
}
echo "VAULT-03: Pomerium을 원래 replica 수로 복구했다(회귀 없음)."

echo "VAULT-03: audit device에 이번 로그인 event가 있고 token 원문은 0건인지 확인한다."
audit_lines=$(remote_kubectl -n vault logs vault-0 --since-time="${audit_since}")
grep -Fq '"path":"auth/oidc' <<<"${audit_lines}" || {
  echo "audit 로그에 이번 창의 oidc 로그인 event가 없다." >&2
  exit 1
}
if grep -F "${vault_token}" <<<"${audit_lines}" >/dev/null; then
  echo "audit 로그에 Vault token 원문이 남아 있다." >&2
  exit 1
fi
echo "VAULT-03: audit event 확인, token 원문 0건 확인 완료."

echo "VAULT-03: Traefik 정적 설정·Pod UID·restart, HelmChartConfig 불변을 확인한다."
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

echo "VAULT-03: 기존 Vault Agent 소비자(Keycloak·Pomerium) 회귀가 없는지 확인한다."
remote_kubectl -n keycloak get pod -l app.kubernetes.io/name=keycloak,app.kubernetes.io/component=server -o json | jq -e '
  .items | length >= 1 and all(.[]; .status.phase == "Running")
' >/dev/null || {
  echo "Keycloak server Pod가 Running이 아니다." >&2
  exit 1
}
remote_kubectl -n pomerium get pod -l app.kubernetes.io/name=pomerium -o json | jq -e '
  .items | length >= 1 and all(.[]; .status.phase == "Running")
' >/dev/null || {
  echo "Pomerium Pod가 Running이 아니다." >&2
  exit 1
}

listener=$(ssh "${ssh_options[@]}" "${k3s_host}" "sudo -n ss -H -lnt '( sport = :28200 )'")
[[ -z "${listener}" ]] || {
  echo "VAULT-03 loopback port-forward listener가 남아 있다." >&2
  exit 1
}
remaining=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "find /tmp -maxdepth 1 -type f \\( -name 'vault03-*' \\) -print -quit")
[[ -z "${remaining}" ]] || {
  echo "VAULT-03 임시 파일이 k3s-01에 남아 있다: ${remaining}" >&2
  exit 1
}

echo "VAULT-03: Git 추적 파일의 Vault token·JWT 원문 부재를 확인한다."
if git -C "${repo_root}" grep -En 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' -- . >/dev/null 2>&1; then
  echo "Git 추적 파일에서 JWT 형식 원문을 찾았다." >&2
  exit 1
fi
if git -C "${repo_root}" grep -Fq "${vault_token}" -- . >/dev/null 2>&1; then
  echo "Git 추적 파일에서 Vault token 원문을 찾았다." >&2
  exit 1
fi

echo "VAULT-03: OIDC auth·policy 격리 / Ingress·backend TLS 신뢰 / Pomerium 독립성 /"
echo "  break-glass 보존 / audit / Traefik 불변 / Vault Agent 소비자 회귀 없음 확인 통과"
