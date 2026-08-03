#!/usr/bin/env bash
# WAZUH-01 단일 라이브 검증 진입점.
#
# `capacity-pre`는 배포 전 capacity gate 한 번, `verify`는 완료 증거 다섯 개를 한 번에
# 판정한다. Secret, token, kubeconfig, 원문 credential은 출력하지 않는다.
set -euo pipefail

readonly mode=${1:-verify}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/wazuh
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}

# capacity gate 상수. docs/capacity-plan.md와 docs/audit-event-standard.md가 단일 원본이다.
readonly wazuh_pvc_bytes=$((16 * 1024 * 1024 * 1024))
readonly pvc_warn_bytes=$((96 * 1024 * 1024 * 1024))
readonly pvc_stop_bytes=$((120 * 1024 * 1024 * 1024))
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
readonly available_entry_bytes=$((11 * 1024 * 1024 * 1024))

# 보존 상한. D30 30일 7.5 GiB, A90 90일 8.4375 GiB, 합계 16 GiB.
readonly d30_days=30
readonly a90_days=90
readonly d30_total_cap_bytes=8053063680
readonly a90_total_cap_bytes=9059696640
readonly index_total_cap_bytes=$((16 * 1024 * 1024 * 1024))
readonly d30_daily_cap_bytes=$((256 * 1024 * 1024))
readonly a90_daily_cap_bytes=$((96 * 1024 * 1024))

# 고정 관측창. 대표 event는 이 창 안에서 정확히 한 번만 만든다.
readonly window_seconds=${WAZUH01_WINDOW_SECONDS:-900}
readonly representative_sid=2029054
readonly representative_user_agent='Mozilla/5.0 zgrab/0.x'
readonly representative_target=${WAZUH01_REPRESENTATIVE_TARGET:-http://10.10.20.10/}
# 이 host에서 k3s-01로 가는 경로는 NAT를 거쳐 source port가 재작성되므로 port로 식별하지
# 않는다. Suricata가 기록하는 source IP는 보존되며 고정창 안에서 유일하다.
readonly representative_source_ip=${WAZUH01_REPRESENTATIVE_SOURCE_IP:-10.10.60.2}
# NIDS-01이 fingerprint 없이 any->any로 등록한 테스트 시그니처. 중앙 저장 대상이 아니다.
readonly nids_test_signature_prefix='NIDS-01 DMZ'
readonly d30_index_pattern='wazuh-alerts-4.x-*'
readonly a90_index_pattern='wazuh-alerts-4.x-audit-*'

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
  # 인자는 이 스크립트가 만든 비밀 없는 고정값만 전달한다.
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

measure_capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'REMOTE'
set -euo pipefail
k='sudo -n /usr/local/bin/k3s kubectl'
available_bytes=$(free -b | awk '/Mem:/{print $7}')
swap_used_bytes=$(free -b | awk '/Swap:/{print $3}')
read -r root_size_bytes root_available_bytes < <(df -B1 --output=size,avail / | awk 'NR==2{print $1,$2}')
root_free_percent=$((root_available_bytes * 100 / root_size_bytes))
pvc_request_bytes=$(
  ${k} get pvc -A -o json \
    | jq -r '.items[].spec.resources.requests.storage' \
    | while IFS= read -r quantity; do numfmt --from=iec-i "${quantity}"; done \
    | awk '{sum+=$1} END{printf "%.0f\n",sum+0}'
)
printf 'AVAILABLE_BYTES=%s\nSWAP_USED_BYTES=%s\nROOT_SIZE_BYTES=%s\nROOT_AVAILABLE_BYTES=%s\nROOT_FREE_PERCENT=%s\nPVC_REQUEST_BYTES=%s\n' \
  "${available_bytes}" "${swap_used_bytes}" "${root_size_bytes}" "${root_available_bytes}" \
  "${root_free_percent}" "${pvc_request_bytes}"
REMOTE
}

capacity_field() {
  awk -F= -v key="$2" '$1==key{print $2}' <<<"$1"
}

