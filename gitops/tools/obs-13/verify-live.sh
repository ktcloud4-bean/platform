#!/usr/bin/env bash
# OBS-13: 상시 alert rule 4종(5개 alertname)과 실제 채널(obs-13-receiver) 검증.
#
# capacity-pre: 배포 직전 기준값을 측정해 PRE_* 로 출력한다.
# verify: immutable Argo revision·workload Ready·배포 후 capacity·baseline 0 firing을
#   확인한 뒤, 실제 조건 5건을 동시에 유발해 firing→Alertmanager active→obs-13-receiver
#   수신까지 한 번씩 실증하고, cleanup 뒤 다시 0 firing으로 돌아오는지 확인한다.
#
# 실제 조건:
#   NodeDown              — netbird-01 node_exporter systemd 정지(5분 이상)
#   RootFilesystemUsage*  — 실측 root 사용률(수 %대)이 넘도록 임계값만 낮춘 별도
#                            임시 PrometheusRule(obs-13-verify-thresholds, git 밖 ad-hoc
#                            객체라 Argo prune/selfHeal 대상이 아님)을 같은 alertname으로
#                            병행 선언한다. 실제 선언 rule(85/95%)은 건드리지 않는다.
#   TLSCertificateExpiringSoon — 실측 잔여일(수십 일)이 넘도록 cutoff만 늘린 같은 임시
#                            PrometheusRule.
#   VeleroBackupFailed    — 존재하지 않는 namespace selector로 안전한 PartiallyFailed
#                            Backup을 1건 만들어 velero_backup_partial_failure_total을
#                            늘린다(완전 실패는 운영 backup 경로를 직접 건드려야 해서
#                            범위 밖; rule 자체가 partial failure도 포함하도록 이미
#                            넓혀뒀다).
set -euo pipefail

readonly mode=${1:-verify}
readonly k3s_host=${OBS13_K3S_SSH:-rocky@10.10.20.10}
readonly verify_target_host=${OBS13_VERIFY_TARGET_SSH:-rocky@10.10.40.10}
readonly known_hosts=${OBS13_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/kubectl}
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
readonly observation_seconds=${OBS13_OBSERVATION_SECONDS:-900}
readonly resolve_seconds=${OBS13_RESOLVE_SECONDS:-180}
readonly velero_test_backup=obs-13-verify-backup
readonly verify_rule_name=obs-13-verify-thresholds
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
  echo '검증 실패 단계=capacity 원인=인증된 known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote() {
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" "$@"
}

remote_target() {
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${verify_target_host}" "$@"
}

remote_kubectl() {
  remote "${kubectl_command} $*"
}

measure_capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<REMOTE
set -euo pipefail
k='${kubectl_command}'
available_bytes=\$(free -b | awk '/Mem:/{print \$7}')
swap_used_bytes=\$(free -b | awk '/Swap:/{print \$3}')
read -r root_size_bytes root_available_bytes < <(df -B1 --output=size,avail / | awk 'NR==2{print \$1,\$2}')
root_free_percent=\$((root_available_bytes * 100 / root_size_bytes))
pvc_request_bytes=\$(
  \${k} get pvc -A -o json \
    | python3 -c "
import json,sys
data=json.load(sys.stdin)
def to_bytes(q):
    units={'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4}
    for suf,mul in units.items():
        if q.endswith(suf):
            return int(float(q[:-len(suf)])*mul)
    return int(q)
print(sum(to_bytes(i['spec']['resources']['requests']['storage']) for i in data['items']))
"
)
prom_ip=\$(\${k} get svc -n obs obs-prometheus -o jsonpath='{.spec.clusterIP}')
head_series=\$(curl -s "http://\${prom_ip}:9090/metrics" | awk '/^prometheus_tsdb_head_series /{print \$2}')
printf 'AVAILABLE_BYTES=%s\nSWAP_USED_BYTES=%s\nROOT_SIZE_BYTES=%s\nROOT_AVAILABLE_BYTES=%s\nROOT_FREE_PERCENT=%s\nPVC_REQUEST_BYTES=%s\nHEAD_SERIES=%s\n' \
  "\${available_bytes}" "\${swap_used_bytes}" "\${root_size_bytes}" "\${root_available_bytes}" \
  "\${root_free_percent}" "\${pvc_request_bytes}" "\${head_series}"
REMOTE
}

