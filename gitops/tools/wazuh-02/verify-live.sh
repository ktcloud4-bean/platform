#!/usr/bin/env bash
# WAZUH-02 단일 라이브 검증 진입점.
#
# `capacity-pre`는 배포 전 capacity gate 한 번, `verify`는 완료 증거를 한 번에 판정한다.
# WAZUH-01이 이미 판정한 Suricata 수집·D30/A90 라우팅·NIDS-01 제외는 다시 검증하지 않는다.
# Secret, token, kubeconfig, 원문 credential은 출력하지 않는다.
set -Eeuo pipefail

readonly mode=${1:-verify}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly wazuh_secret_dir=${secret_root}/wazuh
readonly connect_ip=${WAZUH02_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
readonly soar01_entry_bytes=$((12 * 1024 * 1024 * 1024))
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == capacity-pre || ${mode} == verify ]] || {
  echo 'usage: verify-live.sh [capacity-pre|verify]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'WAZUH-02 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "WAZUH-02 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

measure_capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'REMOTE'
set -euo pipefail
k='sudo -n /usr/local/bin/k3s kubectl'
available_bytes=$(free -b | awk '/Mem:/{print $7}')
swap_used_bytes=$(free -b | awk '/Swap:/{print $3}')
pvc_request_bytes=$(
  ${k} get pvc -A -o json \
    | jq -r '.items[].spec.resources.requests.storage' \
    | while IFS= read -r quantity; do numfmt --from=iec-i "${quantity}"; done \
    | awk '{sum+=$1} END{printf "%.0f\n",sum+0}'
)
printf 'AVAILABLE_BYTES=%s\nSWAP_USED_BYTES=%s\nPVC_REQUEST_BYTES=%s\n' \
  "${available_bytes}" "${swap_used_bytes}" "${pvc_request_bytes}"
REMOTE
}

capacity_field() {
  awk -F= -v key="$2" '$1==key{print $2}' <<<"$1"
}

if [[ ${mode} == capacity-pre ]]; then
  capacity=$(measure_capacity)
  available_bytes=$(capacity_field "${capacity}" AVAILABLE_BYTES)
  swap_used_bytes=$(capacity_field "${capacity}" SWAP_USED_BYTES)
  pvc_request_bytes=$(capacity_field "${capacity}" PVC_REQUEST_BYTES)
  [[ ${available_bytes} =~ ^[0-9]+$ && ${swap_used_bytes} =~ ^[0-9]+$ && ${pvc_request_bytes} =~ ^[0-9]+$ ]] \
    || fail capacity 'PRE RAM/PVC 측정값을 읽지 못했다.'
  (( available_bytes >= available_stop_bytes )) || fail capacity 'PRE k3s available RAM이 8 GiB 정지선 아래다.'
  (( swap_used_bytes == 0 )) || fail capacity 'PRE k3s swap 사용량이 0이 아니다.'
  printf '%s\n' "${capacity}" | sed 's/^/PRE_/'
  echo 'WAZUH02_CAPACITY_PRE=PASS'
  exit 0
fi

readonly expected_root_revision=${WAZUH02_EXPECTED_ROOT_REVISION:?root pointer SHA가 필요하다}
readonly expected_wazuh_revision=${WAZUH02_EXPECTED_WAZUH_REVISION:?wazuh settings SHA가 필요하다}
readonly expected_pomerium_revision=${WAZUH02_EXPECTED_POMERIUM_REVISION:?pomerium settings SHA가 필요하다}
readonly pre_available_bytes=${WAZUH02_PRE_AVAILABLE_BYTES:?배포 전 available bytes가 필요하다}
readonly pre_pvc_request_bytes=${WAZUH02_PRE_PVC_REQUEST_BYTES:?배포 전 PVC 합계가 필요하다}
[[ ${expected_root_revision} =~ ^[0-9a-f]{40}$ && ${expected_wazuh_revision} =~ ^[0-9a-f]{40}$ &&
   ${expected_pomerium_revision} =~ ^[0-9a-f]{40}$ ]] || fail argo 'immutable SHA 형식이 아니다.'
[[ ${pre_available_bytes} =~ ^[0-9]+$ && ${pre_pvc_request_bytes} =~ ^[0-9]+$ ]] \
  || fail preflight '배포 전 기준값 형식이 아니다.'
for material in root-ca.pem admin.pem admin-key.pem; do
  [[ -f ${wazuh_secret_dir}/${material} && ! -L ${wazuh_secret_dir}/${material} ]] \
    || fail precondition "indexer 조회용 ${material}이 없다. wazuh-01 provision.sh apply를 먼저 실행한다."
