#!/usr/bin/env bash
# OBS-10의 Traefik dashboard vendoring과 기존 OBS-05 drill-down link만 판정한다.
set -Eeuo pipefail

readonly mode=${1:-verify}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
umask 077
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

[[ ${mode} == scope-pre || ${mode} == verify ]] || {
  echo 'usage: verify-live.sh [scope-pre|verify]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'OBS-10 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "OBS-10 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  timeout 30s ssh "${ssh_options[@]}" "${k3s_host}" \
    timeout 20s sudo -n /usr/local/bin/k3s kubectl "$@"
}

prom_raw() {
  remote_kubectl --request-timeout=15s get --raw "$1"
}

prom_query() {
  local encoded
  encoded=$(jq -rn --arg query "$1" '$query | @uri')
  prom_raw "/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/query?query=${encoded}&timeout=10s"
}

metric_labels() {
  local metric=$1 encoded
  encoded=$(jq -rn --arg selector "${metric}" '$selector | @uri')
  prom_raw "/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/series?match%5B%5D=${encoded}" |
    jq -cer --arg metric "${metric}" '{metric:$metric,series:(.data | length),labels:([.data[] | keys[]] | unique | sort)}'
}

grafana_dashboard() {
  # $()은 Grafana Pod의 sh에서만 확장한다. ssh 인수로 넘기면 k3s host에서 확장될 수 있다.
  local uid=$1
  timeout 30s ssh "${ssh_options[@]}" "${k3s_host}" 'bash -se' -- "${uid}" <<'REMOTE'
uid=$1
timeout 20s sudo -n /usr/local/bin/k3s kubectl -n obs exec deploy/obs-grafana -c grafana -- \
  sh -ec 'curl --max-time 15 --fail --silent --show-error -u "admin:$(cat /vault/secrets/admin-password)" "http://127.0.0.1:3000/api/dashboards/uid/$1"' -- "${uid}"
REMOTE
}

pod_uid() {
  local namespace=$1 selector=$2 name=$3
  remote_kubectl -n "${namespace}" get pod -l "${selector}" -o json | jq -er --arg name "${name}" '
    .items |
    if length == 1 and ([.[0].status.containerStatuses[]? | select(.name == $name and .ready == true)] | length) == 1
    then .[0].metadata.uid else error("one Ready pod required") end
  '
}

scope_snapshot() {
  local traefik_uid grafana_uid service_count servicemonitor_count networkpolicy_count pvc_count secret_count ingress_count
  traefik_uid=$(pod_uid kube-system 'app.kubernetes.io/name=traefik,app.kubernetes.io/instance=traefik-kube-system' traefik) || fail scope 'Ready Traefik Pod UID를 읽지 못했다.'
  grafana_uid=$(pod_uid obs 'app.kubernetes.io/name=grafana' grafana) || fail scope 'Ready Grafana Pod UID를 읽지 못했다.'
  service_count=$(remote_kubectl -n obs get services -o json | jq -er '.items | length')
  servicemonitor_count=$(remote_kubectl -n obs get servicemonitors.monitoring.coreos.com -o json | jq -er '.items | length')
  networkpolicy_count=$(remote_kubectl -n obs get networkpolicies.networking.k8s.io -o json | jq -er '.items | length')
  pvc_count=$(remote_kubectl -n obs get persistentvolumeclaims -o json | jq -er '.items | length')
  secret_count=$(remote_kubectl -n obs get secrets -o json | jq -er '.items | length')
  ingress_count=$(remote_kubectl -n obs get ingresses.networking.k8s.io -o json | jq -er '.items | length')
  printf 'TRAEFIK_POD_UID=%s\nGRAFANA_POD_UID=%s\nOBS_SERVICE_COUNT=%s\nOBS_SERVICEMONITOR_COUNT=%s\nOBS_NETWORKPOLICY_COUNT=%s\nOBS_PVC_COUNT=%s\nOBS_SECRET_COUNT=%s\nOBS_INGRESS_COUNT=%s\n' \
    "${traefik_uid}" "${grafana_uid}" "${service_count}" "${servicemonitor_count}" \
    "${networkpolicy_count}" "${pvc_count}" "${secret_count}" "${ingress_count}"
}

if [[ ${mode} == scope-pre ]]; then
  scope_snapshot
  echo 'OBS10_SCOPE_PRE=PASS'
  exit 0
fi

readonly expected_config_revision=${OBS10_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS10_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}
readonly pre_traefik_pod_uid=${OBS10_PRE_TRAEFIK_POD_UID:?배포 전 Traefik Pod UID가 필요하다}
readonly pre_grafana_pod_uid=${OBS10_PRE_GRAFANA_POD_UID:?배포 전 Grafana Pod UID가 필요하다}
readonly pre_service_count=${OBS10_PRE_SERVICE_COUNT:?배포 전 obs Service 수가 필요하다}
readonly pre_servicemonitor_count=${OBS10_PRE_SERVICEMONITOR_COUNT:?배포 전 obs ServiceMonitor 수가 필요하다}
readonly pre_networkpolicy_count=${OBS10_PRE_NETWORKPOLICY_COUNT:?배포 전 obs NetworkPolicy 수가 필요하다}
readonly pre_pvc_count=${OBS10_PRE_PVC_COUNT:?배포 전 obs PVC 수가 필요하다}
readonly pre_secret_count=${OBS10_PRE_SECRET_COUNT:?배포 전 obs Secret 수가 필요하다}
readonly pre_ingress_count=${OBS10_PRE_INGRESS_COUNT:?배포 전 obs Ingress 수가 필요하다}

