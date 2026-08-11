#!/usr/bin/env bash
# OBS-09-FIX-01의 Kubernetes Global PromQL quote escaping만 판정한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
umask 077
readonly ssh_control_dir=$(mktemp -d "${TMPDIR:-/tmp}/obs-09-fix-01-ssh.XXXXXX")
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

readonly expected_config_revision=${OBS09_FIX01_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS09_FIX01_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'OBS-09-FIX-01 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] || {
  echo 'OBS-09-FIX-01 검증 실패 단계=preflight 원인=immutable SHA 형식이 아니다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "OBS-09-FIX-01 검증 실패 단계=${stage} 원인=$*" >&2
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

prom_query() {
  local encoded
  encoded=$(jq -rn --arg query "$1" '$query | @uri')
  remote_kubectl --request-timeout=15s get --raw \
    "/api/v1/namespaces/obs/services/http:obs-prometheus:9090/proxy/api/v1/query?query=${encoded}&timeout=10s"
}

grafana_dashboard() {
  # $()은 Grafana Pod의 sh에서만 확장한다. ssh 인수로 넘기면 k3s host에서 확장될 수 있다.
  timeout 30s ssh "${ssh_options[@]}" "${k3s_host}" 'bash -se' <<'REMOTE'
timeout 20s sudo -n /usr/local/bin/k3s kubectl -n obs exec deploy/obs-grafana -c grafana -- sh -ec 'curl --max-time 15 --fail --silent --show-error -u "admin:$(cat /vault/secrets/admin-password)" http://127.0.0.1:3000/api/dashboards/uid/obs-09-kubernetes-global'
REMOTE
}

dashboard_queries() {
  jq -er '
    [.dashboard.panels[]? | (.targets // [])[]? | .expr? |
     select(contains("kube_node_status_allocatable"))] | unique |
    if length == 6 then .[] else error("six allocatable queries required") end
  '
}

dashboard_matches() {
  jq -e '
    ([.dashboard.panels[]? | (.targets // [])[]? | .expr? |
      select(contains("kube_node_status_allocatable"))] | unique) as $queries |
    (.dashboard.uid == "obs-09-kubernetes-global" and
     .dashboard.editable == false and
     .dashboard.schemaVersion == 41 and
     ($queries | length == 6) and
     ($queries | all(.[]; contains("\\") | not)) and
     ($queries | all(.[]; contains("resource=\"cpu\"") or contains("resource=\"memory\""))) and
     ($queries | any(.[]; contains("unit=\"core\""))) and
     ($queries | any(.[]; contains("unit=\"byte\""))))
  ' >/dev/null
}

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

dashboard=''
for _ in $(seq 1 36); do
  dashboard=$(grafana_dashboard 2>/dev/null || true)
  if [[ -n ${dashboard} ]] && dashboard_matches <<<"${dashboard}" 2>/dev/null; then
    break
  fi
  sleep 5
done
dashboard_matches <<<"${dashboard}" || fail grafana 'KSM allocatable query의 quote escaping 또는 Grafana read-only provisioning이 일치하지 않는다.'

queries=$(dashboard_queries <<<"${dashboard}") || fail grafana 'KSM allocatable query 여섯 건을 읽지 못했다.'
mapfile -t query_list <<<"${queries}"
(( ${#query_list[@]} == 6 )) || fail grafana 'KSM allocatable query 여섯 건을 읽지 못했다.'
for query in "${query_list[@]}"; do
  prom_query "${query}" | jq -e '.status == "success"' >/dev/null \
    || fail promql 'KSM allocatable query가 Prometheus API에서 parse되지 않는다.'
done
echo 'GrafanaPromQL=PASS dashboard=obs-09-kubernetes-global allocatable_queries=6 literal_backslash=0 prometheus_parse=success'
echo 'OBS09_FIX01_VERIFY=PASS'