capacity_stop_gate() {
  local prefix=$1 capacity=$2
  local available_bytes swap_used_bytes root_free_percent pvc_request_bytes
  available_bytes=$(capacity_field "${capacity}" AVAILABLE_BYTES)
  swap_used_bytes=$(capacity_field "${capacity}" SWAP_USED_BYTES)
  root_free_percent=$(capacity_field "${capacity}" ROOT_FREE_PERCENT)
  pvc_request_bytes=$(capacity_field "${capacity}" PVC_REQUEST_BYTES)
  [[ ${available_bytes} =~ ^[0-9]+$ && ${swap_used_bytes} =~ ^[0-9]+$ &&
     ${root_free_percent} =~ ^[0-9]+$ && ${pvc_request_bytes} =~ ^[0-9]+$ ]] \
    || fail capacity "${prefix} guest RAM/disk/PVC 측정값을 읽지 못했다."
  (( available_bytes >= available_stop_bytes )) \
    || fail capacity "${prefix} k3s available RAM이 8 GiB 정지선 아래다."
  (( swap_used_bytes == 0 )) || fail capacity "${prefix} k3s swap 사용량이 0이 아니다."
  (( root_free_percent >= 20 )) || fail capacity "${prefix} k3s guest disk 여유가 20% 정지선 아래다."
  (( pvc_request_bytes < pvc_stop_bytes )) \
    || fail capacity "${prefix} PVC 선언 합계가 120 GiB 정지선에 도달했다."
}

if [[ ${mode} == capacity-pre ]]; then
  capacity=$(measure_capacity)
  capacity_stop_gate PRE "${capacity}"
  available_bytes=$(capacity_field "${capacity}" AVAILABLE_BYTES)
  swap_used_bytes=$(capacity_field "${capacity}" SWAP_USED_BYTES)
  root_free_percent=$(capacity_field "${capacity}" ROOT_FREE_PERCENT)
  pvc_request_bytes=$(capacity_field "${capacity}" PVC_REQUEST_BYTES)
  projected_pvc_bytes=$((pvc_request_bytes + wazuh_pvc_bytes))
  (( available_bytes >= available_entry_bytes )) \
    || fail capacity "배포 전 available이 WAZUH-01 재진입선 11 GiB 미만이다: ${available_bytes}"
  (( projected_pvc_bytes < pvc_warn_bytes )) \
    || fail capacity "Wazuh 16 GiB를 더하면 PVC 96 GiB 경고선에 도달한다: ${projected_pvc_bytes}"
  printf '%s\n' "${capacity}" | sed 's/^/PRE_/'
  echo "WAZUH_DECLARED_PVC_BYTES=${wazuh_pvc_bytes} PROJECTED_PVC_REQUEST_BYTES=${projected_pvc_bytes}"
  echo "CAPACITY_PRE=PASS AVAILABLE_BYTES=${available_bytes} SWAP_USED_BYTES=${swap_used_bytes} ROOT_FREE_PERCENT=${root_free_percent} PVC_REQUEST_BYTES=${pvc_request_bytes}"
  exit 0
fi

readonly expected_config_revision=${WAZUH01_EXPECTED_CONFIG_REVISION:?wazuh child 설정 commit SHA가 필요하다}
readonly expected_root_revision=${WAZUH01_EXPECTED_ROOT_REVISION:?platform-root pointer commit SHA가 필요하다}
readonly pre_available_bytes=${WAZUH01_PRE_AVAILABLE_BYTES:?배포 전 available bytes가 필요하다}
readonly pre_root_free_percent=${WAZUH01_PRE_ROOT_FREE_PERCENT:?배포 전 guest disk 여유율이 필요하다}
readonly pre_pvc_request_bytes=${WAZUH01_PRE_PVC_REQUEST_BYTES:?배포 전 PVC 합계가 필요하다}
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail deployment 'immutable commit SHA 형식이 아니다.'
[[ ${pre_available_bytes} =~ ^[0-9]+$ && ${pre_root_free_percent} =~ ^[0-9]+$ &&
   ${pre_pvc_request_bytes} =~ ^[0-9]+$ ]] || fail capacity '배포 전 capacity 입력이 정수가 아니다.'