done

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root wazuh pomerium -o json 2>/dev/null || true)
  if jq -e \
    --arg root "${expected_root_revision}" \
    --arg wazuh "${expected_wazuh_revision}" \
    --arg pomerium "${expected_pomerium_revision}" '
      ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
      ([.items[] | select(.metadata.name == "wazuh")][0] // {}) as $wazuh_app |
      ([.items[] | select(.metadata.name == "pomerium")][0] // {}) as $pomerium_app |
      $root_app.spec.source.targetRevision == $root and
      $root_app.status.sync.revision == $root and
      $root_app.status.sync.status == "Synced" and
      $root_app.status.health.status == "Healthy" and
      $wazuh_app.spec.source.targetRevision == $wazuh and
      $wazuh_app.status.sync.revision == $wazuh and
      $wazuh_app.status.sync.status == "Synced" and
      $wazuh_app.status.health.status == "Healthy" and
      $pomerium_app.spec.source.targetRevision == $pomerium and
      $pomerium_app.status.sync.revision == $pomerium and
      $pomerium_app.status.sync.status == "Synced" and
      $pomerium_app.status.health.status == "Healthy"
    ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e \
  --arg root "${expected_root_revision}" \
  --arg wazuh "${expected_wazuh_revision}" \
  --arg pomerium "${expected_pomerium_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "wazuh")][0] // {}) as $wazuh_app |
    ([.items[] | select(.metadata.name == "pomerium")][0] // {}) as $pomerium_app |
    $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
    $wazuh_app.spec.source.targetRevision == $wazuh and $wazuh_app.status.sync.revision == $wazuh and
    $wazuh_app.status.sync.status == "Synced" and $wazuh_app.status.health.status == "Healthy" and
    $pomerium_app.spec.source.targetRevision == $pomerium and $pomerium_app.status.sync.revision == $pomerium and
    $pomerium_app.status.sync.status == "Synced" and $pomerium_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null || fail argo 'root/wazuh/pomerium이 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} wazuh=${expected_wazuh_revision} pomerium=${expected_pomerium_revision}"

remote_kubectl -n wazuh rollout status deployment/wazuh-dashboard --timeout=180s >/dev/null \
  || fail deployment 'wazuh/wazuh-dashboard가 Ready가 아니다.'
remote_kubectl -n pomerium rollout status deployment/pomerium --timeout=180s >/dev/null \
  || fail deployment 'pomerium/pomerium이 Ready가 아니다.'

# indexer/manager 회귀 확인: WAZUH-01이 이미 판정한 값이 그대로인지만 본다.
manager_pod=$(remote_kubectl -n wazuh get pod -l app.kubernetes.io/component=manager -o jsonpath='{.items[0].metadata.name}')
[[ -n ${manager_pod} ]] || fail regression 'manager Pod를 찾지 못했다.'
remote_kubectl -n wazuh exec "${manager_pod}" -- \
  grep -A1 '<active-response>' /var/ossec/etc/ossec.conf | grep -q '<disabled>yes</disabled>' \
  || fail regression 'manager active-response가 더 이상 disabled=yes가 아니다.'
ar_dangerous=$(remote_kubectl -n wazuh exec "${manager_pod}" -- \
  grep -Ec 'firewall-drop|host-deny|route-null|disable-account|netsh|ip-customblock' \
  /var/ossec/etc/shared/ar.conf || true)
[[ ${ar_dangerous} == 0 ]] || fail regression 'manager ar.conf에 차단성 active-response 명령이 생겼다.'

indexer_port=${WAZUH02_INDEXER_FORWARD_PORT:-19201}
indexer_ip=$(remote_kubectl -n wazuh get service indexer -o jsonpath='{.spec.clusterIP}')
[[ ${indexer_ip} =~ ^[0-9a-fA-F:.]+$ ]] || fail regression 'indexer ClusterIP를 읽지 못했다.'
ssh "${ssh_options[@]}" -f -N \
  -L "127.0.0.1:${indexer_port}:${indexer_ip}:9200" \
  "${k3s_host}"
port_forward_pid=$(pgrep -f "L 127.0.0.1:${indexer_port}:${indexer_ip}:9200" | tail -1 || true)
cleanup() { [[ -n ${port_forward_pid} ]] && kill "${port_forward_pid}" 2>/dev/null || true; }
trap cleanup EXIT
indexer_url="https://localhost:${indexer_port}"
indexer_curl=(curl -fsS --cacert "${wazuh_secret_dir}/root-ca.pem" --cert "${wazuh_secret_dir}/admin.pem" --key "${wazuh_secret_dir}/admin-key.pem")
for _ in $(seq 1 30); do
  "${indexer_curl[@]}" "${indexer_url}/_cluster/health" >/dev/null 2>&1 && break
  sleep 1
done
"${indexer_curl[@]}" "${indexer_url}/_cluster/health" >/dev/null || fail regression 'indexer API에 admin 인증서로 접근하지 못했다.'
for policy in wazuh-01-d30 wazuh-01-a90; do
  "${indexer_curl[@]}" "${indexer_url}/_plugins/_ism/policies/${policy}" >/dev/null \
    || fail regression "ISM 정책 ${policy}이 사라졌다."
done
d30_delete_days=$("${indexer_curl[@]}" "${indexer_url}/_plugins/_ism/policies/wazuh-01-d30" \
  | jq -r '.policy.states[] | select(.name=="delete_after_30d" or (.transitions[]?.conditions.min_index_age=="30d")) | .name' | head -1)
[[ -n ${d30_delete_days} ]] || fail regression 'wazuh-01-d30 정책에서 30일 삭제 state를 찾지 못했다.'
echo 'Regression=PASS active-response-disabled ism-policies-unchanged'

wait_for_route_tls() {
  local attempt ready=false
  for ((attempt = 1; attempt <= 36; attempt++)); do
    if curl --silent --show-error --fail \
      --resolve "wazuh.imcherry5778.xyz:443:${connect_ip}" \
      "https://wazuh.imcherry5778.xyz/.well-known/pomerium" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 5
  done
  [[ ${ready} == true ]] || fail route-tls 'wazuh.imcherry5778.xyz 강제 TLS가 180초 안에 준비되지 않았다.'
  echo 'RouteTLS=PASS wazuh'
}
wait_for_route_tls

: "${WAZUH02_DENY_USERNAME:?platform-privileged 미소속 계정 이름이 필요하다}"
: "${WAZUH02_DENY_PASSWORD_FILE:?platform-privileged 미소속 계정 password file이 필요하다}"
: "${WAZUH02_DENY_TOTP_FILE:?platform-privileged 미소속 계정 TOTP file이 필요하다}"
python3 "${repo_root}/gitops/tools/wazuh-02/verify-routes.py" \
  --repo-root "${repo_root}" \
  --connect-ip "${connect_ip}" \
  --privileged-username "${WAZUH02_PRIVILEGED_USERNAME:-imcherry-admin}" \
  --privileged-password-file "${KC01_PRIVILEGED_PASSWORD_FILE:-${secret_root}/keycloak/privileged-password}" \
  --privileged-totp-file "${KC01_PRIVILEGED_TOTP_FILE:-${secret_root}/keycloak/privileged-totp}" \
  --deny-username "${WAZUH02_DENY_USERNAME}" \
  --deny-password-file "${WAZUH02_DENY_PASSWORD_FILE}" \
  --deny-totp-file "${WAZUH02_DENY_TOTP_FILE}" \
  --dashboard-password-file "${wazuh_secret_dir}/indexer-admin-password"

post_capacity=$(measure_capacity)
post_available_bytes=$(capacity_field "${post_capacity}" AVAILABLE_BYTES)
post_swap_used_bytes=$(capacity_field "${post_capacity}" SWAP_USED_BYTES)
post_pvc_request_bytes=$(capacity_field "${post_capacity}" PVC_REQUEST_BYTES)
(( post_available_bytes >= available_stop_bytes )) || fail capacity 'POST k3s available RAM이 8 GiB 정지선 아래다.'
(( post_swap_used_bytes == 0 )) || fail capacity 'POST k3s swap 사용량이 0이 아니다.'
(( post_pvc_request_bytes == pre_pvc_request_bytes )) || fail capacity 'WAZUH-02 뒤 신규 PVC 선언이 생겼다.'
if (( post_available_bytes >= soar01_entry_bytes )); then
  soar01_note="SOAR01_ENTRY=MET margin_bytes=$((post_available_bytes - soar01_entry_bytes))"
else
  soar01_note="SOAR01_ENTRY=NOT_MET shortfall_bytes=$((soar01_entry_bytes - post_available_bytes)) note=k3s-01_32GiB_expansion_is_SOAR-01_prerequisite"
fi
printf 'Capacity=PASS PRE_AVAILABLE_BYTES=%s POST_AVAILABLE_BYTES=%s PRE_PVC_REQUEST_BYTES=%s POST_PVC_REQUEST_BYTES=%s\n' \
  "${pre_available_bytes}" "${post_available_bytes}" "${pre_pvc_request_bytes}" "${post_pvc_request_bytes}"
echo "${soar01_note}"
echo 'WAZUH02_VERIFY=PASS'