capacity_gate() {
  local prefix=$1 capacity=$2
  local available_bytes swap_used_bytes root_free_percent
  available_bytes=$(awk -F= '$1=="AVAILABLE_BYTES"{print $2}' <<<"${capacity}")
  swap_used_bytes=$(awk -F= '$1=="SWAP_USED_BYTES"{print $2}' <<<"${capacity}")
  root_free_percent=$(awk -F= '$1=="ROOT_FREE_PERCENT"{print $2}' <<<"${capacity}")
  [[ ${available_bytes} =~ ^[0-9]+$ && ${swap_used_bytes} =~ ^[0-9]+$ && ${root_free_percent} =~ ^[0-9]+$ ]] \
    || fail capacity "${prefix} guest disk/RAM 측정값을 읽지 못했다."
  (( available_bytes >= available_stop_bytes )) || fail capacity "${prefix} k3s-01 available RAM이 8 GiB 정지선 아래다."
  (( swap_used_bytes == 0 )) || fail capacity "${prefix} k3s-01 swap 사용량이 0이 아니다."
  (( root_free_percent >= 20 )) || fail capacity "${prefix} k3s-01 guest disk 여유가 20% 정지선 아래다."
}

if [[ ${mode} == capacity-pre ]]; then
  capacity=$(measure_capacity)
  capacity_gate PRE "${capacity}"
  printf '%s\n' "${capacity}" | sed 's/^/PRE_/'
  echo 'CAPACITY_PRE=PASS'
  exit 0
fi

readonly expected_config_revision=${OBS13_EXPECTED_CONFIG_REVISION:?obs child 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS13_EXPECTED_ROOT_REVISION:?platform-root pointer commit SHA가 필요하다}
readonly pre_available_bytes=${OBS13_PRE_AVAILABLE_BYTES:?배포 전 available bytes가 필요하다}
readonly pre_root_free_percent=${OBS13_PRE_ROOT_FREE_PERCENT:?배포 전 guest disk 여유율이 필요하다}
readonly pre_pvc_request_bytes=${OBS13_PRE_PVC_REQUEST_BYTES:?배포 전 PVC 합계가 필요하다}
readonly pre_head_series=${OBS13_PRE_HEAD_SERIES:?배포 전 head series가 필요하다}
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail deployment 'immutable commit SHA 형식이 아니다.'

echo '== Argo Synced/Healthy =='
argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
  if python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
root=[a for a in d['items'] if a['metadata']['name']=='platform-root'][0]
obs=[a for a in d['items'] if a['metadata']['name']=='obs'][0]
ok = (
    root['spec']['source']['targetRevision']=='${expected_root_revision}'
    and root['status']['sync']['revision']=='${expected_root_revision}'
    and root['status']['sync']['status']=='Synced'
    and root['status']['health']['status']=='Healthy'
    and obs['spec']['source']['targetRevision']=='${expected_config_revision}'
    and obs['status']['sync']['revision']=='${expected_config_revision}'
    and obs['status']['sync']['status']=='Synced'
    and obs['status']['health']['status']=='Healthy'
)
sys.exit(0 if ok else 1)
" <<<"${argo_state}"; then
    break
  fi
  sleep 5
done
python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
root=[a for a in d['items'] if a['metadata']['name']=='platform-root'][0]
obs=[a for a in d['items'] if a['metadata']['name']=='obs'][0]
ok = (
    root['spec']['source']['targetRevision']=='${expected_root_revision}'
    and root['status']['sync']['revision']=='${expected_root_revision}'
    and root['status']['sync']['status']=='Synced'
    and root['status']['health']['status']=='Healthy'
    and obs['spec']['source']['targetRevision']=='${expected_config_revision}'
    and obs['status']['sync']['revision']=='${expected_config_revision}'
    and obs['status']['sync']['status']=='Synced'
    and obs['status']['health']['status']=='Healthy'
)
sys.exit(0 if ok else 1)
" <<<"${argo_state}" || fail deployment 'platform-root 또는 obs child가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

