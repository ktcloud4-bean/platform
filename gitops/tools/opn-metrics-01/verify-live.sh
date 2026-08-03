#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-opnsense.sh
source "${script_dir}/lib-opnsense.sh"

readonly expected_config_revision=${OPN_METRICS_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OPN_METRICS_EXPECTED_ROOT_REVISION:?platform-root pointer commit SHA가 필요하다}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly rule_description='OPN-METRICS-01: k3s-01 Prometheus에서 OPNsense node_exporter TCP 9100만 허용'
readonly observation_seconds=180
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  local stage=$1
  shift
  echo "검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail deployment 'immutable commit SHA 형식이 아니다.'
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] \
  || fail deployment '인증된 k3s known_hosts 파일이 없다.'

remote_kubectl() {
  # 인자는 이 스크립트가 만든 비밀 없는 고정값만 전달한다.
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg config "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $obs.spec.source.targetRevision == $config and
    $obs.status.sync.revision == $config and
    $obs.status.sync.status == "Synced" and
    $obs.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${expected_root_revision}" --arg config "${expected_config_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs |
  $root_app.spec.source.targetRevision == $root and
  $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $obs.spec.source.targetRevision == $config and
  $obs.status.sync.revision == $config and
  $obs.status.sync.status == "Synced" and
  $obs.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null \
  || fail deployment 'platform-root 또는 obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

prometheus_ip=$(remote_kubectl -n obs get service obs-prometheus -o jsonpath='{.spec.clusterIP}')
[[ ${prometheus_ip} =~ ^[0-9a-fA-F:.]+$ ]] \
  || fail metrics 'Prometheus ClusterIP를 읽지 못했다.'
prom_forward_port=${OPN_METRICS_PROM_FORWARD_PORT:-19190}
socket_dir=$(mktemp -d /tmp/opn-metrics-01-forward.XXXXXX)
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
  opn_metrics_cleanup
}
trap cleanup EXIT HUP INT TERM

ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -M -S "${socket_path}" -fNT \
  -L "127.0.0.1:${prom_forward_port}:${prometheus_ip}:9090" "${k3s_host}"
readonly prometheus_url="http://127.0.0.1:${prom_forward_port}"
for _ in $(seq 1 30); do
  if curl -fsS "${prometheus_url}/-/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "${prometheus_url}/-/ready" >/dev/null \
  || fail metrics 'Prometheus API forward가 ready가 아니다.'

prom_query() {
  local query=$1 encoded
  encoded=$(jq -rn --arg value "${query}" '$value|@uri')
  curl -fsS "${prometheus_url}/api/v1/query?query=${encoded}"
}

readonly observation_deadline=$(( $(date -u +%s) + observation_seconds ))
assert_one_series() {
  local evidence=$1 query=$2 result=''
  while (( $(date -u +%s) <= observation_deadline )); do
    result=$(prom_query "${query}" || true)
    if jq -e '.status == "success" and (.data.result | length) == 1' \
      <<<"${result}" >/dev/null 2>&1; then
      printf '%s=' "${evidence}"
      jq -c '.data.result[0] | {metric:.metric,value:.value[1]}' <<<"${result}"
      return
    fi
    sleep 5
  done
  fail metrics "3분 고정 관측창에서 ${evidence} 시계열 하나를 얻지 못했다: ${query}"
}

assert_one_series TargetUp \
  'up{instance="opnsense.imcherry5778.xyz"} == 1'
assert_one_series CPU \
  'topk(1,node_cpu_seconds_total{instance="opnsense.imcherry5778.xyz",mode="idle"})'
assert_one_series Memory \
  'node_memory_size_bytes{instance="opnsense.imcherry5778.xyz"}'
assert_one_series Interface \
  'topk(1,node_network_receive_bytes_total{instance="opnsense.imcherry5778.xyz",device!="lo0"})'

opn_metrics_load_env "${OPN_METRICS_ENV_FILE:-${OPN_METRICS_DEFAULT_ENV_FILE}}"
rules=${OPN_METRICS_API_TMP}/rules.json
opn_metrics_api GET '/api/firewall/filter/search_rule?interface=opt2&show_all=1' "${rules}"
jq -e . "${rules}" >/dev/null || fail firewall '방화벽 API 응답이 JSON이 아니다.'
rule=$(jq --arg description "${rule_description}" \
  '[.rows[] | select(.description == $description)]' "${rules}")
jq -e --arg description "${rule_description}" '
  length == 1 and
  .[0].enabled == "1" and
  .[0].sequence == "1020" and
  .[0].action == "pass" and
  .[0].quick == "1" and
  .[0].interface == "opt2" and
  .[0].direction == "in" and
  .[0].ipprotocol == "inet" and
  .[0].protocol == "TCP" and
  .[0].source_net == "10.10.20.10" and
  .[0].destination_net == "10.10.10.1" and
  .[0].destination_port == "9100" and
  .[0].log == "1" and
  .[0].description == $description
' <<<"${rule}" >/dev/null \
  || fail firewall '추가한 exact PASS의 저장 의미값이 일치하지 않는다.'
rule_uuid=$(jq -r '.[0].uuid' <<<"${rule}")
runtime=${OPN_METRICS_API_TMP}/rule-runtime.json
opn_metrics_api GET /api/firewall/filter_util/rule_stats "${runtime}"
jq -e --arg uuid "${rule_uuid}" '
  .status == "ok" and
  (.stats[$uuid].pf_rules | tonumber) >= 1 and
  (.stats[$uuid].packets | tonumber) >= 1
' "${runtime}" >/dev/null \
  || fail firewall 'uncached PF runtime에 생성 UUID의 rule 또는 scrape packet이 없다.'
jq -r --arg uuid "${rule_uuid}" '
  "FirewallRule=PASS uuid=\($uuid) sequence=1020 pf_rules=\(.stats[$uuid].pf_rules) packets=\(.stats[$uuid].packets) bytes=\(.stats[$uuid].bytes)"
' "${runtime}"

"${repo_root}/infra/opnsense/scripts/check-drift.sh" --update
"${repo_root}/infra/opnsense/scripts/check-drift.sh"
echo 'Drift=PASS'
echo 'OPN_METRICS_01_VERIFY=PASS'