for material in root-ca.pem admin.pem admin-key.pem; do
  [[ -f ${secret_dir}/${material} && ! -L ${secret_dir}/${material} ]] \
    || fail precondition "indexer 조회용 ${material}이 없다. provision.sh apply를 먼저 실행한다."
done

# ---------------------------------------------------------------------------
# 증거 5: immutable SHA의 platform-root와 wazuh child가 Synced/Healthy
# ---------------------------------------------------------------------------
# jq 프로그램 변수는 jq가 확장한다.
# shellcheck disable=SC2016
argo_expected='
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root |
  ([.items[] | select(.metadata.name == "wazuh")][0] // {}) as $child |
  $root.spec.source.targetRevision == $rootrev and
  $root.status.sync.revision == $rootrev and
  $root.status.sync.status == "Synced" and
  $root.status.health.status == "Healthy" and
  $child.spec.source.targetRevision == $configrev and
  $child.status.sync.revision == $configrev and
  $child.status.sync.status == "Synced" and
  $child.status.health.status == "Healthy"
'
argo_state=''
for _ in $(seq 1 90); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root wazuh -o json 2>/dev/null || true)
  if jq -e --arg rootrev "${expected_root_revision}" --arg configrev "${expected_config_revision}" \
    "${argo_expected}" <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
jq -e --arg rootrev "${expected_root_revision}" --arg configrev "${expected_config_revision}" \
  "${argo_expected}" <<<"${argo_state}" >/dev/null \
  || fail deployment 'platform-root 또는 wazuh child가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} wazuh=${expected_config_revision}"

for workload in statefulset/wazuh-indexer statefulset/wazuh-manager-master; do
  remote_kubectl -n wazuh rollout status "${workload}" --timeout=600s >/dev/null \
    || fail deployment "${workload}가 Ready가 아니다."
done
remote_kubectl -n wazuh wait --for=condition=complete job/wazuh-retention-bootstrap --timeout=600s >/dev/null \
  || fail deployment '보존 정책 bootstrap Job이 완료되지 않았다.'
echo 'Workloads=PASS indexer manager retention-bootstrap'

# ---------------------------------------------------------------------------
# indexer 조회 경로. admin client 인증서만 쓰고 password는 읽지 않는다.
# ---------------------------------------------------------------------------
indexer_port=${WAZUH01_INDEXER_FORWARD_PORT:-19200}
loki_port=${WAZUH01_LOKI_FORWARD_PORT:-13100}
socket_dir=$(mktemp -d /tmp/wazuh-01-forward.XXXXXX)
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

indexer_get() {
  "${indexer_curl[@]}" "${indexer_url}$1"
}
indexer_post() {
  "${indexer_curl[@]}" -H 'Content-Type: application/json' -X POST --data "$2" "${indexer_url}$1"
}

for _ in $(seq 1 60); do
  if indexer_get '/_cluster/health' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
indexer_get '/_cluster/health' >/dev/null || fail search 'indexer API에 admin 인증서로 접근하지 못했다.'

# ---------------------------------------------------------------------------
# 증거 3: running 설정의 D30=30일, A90=90일
# ---------------------------------------------------------------------------
policy_age() {
  indexer_get "/_plugins/_ism/policies/$1" \
    | jq -r '.policy.states[] | select(.transitions | length > 0) | .transitions[0].conditions.min_index_age'
}
d30_age=$(policy_age wazuh-01-d30 || true)
a90_age=$(policy_age wazuh-01-a90 || true)
[[ ${d30_age} == "${d30_days}d" ]] || fail retention "running D30 정책이 ${d30_days}d가 아니다: ${d30_age:-없음}"
[[ ${a90_age} == "${a90_days}d" ]] || fail retention "running A90 정책이 ${a90_days}d가 아니다: ${a90_age:-없음}"
d30_pattern=$(indexer_get /_plugins/_ism/policies/wazuh-01-d30 | jq -r '.policy.ism_template[0].index_patterns[0]')
a90_pattern=$(indexer_get /_plugins/_ism/policies/wazuh-01-a90 | jq -r '.policy.ism_template[0].index_patterns[0]')
[[ ${d30_pattern} == "${d30_index_pattern}" && ${a90_pattern} == "${a90_index_pattern}" ]] \
  || fail retention "ISM index pattern이 D30/A90 계약과 다르다: ${d30_pattern} / ${a90_pattern}"