echo '== workload Ready =='
for workload in \
  deployment/obs-operator \
  deployment/obs-kube-state-metrics \
  deployment/obs-grafana \
  deployment/obs-blackbox \
  deployment/obs-13-receiver \
  daemonset/obs-prometheus-node-exporter \
  statefulset/prometheus-obs-prometheus \
  statefulset/alertmanager-obs-alertmanager
do
  remote_kubectl -n obs rollout status "${workload}" --timeout=180s >/dev/null \
    || fail deployment "${workload}가 Ready가 아니다."
done
echo 'Workloads=PASS'

echo '== 배포 후 capacity =='
capacity=$(measure_capacity)
capacity_gate POST "${capacity}"
post_available_bytes=$(awk -F= '$1=="AVAILABLE_BYTES"{print $2}' <<<"${capacity}")
post_root_free_percent=$(awk -F= '$1=="ROOT_FREE_PERCENT"{print $2}' <<<"${capacity}")
post_pvc_request_bytes=$(awk -F= '$1=="PVC_REQUEST_BYTES"{print $2}' <<<"${capacity}")
post_head_series=$(awk -F= '$1=="HEAD_SERIES"{print $2}' <<<"${capacity}")
[[ ${post_pvc_request_bytes} == "${pre_pvc_request_bytes}" ]] \
  || fail capacity "OBS-13은 새 PVC를 선언하지 않는데 배포 전후 PVC 합계가 달라졌다: ${pre_pvc_request_bytes} -> ${post_pvc_request_bytes}"
echo "Capacity=PASS PRE_AVAILABLE_BYTES=${pre_available_bytes} POST_AVAILABLE_BYTES=${post_available_bytes} DELTA_BYTES=$((post_available_bytes - pre_available_bytes)) PRE_ROOT_FREE_PERCENT=${pre_root_free_percent} POST_ROOT_FREE_PERCENT=${post_root_free_percent} PVC_REQUEST_BYTES=${post_pvc_request_bytes}(불변) PRE_HEAD_SERIES=${pre_head_series} POST_HEAD_SERIES=${post_head_series}"

prom_forward_port=${OBS13_PROM_FORWARD_PORT:-19190}
alert_forward_port=${OBS13_ALERT_FORWARD_PORT:-19193}
socket_dir=$(mktemp -d /tmp/obs-13-forward.XXXXXX)
socket_path=${socket_dir}/control
node_exporter_stopped=false
verify_rule_applied=false
velero_backup_created=false
cleanup_done=false
cleanup() {
  if [[ ${cleanup_done} == false ]]; then
    if [[ ${node_exporter_stopped} == true ]]; then
      remote_target 'sudo systemctl start node_exporter' >/dev/null 2>&1 || true
    fi
    if [[ ${verify_rule_applied} == true ]]; then
      remote_kubectl -n obs delete "prometheusrule/${verify_rule_name}" --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
    fi
    if [[ ${velero_backup_created} == true ]]; then
      remote_kubectl -n velero delete "backup/${velero_test_backup}" --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
    fi
    if [[ -S ${socket_path} ]]; then
      ssh "${ssh_options[@]}" -S "${socket_path}" -O exit "${k3s_host}" >/dev/null 2>&1 || true
    fi
    rmdir "${socket_dir}" 2>/dev/null || true
    cleanup_done=true
  fi
}
trap cleanup EXIT HUP INT TERM

prometheus_ip=$(remote_kubectl -n obs get service obs-prometheus -o jsonpath='{.spec.clusterIP}')
alertmanager_ip=$(remote_kubectl -n obs get service obs-alertmanager -o jsonpath='{.spec.clusterIP}')
[[ ${prometheus_ip} =~ ^[0-9a-fA-F:.]+$ && ${alertmanager_ip} =~ ^[0-9a-fA-F:.]+$ ]] \
  || fail metrics 'Prometheus/Alertmanager ClusterIP를 읽지 못했다.'
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -M -S "${socket_path}" -fNT \
  -L "127.0.0.1:${prom_forward_port}:${prometheus_ip}:9090" \
  -L "127.0.0.1:${alert_forward_port}:${alertmanager_ip}:9093" "${k3s_host}"
