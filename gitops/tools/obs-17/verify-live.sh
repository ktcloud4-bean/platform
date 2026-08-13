#!/usr/bin/env bash
# OBS-17의 선언한 세 경보 전제만 immutable SHA에서 한 번 확인한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@10.10.20.10}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly expected_config_revision=${OBS17_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS17_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}
readonly expected_matcher='alertname =~ "NodeDown|RootFilesystemUsageWarning|RootFilesystemUsageCritical|TLSCertificateExpiringSoon|VeleroBackupFailed|NativeMetricsTargetDown|PostgreSQLDatabaseMetricsDown|WarpgateServiceDown|WarpgateACMERenewTimerDown|WarpgateTLSCertificateExpiringSoon"'
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  local stage=$1
  shift
  echo "OBS-17 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

prom_query() {
  local expression=$1 encoded_expression
  # ssh가 remote shell command을 재조합할 때 PromQL의 {}·|·"를 해석하지 않도록 고정한다.
  encoded_expression=$(printf '%s' "${expression}" | base64 -w 0)
  ssh "${ssh_options[@]}" "${k3s_host}" bash -s -- "${encoded_expression}" <<'REMOTE'
set -Eeuo pipefail
expression=$(printf '%s' "$1" | base64 -d)
prometheus_ip=$(sudo -n /usr/local/bin/k3s kubectl -n obs get service obs-prometheus -o jsonpath='{.spec.clusterIP}')
curl --fail --silent --show-error --max-time 15 --data-urlencode "query=${expression}" "http://${prometheus_ip}:9090/api/v1/query"
REMOTE
}

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || fail preflight '인증된 k3s known_hosts 파일이 없다.'
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail preflight 'immutable SHA 형식이 아니다.'

echo '== Argo immutable revision =='
argo_state=''
for _ in $(seq 1 36); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg config "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
    $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
    $obs_app.spec.source.targetRevision == $config and $obs_app.status.sync.revision == $config and
    $obs_app.status.sync.status == "Synced" and $obs_app.status.health.status == "Healthy"
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
' <<<"${argo_state}" >/dev/null || fail deployment 'platform-root 또는 obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

remote_kubectl -n obs rollout status deployment/obs-blackbox --timeout=180s >/dev/null \
  || fail deployment 'blackbox exporter가 Ready가 아니다.'
remote_kubectl -n obs rollout status statefulset/alertmanager-obs-alertmanager --timeout=180s >/dev/null \
  || fail deployment 'Alertmanager가 Ready가 아니다.'

echo '== systemd metric state =='
units=''
for _ in $(seq 1 12); do
  units=$(prom_query 'node_systemd_unit_state{job="node-exporter",instance="10.10.30.10:9100",name=~"warpgate.service|warpgate-acme-renew.timer",state="active"}' 2>/dev/null || true)
  if jq -e '
    .status == "success" and (.data.result | length == 2) and
    ([.data.result[] | select(.value[1] == "1")] | length == 2)
  ' <<<"${units}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e '
  .status == "success" and (.data.result | length == 2) and
  ([.data.result[] | select(.metric.name == "warpgate.service" and .value[1] == "1")] | length == 1) and
  ([.data.result[] | select(.metric.name == "warpgate-acme-renew.timer" and .value[1] == "1")] | length == 1)
' <<<"${units}" >/dev/null || fail systemd 'warpgate.service 또는 warpgate-acme-renew.timer가 active=1이 아니다.'
oneshot=$(prom_query 'node_systemd_unit_state{job="node-exporter",instance="10.10.30.10:9100",name="warpgate-acme-renew.service",state="inactive"}')
jq -e '.status == "success" and (.data.result | length == 1) and .data.result[0].value[1] == "1"' <<<"${oneshot}" >/dev/null \
  || fail systemd 'warpgate-acme-renew.service의 정상 oneshot inactive=1을 확인하지 못했다.'
echo 'Systemd=PASS service=active timer=active oneshot=inactive'

echo '== private TLS probe =='
tls=''
for _ in $(seq 1 12); do
  tls=$(prom_query 'probe_success{service="obs-blackbox",target="warpgate-certificate"}' 2>/dev/null || true)
  if jq -e '.status == "success" and (.data.result | length == 1) and .data.result[0].value[1] == "1"' <<<"${tls}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e '.status == "success" and (.data.result | length == 1) and .data.result[0].value[1] == "1"' <<<"${tls}" >/dev/null \
  || fail tls 'warpgate private SNI probe_success가 1이 아니다.'
expiry=$(prom_query '(probe_ssl_earliest_cert_expiry{service="obs-blackbox",target="warpgate-certificate"} - time()) > bool 14 * 86400')
jq -e '.status == "success" and (.data.result | length == 1) and .data.result[0].value[1] == "1"' <<<"${expiry}" >/dev/null \
  || fail tls 'warpgate TLS 잔여 기간이 14일을 초과하지 않는다.'
echo 'TLS=PASS probe_success=1 expiry_over_14_days=1'

echo '== receiver route and egress =='
if ! ssh "${ssh_options[@]}" "${k3s_host}" bash -s -- "${expected_matcher}" <<'REMOTE'
set -Eeuo pipefail
expected_matcher=$1
k=(sudo -n /usr/local/bin/k3s kubectl)
pod=$("${k[@]}" -n obs get pod -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}')
[[ ${pod} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
"${k[@]}" -n obs exec "${pod}" -- grep -F -- "${expected_matcher}" /etc/alertmanager/config_out/alertmanager.env.yaml >/dev/null
REMOTE
then
  fail route 'runtime Alertmanager matcher가 OBS-17 세 alertname을 정확히 포함하지 않는다.'
fi
policy=$(remote_kubectl -n obs get networkpolicy obs-blackbox-traefik-egress -o json)
jq -e '
  any(.spec.egress[];
    .to == [{"ipBlock":{"cidr":"10.10.30.10/32"}}] and
    .ports == [{"protocol":"TCP","port":8888}]
  )
' <<<"${policy}" >/dev/null || fail networkpolicy 'blackbox의 Warpgate TCP 8888 exact egress가 없다.'
echo 'RouteNetworkPolicy=PASS receiver=obs-13-receiver warpgate_tcp_8888=exact'

echo 'ALL PASS'