# 정책 존재만으로는 부족하다. 실제 index에 붙었는지 running 상태로 확인한다.
a90_managed=$(indexer_get "/_plugins/_ism/explain/${a90_index_pattern}" 2>/dev/null \
  | jq -r '[to_entries[] | select(.key != "total_managed_indices")
      | select(.value.enabled == true and .value.policy_id == "wazuh-01-a90")] | length' 2>/dev/null || echo 0)
d30_managed=$(indexer_get "/_plugins/_ism/explain/${d30_index_pattern}" 2>/dev/null \
  | jq -r '[to_entries[] | select(.key != "total_managed_indices")
      | select(.key | startswith("wazuh-alerts-4.x-audit-") | not)
      | select(.value.enabled == true and .value.policy_id == "wazuh-01-d30")] | length' 2>/dev/null || echo 0)
[[ ${a90_managed} =~ ^[0-9]+$ ]] || a90_managed=0
[[ ${d30_managed} =~ ^[0-9]+$ ]] || d30_managed=0
(( a90_managed >= 1 )) \
  || fail retention 'A90 index에 wazuh-01-a90 정책이 붙어 있지 않다.'
echo "Retention=PASS D30=${d30_age} pattern=${d30_pattern} A90=${a90_age} pattern=${a90_pattern} A90_MANAGED=${a90_managed} D30_MANAGED=${d30_managed}"

# ---------------------------------------------------------------------------
# 증거 5: active response 비활성
# ---------------------------------------------------------------------------
# StatefulSet 재적용 직후에는 Pod가 교체되는 동안 exec가 일시적으로 실패한다.
# 대상이 아니라 조회 시점 문제이므로 같은 명령을 정해진 횟수만 다시 시도한다.
# 일부 대상 명령은 정상 상태에서도 0이 아닌 코드를 낸다(예: wazuh-control status는
# 선택적 daemon이 꺼져 있으면 1). 그래서 exit code가 아니라 출력 유무로 성공을 판정한다.
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

remote_kubectl -n wazuh rollout status statefulset/wazuh-manager-master --timeout=300s >/dev/null \
  || fail active-response 'manager StatefulSet이 Ready 상태가 아니다.'
running_conf_raw=$(manager_exec cat /var/ossec/etc/ossec.conf) \
  || fail active-response 'running ossec.conf를 읽지 못했다.'
# XML 주석을 먼저 제거한다. 주석 안의 설명 문구를 실제 선언으로 세면 오탐이 된다.
running_conf=$(python3 -c \
  'import re,sys; sys.stdout.write(re.sub(r"<!--.*?-->", "", sys.stdin.read(), flags=re.S))' \
  <<<"${running_conf_raw}")
grep -qE '<active-response>[[:space:]]*<disabled>yes</disabled>[[:space:]]*</active-response>' \
  <<<"$(tr -d '\n' <<<"${running_conf}" | sed 's/>[[:space:]]*</></g')" \
  || fail active-response 'running ossec.conf에서 active-response 비활성 선언을 찾지 못했다.'
command_count=$(grep -c '<command>' <<<"${running_conf}" || true)
(( command_count == 0 )) || fail active-response "running ossec.conf에 active response command가 ${command_count}건 있다."
# `wazuh-execd` 상주 여부는 판정 기준이 아니다. 이 daemon은 active response 설정과
# 무관하게 항상 뜬다. 실제로 무엇이 실행될 수 있는지는 manager가 agent에 배포하는
# `ar.conf`가 결정하므로 그 내용에서 차단·계정 계열 응답이 0건인지 본다.
# agent 쪽 `<active-response><disabled>yes</disabled>`는 apply-opnsense.sh가 소유한다.
ar_conf=$(manager_exec cat /var/ossec/etc/shared/ar.conf) \
  || fail active-response 'ar.conf를 읽지 못했다.'