prometheus_url="http://127.0.0.1:${prom_forward_port}"
alertmanager_url="http://127.0.0.1:${alert_forward_port}"

for _ in $(seq 1 30); do
  if curl -fsS "${prometheus_url}/-/ready" >/dev/null 2>&1 && curl -fsS "${alertmanager_url}/-/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "${prometheus_url}/-/ready" >/dev/null || fail metrics 'Prometheus API forward가 ready가 아니다.'
curl -fsS "${alertmanager_url}/-/ready" >/dev/null || fail alert 'Alertmanager API forward가 ready가 아니다.'

prom_query() {
  local query=$1 encoded
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${query}")
  curl -fsS "${prometheus_url}/api/v1/query?query=${encoded}"
}

readonly alertnames='NodeDown|RootFilesystemUsageWarning|RootFilesystemUsageCritical|TLSCertificateExpiringSoon|VeleroBackupFailed'

echo '== 신규 target up (첫 scrape 대기, 최대 90s) =='
wait_target_up() {
  local query=$1 min_count=$2 label=$3 ok=false
  for _ in $(seq 1 18); do
    result=$(prom_query "${query}" || true)
    if python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    r=d['data']['result']
    sys.exit(0 if len(r)>=${min_count} and all(v['value'][1]=='1' for v in r) else 1)
except Exception:
    sys.exit(1)
" <<<"${result}"; then
      ok=true
      break
    fi
    sleep 5
  done
  [[ ${ok} == true ]] || fail metrics "${label} target up=1이 되지 않았다."
}
wait_target_up 'up{job="node-exporter-root"}' 1 'node-exporter-root(k3s-01:9101)'
wait_target_up 'up{job="obs-13-receiver"}' 1 'obs-13-receiver'
echo 'NewTargets=PASS node-exporter-root obs-13-receiver'

echo '== 배포 직후 baseline 0 firing =='
result=$(prom_query "ALERTS{alertname=~\"${alertnames}\",alertstate=\"firing\"}")
python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
assert len(d['data']['result'])==0, d['data']['result']
" <<<"${result}" || fail alert '배포 직후인데 OBS-13 alert가 이미 firing 상태다.'
echo 'BaselineZeroFiring=PASS'

echo '== 실제 조건 5건 유발 =='
remote_target 'sudo systemctl stop node_exporter'
node_exporter_stopped=true
echo "NodeDown 조건: ${verify_target_host} node_exporter 정지"

remote_kubectl apply -f - >/dev/null <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ${verify_rule_name}
  namespace: obs
  labels:
    release: obs
    app.kubernetes.io/part-of: obs-13-verification
spec:
  groups:
    - name: ${verify_rule_name}
      rules:
        - alert: RootFilesystemUsageWarning
          expr: >-
            100 * (1 - node_filesystem_avail_bytes{job=~"node-exporter|node-exporter-root",mountpoint="/",fstype!="tmpfs"}
            / node_filesystem_size_bytes{job=~"node-exporter|node-exporter-root",mountpoint="/",fstype!="tmpfs"}) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "OBS-13 verify: 실측 root 사용률이 인위로 낮춘 warning 임계값을 넘는지 실증"
        - alert: RootFilesystemUsageCritical
          expr: >-
            100 * (1 - node_filesystem_avail_bytes{job=~"node-exporter|node-exporter-root",mountpoint="/",fstype!="tmpfs"}
            / node_filesystem_size_bytes{job=~"node-exporter|node-exporter-root",mountpoint="/",fstype!="tmpfs"}) > 1
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "OBS-13 verify: 실측 root 사용률이 인위로 낮춘 critical 임계값을 넘는지 실증"
        - alert: TLSCertificateExpiringSoon
          expr: >-
            (probe_ssl_earliest_cert_expiry{service="obs-blackbox",target="traefik-certificate"} - time()) < 85 * 86400
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "OBS-13 verify: 실측 인증서 잔여일이 인위로 늘린 cutoff를 넘는지 실증"
YAML
verify_rule_applied=true
echo 'RootFilesystemUsage*/TLSCertificateExpiringSoon 조건: 실제 선언 rule은 그대로 두고, 같은 alertname으로 임계값만 인위로 조정한 별도 임시 PrometheusRule 병행 적용'

