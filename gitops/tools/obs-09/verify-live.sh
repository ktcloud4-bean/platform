#!/usr/bin/env bash
# OBS-09의 비민감 Kubernetes inventory 수집과 Grafana drill-down만 판정한다.
set -Eeuo pipefail

readonly mode=${1:-verify}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
readonly expected_resources='nodes,persistentvolumeclaims,persistentvolumes,pods,namespaces,deployments,daemonsets,statefulsets,replicasets,jobs,cronjobs,services,endpoints,ingresses,horizontalpodautoscalers,networkpolicies,resourcequotas'
umask 077
readonly ssh_control_dir=$(mktemp -d "${TMPDIR:-/tmp}/obs-09-ssh.XXXXXX")
readonly ssh_control_path="${ssh_control_dir}/control"
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o ControlMaster=auto
  -o ControlPersist=60s
  -o "ControlPath=${ssh_control_path}"
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

[[ ${mode} == capacity-pre || ${mode} == verify ]] || {
  echo 'usage: verify-live.sh [capacity-pre|verify]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'OBS-09 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "OBS-09 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

cleanup_ssh() {
  timeout 5s ssh "${ssh_options[@]}" -O exit "${k3s_host}" >/dev/null 2>&1 || true
  rmdir "${ssh_control_dir}" >/dev/null 2>&1 || true
}
trap cleanup_ssh EXIT

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

prom_scalar() {
  prom_query "$1" | jq -er '
    if .status == "success" and (.data.result | length) == 1 and
       (.data.result[0].value[1] | type) == "string" then .data.result[0].value[1]
    else error("single scalar result required") end
  '
}

grafana_dashboard() {
  # $()은 Grafana Pod의 sh에서만 확장한다. ssh 인수로 넘기면 k3s host에서 확장될 수 있다.
  timeout 30s ssh "${ssh_options[@]}" "${k3s_host}" 'bash -se' <<'REMOTE'
timeout 20s sudo -n /usr/local/bin/k3s kubectl -n obs exec deploy/obs-grafana -c grafana -- sh -ec 'curl --max-time 15 --fail --silent --show-error -u "admin:$(cat /vault/secrets/admin-password)" http://127.0.0.1:3000/api/dashboards/uid/obs-09-kubernetes-global'
REMOTE
}

dashboard_matches() {
  jq -e '
    ([.dashboard.panels[]? | (.targets // [])[]? | .expr // ""] | join("\n")) as $queries |
    ([.dashboard.panels[]? | select(.id == 52) | (.targets // [])[]?.expr] | join("\n")) as $inventory |
    (.dashboard.uid == "obs-09-kubernetes-global" and
     .dashboard.title == "Kubernetes / Views / Global" and
     .dashboard.editable == false and
     .dashboard.schemaVersion == 41 and
     ([.dashboard.templating.list[]? | .name] | sort == ["job", "resolution"]) and
     ([.. | objects | select((.datasource? | type) == "object") | .datasource.uid] | all(.[]; . == "prometheus")) and
     ((.dashboard | tostring) | test("\\$\\{datasource\\}|\\$cluster|kube_secret_|kube_configmap_") | not) and
     ($queries | contains("kube_deployment_")) and
     ($queries | contains("kube_networkpolicy_")) and
     ($inventory | contains("kube_namespace_created")) and
     ($inventory | contains("kube_horizontalpodautoscaler_info")) and
     ($inventory | contains("kube_resourcequota_created")))
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

object_count() {
  remote_kubectl -n obs get "$1" -o json | jq -er '.items | length'
}

measure_capacity() {
  local head_series prometheus_working_set ksm_working_set node_capacity retention_state
  head_series=$(prom_scalar 'prometheus_tsdb_head_series') || fail capacity 'Prometheus head series를 읽지 못했다.'
  prometheus_working_set=$(pod_working_set_bytes 'app.kubernetes.io/name=prometheus')
  ksm_working_set=$(pod_working_set_bytes 'app.kubernetes.io/name=kube-state-metrics')
  node_capacity=$(ssh "${ssh_options[@]}" "${k3s_host}" bash -s <<'REMOTE'
free -b | awk '/Mem:/{print "AVAILABLE_BYTES=" $7} /Swap:/{print "SWAP_USED_BYTES=" $3}'
REMOTE
) || fail capacity 'k3s RAM/swap을 읽지 못했다.'
  retention_state=$(remote_kubectl -n obs get prometheus obs-prometheus -o json | jq -er '
    select(.spec.retention == "3d" and .spec.retentionSize == "6GiB" and
           .spec.storage.volumeClaimTemplate.spec.resources.requests.storage == "8Gi") |
    "PROMETHEUS_RETENTION=" + .spec.retention + "\nPROMETHEUS_RETENTION_SIZE=" + .spec.retentionSize + "\nPROMETHEUS_PVC=" + .spec.storage.volumeClaimTemplate.spec.resources.requests.storage
  ') || fail capacity 'Prometheus retention 3d/6GiB 또는 PVC 8Gi 선언이 다르다.'
  printf 'HEAD_SERIES=%s\nPROMETHEUS_WORKING_SET=%s\nKSM_WORKING_SET=%s\n%s\n%s\nOBS_SERVICE_COUNT=%s\nOBS_NETWORKPOLICY_COUNT=%s\nOBS_PVC_COUNT=%s\nOBS_SECRET_COUNT=%s\n' \
    "${head_series}" "${prometheus_working_set}" "${ksm_working_set}" "${node_capacity}" "${retention_state}" \
    "$(object_count services)" "$(object_count networkpolicies.networking.k8s.io)" \
    "$(object_count persistentvolumeclaims)" "$(object_count secrets)"
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
  printf '%s\nOBS09_CAPACITY_PRE=PASS\n' "${capacity}"
  exit 0
fi

readonly expected_config_revision=${OBS09_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS09_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}
readonly pre_head_series=${OBS09_PRE_HEAD_SERIES:?배포 전 head series가 필요하다}
readonly pre_available_bytes=${OBS09_PRE_AVAILABLE_BYTES:?배포 전 available RAM이 필요하다}
readonly pre_prometheus_working_set=${OBS09_PRE_PROMETHEUS_WORKING_SET:?배포 전 Prometheus working set이 필요하다}
readonly pre_ksm_working_set=${OBS09_PRE_KSM_WORKING_SET:?배포 전 kube-state-metrics working set이 필요하다}
readonly pre_service_count=${OBS09_PRE_SERVICE_COUNT:?배포 전 obs Service 수가 필요하다}
readonly pre_networkpolicy_count=${OBS09_PRE_NETWORKPOLICY_COUNT:?배포 전 obs NetworkPolicy 수가 필요하다}
readonly pre_pvc_count=${OBS09_PRE_PVC_COUNT:?배포 전 obs PVC 수가 필요하다}
readonly pre_secret_count=${OBS09_PRE_SECRET_COUNT:?배포 전 obs Secret 수가 필요하다}

[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail preflight 'immutable SHA 형식이 아니다.'
[[ ${pre_head_series} =~ ^[0-9]+([.][0-9]+)?$ && ${pre_available_bytes} =~ ^[0-9]+$ &&
   ${pre_prometheus_working_set} =~ ^[0-9]+([.][0-9]+)?$ && ${pre_ksm_working_set} =~ ^[0-9]+([.][0-9]+)?$ &&
   ${pre_service_count} =~ ^[0-9]+$ && ${pre_networkpolicy_count} =~ ^[0-9]+$ &&
   ${pre_pvc_count} =~ ^[0-9]+$ && ${pre_secret_count} =~ ^[0-9]+$ ]] \
  || fail preflight '배포 전 측정값 형식이 올바르지 않다.'

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

remote_kubectl -n obs rollout status deployment/obs-kube-state-metrics --timeout=180s >/dev/null \
  || fail ksm 'kube-state-metrics가 Ready가 아니다.'
remote_kubectl -n obs rollout status deployment/obs-grafana --timeout=180s >/dev/null \
  || fail grafana 'Grafana가 Ready가 아니다.'
remote_kubectl -n obs get deployment obs-kube-state-metrics -o json | jq -e --arg resources "${expected_resources}" '
  [.spec.template.spec.containers[] | select(.name == "kube-state-metrics") | .args[] | select(startswith("--resources="))] == ["--resources=" + $resources]
' >/dev/null || fail ksm 'kube-state-metrics 비민감 collector 목록이 정확히 일치하지 않는다.'

target_state=''
for _ in $(seq 1 36); do
  target_state=$(prom_raw '/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/targets' 2>/dev/null || true)
  if [[ -n ${target_state} ]] && jq -e '[.data.activeTargets[] | select(.labels.namespace == "obs" and .labels.service == "obs-kube-state-metrics" and .health == "up")] | length == 1' \
    <<<"${target_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if [[ -z ${target_state} ]] || ! jq -e '[.data.activeTargets[] | select(.labels.namespace == "obs" and .labels.service == "obs-kube-state-metrics" and .health == "up")] | length == 1' \
  <<<"${target_state}" >/dev/null; then
  fail scrape 'obs-kube-state-metrics target up=1 한 건이 아니다.'
fi

declare -A resource_metrics=(
  [namespace]=kube_namespace_created
  [deployment]=kube_deployment_created
  [daemonset]=kube_daemonset_created
  [statefulset]=kube_statefulset_created
  [replicaset]=kube_replicaset_created
  [job]=kube_job_info
  [cronjob]=kube_cronjob_info
  [service]=kube_service_info
  [endpoint]=kube_endpoint_info
  [ingress]=kube_ingress_info
  [hpa]=kube_horizontalpodautoscaler_info
  [networkpolicy]=kube_networkpolicy_created
  [resourcequota]=kube_resourcequota_created
)
declare -A resource_objects=(
  [namespace]=namespaces
  [deployment]=deployments.apps
  [daemonset]=daemonsets.apps
  [statefulset]=statefulsets.apps
  [replicaset]=replicasets.apps
  [job]=jobs.batch
  [cronjob]=cronjobs.batch
  [service]=services
  [endpoint]=endpoints
  [ingress]=ingresses.networking.k8s.io
  [hpa]=horizontalpodautoscalers.autoscaling
  [networkpolicy]=networkpolicies.networking.k8s.io
  [resourcequota]=resourcequotas
)
metric_summary=()
metric_names=()
for resource in "${!resource_metrics[@]}"; do
  metric=${resource_metrics[${resource}]}
  object_total=$(remote_kubectl get "${resource_objects[${resource}]}" --all-namespaces -o json | jq -er '.items | length') \
    || fail metric "${resource} 객체 수를 읽지 못했다."
  if (( object_total == 0 )); then
    metric_summary+=("${resource}=objects-0")
    continue
  fi
  metric_names+=("${metric}")
done
metric_regex=$(IFS='|'; echo "${metric_names[*]}")
metric_counts=$(prom_query "count by (__name__) ({__name__=~\"${metric_regex}\"})") \
  || fail metric '비민감 resource 대표 series 집계 질의를 읽지 못했다.'
for resource in "${!resource_metrics[@]}"; do
  metric=${resource_metrics[${resource}]}
  if [[ " ${metric_names[*]} " != *" ${metric} "* ]]; then
    continue
  fi
  count=$(jq -er --arg metric "${metric}" '
    [.data.result[] | select(.metric.__name__ == $metric) | .value[1]] |
    if length == 1 and (.[0] | tonumber > 0) then .[0] else error("positive series count required") end
  ' <<<"${metric_counts}") || fail metric "${metric}가 0건이거나 집계 결과가 없다."
  metric_summary+=("${resource}=${count}")
done
ksm_pod=$(remote_kubectl -n obs get pod -l app.kubernetes.io/name=kube-state-metrics -o jsonpath='{.items[0].metadata.name}')
ksm_metrics=$(remote_kubectl -n obs get --raw "/api/v1/namespaces/obs/pods/${ksm_pod}:8080/proxy/metrics") \
  || fail metric 'kube-state-metrics raw metrics를 읽지 못했다.'
if grep -Eq '^kube_(secret|configmap)_' <<<"${ksm_metrics}"; then
  fail metric 'Secret 또는 ConfigMap metric family가 kube-state-metrics에 노출된다.'
fi
echo "Metric=PASS ${metric_summary[*]} sensitive-collectors=absent"

dashboard=''
for _ in $(seq 1 36); do
  dashboard=$(grafana_dashboard 2>/dev/null || true)
  if [[ -n ${dashboard} ]] && dashboard_matches <<<"${dashboard}" 2>/dev/null; then
    break
  fi
  sleep 5
done
dashboard_matches <<<"${dashboard}" || fail grafana 'OBS-09 dashboard UID·변수·datasource·비민감 query 정규화가 일치하지 않는다.'
echo 'Grafana=PASS uid=obs-09-kubernetes-global editable=false datasource=prometheus drill-down=displayed'

post_capacity=$(measure_capacity)
capacity_gate POST "${post_capacity}"
post_head_series=$(awk -F= '$1 == "HEAD_SERIES" {print $2}' <<<"${post_capacity}")
post_available_bytes=$(awk -F= '$1 == "AVAILABLE_BYTES" {print $2}' <<<"${post_capacity}")
post_prometheus_working_set=$(awk -F= '$1 == "PROMETHEUS_WORKING_SET" {print $2}' <<<"${post_capacity}")
post_ksm_working_set=$(awk -F= '$1 == "KSM_WORKING_SET" {print $2}' <<<"${post_capacity}")
for resource in OBS_SERVICE_COUNT OBS_NETWORKPOLICY_COUNT OBS_PVC_COUNT OBS_SECRET_COUNT; do
  after=$(awk -F= -v key="${resource}" '$1 == key {print $2}' <<<"${post_capacity}")
  expected_var="OBS09_PRE_${resource#OBS_}"
  [[ ${after} == "${!expected_var}" ]] || fail scope "${resource}가 배포 전후 달라졌다."
done
printf 'Capacity=PASS PRE_HEAD_SERIES=%s POST_HEAD_SERIES=%s PRE_AVAILABLE_BYTES=%s POST_AVAILABLE_BYTES=%s PRE_PROMETHEUS_WORKING_SET=%s POST_PROMETHEUS_WORKING_SET=%s PRE_KSM_WORKING_SET=%s POST_KSM_WORKING_SET=%s retention=3d/6GiB scope=unchanged\n' \
  "${pre_head_series}" "${post_head_series}" "${pre_available_bytes}" "${post_available_bytes}" \
  "${pre_prometheus_working_set}" "${post_prometheus_working_set}" "${pre_ksm_working_set}" "${post_ksm_working_set}"
echo 'OBS09_VERIFY=PASS'
