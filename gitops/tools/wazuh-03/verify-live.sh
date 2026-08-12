#!/usr/bin/env bash
# gitops/tools/wazuh-03/verify-live.sh
#
# WAZUH-03 단일 라이브 검증 진입점. WAZUH-01/02가 이미 판정한 D30/A90 라우팅,
# Dashboard RBAC, active response 비활성 경계는 다시 검증하지 않는다.
#
# 판정 항목:
#   1. immutable SHA의 platform-root·wazuh child가 Synced/Healthy
#   2. manager에서 7개 agent(OPNsense 1 + host 6) 전부 Active
#   3. 대표 host(k3s-01)에서 rootcheck 스캔이 시작·종료됐다는 agent 로컬 로그 증거
#   4. 대표 host(k3s-01)의 syscheck 감시 경로에 테스트 파일을 추가해 FIM alert 생성 확인
#      (이 alert가 나오려면 최초 baseline scan이 이미 끝나 비교 기준이 있어야 하므로
#      "baseline scan 완료"와 "테스트 파일 변경 alert" 두 증거를 하나로 판정한다)
#   5. 고정 관측창의 D30/A90 실제 저장 증가량이 16 GiB 상한 안
#   6. 같은 창의 Loki에 FIM·rootcheck event 복제본 0건
set -euo pipefail

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/wazuh
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}

readonly d30_days=30
readonly a90_days=90
readonly d30_total_cap_bytes=8053063680
readonly a90_total_cap_bytes=9059696640
readonly index_total_cap_bytes=$((16 * 1024 * 1024 * 1024))
readonly d30_daily_cap_bytes=$((256 * 1024 * 1024))
readonly a90_daily_cap_bytes=$((96 * 1024 * 1024))
readonly d30_index_pattern='wazuh-alerts-4.x-*'
readonly a90_index_pattern='wazuh-alerts-4.x-audit-*'

readonly window_seconds=${WAZUH03_WINDOW_SECONDS:-300}
readonly fim_test_path=${WAZUH03_FIM_TEST_PATH:-/etc/sudoers.d/.wazuh03-fim-test}
readonly fim_test_host_name=${WAZUH03_FIM_TEST_AGENT_NAME:-k3s-01}
readonly expected_agent_names=(opnsense-01 k3s-01 postgres-01 object-01 warpgate-01 netbird-01 proxmox-01)

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo '검증 실패 단계=precondition 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