remote_kubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${velero_test_backup}
  namespace: velero
spec:
  storageLocation: default
  includedNamespaces: ['obs-13-verify-nonexistent-ns']
  ttl: 10m0s
YAML
velero_backup_created=true
echo 'VeleroBackupFailed 조건: 존재하지 않는 namespace selector로 안전한 PartiallyFailed Backup 생성'

echo '== firing -> Alertmanager active -> obs-13-receiver 수신 (최대 '"${observation_seconds}"'s) =='
observation_start_epoch=$(date -u +%s)
observation_start_iso=$(date -u -d "@${observation_start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
observation_deadline_epoch=$((observation_start_epoch + observation_seconds))
declare -A confirmed=()
for name in NodeDown RootFilesystemUsageWarning RootFilesystemUsageCritical TLSCertificateExpiringSoon VeleroBackupFailed; do
  confirmed[${name}]=false
done

while (( $(date -u +%s) <= observation_deadline_epoch )); do
  all_done=true
  for name in "${!confirmed[@]}"; do
    [[ ${confirmed[${name}]} == true ]] && continue
    all_done=false
    prom_result=$(prom_query "ALERTS{alertname=\"${name}\",alertstate=\"firing\"}" || true)
    prom_ok=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    print('1' if len(d['data']['result'])>0 else '0')
except Exception:
    print('0')
" <<<"${prom_result}")
    [[ ${prom_ok} == '1' ]] || continue
    am_result=$(curl -fsS "${alertmanager_url}/api/v2/alerts" || true)
    am_ok=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    print('1' if any(a['labels'].get('alertname')=='${name}' and a['status']['state']=='active' for a in d) else '0')
except Exception:
    print('0')
" <<<"${am_result}")
    [[ ${am_ok} == '1' ]] || continue
    sink_log=$(remote_kubectl -n obs logs "deploy/obs-13-receiver --since-time=${observation_start_iso}" 2>/dev/null || true)
    if grep -q "RECEIVED alertname=${name} .*status=firing" <<<"${sink_log}"; then
      confirmed[${name}]=true
      echo "CONFIRMED alertname=${name} prometheus=firing alertmanager=active receiver=RECEIVED"
    fi
  done
  [[ ${all_done} == true ]] && break
  sleep 10
done

for name in "${!confirmed[@]}"; do
  [[ ${confirmed[${name}]} == true ]] || fail alert "${name}이 관측창 안에 firing->active->receiver 수신까지 완성되지 않았다."
done
echo 'AlertDelivery=PASS NodeDown RootFilesystemUsageWarning RootFilesystemUsageCritical TLSCertificateExpiringSoon VeleroBackupFailed'

echo '== cleanup =='
cleanup
trap - EXIT HUP INT TERM
echo 'InducedConditionCleanup=PASS node_exporter=restarted verify_rule=deleted velero_backup=deleted'

echo '== cleanup 후 0 firing 복귀 =='
resolve_start_epoch=$(date -u +%s)
resolve_deadline_epoch=$((resolve_start_epoch + resolve_seconds))
resolved=false
while (( $(date -u +%s) <= resolve_deadline_epoch )); do
  result=$(prom_query "ALERTS{alertname=~\"${alertnames}\",alertstate=\"firing\"}" || true)
  count=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(len(d['data']['result']))
except Exception:
    print(-1)
" <<<"${result}")
  if [[ ${count} == '0' ]]; then
    resolved=true
    break
  fi
  sleep 10
done
[[ ${resolved} == true ]] || fail alert 'cleanup 후에도 OBS-13 alert가 0 firing으로 돌아오지 않았다.'
echo 'ResolvedAfterCleanup=PASS'

echo 'OBS13_VERIFY=PASS'
