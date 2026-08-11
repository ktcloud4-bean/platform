#!/usr/bin/env bash
# OBS-12의 Argo CD Application metric 최소 수집과 Grafana provisioning만 판정한다.
set -Eeuo pipefail

readonly mode=${1:-verify}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
readonly argocd_samples_limit=128
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
  echo 'OBS-12 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "OBS-12 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

prom_raw() {
  remote_kubectl --request-timeout=15s get --raw "$1"
}

prom_query() {
  local encoded
  encoded=$(jq -rn --arg query "$1" '$query | @uri')
  prom_raw "/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/query?query=${encoded}"
}

prom_scalar() {
  prom_query "$1" | jq -er '
    if .status == "success" and (.data.result | length) == 1 and
       (.data.result[0].value[1] | type) == "string" then .data.result[0].value[1]
    else error("single scalar result required") end
  '
}

grafana_dashboard() {
  # $()은 Grafana Pod의 sh에서만 확장한다. ssh 인수로 넘기면 k3s host에서 확장될 수 있다.
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -se' <<'REMOTE'
sudo -n /usr/local/bin/k3s kubectl -n obs exec deploy/obs-grafana -c grafana -- sh -ec 'curl --fail --silent --show-error -u "admin:$(cat /vault/secrets/admin-password)" http://127.0.0.1:3000/api/dashboards/uid/obs-12-argocd-applications'
REMOTE
}

