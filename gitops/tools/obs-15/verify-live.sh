#!/usr/bin/env bash
set -euo pipefail

readonly K3S_HOST=${OBS15_K3S_SSH:-rocky@10.10.20.10}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly target_args=(
  -o BatchMode=yes
  -o ConnectTimeout=6
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  echo "OBS-15 검증 실패: $*" >&2
  exit 1
}

remote() {
  # shellcheck disable=SC2029 # 인자는 k3s-01에서만 확장해야 한다.
  ssh "${target_args[@]}" "${K3S_HOST}" "$@"
}

remote_kubectl() {
  remote "sudo -n /usr/local/bin/k3s kubectl $*"
}

prom_query() {
  local expression=$1
  remote "PROM=\$(sudo -n /usr/local/bin/k3s kubectl get svc -n obs obs-prometheus -o jsonpath={.spec.clusterIP}); curl --fail --silent --show-error --max-time 15 --data-urlencode 'query=${expression}' \"http://\${PROM}:9090/api/v1/query\""
}

readonly expected_config_revision=${OBS15_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS15_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || fail '인증된 k3s known_hosts 파일이 없다.'
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail 'immutable SHA 형식이 아니다.'

echo '== Argo immutable revision =='
argo_state=''
for _ in $(seq 1 36); do
  argo_state=$(remote_kubectl 'get applications.argoproj.io -n argocd platform-root obs -o json' 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg config "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $obs_app.spec.source.targetRevision == $config and
    $obs_app.status.sync.revision == $config and
    $obs_app.status.sync.status == "Synced" and
    $obs_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${expected_root_revision}" --arg config "${expected_config_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
  $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $config and $obs_app.status.sync.revision == $config and
  $obs_app.status.sync.status == "Synced" and $obs_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || fail 'platform-root 또는 obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

echo '== postgres_exporter target up=1 =='
target_json=''
for _ in $(seq 1 36); do
  target_json=$(prom_query 'up{job="postgres-exporter",instance="postgres-01.imcherry5778.xyz"}' 2>/dev/null || true)
  if jq -e '.data.result | length == 1 and .[0].value[1] == "1"' <<<"${target_json}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
target_count=$(jq '.data.result | length' <<<"${target_json}")
[[ ${target_count} == 1 ]] || fail "postgres-exporter target이 정확히 1건이 아니다: ${target_count}"
target_value=$(jq -r '.data.result[0].value[1]' <<<"${target_json}")
echo "postgres-exporter up=${target_value}"
[[ ${target_value} == 1 ]] || fail 'postgres-exporter target up이 1이 아니다.'

echo '== pg_stat_database_xact_commit 대표 시계열 =='
metric_json=$(prom_query 'count(pg_stat_database_xact_commit{job="postgres-exporter",instance="postgres-01.imcherry5778.xyz"})')
metric_count=$(jq -r '.data.result[0].value[1] // 0' <<<"${metric_json}")
echo "pg_stat_database_xact_commit series=${metric_count}"
[[ ${metric_count} =~ ^[1-9][0-9]*$ ]] || fail 'pg_stat_database_xact_commit 대표 시계열이 없다.'

echo 'ALL PASS'
