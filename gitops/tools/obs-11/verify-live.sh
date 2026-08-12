#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir

readonly K3S_HOST=${OBS11_K3S_SSH:-rocky@10.10.20.10}
readonly TARGETS_ARGS=(-o BatchMode=yes -o ConnectTimeout=6)

fail() {
  echo "OBS-11 검증 실패: $*" >&2
  exit 1
}

remote() {
  ssh "${TARGETS_ARGS[@]}" "${K3S_HOST}" "$@"
}

remote_kubectl() {
  remote "sudo /usr/local/bin/kubectl $*"
}

prom_query() {
  local expr=$1
  remote "PROM=\$(sudo /usr/local/bin/kubectl get svc -n obs obs-prometheus -o jsonpath={.spec.clusterIP}); curl -s --data-urlencode 'query=${expr}' \"http://\${PROM}:9090/api/v1/query\""
}

echo '== Argo Synced/Healthy =='
for app in platform-root obs; do
  status=$(remote_kubectl "get application -n argocd ${app} -o jsonpath='{.status.sync.status} {.status.health.status}'")
  echo "${app}: ${status}"
  [[ ${status} == "Synced Healthy" ]] || fail "${app}이 Synced/Healthy가 아니다: ${status}"
done

echo '== node-exporter target up=1 (6건) =='
targets_json=$(prom_query 'up{job="node-exporter"}')
count=$(jq '.data.result | length' <<<"${targets_json}")
[[ ${count} == 6 ]] || fail "node-exporter target이 6개가 아니다: ${count}"
jq -r '.data.result[] | "\(.metric.instance) up=\(.value[1])"' <<<"${targets_json}"
jq -e '[.data.result[] | select(.value[1] != "1")] | length == 0' <<<"${targets_json}" >/dev/null \
  || fail 'up이 1이 아닌 node-exporter target이 있다.'

echo '== 대표 시계열 (CPU·메모리·disk·network, 6건) =='
for metric in node_cpu_seconds_total node_memory_MemAvailable_bytes node_disk_io_now node_network_receive_bytes_total; do
  result=$(prom_query "count(${metric}{job=\"node-exporter\"}) by (instance)")
  instances=$(jq '.data.result | length' <<<"${result}")
  [[ ${instances} == 6 ]] || fail "${metric}이 6개 instance에서 나오지 않는다: ${instances}"
done
echo 'PASS: 4개 대표 metric family가 node-exporter target 6개 모두에서 존재한다.'

echo '== filesystem 대표 시계열 (systemd fleet 5건; k3s-01은 기존 DaemonSet의 non-root securityContext로 /proc/1/mountinfo 권한이 없어 이 작업 범위에서 확대하지 않은 기존 한계) =='
result=$(prom_query 'count(node_filesystem_avail_bytes{job="node-exporter"}) by (instance)')
fs_instances=$(jq '.data.result | length' <<<"${result}")
[[ ${fs_instances} == 5 ]] || fail "node_filesystem_avail_bytes가 5개 instance(fleet)에서 나오지 않는다: ${fs_instances}"
jq -e '[.data.result[].metric.instance] | index("10.10.20.10:9100") == null' <<<"${result}" >/dev/null \
  || fail 'k3s-01 filesystem collector 상태가 예상(실패)과 달라졌다 — 재확인 필요.'

echo '== systemd collector (fleet 5대, k3s-01 DaemonSet 제외) =='
result=$(prom_query 'count(node_systemd_units) by (instance)')
instances=$(jq '.data.result | length' <<<"${result}")
[[ ${instances} == 5 ]] || fail "node_systemd_units가 5개 instance에서 나오지 않는다: ${instances}"

echo '== Grafana dashboard (read-only, Platform 폴더) =='
dashboard=$(remote_kubectl "-n obs exec deploy/obs-grafana -c grafana -- sh -ec 'curl --max-time 15 --fail --silent --show-error -u \"admin:\$(cat /vault/secrets/admin-password)\" http://127.0.0.1:3000/api/dashboards/uid/obs-11-node-exporter-full'")
jq -e '.dashboard.uid == "obs-11-node-exporter-full" and .dashboard.editable == false and .meta.folderTitle == "Platform"' <<<"${dashboard}" >/dev/null \
  || fail 'dashboard uid·editable·folder가 계획과 다르다.'
panels=$(jq '.dashboard.panels | length' <<<"${dashboard}")
[[ ${panels} == 31 ]] || fail "dashboard panel 개수가 31이 아니다: ${panels}"
jq -e '[.dashboard.panels[].panels?[]? | select(.id == 313 or .id == 314 or .id == 315)] | length == 0' <<<"${dashboard}" >/dev/null \
  || fail 'processes collector 의존 panel(313·314·315)이 제거되지 않았다.'

echo '== 용량 정지 기준 =='
head_series=$(prom_query 'prometheus_tsdb_head_series')
head_series_value=$(jq -r '.data.result[0].value[1]' <<<"${head_series}")
echo "prometheus_tsdb_head_series=${head_series_value}"

k3s_mem=$(remote 'free -b')
k3s_available=$(awk '/^Mem:/{print $7}' <<<"${k3s_mem}")
k3s_swap=$(awk '/^Swap:/{print $3}' <<<"${k3s_mem}")
echo "k3s-01 available=${k3s_available} swap=${k3s_swap}"
[[ ${k3s_available} -gt 8589934592 ]] || fail 'k3s-01 available RAM이 8 GiB 정지선 미만이다.'
[[ ${k3s_swap} == 0 ]] || fail 'k3s-01 swap이 사용 중이다.'

pve_mem=$(ssh "${TARGETS_ARGS[@]}" root@10.10.10.10 'free -b')
pve_available=$(awk '/^Mem:/{print $7}' <<<"${pve_mem}")
pve_swap=$(awk '/^Swap:/{print $3}' <<<"${pve_mem}")
echo "proxmox-01 available=${pve_available} swap=${pve_swap}"
[[ ${pve_available} -gt 8589934592 ]] || fail 'proxmox-01 available RAM이 8 GiB 정지선 미만이다.'
[[ ${pve_swap} == 0 ]] || fail 'proxmox-01 swap이 사용 중이다.'

pvc_count=$(remote_kubectl "get pvc -n obs --no-headers | wc -l")
[[ ${pvc_count} == 2 ]] || fail "obs namespace PVC 개수가 2(prometheus·alertmanager)가 아니다: ${pvc_count}"

echo 'ALL PASS'