dashboard_matches() {
  jq -e '
    ([.dashboard.panels[]? | (.targets // [])[]? | .expr // ""] | join("\n")) as $queries |
    (.dashboard.uid == "obs-12-argocd-applications" and
     .dashboard.title == "ArgoCD / Application / Overview" and
     .dashboard.editable == false and
     ($queries | contains("argocd_app_info")) and
     ($queries | contains("argocd_app_sync_total")) and
     ($queries | contains("dest_namespace")) and
     ($queries | contains("exported_namespace") | not) and
     ($queries | contains("cluster=\"$cluster\"") | not) and
     ([.dashboard.templating.list[]? | .datasource.uid] | length == 6 and all(.[]; . == "prometheus")) and
     ((.dashboard | tostring) | contains("${datasource}") | not) and
     ([.dashboard.templating.list[]? | .name] | sort == ["application", "application_namespace", "job", "kubernetes_cluster", "namespace", "project"]) and
     any(.dashboard.templating.list[]?; .name == "kubernetes_cluster" and (.query | contains("dest_server"))))
  ' >/dev/null
}

pod_working_set_bytes() {
  local selector=$1 line memory
  line=$(remote_kubectl -n obs top pod -l "${selector}" --no-headers) \
    || fail capacity "${selector} Pod working set을 읽지 못했다."
  [[ $(wc -l <<<"${line}") -eq 1 ]] || fail capacity "${selector} Pod 수가 정확히 한 건이 아니다."
  memory=$(awk '{print $3}' <<<"${line}")
  [[ ${memory} =~ ^[0-9]+(Ki|Mi|Gi)$ ]] || fail capacity "${selector} memory 표기 형식이 올바르지 않다."
  numfmt --from=iec-i "${memory}"
}

measure_capacity() {
  local head_series prometheus_working_set grafana_working_set node_capacity
  head_series=$(prom_scalar 'prometheus_tsdb_head_series') || fail capacity 'Prometheus head series를 읽지 못했다.'
  prometheus_working_set=$(pod_working_set_bytes 'app.kubernetes.io/name=prometheus')
  grafana_working_set=$(pod_working_set_bytes 'app.kubernetes.io/name=grafana')
  node_capacity=$(ssh "${ssh_options[@]}" "${k3s_host}" bash -s <<'REMOTE'
free -b | awk '/Mem:/{print "AVAILABLE_BYTES=" $7} /Swap:/{print "SWAP_USED_BYTES=" $3}'
REMOTE
) \
    || fail capacity 'k3s RAM/swap을 읽지 못했다.'
  printf 'HEAD_SERIES=%s\nPROMETHEUS_WORKING_SET=%s\nGRAFANA_WORKING_SET=%s\n%s' \
    "${head_series}" "${prometheus_working_set}" "${grafana_working_set}" "${node_capacity}"
}

capacity_gate() {
  local prefix=$1 values=$2 available_bytes swap_used_bytes
  available_bytes=$(awk -F= '$1 == "AVAILABLE_BYTES" {print $2}' <<<"${values}")
  swap_used_bytes=$(awk -F= '$1 == "SWAP_USED_BYTES" {print $2}' <<<"${values}")
  [[ ${available_bytes} =~ ^[0-9]+$ && ${swap_used_bytes} =~ ^[0-9]+$ ]] \
    || fail capacity "${prefix} RAM/swap 측정값 형식이 올바르지 않다."
  (( available_bytes >= available_stop_bytes )) \
    || fail capacity "${prefix} k3s available RAM이 8 GiB 정지선 아래다."
  (( swap_used_bytes == 0 )) || fail capacity "${prefix} k3s swap 사용량이 0이 아니다."
}

if [[ ${mode} == capacity-pre ]]; then
  capacity=$(measure_capacity)
  capacity_gate PRE "${capacity}"
  printf '%s\nOBS12_CAPACITY_PRE=PASS\n' "${capacity}"
  exit 0
fi

readonly expected_config_revision=${OBS12_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS12_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}
readonly pre_head_series=${OBS12_PRE_HEAD_SERIES:?배포 전 head series가 필요하다}
readonly pre_available_bytes=${OBS12_PRE_AVAILABLE_BYTES:?배포 전 available RAM이 필요하다}
readonly pre_prometheus_working_set=${OBS12_PRE_PROMETHEUS_WORKING_SET:?배포 전 Prometheus working set이 필요하다}
readonly pre_grafana_working_set=${OBS12_PRE_GRAFANA_WORKING_SET:?배포 전 Grafana working set이 필요하다}

[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail preflight 'immutable SHA 형식이 아니다.'
[[ ${pre_head_series} =~ ^[0-9]+([.][0-9]+)?$ && ${pre_available_bytes} =~ ^[0-9]+$ &&
   ${pre_prometheus_working_set} =~ ^[0-9]+([.][0-9]+)?$ && ${pre_grafana_working_set} =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || fail preflight '배포 전 capacity 측정값 형식이 올바르지 않다.'

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
  if jq -e --arg root_revision "${expected_root_revision}" --arg config_revision "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
    $root_app.spec.source.targetRevision == $root_revision and
    $root_app.status.sync.revision == $root_revision and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $obs_app.spec.source.targetRevision == $config_revision and
    $obs_app.status.sync.revision == $config_revision and
    $obs_app.status.sync.status == "Synced" and
    $obs_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root_revision "${expected_root_revision}" --arg config_revision "${expected_config_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
  $root_app.spec.source.targetRevision == $root_revision and $root_app.status.sync.revision == $root_revision and
  $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $config_revision and $obs_app.status.sync.revision == $config_revision and
  $obs_app.status.sync.status == "Synced" and $obs_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || fail argo 'platform-root 또는 obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

remote_kubectl -n obs rollout status deployment/obs-grafana --timeout=180s >/dev/null \
  || fail grafana 'Grafana가 Ready가 아니다.'

target_state=''
for _ in $(seq 1 36); do
  target_state=$(prom_raw '/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/targets' 2>/dev/null || true)
  if [[ -n ${target_state} ]] && jq -e '[.data.activeTargets[] | select(.labels.namespace == "argocd" and .labels.service == "argocd-metrics" and .health == "up")] | length == 1' \
    <<<"${target_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if [[ -z ${target_state} ]] || ! jq -e '[.data.activeTargets[] | select(.labels.namespace == "argocd" and .labels.service == "argocd-metrics" and .health == "up")] | length == 1' \
  <<<"${target_state}" >/dev/null; then
  fail scrape 'argocd-metrics target up=1 한 건이 아니다.'
fi

app_info_count=$(prom_scalar 'count(argocd_app_info)') || fail metric 'argocd_app_info 대표 series를 읽지 못했다.'
app_sync_count=$(prom_scalar 'count(argocd_app_sync_total)') || fail metric 'argocd_app_sync_total 대표 series를 읽지 못했다.'
argocd_samples=$(prom_scalar 'max(scrape_samples_post_metric_relabeling{job="argocd-metrics"})') \
  || fail metric 'argocd-metrics scrape sample 수를 읽지 못했다.'
awk -v count="${app_info_count}" 'BEGIN {exit !(count > 0)}' || fail metric 'argocd_app_info가 0건이다.'
awk -v count="${app_sync_count}" 'BEGIN {exit !(count > 0)}' || fail metric 'argocd_app_sync_total가 0건이다.'
awk -v samples="${argocd_samples}" -v limit="${argocd_samples_limit}" \
  'BEGIN {exit !(samples > 0 && samples <= limit)}' \
  || fail metric "argocd-metrics scrape sample 수가 1..${argocd_samples_limit} 범위를 벗어났다."
prom_raw '/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/labels?match%5B%5D=argocd_app_info' \
  | jq -e '(.data | index("repo") | not) and (.data | index("operation") | not) and (.data | index("dry_run") | not)' >/dev/null \
  || fail metric 'drop 대상 label이 Prometheus에 남아 있다.'
echo "Metric=PASS argocd_app_info=${app_info_count} argocd_app_sync_total=${app_sync_count} scrape_samples=${argocd_samples} labels=filtered"

dashboard=''
for _ in $(seq 1 36); do
  dashboard=$(grafana_dashboard 2>/dev/null || true)
  if [[ -n ${dashboard} ]] && dashboard_matches <<<"${dashboard}" 2>/dev/null; then
    break
  fi
  sleep 5
done
dashboard_matches <<<"${dashboard}" || fail grafana 'OBS-12 dashboard UID·변수 datasource·정규화 query가 일치하지 않는다.'
echo 'Grafana=PASS uid=obs-12-argocd-applications editable=false variables=prometheus queries=normalized'

post_capacity=$(measure_capacity)
capacity_gate POST "${post_capacity}"
post_head_series=$(awk -F= '$1 == "HEAD_SERIES" {print $2}' <<<"${post_capacity}")
post_available_bytes=$(awk -F= '$1 == "AVAILABLE_BYTES" {print $2}' <<<"${post_capacity}")
post_prometheus_working_set=$(awk -F= '$1 == "PROMETHEUS_WORKING_SET" {print $2}' <<<"${post_capacity}")
post_grafana_working_set=$(awk -F= '$1 == "GRAFANA_WORKING_SET" {print $2}' <<<"${post_capacity}")
printf 'Capacity=PASS PRE_HEAD_SERIES=%s POST_HEAD_SERIES=%s PRE_AVAILABLE_BYTES=%s POST_AVAILABLE_BYTES=%s PRE_PROMETHEUS_WORKING_SET=%s POST_PROMETHEUS_WORKING_SET=%s PRE_GRAFANA_WORKING_SET=%s POST_GRAFANA_WORKING_SET=%s\n' \
  "${pre_head_series}" "${post_head_series}" "${pre_available_bytes}" "${post_available_bytes}" \
  "${pre_prometheus_working_set}" "${post_prometheus_working_set}" \
  "${pre_grafana_working_set}" "${post_grafana_working_set}"
echo 'OBS12_VERIFY=PASS'
