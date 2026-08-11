#!/usr/bin/env bash
# TRAEFIK-METRICS의 private scrape 경로와 metric 경계만 판정한다.
set -Eeuo pipefail

readonly mode=${1:-verify}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
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
  echo 'TRAEFIK-METRICS 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "TRAEFIK-METRICS 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

if [[ ${mode} == verify && ${TRAEFIK_METRICS_ARGO_LOCK_HELD:-false} != true ]]; then
  exec 9>/tmp/ktcloud4-bean-argo-root.lock
  flock -n 9 || fail lock '다른 ARGO-ROOT 작업이 실행 중이다.'
fi
if [[ ${mode} == verify && ${TRAEFIK_METRICS_TRAEFIK_LOCK_HELD:-false} != true ]]; then
  exec 8>/tmp/ktcloud4-bean-traefik-live.lock
  flock -n 8 || fail lock '다른 TRAEFIK-LIVE 작업이 실행 중이다.'
fi

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

prom_raw() {
  remote_kubectl --request-timeout=15s get --raw "$1"
}

prom_query() {
  local encoded
  encoded=$(jq -rn --arg query "$1" '$query | @uri')
  prom_raw "/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/query?query=${encoded}&timeout=10s"
}

prom_scalar() {
  prom_query "$1" | jq -er '
    if .status == "success" and (.data.result | length) == 1 and
       (.data.result[0].value[1] | type) == "string" then .data.result[0].value[1]
    else error("single scalar result required") end
  '
}

pod_working_set_bytes() {
  local line memory
  line=$(remote_kubectl -n obs top pod -l 'app.kubernetes.io/name=prometheus,operator.prometheus.io/name=obs-prometheus' --no-headers) \
    || fail capacity 'Prometheus Pod working set을 읽지 못했다.'
  [[ $(wc -l <<<"${line}") -eq 1 ]] || fail capacity 'Prometheus Pod가 정확히 한 건이 아니다.'
  memory=$(awk '{print $3}' <<<"${line}")
  [[ ${memory} =~ ^[0-9]+(Ki|Mi|Gi)$ ]] || fail capacity 'Prometheus memory 표기 형식이 올바르지 않다.'
  numfmt --from=iec-i "${memory}"
}

scope_counts() {
  ssh "${ssh_options[@]}" "${k3s_host}" bash -s <<'REMOTE'
set -Eeuo pipefail
count() {
  local namespace=$1 resource=$2
  sudo -n /usr/local/bin/k3s kubectl -n "${namespace}" get "${resource}" -o json | jq -er '.items | length'
}
kube_system_service_count=$(count kube-system services)
obs_servicemonitor_count=$(count obs servicemonitors.monitoring.coreos.com)
obs_networkpolicy_count=$(count obs networkpolicies.networking.k8s.io)
obs_pvc_count=$(count obs persistentvolumeclaims)
obs_secret_count=$(count obs secrets)
obs_ingress_count=$(count obs ingresses.networking.k8s.io)
printf 'KUBE_SYSTEM_SERVICE_COUNT=%s\nOBS_SERVICEMONITOR_COUNT=%s\nOBS_NETWORKPOLICY_COUNT=%s\nOBS_PVC_COUNT=%s\nOBS_SECRET_COUNT=%s\nOBS_INGRESS_COUNT=%s\n' \
  "${kube_system_service_count}" "${obs_servicemonitor_count}" "${obs_networkpolicy_count}" \
  "${obs_pvc_count}" "${obs_secret_count}" "${obs_ingress_count}"
REMOTE
}