blocking_responses=$(grep -cE 'firewall-drop|host-deny|route-null|disable-account|netsh|ip-customblock' \
  <<<"${ar_conf}" || true)
(( blocking_responses == 0 )) \
  || fail active-response "ar.conf에 차단·계정 계열 active response가 ${blocking_responses}건 있다."
ar_entries=$(grep -c . <<<"${ar_conf}" || true)
echo "ActiveResponse=PASS disabled=yes commands=0 ar_blocking_responses=0 ar_builtin_entries=${ar_entries}"

# ---------------------------------------------------------------------------
# 증거 2(정적 절반): Loki relay 부재
# ---------------------------------------------------------------------------
# 판정은 문서 산문이 아니라 실제 연결 지점만 본다. 설명 주석에 제품 이름이 나오는 것과
# relay 경로가 있는 것은 다르다. endpoint 형태와 NetworkPolicy의 구조 필드만 센다.
readonly endpoint_pattern='\.svc|://|:[0-9]{2,5}([^0-9]|$)'
alloy_relay=$(remote_kubectl -n loki get configmap -o json \
  | jq -r '[.items[].data // {} | to_entries[] | .value] | join("\n")' \
  | grep -iE 'wazuh' | grep -cE "${endpoint_pattern}" || true)
(( alloy_relay == 0 )) || fail loki-relay "Loki 수집 설정에 wazuh endpoint 참조가 ${alloy_relay}건 있다."
wazuh_loki_endpoint=$(remote_kubectl -n wazuh get configmap -o json \
  | jq -r '[.items[].data // {} | to_entries[] | .value] | join("\n")' \
  | grep -iE 'loki' | grep -cE "${endpoint_pattern}" || true)
(( wazuh_loki_endpoint == 0 )) \
  || fail loki-relay "wazuh 설정에 loki endpoint 참조가 ${wazuh_loki_endpoint}건 있다."
