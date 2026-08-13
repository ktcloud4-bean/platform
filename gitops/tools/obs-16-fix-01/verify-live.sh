#!/usr/bin/env bash
# OBS-16-FIX-01: 기존 receiver route와 정확히 같은 alertname의 만료 test alert 한 건만
# Alertmanager에 주입해 firing·수신·자동 resolved를 확인한다. 서비스 장애는 만들지 않는다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@10.10.20.10}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly expected_config_revision=${OBS16_FIX01_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS16_FIX01_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}
readonly test_alertname=NativeMetricsTargetDown
readonly expected_matcher='alertname =~ "NodeDown|RootFilesystemUsageWarning|RootFilesystemUsageCritical|TLSCertificateExpiringSoon|VeleroBackupFailed|NativeMetricsTargetDown|PostgreSQLDatabaseMetricsDown"'
readonly test_ttl_seconds=${OBS16_FIX01_TEST_TTL_SECONDS:-90}
readonly firing_wait_seconds=${OBS16_FIX01_FIRING_WAIT_SECONDS:-75}
readonly resolved_wait_seconds=${OBS16_FIX01_RESOLVED_WAIT_SECONDS:-150}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)
alertmanager_ip=''
receiver_ip=''
test_id=''

fail() {
  local stage=$1
  shift
  echo "OBS-16-FIX-01 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

remote_http_get() {
  ssh "${ssh_options[@]}" "${k3s_host}" curl --fail --silent --show-error --max-time 10 "$1"
}

receiver_metric_count() {
  local status=$1 metrics
  metrics=$(remote_http_get "http://${receiver_ip}:8080/metrics")
  python3 -c '
import sys

alertname, status = sys.argv[1:]
prefix = "obs13_alerts_received_total{alertname=\"%s\",severity=\"critical\",status=\"%s\"} " % (alertname, status)
for line in sys.stdin.read().splitlines():
    if line.startswith(prefix):
        print(int(float(line.removeprefix(prefix))))
        break
else:
    print(0)
' "${test_alertname}" "${status}" <<<"${metrics}"
}

alert_state_matches() {
  local expected_state=$1 response
  response=$(remote_http_get "http://${alertmanager_ip}:9093/api/v2/alerts")
  python3 -c '
import json
import sys

alertname, test_id, expected_state = sys.argv[1:]
try:
    alerts = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
for alert in alerts:
    labels = alert.get("labels", {})
    if (
        labels.get("alertname") == alertname
        and labels.get("test") == "true"
        and labels.get("test_id") == test_id
    ):
        raise SystemExit(0 if alert.get("status", {}).get("state") == expected_state else 1)
raise SystemExit(1)
' "${test_alertname}" "${test_id}" "${expected_state}" <<<"${response}"
}

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] \
  || fail preflight '인증된 k3s known_hosts 파일이 없다.'
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail preflight 'immutable SHA 형식이 아니다.'
[[ ${test_ttl_seconds} =~ ^[0-9]+$ && ${firing_wait_seconds} =~ ^[0-9]+$ && ${resolved_wait_seconds} =~ ^[0-9]+$ ]] \
  || fail preflight '검증 시간은 양의 정수 초여야 한다.'
(( test_ttl_seconds >= 75 && test_ttl_seconds <= 300 )) \
  || fail preflight 'test alert TTL은 75~300초여야 한다.'

echo '== Argo immutable revision =='
argo_state=''
for _ in $(seq 1 36); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
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
  $root_app.spec.source.targetRevision == $root and
  $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $config and
  $obs_app.status.sync.revision == $config and
  $obs_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || fail deployment 'platform-root 또는 obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

echo '== runtime receiver route =='
remote_kubectl -n obs rollout status statefulset/alertmanager-obs-alertmanager --timeout=180s >/dev/null \
  || fail deployment 'Alertmanager가 Ready가 아니다.'
remote_kubectl -n obs rollout status deployment/obs-13-receiver --timeout=180s >/dev/null \
  || fail deployment 'obs-13-receiver가 Ready가 아니다.'
