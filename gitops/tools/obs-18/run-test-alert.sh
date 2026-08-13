#!/usr/bin/env bash
# OBS-18의 승인된 한 번뿐인 [TEST] critical alert를 Alertmanager API에 넣고 자동 만료를 확인한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly allow_test=${OBS18_RUN_TEST:-}
readonly test_ttl_seconds=${OBS18_TEST_TTL_SECONDS:-90}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  echo "OBS-18 test 실패 단계=$1 원인=$2" >&2
  exit 1
}

remote_kubectl() {
  ssh "${ssh_options[@]}" "$k3s_host" sudo -n /usr/local/bin/k3s kubectl "$@"
}

remote_alerts() {
  ssh "${ssh_options[@]}" "$k3s_host" bash -s <<'REMOTE'
set -Eeuo pipefail
ip=$(sudo -n /usr/local/bin/k3s kubectl -n obs get service obs-alertmanager -o jsonpath='{.spec.clusterIP}')
curl --fail --silent --show-error --max-time 10 "http://$ip:9093/api/v2/alerts"
REMOTE
}

[[ $allow_test == 1 ]] || fail preflight 'OBS18_RUN_TEST=1인 승인된 실행만 허용한다.'
[[ -f $known_hosts && ! -L $known_hosts ]] || fail preflight '인증된 k3s known_hosts 파일이 없다.'
[[ $test_ttl_seconds =~ ^[0-9]+$ ]] && (( test_ttl_seconds >= 75 && test_ttl_seconds <= 180 )) || fail preflight 'test TTL은 75~180초여야 한다.'

baseline=$(remote_alerts)
if ! python3 -c '
import json
import sys

allowed = {
    "NodeDown", "RootFilesystemUsageWarning", "RootFilesystemUsageCritical",
    "TLSCertificateExpiringSoon", "VeleroBackupFailed", "NativeMetricsTargetDown",
    "PostgreSQLDatabaseMetricsDown", "WarpgateServiceDown",
    "WarpgateACMERenewTimerDown", "WarpgateTLSCertificateExpiringSoon",
}
active = [
    alert for alert in json.load(sys.stdin)
    if alert.get("labels", {}).get("alertname") in allowed
    and alert.get("status", {}).get("state") == "active"
]
raise SystemExit(0 if not active else 1)
' <<<"$baseline"; then
  fail baseline '허용 alertname 중 이미 active인 경보가 있어 test를 만들지 않는다.'
fi

test_start_epoch=$(date -u +%s)
test_end_epoch=$((test_start_epoch + test_ttl_seconds))
test_start_iso=$(date -u -d "@${test_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
test_end_iso=$(date -u -d "@${test_end_epoch}" +%Y-%m-%dT%H:%M:%SZ)
test_id="obs18${test_start_epoch}${RANDOM}"

test_state() {
  local expected=$1 response
  response=$(remote_alerts)
  python3 -c '
import json
import sys

expected, test_id = sys.argv[1:]
for alert in json.load(sys.stdin):
    labels = alert.get("labels", {})
    if labels.get("test_id") == test_id:
        raise SystemExit(0 if alert.get("status", {}).get("state") == expected else 1)
raise SystemExit(1)
' "$expected" "$test_id" <<<"$response"
}

test_absent() {
  local response
  response=$(remote_alerts)
  python3 -c '
import json
import sys

test_id = sys.argv[1]
raise SystemExit(0 if not any(
    alert.get("labels", {}).get("test_id") == test_id
    for alert in json.load(sys.stdin)
) else 1)
' "$test_id" <<<"$response"
}

receiver_metric_count() {
  local status=$1 metrics
  metrics=$(ssh "${ssh_options[@]}" "$k3s_host" bash -s <<'REMOTE'
set -Eeuo pipefail
ip=$(sudo -n /usr/local/bin/k3s kubectl -n obs get service obs-13-receiver -o jsonpath='{.spec.clusterIP}')
curl --fail --silent --show-error --max-time 10 "http://$ip:8080/metrics"
REMOTE
)
  python3 -c '
import sys

status = sys.argv[1]
prefix = (
    "obs13_alerts_received_total{"
    "alertname=\"NodeDown\",severity=\"critical\",status=\"%s\"} "
    % status
)
for line in sys.stdin:
    if line.startswith(prefix):
        print(int(float(line[len(prefix):].strip())))
        break
else:
    print(0)
' "$status" <<<"$metrics"
}

firing_before=$(receiver_metric_count firing)
resolved_before=$(receiver_metric_count resolved)

payload=$(python3 - "$test_id" "$test_start_iso" "$test_end_iso" <<'PY'
import json
import sys

test_id, starts_at, ends_at = sys.argv[1:]
print(json.dumps([{
    "labels": {
        "alertname": "NodeDown",
        "severity": "critical",
        "instance": "[TEST] obs-18-slack",
        "test": "true",
        "test_id": test_id,
    },
    "startsAt": starts_at,
    "endsAt": ends_at,
    "generatorURL": "https://grafana.imcherry5778.xyz/alerting/list",
}]))
PY
)
alertmanager_ip=$(remote_kubectl -n obs get service obs-alertmanager -o jsonpath='{.spec.clusterIP}')
[[ $alertmanager_ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail preflight 'Alertmanager ClusterIP 형식이 아니다.'
printf '%s' "$payload" \
  | ssh "${ssh_options[@]}" "$k3s_host" \
    "curl --fail --silent --show-error --max-time 10 -H 'Content-Type: application/json' --data-binary @- 'http://$alertmanager_ip:9093/api/v2/alerts'" >/dev/null \
  || fail firing 'Alertmanager test alert 주입이 거부됐다.'
unset payload

for _ in $(seq 1 15); do
  if test_state active && (( $(receiver_metric_count firing) > firing_before )); then
    break
  fi
  sleep 5
done
test_state active && (( $(receiver_metric_count firing) > firing_before )) \
  || fail firing 'test alert가 active 또는 내부 수신기에 나타나지 않았다.'
echo "TestFiring=PASS alertname=NodeDown severity=critical instance=[TEST] obs-18-slack test_id=$test_id"

for _ in $(seq 1 42); do
  if test_absent && (( $(receiver_metric_count resolved) > resolved_before )); then
    break
  fi
  sleep 5
done
test_absent || fail resolve 'test alert가 TTL 뒤 API에서 제거되지 않았다.'
(( $(receiver_metric_count resolved) > resolved_before )) \
  || fail resolve '내부 수신기에 resolved가 도착하기 전에 검증이 끝났다.'
echo "TestResolved=PASS test_id=$test_id receiver=resolved temporary_alert=absent"
echo "SlackManualCheck=REQUIRED test_id=$test_id expected=firing,resolved"