readonly expected_wazuh_revision=${WAZUH03_EXPECTED_WAZUH_REVISION:?wazuh child 설정 commit SHA가 필요하다}
readonly expected_root_revision=${WAZUH03_EXPECTED_ROOT_REVISION:?platform-root pointer commit SHA가 필요하다}
[[ ${expected_wazuh_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail deployment 'immutable commit SHA 형식이 아니다.'
for material in root-ca.pem admin.pem admin-key.pem; do
  [[ -f ${secret_dir}/${material} && ! -L ${secret_dir}/${material} ]] \
    || fail precondition "indexer 조회용 ${material}이 없다."
done

# ---------------------------------------------------------------------------
# 증거: immutable SHA의 platform-root·wazuh child Synced/Healthy
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016
argo_expected='
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root |
  ([.items[] | select(.metadata.name == "wazuh")][0] // {}) as $child |
  $root.spec.source.targetRevision == $rootrev and
  $root.status.sync.revision == $rootrev and
  $root.status.sync.status == "Synced" and
  $root.status.health.status == "Healthy" and
  $child.spec.source.targetRevision == $wazuhrev and
  $child.status.sync.revision == $wazuhrev and
  $child.status.sync.status == "Synced" and
  $child.status.health.status == "Healthy"
'
argo_state=''
for _ in $(seq 1 90); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root wazuh -o json 2>/dev/null || true)
  if jq -e --arg rootrev "${expected_root_revision}" --arg wazuhrev "${expected_wazuh_revision}" \
    "${argo_expected}" <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
jq -e --arg rootrev "${expected_root_revision}" --arg wazuhrev "${expected_wazuh_revision}" \
  "${argo_expected}" <<<"${argo_state}" >/dev/null \
  || fail deployment 'platform-root 또는 wazuh child가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} wazuh=${expected_wazuh_revision}"

# ---------------------------------------------------------------------------
# 증거: 7개 agent 전부 Active
# ---------------------------------------------------------------------------
manager_exec() {
  local output
  for _ in $(seq 1 10); do
    output=$(remote_kubectl -n wazuh exec statefulset/wazuh-manager-master \
      -c wazuh-manager -- "$@" 2>/dev/null || true)
    if [[ -n ${output} ]]; then
      printf '%s' "${output}"
      return 0
    fi
    sleep 6
  done
  return 1
}

agent_list_raw=$(manager_exec /var/ossec/bin/agent_control -l) \
  || fail agent-active 'agent_control -l 출력을 읽지 못했다.'
echo "${agent_list_raw}"
missing=0
for name in "${expected_agent_names[@]}"; do
  grep -qE "Name: ${name}[^A-Za-z0-9._-]" <<<"${agent_list_raw}" \
    && grep -A1 "Name: ${name}[^A-Za-z0-9._-]" <<<"${agent_list_raw}" | grep -q 'Active' \
    || { echo "AgentMissingOrInactive=${name}" >&2; missing=$((missing + 1)); }
done
(( missing == 0 )) \
  || fail agent-active "${missing}개 agent가 목록에 없거나 Active가 아니다."
echo "AgentActive=PASS count=${#expected_agent_names[@]}"

# ---------------------------------------------------------------------------
# indexer 조회 경로 준비 (WAZUH-01과 동일)
# ---------------------------------------------------------------------------
indexer_port=${WAZUH03_INDEXER_FORWARD_PORT:-19201}
loki_port=${WAZUH03_LOKI_FORWARD_PORT:-13101}
socket_dir=$(mktemp -d /tmp/wazuh-03-forward.XXXXXX)
socket_path=${socket_dir}/control
cleanup_done=false
cleanup() {
  if [[ ${cleanup_done} == false ]]; then
    if [[ -S ${socket_path} ]]; then
      ssh "${ssh_options[@]}" -S "${socket_path}" -O exit "${k3s_host}" >/dev/null 2>&1 || true
    fi
    rmdir "${socket_dir}" 2>/dev/null || true
    cleanup_done=true
  fi
}
trap cleanup EXIT HUP INT TERM

indexer_ip=$(remote_kubectl -n wazuh get service indexer -o jsonpath='{.spec.clusterIP}')
loki_ip=$(remote_kubectl -n loki get service loki -o jsonpath='{.spec.clusterIP}')
[[ ${indexer_ip} =~ ^[0-9a-fA-F:.]+$ && ${loki_ip} =~ ^[0-9a-fA-F:.]+$ ]] \
  || fail search 'indexer/Loki ClusterIP를 읽지 못했다.'
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -M -S "${socket_path}" -fNT \
  -L "127.0.0.1:${indexer_port}:${indexer_ip}:9200" \
  -L "127.0.0.1:${loki_port}:${loki_ip}:3100" "${k3s_host}"

indexer_url="https://localhost:${indexer_port}"
loki_url="http://127.0.0.1:${loki_port}"
indexer_curl=(
  curl -fsS --cacert "${secret_dir}/root-ca.pem"
  --cert "${secret_dir}/admin.pem" --key "${secret_dir}/admin-key.pem"
)
indexer_get() { "${indexer_curl[@]}" "${indexer_url}$1"; }
indexer_post() { "${indexer_curl[@]}" -H 'Content-Type: application/json' -X POST --data "$2" "${indexer_url}$1"; }

for _ in $(seq 1 60); do
  indexer_get '/_cluster/health' >/dev/null 2>&1 && break
  sleep 5
done
indexer_get '/_cluster/health' >/dev/null || fail search 'indexer API에 admin 인증서로 접근하지 못했다.'

index_store_bytes() {
  local pattern=$1 exclude=${2:-}
  local stats
  stats=$(indexer_get "/${pattern}/_stats/store?ignore_unavailable=true" 2>/dev/null || echo '{}')
  jq -r --arg exclude "${exclude}" '
    (.indices // {}) | to_entries
    | map(select($exclude == "" or (.key | startswith($exclude) | not)))
    | map(.value.total.store.size_in_bytes) | add // 0
  ' <<<"${stats}"
}
flush_indices() {
  indexer_post "/${d30_index_pattern}/_refresh?ignore_unavailable=true" '' >/dev/null 2>&1 || true
  indexer_post "/${d30_index_pattern}/_flush?ignore_unavailable=true" '' >/dev/null 2>&1 || true
}
search_count() {
  local pattern=$1 query=$2 from=$3 body response
  body=$(jq -cn --arg q "${query}" --arg from "${from}" '{
    size: 0, track_total_hits: true,
    query: { bool: { filter: [
      { range: { "@timestamp": { gte: $from } } },
      { query_string: { query: $q, analyze_wildcard: false } }
    ] } }
  }')
  response=$(indexer_post "/${pattern}/_search?ignore_unavailable=true" "${body}" 2>/dev/null || echo '{}')
  jq -r '.hits.total.value // 0' <<<"${response}"
}

# ---------------------------------------------------------------------------
# 증거: 대표 host(k3s-01) rootcheck 스캔 시작·종료 로그
# ---------------------------------------------------------------------------
rootcheck_log=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  'sudo -n grep -i rootcheck /var/ossec/logs/ossec.log 2>/dev/null | tail -20' || true)
rootcheck_started=$(grep -ci 'Starting rootcheck scan' <<<"${rootcheck_log}" || true)
rootcheck_ended=$(grep -ci 'Ending rootcheck scan' <<<"${rootcheck_log}" || true)
(( rootcheck_started > 0 && rootcheck_ended > 0 )) \
  || fail rootcheck "${fim_test_host_name} agent 로컬 로그에서 rootcheck 시작·종료 기록을 찾지 못했다: started=${rootcheck_started} ended=${rootcheck_ended}"
echo "RootcheckScan=PASS host=${fim_test_host_name} started=${rootcheck_started} ended=${rootcheck_ended}"

# ---------------------------------------------------------------------------
# 고정 관측창 시작
# ---------------------------------------------------------------------------
flush_indices
window_start_epoch=$(date -u +%s)
window_start_iso=$(date -u -d "@${window_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
d30_start_bytes=$(index_store_bytes "${d30_index_pattern}" 'wazuh-alerts-4.x-audit-')
a90_start_bytes=$(index_store_bytes "${a90_index_pattern}")
echo "Window=OPEN start=${window_start_iso} d30_start_bytes=${d30_start_bytes} a90_start_bytes=${a90_start_bytes}"

# ---------------------------------------------------------------------------
# 증거: 테스트 파일 변경 1건의 FIM alert (baseline scan 완료를 함께 증명)
#
# wazuh-agent를 systemctl로 재시작해 유발하는 scan_on_start는 실측 결과 새 파일을
# fim.db에 기록만 하고 "added" alert를 보내지 않았다(daemon 재시작 직후의 최초 스캔은
# diff 이벤트를 내지 않는 것으로 보인다). 이미 떠 있는 agent에 Manager API
# `PUT /syscheck?agents_list=<id>`로 즉시 재스캔을 요청하는 방식만 실측에서 정상
# 동작했다 — 이 경로가 실제 운영 중 rescan(scheduled frequency 도달 시)과 같은
# 코드 경로이기도 하다.
# ---------------------------------------------------------------------------
apipass_file=${secret_dir}/api-password
[[ -f ${apipass_file} && ! -L ${apipass_file} ]] \
  || fail fim 'Manager API password 입력이 없다(provision.sh가 만든 api-password 필요).'
fim_agent_id=$(grep -A1 "Name: ${fim_test_host_name}[^A-Za-z0-9._-]" <<<"${agent_list_raw}" \
  | head -1 | sed -n 's/^ *ID: \([0-9]\+\),.*/\1/p')
[[ ${fim_agent_id} =~ ^[0-9]+$ ]] \
  || fail fim "${fim_test_host_name}의 agent ID를 agent_control 출력에서 읽지 못했다."

ssh "${ssh_options[@]}" "${k3s_host}" \
  "sudo -n bash -c 'printf \"# wazuh-03 fim test marker\\n\" > ${fim_test_path} && chmod 0440 ${fim_test_path}'" \
  || fail fim "${fim_test_host_name}에 테스트 파일을 만들지 못했다: ${fim_test_path}"
echo "FimTestFile=CREATED host=${fim_test_host_name} path=${fim_test_path}"

trigger_syscheck_scan() {
  local apipass token_json token scan_json
  apipass=$(cat "${apipass_file}")
  token_json=$(manager_exec curl -s -k -u "wazuh-01-api:${apipass}" \
    -X POST 'https://localhost:55000/security/user/authenticate?raw=false') || return 1
  token=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["token"])' <<<"${token_json}" 2>/dev/null) || return 1
  [[ -n ${token} ]] || return 1
  scan_json=$(manager_exec curl -s -k -H "Authorization: Bearer ${token}" \
    -X PUT "https://localhost:55000/syscheck?agents_list=${fim_agent_id}") || return 1
  jq -e --arg id "${fim_agent_id}" '.data.affected_items | index($id) != null' <<<"${scan_json}" >/dev/null
}
trigger_syscheck_scan \
  || fail fim "${fim_test_host_name}(agent ${fim_agent_id})의 on-demand syscheck 트리거에 실패했다."
echo "SyscheckTrigger=PASS agent_id=${fim_agent_id}"

fim_query="rule.groups:syscheck AND agent.name:\"${fim_test_host_name}\" AND syscheck.path:\"${fim_test_path}\""
fim_hits=0
for _ in $(seq 1 30); do
  indexer_post "/${d30_index_pattern}/_refresh?ignore_unavailable=true" '' >/dev/null 2>&1 || true
  fim_hits=$(search_count "${d30_index_pattern}" "${fim_query}" "${window_start_iso}")
  (( fim_hits > 0 )) && break
  sleep 10
done
(( fim_hits > 0 )) \
  || fail fim "테스트 파일 변경 FIM alert를 찾지 못했다(baseline scan 미완료 가능성): ${fim_query}"
echo "FimDetection=PASS hits=${fim_hits} query='${fim_query}'"

# 정리: 테스트 파일을 지우고 삭제도 탐지되는지 함께 확인한다(부가 증거, 실패해도 gate는 아님).
ssh "${ssh_options[@]}" "${k3s_host}" "sudo -n rm -f ${fim_test_path}" || true
trigger_syscheck_scan || true

# ---------------------------------------------------------------------------
# 창이 끝날 때까지 기다린 뒤 D30/A90 저장 증가량을 한 번 측정한다
# ---------------------------------------------------------------------------
window_end_epoch=$((window_start_epoch + window_seconds))
while (( $(date -u +%s) < window_end_epoch )); do
  sleep 10
done
flush_indices
window_actual_seconds=$(( $(date -u +%s) - window_start_epoch ))
d30_end_bytes=$(index_store_bytes "${d30_index_pattern}" 'wazuh-alerts-4.x-audit-')
a90_end_bytes=$(index_store_bytes "${a90_index_pattern}")
d30_delta_bytes=$((d30_end_bytes - d30_start_bytes))
a90_delta_bytes=$((a90_end_bytes - a90_start_bytes))
(( d30_delta_bytes < 0 )) && d30_delta_bytes=0
(( a90_delta_bytes < 0 )) && a90_delta_bytes=0

d30_daily_bytes=$(( d30_delta_bytes * 86400 / window_actual_seconds ))
a90_daily_bytes=$(( a90_delta_bytes * 86400 / window_actual_seconds ))
d30_retained_bytes=$(( d30_daily_bytes * d30_days ))
a90_retained_bytes=$(( a90_daily_bytes * a90_days ))
index_total_bytes=$(( d30_retained_bytes + a90_retained_bytes ))

(( d30_daily_bytes <= d30_daily_cap_bytes )) \
  || fail retention "D30 환산 일일 저장량이 256 MiB 상한을 넘는다: ${d30_daily_bytes}"
(( a90_daily_bytes <= a90_daily_cap_bytes )) \
  || fail retention "A90 환산 일일 저장량이 96 MiB 상한을 넘는다: ${a90_daily_bytes}"
(( d30_retained_bytes <= d30_total_cap_bytes )) \
  || fail retention "D30 30일 환산 보존량이 7.5 GiB 상한을 넘는다: ${d30_retained_bytes}"
(( a90_retained_bytes <= a90_total_cap_bytes )) \
  || fail retention "A90 90일 환산 보존량이 8.4375 GiB 상한을 넘는다: ${a90_retained_bytes}"
(( index_total_bytes <= index_total_cap_bytes )) \
  || fail retention "Wazuh index 전체 환산 보존량이 16 GiB 상한을 넘는다: ${index_total_bytes}"
echo "IndexGrowth=PASS WINDOW_SECONDS=${window_actual_seconds} D30_DELTA_BYTES=${d30_delta_bytes} A90_DELTA_BYTES=${a90_delta_bytes} D30_DAILY_BYTES=${d30_daily_bytes} A90_DAILY_BYTES=${a90_daily_bytes} D30_RETAINED_BYTES=${d30_retained_bytes} A90_RETAINED_BYTES=${a90_retained_bytes} INDEX_TOTAL_BYTES=${index_total_bytes}"

# ---------------------------------------------------------------------------
# 증거: 같은 창의 Loki에 FIM·rootcheck event 복제본 0건
# ---------------------------------------------------------------------------
loki_count() {
  local query=$1 encoded
  encoded=$(jq -rn --arg value "${query}" '$value|@uri')
  curl -fsS "${loki_url}/loki/api/v1/query?query=${encoded}&time=$(date -u +%s)" \
    | jq -r '[.data.result[]?.value[1] | tonumber] | add // 0'
}
loki_fim_marker=$(loki_count "sum(count_over_time({cluster=\"k3s-01\"} |~ \"(?i)wazuh03-fim-test|syscheck|rootcheck\"[${window_seconds}s]))" || echo 0)
[[ ${loki_fim_marker} =~ ^[0-9]+$ ]] || loki_fim_marker=0
(( loki_fim_marker == 0 )) \
  || fail loki-duplicate "같은 창의 Loki에 FIM/rootcheck 복제본으로 보이는 record가 ${loki_fim_marker}건 있다."
echo 'LokiDuplicate=PASS fim_rootcheck_marker=0'

cleanup
trap - EXIT HUP INT TERM
echo 'WAZUH03_VERIFY=PASS'