if ! ssh "${ssh_options[@]}" "${k3s_host}" bash -s -- "${expected_matcher}" <<'REMOTE'
set -Eeuo pipefail
expected_matcher=$1
k=(sudo -n /usr/local/bin/k3s kubectl)
pod=$("${k[@]}" -n obs get pod -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}')
[[ ${pod} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
"${k[@]}" -n obs exec "${pod}" -- grep -F -- "${expected_matcher}" /etc/alertmanager/config_out/alertmanager.env.yaml >/dev/null
REMOTE
then
  fail route 'runtime Alertmanager matcher가 기존 5개와 OBS-16 두 alertname을 정확히 포함하지 않는다.'
fi
echo 'RuntimeRoute=PASS receiver=obs-13-receiver alertname=NativeMetricsTargetDown|PostgreSQLDatabaseMetricsDown'

alertmanager_ip=$(remote_kubectl -n obs get service obs-alertmanager -o jsonpath='{.spec.clusterIP}')
receiver_ip=$(remote_kubectl -n obs get service obs-13-receiver -o jsonpath='{.spec.clusterIP}')
[[ ${alertmanager_ip} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && ${receiver_ip} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
  || fail preflight 'Alertmanager 또는 receiver ClusterIP 형식이 아니다.'

echo '== baseline =='
baseline_alerts=$(remote_http_get "http://${alertmanager_ip}:9093/api/v2/alerts")
python3 -c '
import json
import sys

alerts = json.load(sys.stdin)
names = {"NativeMetricsTargetDown", "PostgreSQLDatabaseMetricsDown"}
raise SystemExit(0 if not any(a.get("labels", {}).get("alertname") in names and a.get("status", {}).get("state") == "active" for a in alerts) else 1)
' <<<"${baseline_alerts}" || fail baseline 'OBS-16 native metrics alert가 이미 active다.'
firing_before=$(receiver_metric_count firing)
resolved_before=$(receiver_metric_count resolved)
echo 'Baseline=PASS native_metrics_alerts=0'

test_start_epoch=$(date -u +%s)
test_end_epoch=$((test_start_epoch + test_ttl_seconds))
test_start_iso=$(date -u -d "@${test_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
test_end_iso=$(date -u -d "@${test_end_epoch}" +%Y-%m-%dT%H:%M:%SZ)
test_id="obs16fix${test_start_epoch}${RANDOM}"
payload=$(python3 - "${test_alertname}" "${test_id}" "${test_start_iso}" "${test_end_iso}" <<'PY'
import json
import sys

alertname, test_id, starts_at, ends_at = sys.argv[1:]
print(json.dumps([{
    "labels": {
        "alertname": alertname,
        "severity": "critical",
        "test": "true",
        "test_id": test_id,
    },
    "annotations": {"summary": "OBS-16-FIX-01 만료 test alert"},
    "startsAt": starts_at,
    "endsAt": ends_at,
    "generatorURL": "https://prometheus.imcherry5778.xyz/graph",
}]))
PY
)

echo '== expiring test alert one-shot =='
# shellcheck disable=SC2029 # 검증한 private ClusterIP를 local에서 확장해 remote curl에 전달한다.
printf '%s' "${payload}" \
  | ssh "${ssh_options[@]}" "${k3s_host}" \
    "curl --fail --silent --show-error --max-time 10 -H 'Content-Type: application/json' --data-binary @- 'http://${alertmanager_ip}:9093/api/v2/alerts'" >/dev/null \
  || fail alert 'Alertmanager test alert 주입이 거부됐다.'

firing_deadline=$((test_start_epoch + firing_wait_seconds))
firing_confirmed=false
while (( $(date -u +%s) <= firing_deadline )); do
  if alert_state_matches active; then
    firing_now=$(receiver_metric_count firing)
    if (( firing_now > firing_before )); then
      firing_confirmed=true
      break
    fi
  fi
  sleep 5
done
[[ ${firing_confirmed} == true ]] \
  || fail alert '동일 alertname test=true alert의 active와 obs-13-receiver firing 수신을 확인하지 못했다.'
echo 'FiringReceived=PASS alertname=NativeMetricsTargetDown test=true'

resolved_deadline=$((test_end_epoch + resolved_wait_seconds))
resolved_confirmed=false
while (( $(date -u +%s) <= resolved_deadline )); do
  if ! alert_state_matches active; then
    resolved_now=$(receiver_metric_count resolved)
    if (( resolved_now > resolved_before )); then
      resolved_confirmed=true
      break
    fi
  fi
  sleep 5
done
[[ ${resolved_confirmed} == true ]] \
  || fail alert 'test alert 자동 만료 뒤 Alertmanager 종료와 obs-13-receiver resolved 수신을 확인하지 못했다.'
echo 'AutoResolved=PASS alertname=NativeMetricsTargetDown receiver=resolved'
echo 'OBS16_FIX01_VERIFY=PASS'