[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail preflight 'immutable SHA 형식이 아니다.'
[[ ${pre_traefik_pod_uid} =~ ^[0-9a-f-]{36}$ && ${pre_grafana_pod_uid} =~ ^[0-9a-f-]{36}$ ]] \
  || fail preflight 'Pod UID 형식이 올바르지 않다.'
for count in "${pre_service_count}" "${pre_servicemonitor_count}" "${pre_networkpolicy_count}" "${pre_pvc_count}" "${pre_secret_count}" "${pre_ingress_count}"; do
  [[ ${count} =~ ^[0-9]+$ ]] || fail preflight '배포 전 object 수 형식이 올바르지 않다.'
done

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

dashboard_matches() {
  jq -e '
    ([.dashboard.panels[]? | .title] | sort) as $titles |
    ([.dashboard.panels[]? | (.targets // [])[]? | .expr // ""] | unique) as $queries |
    ([.dashboard.templating.list[]? | .name] | sort) as $variables |
    (.dashboard.uid == "obs-10-traefik-traffic" and
     .dashboard.title == "Traefik Traffic Drill-down" and
     .dashboard.editable == false and
     .dashboard.schemaVersion == 41 and
     (.dashboard.description | contains("ID 17346 revision 9")) and
     (.dashboard.description | contains("3ad329d2737120f32f67aab083f245b554ea5c4ec8378feee7196ef6bb9f7da9")) and
     $titles == ["Entrypoint QPS", "HTTP 5xx ratio", "HTTP status QPS", "Top entrypoints by QPS", "Top routers by QPS", "Top services by QPS", "p95 / p99 latency"] and
     $variables == ["entrypoint", "router", "service"] and
     ([.. | objects | select((.datasource? | type) == "object") | .datasource.uid] | all(.[]; . == "prometheus")) and
     ($queries | length == 8) and
     ($queries | any(.[]; contains("sum by (entrypoint) (rate(traefik_entrypoint_requests_total"))) and
     ($queries | any(.[]; contains("sum by (code) (rate(traefik_entrypoint_requests_total"))) and
     ($queries | any(.[]; contains("code=~\"5..\""))) and
     ($queries | any(.[]; contains("histogram_quantile(0.95"))) and
     ($queries | any(.[]; contains("histogram_quantile(0.99"))) and
     ($queries | any(.[]; contains("traefik_router_requests_total"))) and
     ($queries | any(.[]; contains("traefik_service_requests_total"))) and
     ($queries | all(.[]; contains("or vector(0)") | not)) and
     ((.dashboard | tostring) | test("path|client[_-]?ip|authorization|header"; "i") | not))
  ' >/dev/null
}

core_link_matches() {
  jq -e '
    ([.dashboard.panels[]? | (.targets // [])[]? | .expr // ""] | join("\\n")) as $queries |
    (.dashboard.uid == "obs-05-core-services" and
     .dashboard.editable == false and
     ([.dashboard.panels[]? | select(.title == "Traefik traffic drill-down")] | length == 1) and
     any(.dashboard.panels[]?; .title == "Traefik traffic drill-down" and .type == "text" and (.options.content | contains("/d/obs-10-traefik-traffic"))) and
     ($queries | test("traefik_(entrypoint_requests_total|service_requests_total|entrypoint_request_duration_seconds)") | not))
  ' >/dev/null
}

remote_kubectl -n obs rollout status deployment/obs-grafana --timeout=180s >/dev/null \
  || fail grafana 'Grafana가 Ready가 아니다.'

dashboard=''
core_dashboard=''
for _ in $(seq 1 36); do
  dashboard=$(grafana_dashboard obs-10-traefik-traffic 2>/dev/null || true)
  core_dashboard=$(grafana_dashboard obs-05-core-services 2>/dev/null || true)
  if [[ -n ${dashboard} && -n ${core_dashboard} ]] && dashboard_matches <<<"${dashboard}" 2>/dev/null && core_link_matches <<<"${core_dashboard}" 2>/dev/null; then
    break
  fi
  sleep 5
done
dashboard_matches <<<"${dashboard}" || fail grafana 'Traefik dashboard의 source 고정, panel/변수, datasource 또는 read-only provisioning이 일치하지 않는다.'
core_link_matches <<<"${core_dashboard}" || fail grafana 'OBS-05 Traefik summary panel이 단일 drill-down link로 정규화되지 않았다.'

entrypoint_labels=$(metric_labels traefik_entrypoint_requests_total) || fail metric 'entrypoint metric label 이름을 읽지 못했다.'
histogram_labels=$(metric_labels traefik_entrypoint_request_duration_seconds_bucket) || fail metric 'latency histogram label 이름을 읽지 못했다.'
router_labels=$(metric_labels traefik_router_requests_total) || fail metric 'router metric label 이름을 읽지 못했다.'
service_labels=$(metric_labels traefik_service_requests_total) || fail metric 'service metric label 이름을 읽지 못했다.'
jq -en '
  ($entrypoint.series > 0 and $histogram.series > 0 and $router.series > 0 and $service.series > 0) and
  (["code", "entrypoint", "method", "protocol"] - $entrypoint.labels == []) and
  (["le", "entrypoint"] - $histogram.labels == []) and
  (["router", "service", "code", "method", "protocol"] - $router.labels == []) and
  (["service", "code", "method", "protocol"] - $service.labels == []) and
  ([$entrypoint.labels[], $histogram.labels[], $router.labels[], $service.labels[]] |
    any(. == "path" or . == "client_ip" or . == "user" or . == "authorization" or . == "header") | not)
' --argjson entrypoint "${entrypoint_labels}" --argjson histogram "${histogram_labels}" \
  --argjson router "${router_labels}" --argjson service "${service_labels}" >/dev/null \
  || fail metric '필수 native metric/label이 없거나 금지한 민감 label 이름이 있다.'
prom_query 'up{job="traefik"}' | jq -e '.status == "success" and (.data.result | length == 1) and .data.result[0].value[1] == "1"' >/dev/null \
  || fail metric 'Traefik Prometheus target up=1 한 건이 아니다.'

mapfile -t dashboard_queries < <(jq -er '[.dashboard.panels[]? | (.targets // [])[]? | .expr // ""] | unique[]' <<<"${dashboard}")
(( ${#dashboard_queries[@]} == 8 )) || fail promql 'Traefik dashboard panel query 여덟 건을 읽지 못했다.'
for query in "${dashboard_queries[@]}"; do
  resolved_query=$(jq -rn --arg query "${query}" '$query | gsub("\\$entrypoint"; ".*") | gsub("\\$router"; ".*") | gsub("\\$service"; ".*") | gsub("\\$__rate_interval"; "10m")')
  prom_query "${resolved_query}" | jq -e '.status == "success" and (.data.result | length > 0)' >/dev/null \
    || fail promql "dashboard panel query가 Prometheus API에서 parse되거나 결과를 내지 못한다."
done
echo "GrafanaPromQL=PASS dashboard=obs-10-traefik-traffic panels=7 queries=8 datasource=prometheus target_up=1 labels=inventory"

post_scope=$(scope_snapshot)
post_traefik_pod_uid=$(awk -F= '$1 == "TRAEFIK_POD_UID" {print $2}' <<<"${post_scope}")
post_grafana_pod_uid=$(awk -F= '$1 == "GRAFANA_POD_UID" {print $2}' <<<"${post_scope}")
post_service_count=$(awk -F= '$1 == "OBS_SERVICE_COUNT" {print $2}' <<<"${post_scope}")
post_servicemonitor_count=$(awk -F= '$1 == "OBS_SERVICEMONITOR_COUNT" {print $2}' <<<"${post_scope}")
post_networkpolicy_count=$(awk -F= '$1 == "OBS_NETWORKPOLICY_COUNT" {print $2}' <<<"${post_scope}")
post_pvc_count=$(awk -F= '$1 == "OBS_PVC_COUNT" {print $2}' <<<"${post_scope}")
post_secret_count=$(awk -F= '$1 == "OBS_SECRET_COUNT" {print $2}' <<<"${post_scope}")
post_ingress_count=$(awk -F= '$1 == "OBS_INGRESS_COUNT" {print $2}' <<<"${post_scope}")
[[ ${post_traefik_pod_uid} == "${pre_traefik_pod_uid}" && ${post_grafana_pod_uid} == "${pre_grafana_pod_uid}" ]] \
  || fail scope 'Traefik 또는 Grafana Pod가 재기동됐다.'
[[ ${post_service_count} == "${pre_service_count}" && ${post_servicemonitor_count} == "${pre_servicemonitor_count}" &&
   ${post_networkpolicy_count} == "${pre_networkpolicy_count}" && ${post_pvc_count} == "${pre_pvc_count}" &&
   ${post_secret_count} == "${pre_secret_count}" && ${post_ingress_count} == "${pre_ingress_count}" ]] \
  || fail scope 'OBS Service/ServiceMonitor/NetworkPolicy/PVC/Secret/Ingress object 수가 바뀌었다.'
printf 'Scope=PASS traefik_uid=%s grafana_uid=%s services=%s servicemonitors=%s networkpolicies=%s pvcs=%s secrets=%s ingresses=%s\n' \
  "${post_traefik_pod_uid}" "${post_grafana_pod_uid}" "${post_service_count}" "${post_servicemonitor_count}" \
  "${post_networkpolicy_count}" "${post_pvc_count}" "${post_secret_count}" "${post_ingress_count}"
echo 'OBS10_VERIFY=PASS'