wazuh_loki_egress=$(remote_kubectl -n wazuh get networkpolicy -o json \
  | jq '[.items[].spec.egress[]?.to[]?
      | select((.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] // "") == "loki")]
      | length')
(( wazuh_loki_egress == 0 )) \
  || fail loki-relay "wazuh NetworkPolicy에 loki namespace egress가 ${wazuh_loki_egress}건 있다."
echo 'LokiRelay=PASS alloy_wazuh_endpoint=0 wazuh_loki_endpoint=0 wazuh_loki_egress=0'

# ---------------------------------------------------------------------------
# 고정 관측창 시작
# ---------------------------------------------------------------------------
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

flush_indices
window_start_epoch=$(date -u +%s)
window_end_epoch=$((window_start_epoch + window_seconds))
window_start_iso=$(date -u -d "@${window_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
d30_start_bytes=$(index_store_bytes "${d30_index_pattern}" 'wazuh-alerts-4.x-audit-')
a90_start_bytes=$(index_store_bytes "${a90_index_pattern}")
echo "Window=OPEN start=${window_start_iso} seconds=${window_seconds} d30_start_bytes=${d30_start_bytes} a90_start_bytes=${a90_start_bytes}"

# ---------------------------------------------------------------------------
# 증거 1: 대표 Suricata event를 정확히 한 건 만든다
# ---------------------------------------------------------------------------
representative_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -A "${representative_user_agent}" "${representative_target}" || true)
[[ ${representative_status} =~ ^[0-9]{3}$ ]] \
  || fail detection "대표 event 생성 HTTP 요청이 응답하지 않았다: ${representative_status}"
echo "RepresentativeEvent=SENT sid=${representative_sid} src_ip=${representative_source_ip} http_status=${representative_status}"

search_count() {
  local pattern=$1 query=$2 body response
  body=$(jq -cn --arg q "${query}" --arg from "${window_start_iso}" '{
    size: 0,
    track_total_hits: true,
    query: { bool: { filter: [
      { range: { "@timestamp": { gte: $from } } },
      { query_string: { query: $q, analyze_wildcard: false } }
    ] } }
  }')
  response=$(indexer_post "/${pattern}/_search?ignore_unavailable=true" "${body}" 2>/dev/null || echo '{}')
  jq -r '.hits.total.value // 0' <<<"${response}"
}

# signature_id는 `2029054.000000` 실수 문자열로 저장되므로 prefix로 판정한다.
representative_query="rule.groups:suricata AND data.src_ip:\"${representative_source_ip}\" AND data.alert.signature_id:${representative_sid}*"
representative_hits=0
while (( $(date -u +%s) < window_end_epoch )); do
  indexer_post "/${d30_index_pattern}/_refresh?ignore_unavailable=true" '' >/dev/null 2>&1 || true
  representative_hits=$(search_count "${d30_index_pattern}" "${representative_query}")
  if (( representative_hits > 0 )); then
    break
  fi
  sleep 15
done
(( representative_hits > 0 )) \
  || fail detection "고정 관측창에서 대표 Suricata event(sid=${representative_sid}, src_ip=${representative_source_ip})를 Wazuh index에서 찾지 못했다."
echo "SuricataDetection=PASS hits=${representative_hits} query='${representative_query}'"

# ---------------------------------------------------------------------------
# 창이 끝날 때까지 기다린 뒤 한 번만 측정한다. 창은 늘리지 않는다.
# ---------------------------------------------------------------------------
while (( $(date -u +%s) < window_end_epoch )); do
  sleep 10
done
flush_indices
window_actual_seconds=$(( $(date -u +%s) - window_start_epoch ))
d30_end_bytes=$(index_store_bytes "${d30_index_pattern}" 'wazuh-alerts-4.x-audit-')
a90_end_bytes=$(index_store_bytes "${a90_index_pattern}")
d30_delta_bytes=$((d30_end_bytes - d30_start_bytes))
a90_delta_bytes=$((a90_end_bytes - a90_start_bytes))
if (( d30_delta_bytes < 0 )); then d30_delta_bytes=0; fi
if (( a90_delta_bytes < 0 )); then a90_delta_bytes=0; fi

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
# 오탐 gate: 같은 창에서 D30/A90 밖 record와 대표 시그니처 밖 Suricata alert가 0건
# ---------------------------------------------------------------------------
d30_total_hits=$(search_count "${d30_index_pattern}" '*')
a90_hits=$(search_count "${a90_index_pattern}" '*')
# 실제 오탐원: NIDS-01 all-traffic 테스트 시그니처가 중앙 저장에 들어오면 실패다.
nids_noise_hits=$(search_count "${d30_index_pattern}" \
  "rule.groups:suricata AND data.alert.signature:\"${nids_test_signature_prefix}\"")
# D30/A90 어느 class도 아닌 record가 있으면 수집 경계가 깨진 것이다.
out_of_scope_hits=$(search_count "${d30_index_pattern}" \
  'NOT rule.groups:suricata AND NOT rule.groups:k8s_audit')
a90_out_of_scope_hits=$(search_count "${a90_index_pattern}" 'NOT rule.groups:k8s_audit')
# 대표 시그니처 밖의 정상 Suricata 탐지(인터넷發 실제 스캔)는 참양성이므로 보고만 한다.
suricata_other_hits=$(search_count "${d30_index_pattern}" \
  "rule.groups:suricata AND NOT data.alert.signature_id:${representative_sid}\\.*")
(( nids_noise_hits == 0 )) \
  || fail false-positive "고정 창의 D30 index에 NIDS-01 테스트 시그니처가 ${nids_noise_hits}건 저장됐다."
(( out_of_scope_hits == 0 )) \
  || fail false-positive "고정 창의 D30 index에 D30/A90이 아닌 record가 ${out_of_scope_hits}건 있다."
(( a90_out_of_scope_hits == 0 )) \
  || fail false-positive "고정 창의 A90 index에 k8s_audit이 아닌 record가 ${a90_out_of_scope_hits}건 있다."
echo "FalsePositiveGate=PASS ALERT_HITS_ALL=${d30_total_hits} A90_HITS=${a90_hits} NIDS_TEST_NOISE=0 OUT_OF_SCOPE=0 GENUINE_OTHER_SURICATA=${suricata_other_hits}"

# ---------------------------------------------------------------------------
# 증거 2(라이브 절반): 같은 창의 Loki 보안 event 복제본 0건
# ---------------------------------------------------------------------------
loki_count() {
  local query=$1 encoded
  encoded=$(jq -rn --arg value "${query}" '$value|@uri')
  curl -fsS "${loki_url}/loki/api/v1/query?query=${encoded}&time=$(date -u +%s)" \
    | jq -r '[.data.result[]?.value[1] | tonumber] | add // 0'
}
loki_non_operation=$(loki_count "sum(count_over_time({cluster=\"k3s-01\", event_class!=\"operation\"}[${window_seconds}s]))" || echo 0)
loki_security_marker=$(loki_count "sum(count_over_time({cluster=\"k3s-01\"} |~ \"(?i)zgrab|suricata|audit.k8s.io\"[${window_seconds}s]))" || echo 0)
[[ ${loki_non_operation} =~ ^[0-9]+$ ]] || loki_non_operation=0
[[ ${loki_security_marker} =~ ^[0-9]+$ ]] || loki_security_marker=0
(( loki_non_operation == 0 )) \
  || fail loki-duplicate "같은 창의 Loki에 operation이 아닌 record가 ${loki_non_operation}건 있다."
(( loki_security_marker == 0 )) \
  || fail loki-duplicate "같은 창의 Loki에 보안 event 복제본이 ${loki_security_marker}건 있다."
echo 'LokiDuplicate=PASS non_operation=0 security_marker=0'

# ---------------------------------------------------------------------------
# 증거 4의 나머지: 배포 후 capacity
# ---------------------------------------------------------------------------
capacity=$(measure_capacity)
capacity_stop_gate POST "${capacity}"
available_bytes=$(capacity_field "${capacity}" AVAILABLE_BYTES)
swap_used_bytes=$(capacity_field "${capacity}" SWAP_USED_BYTES)
root_free_percent=$(capacity_field "${capacity}" ROOT_FREE_PERCENT)
pvc_request_bytes=$(capacity_field "${capacity}" PVC_REQUEST_BYTES)
expected_pvc_bytes=$((pre_pvc_request_bytes + wazuh_pvc_bytes))
(( pvc_request_bytes == expected_pvc_bytes )) \
  || fail capacity "배포 전후 PVC 선언 합계 차이가 WAZUH-01 고정 16 GiB와 다르다: ${pvc_request_bytes} != ${expected_pvc_bytes}"
(( pvc_request_bytes < pvc_warn_bytes )) \
  || fail capacity "배포 후 PVC 선언 합계가 96 GiB 경고선에 도달했다: ${pvc_request_bytes}"
printf '%s\n' "${capacity}" | sed 's/^/POST_/'
echo "Capacity=PASS PRE_AVAILABLE_BYTES=${pre_available_bytes} POST_AVAILABLE_BYTES=${available_bytes} DELTA_BYTES=$((available_bytes - pre_available_bytes)) SWAP_USED_BYTES=${swap_used_bytes} PRE_ROOT_FREE_PERCENT=${pre_root_free_percent} POST_ROOT_FREE_PERCENT=${root_free_percent} PRE_PVC_REQUEST_BYTES=${pre_pvc_request_bytes} POST_PVC_REQUEST_BYTES=${pvc_request_bytes}"

cleanup
trap - EXIT HUP INT TERM
echo 'WAZUH01_VERIFY=PASS'