measure_capacity() {
  local head_series prometheus_working_set node_capacity traefik_pod_uid kube_system_service_count
  local obs_servicemonitor_count obs_networkpolicy_count obs_pvc_count obs_secret_count obs_ingress_count counts
  head_series=$(prom_scalar 'prometheus_tsdb_head_series') || fail capacity 'Prometheus head series를 읽지 못했다.'
  prometheus_working_set=$(pod_working_set_bytes)
  node_capacity=$(ssh "${ssh_options[@]}" "${k3s_host}" bash -s <<'REMOTE'
free -b | awk '/Mem:/{print "AVAILABLE_BYTES=" $7} /Swap:/{print "SWAP_USED_BYTES=" $3}'
REMOTE
) || fail capacity 'k3s RAM/swap을 읽지 못했다.'
  traefik_pod_uid=$(remote_kubectl -n kube-system get pod -l 'app.kubernetes.io/name=traefik,app.kubernetes.io/instance=traefik-kube-system' -o json | jq -er '
    .items | if length == 1 then .[0].metadata.uid else error("one Traefik pod required") end
  ') || fail capacity 'Traefik Pod UID를 읽지 못했다.'
  counts=$(scope_counts) || fail capacity '범위 object 수를 읽지 못했다.'
  kube_system_service_count=$(awk -F= '$1 == "KUBE_SYSTEM_SERVICE_COUNT" {print $2}' <<<"${counts}")
  obs_servicemonitor_count=$(awk -F= '$1 == "OBS_SERVICEMONITOR_COUNT" {print $2}' <<<"${counts}")
  obs_networkpolicy_count=$(awk -F= '$1 == "OBS_NETWORKPOLICY_COUNT" {print $2}' <<<"${counts}")
  obs_pvc_count=$(awk -F= '$1 == "OBS_PVC_COUNT" {print $2}' <<<"${counts}")
  obs_secret_count=$(awk -F= '$1 == "OBS_SECRET_COUNT" {print $2}' <<<"${counts}")
  obs_ingress_count=$(awk -F= '$1 == "OBS_INGRESS_COUNT" {print $2}' <<<"${counts}")
  [[ ${kube_system_service_count} =~ ^[0-9]+$ && ${obs_servicemonitor_count} =~ ^[0-9]+$ &&
     ${obs_networkpolicy_count} =~ ^[0-9]+$ && ${obs_pvc_count} =~ ^[0-9]+$ &&
     ${obs_secret_count} =~ ^[0-9]+$ && ${obs_ingress_count} =~ ^[0-9]+$ ]] \
    || fail capacity '범위 object 수 형식이 올바르지 않다.'
  printf 'HEAD_SERIES=%s\nPROMETHEUS_WORKING_SET=%s\n%s\nTRAEFIK_POD_UID=%s\nKUBE_SYSTEM_SERVICE_COUNT=%s\nOBS_SERVICEMONITOR_COUNT=%s\nOBS_NETWORKPOLICY_COUNT=%s\nOBS_PVC_COUNT=%s\nOBS_SECRET_COUNT=%s\nOBS_INGRESS_COUNT=%s\n' \
    "${head_series}" "${prometheus_working_set}" "${node_capacity}" "${traefik_pod_uid}" \
    "${kube_system_service_count}" "${obs_servicemonitor_count}" "${obs_networkpolicy_count}" \
    "${obs_pvc_count}" "${obs_secret_count}" "${obs_ingress_count}"
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
  printf '%s\nTRAEFIK_METRICS_CAPACITY_PRE=PASS\n' "${capacity}"
  exit 0
fi

readonly expected_root_revision=${TRAEFIK_METRICS_EXPECTED_ROOT_REVISION:?root pointer SHA가 필요하다}
readonly expected_ingress_revision=${TRAEFIK_METRICS_EXPECTED_INGRESS_REVISION:?ingress 설정 SHA가 필요하다}
readonly expected_obs_revision=${TRAEFIK_METRICS_EXPECTED_OBS_REVISION:?obs 설정 SHA가 필요하다}
readonly pre_head_series=${TRAEFIK_METRICS_PRE_HEAD_SERIES:?배포 전 head series가 필요하다}
readonly pre_prometheus_working_set=${TRAEFIK_METRICS_PRE_PROMETHEUS_WORKING_SET:?배포 전 Prometheus working set이 필요하다}
readonly pre_available_bytes=${TRAEFIK_METRICS_PRE_AVAILABLE_BYTES:?배포 전 available RAM이 필요하다}
readonly pre_traefik_pod_uid=${TRAEFIK_METRICS_PRE_TRAEFIK_POD_UID:?배포 전 Traefik Pod UID가 필요하다}
readonly pre_kube_system_service_count=${TRAEFIK_METRICS_PRE_KUBE_SYSTEM_SERVICE_COUNT:?배포 전 kube-system Service 수가 필요하다}
readonly pre_obs_servicemonitor_count=${TRAEFIK_METRICS_PRE_OBS_SERVICEMONITOR_COUNT:?배포 전 obs ServiceMonitor 수가 필요하다}
readonly pre_obs_networkpolicy_count=${TRAEFIK_METRICS_PRE_OBS_NETWORKPOLICY_COUNT:?배포 전 obs NetworkPolicy 수가 필요하다}
readonly pre_obs_pvc_count=${TRAEFIK_METRICS_PRE_OBS_PVC_COUNT:?배포 전 obs PVC 수가 필요하다}
readonly pre_obs_secret_count=${TRAEFIK_METRICS_PRE_OBS_SECRET_COUNT:?배포 전 obs Secret 수가 필요하다}
readonly pre_obs_ingress_count=${TRAEFIK_METRICS_PRE_OBS_INGRESS_COUNT:?배포 전 obs Ingress 수가 필요하다}

[[ ${expected_root_revision} =~ ^[0-9a-f]{40}$ && ${expected_ingress_revision} =~ ^[0-9a-f]{40}$ && ${expected_obs_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail preflight 'immutable SHA 형식이 아니다.'
[[ ${pre_head_series} =~ ^[0-9]+([.][0-9]+)?$ && ${pre_prometheus_working_set} =~ ^[0-9]+([.][0-9]+)?$ &&
   ${pre_available_bytes} =~ ^[0-9]+$ && ${pre_kube_system_service_count} =~ ^[0-9]+$ &&
   ${pre_obs_servicemonitor_count} =~ ^[0-9]+$ && ${pre_obs_networkpolicy_count} =~ ^[0-9]+$ &&
   ${pre_obs_pvc_count} =~ ^[0-9]+$ && ${pre_obs_secret_count} =~ ^[0-9]+$ && ${pre_obs_ingress_count} =~ ^[0-9]+$ ]] \
  || fail preflight '배포 전 측정값 형식이 올바르지 않다.'

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root ingress obs -o json 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg ingress "${expected_ingress_revision}" --arg obs "${expected_obs_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "ingress")][0] // {}) as $ingress_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
    $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
    $ingress_app.spec.source.targetRevision == $ingress and $ingress_app.status.sync.revision == $ingress and
    $ingress_app.status.sync.status == "Synced" and $ingress_app.status.health.status == "Healthy" and
    $obs_app.spec.source.targetRevision == $obs and $obs_app.status.sync.revision == $obs and
    $obs_app.status.sync.status == "Synced" and $obs_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${expected_root_revision}" --arg ingress "${expected_ingress_revision}" --arg obs "${expected_obs_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "ingress")][0] // {}) as $ingress_app |
  ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
  $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
  $ingress_app.spec.source.targetRevision == $ingress and $ingress_app.status.sync.revision == $ingress and
  $ingress_app.status.sync.status == "Synced" and $ingress_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $obs and $obs_app.status.sync.revision == $obs and
  $obs_app.status.sync.status == "Synced" and $obs_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || fail argo 'platform-root/ingress/obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} ingress=${expected_ingress_revision} obs=${expected_obs_revision}"

traefik_ready=false
for _ in $(seq 1 36); do
  traefik_config=$(remote_kubectl -n kube-system get deployment traefik -o json 2>/dev/null || true)
  post_traefik_pod_uid=$(remote_kubectl -n kube-system get pod -l 'app.kubernetes.io/name=traefik,app.kubernetes.io/instance=traefik-kube-system' -o json 2>/dev/null | jq -er '.items | if length == 1 then .[0].metadata.uid else error("one Traefik pod required") end' 2>/dev/null || true)
  if [[ -n ${traefik_config} && ${post_traefik_pod_uid} != "${pre_traefik_pod_uid}" ]] && jq -e '
    [.spec.template.spec.containers[] | select(.name == "traefik") | .args[]?] as $args |
    ($args | index("--metrics.prometheus=true")) != null and
    ($args | index("--metrics.prometheus.addRoutersLabels=true")) != null and
    ($args | any(test("metrics[.]prometheus[.]headerlabels")) | not)
  ' <<<"${traefik_config}" >/dev/null 2>&1; then
    traefik_ready=true
    break
  fi
  sleep 5
done
[[ ${traefik_ready} == true ]] || fail config 'k3s Helm controller가 Prometheus router label 설정과 Traefik Pod 교체를 완료하지 않았다.'
remote_kubectl -n kube-system rollout status deployment/traefik --timeout=180s >/dev/null \
  || fail workload 'Traefik가 Ready가 아니다.'

remote_kubectl -n kube-system get service traefik-metrics -o json | jq -e '
  .spec.type == "ClusterIP" and (.spec.externalIPs // [] | length == 0) and
  .spec.selector == {"app.kubernetes.io/instance":"traefik-kube-system", "app.kubernetes.io/name":"traefik"} and
  [.spec.ports[] | {name, protocol, port, targetPort}] == [{"name":"metrics", "protocol":"TCP", "port":9100, "targetPort":"metrics"}]
' >/dev/null || fail service 'private traefik-metrics Service 선언이 다르다.'
remote_kubectl -n kube-system get service traefik -o json | jq -e '
  [.spec.ports[] | {name, port, targetPort}] == [{"name":"web", "port":80, "targetPort":"web"}, {"name":"websecure", "port":443, "targetPort":"websecure"}]
' >/dev/null || fail service '기존 external Traefik Service port가 바뀌었다.'
remote_kubectl -n obs get servicemonitor obs-traefik -o json | jq -e '
  .metadata.labels.release == "obs" and .spec.namespaceSelector.matchNames == ["kube-system"] and
  .spec.selector.matchLabels == {"app.kubernetes.io/name":"traefik", "app.kubernetes.io/component":"metrics"} and
  .spec.jobLabel == "app.kubernetes.io/name" and
  .spec.endpoints == [{"port":"metrics", "path":"/metrics", "interval":"30s", "scrapeTimeout":"10s"}]
' >/dev/null || fail servicemonitor 'obs-traefik ServiceMonitor 선언이 다르다.'
remote_kubectl -n obs get networkpolicy obs-prometheus-scrape-egress -o json | jq -e '
  any(.spec.egress[];
    .to == [{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}}, "podSelector":{"matchLabels":{"app.kubernetes.io/name":"traefik"}}}] and
    .ports == [{"protocol":"TCP", "port":9100}]
  )
' >/dev/null || fail networkpolicy 'Prometheus에서 Traefik TCP 9100으로의 exact egress가 없다.'
echo 'Config=PASS traefik-router-labels=true header-labels=0 private-service=ClusterIP external-9100=0'

targets=''
for _ in $(seq 1 36); do
  targets=$(prom_raw '/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/targets' 2>/dev/null || true)
  if [[ -n ${targets} ]] && jq -e '[.data.activeTargets[] | select(.labels.namespace == "kube-system" and .labels.service == "traefik-metrics" and .labels.job == "traefik" and .health == "up")] | length == 1' <<<"${targets}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e '[.data.activeTargets[] | select(.labels.namespace == "kube-system" and .labels.service == "traefik-metrics" and .labels.job == "traefik" and .health == "up")] | length == 1' <<<"${targets}" >/dev/null \
  || fail scrape 'traefik-metrics target up=1 한 건이 아니다.'

metric_ready=false
for _ in $(seq 1 36); do
  if entrypoint_count=$(prom_scalar 'count(traefik_entrypoint_requests_total)' 2>/dev/null) &&
     entrypoint_histogram_count=$(prom_scalar 'count(traefik_entrypoint_request_duration_seconds_bucket)' 2>/dev/null) &&
     router_count=$(prom_scalar 'count(traefik_router_requests_total)' 2>/dev/null) &&
     service_count=$(prom_scalar 'count(traefik_service_requests_total)' 2>/dev/null) &&
     p95=$(prom_query 'histogram_quantile(0.95, sum by (le, entrypoint) (rate(traefik_entrypoint_request_duration_seconds_bucket[10m])))' 2>/dev/null) &&
     p99=$(prom_query 'histogram_quantile(0.99, sum by (le, entrypoint) (rate(traefik_entrypoint_request_duration_seconds_bucket[10m])))' 2>/dev/null) &&
     jq -e '.status == "success" and (.data.result | length > 0)' <<<"${p95}" >/dev/null &&
     jq -e '.status == "success" and (.data.result | length > 0)' <<<"${p99}" >/dev/null &&
     awk -v a="${entrypoint_count}" -v b="${entrypoint_histogram_count}" -v c="${router_count}" -v d="${service_count}" 'BEGIN {exit !(a > 0 && b > 0 && c > 0 && d > 0)}'; then
    metric_ready=true
    break
  fi
  sleep 5
done
[[ ${metric_ready} == true ]] || fail metric 'entrypoint/router/service metric 또는 p95/p99 대표 series가 준비되지 않았다.'

metric_label_names() {
  local selector=$1 encoded
  encoded=$(jq -rn --arg selector "${selector}" '$selector | @uri')
  prom_raw "/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/series?match%5B%5D=${encoded}" | jq -cer '[.data[] | keys[]] | unique | sort'
}
entrypoint_labels=$(metric_label_names 'traefik_entrypoint_requests_total') || fail metric 'entrypoint label 이름을 읽지 못했다.'
router_labels=$(metric_label_names 'traefik_router_requests_total') || fail metric 'router label 이름을 읽지 못했다.'
service_labels=$(metric_label_names 'traefik_service_requests_total') || fail metric 'service label 이름을 읽지 못했다.'
jq -en '
  (["code", "entrypoint", "method", "protocol"] - $entrypoint) == [] and
  (["code", "method", "protocol", "router", "service"] - $router) == [] and
  (["code", "method", "protocol", "service"] - $service) == [] and
  ([$entrypoint[], $router[], $service[]] | any(. == "path" or . == "client_ip" or . == "user" or . == "authorization" or . == "header") | not)
' --argjson entrypoint "${entrypoint_labels}" --argjson router "${router_labels}" --argjson service "${service_labels}" >/dev/null \
  || fail metric '필수 label이 없거나 금지한 민감 label 이름이 있다.'
printf 'Metric=PASS target=up entrypoint=%s histogram=%s router=%s service=%s entrypoint_labels=%s router_labels=%s service_labels=%s p95_p99=present\n' \
  "${entrypoint_count}" "${entrypoint_histogram_count}" "${router_count}" "${service_count}" \
  "${entrypoint_labels}" "${router_labels}" "${service_labels}"

post_capacity=$(measure_capacity)
capacity_gate POST "${post_capacity}"
post_head_series=$(awk -F= '$1 == "HEAD_SERIES" {print $2}' <<<"${post_capacity}")
post_prometheus_working_set=$(awk -F= '$1 == "PROMETHEUS_WORKING_SET" {print $2}' <<<"${post_capacity}")
post_available_bytes=$(awk -F= '$1 == "AVAILABLE_BYTES" {print $2}' <<<"${post_capacity}")
post_kube_system_service_count=$(awk -F= '$1 == "KUBE_SYSTEM_SERVICE_COUNT" {print $2}' <<<"${post_capacity}")
post_obs_servicemonitor_count=$(awk -F= '$1 == "OBS_SERVICEMONITOR_COUNT" {print $2}' <<<"${post_capacity}")
post_obs_networkpolicy_count=$(awk -F= '$1 == "OBS_NETWORKPOLICY_COUNT" {print $2}' <<<"${post_capacity}")
post_obs_pvc_count=$(awk -F= '$1 == "OBS_PVC_COUNT" {print $2}' <<<"${post_capacity}")
post_obs_secret_count=$(awk -F= '$1 == "OBS_SECRET_COUNT" {print $2}' <<<"${post_capacity}")
post_obs_ingress_count=$(awk -F= '$1 == "OBS_INGRESS_COUNT" {print $2}' <<<"${post_capacity}")
[[ ${post_head_series} =~ ^[0-9]+([.][0-9]+)?$ && ${post_prometheus_working_set} =~ ^[0-9]+([.][0-9]+)?$ &&
   ${post_available_bytes} =~ ^[0-9]+$ && ${post_kube_system_service_count} =~ ^[0-9]+$ &&
   ${post_obs_servicemonitor_count} =~ ^[0-9]+$ && ${post_obs_networkpolicy_count} =~ ^[0-9]+$ &&
   ${post_obs_pvc_count} =~ ^[0-9]+$ && ${post_obs_secret_count} =~ ^[0-9]+$ && ${post_obs_ingress_count} =~ ^[0-9]+$ ]] \
  || fail capacity '배포 후 측정값 형식이 올바르지 않다.'
(( post_kube_system_service_count == pre_kube_system_service_count + 1 )) || fail scope 'kube-system Service 증감이 private metrics Service 한 건과 다르다.'
(( post_obs_servicemonitor_count == pre_obs_servicemonitor_count + 1 )) || fail scope 'obs ServiceMonitor 증감이 한 건과 다르다.'
(( post_obs_networkpolicy_count == pre_obs_networkpolicy_count )) || fail scope 'obs NetworkPolicy object 수가 바뀌었다.'
(( post_obs_pvc_count == pre_obs_pvc_count && post_obs_secret_count == pre_obs_secret_count && post_obs_ingress_count == pre_obs_ingress_count )) || fail scope 'obs PVC/Secret/Ingress object 수가 바뀌었다.'
printf 'CapacityScope=PASS PRE_HEAD_SERIES=%s POST_HEAD_SERIES=%s PRE_PROMETHEUS_WORKING_SET=%s POST_PROMETHEUS_WORKING_SET=%s PRE_AVAILABLE_BYTES=%s POST_AVAILABLE_BYTES=%s services=%s->%s servicemonitors=%s->%s networkpolicies=%s pvcs=%s secrets=%s ingresses=%s\n' \
  "${pre_head_series}" "${post_head_series}" "${pre_prometheus_working_set}" "${post_prometheus_working_set}" \
  "${pre_available_bytes}" "${post_available_bytes}" "${pre_kube_system_service_count}" "${post_kube_system_service_count}" \
  "${pre_obs_servicemonitor_count}" "${post_obs_servicemonitor_count}" "${post_obs_networkpolicy_count}" \
  "${post_obs_pvc_count}" "${post_obs_secret_count}" "${post_obs_ingress_count}"
echo 'TRAEFIK_METRICS_VERIFY=PASS'
