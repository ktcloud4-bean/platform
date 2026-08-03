#!/usr/bin/env bash
set -euo pipefail

readonly mode=${1:-verify}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly test_image='docker.io/library/python:3.13.7-alpine3.22@sha256:9ba6d8cbebf0fb6546ae71f2a1c14f6ffd2fdab83af7fa5669734ef30ad48844'
readonly obs_pvc_bytes=$((9 * 1024 * 1024 * 1024))
readonly pvc_stop_bytes=$((120 * 1024 * 1024 * 1024))
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
readonly observation_seconds=600
readonly test_namespace=obs-01-test
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
  echo '검증 실패 단계=capacity 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  # 인자는 이 스크립트가 만든 비밀 없는 고정값만 전달한다.
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

measure_capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'REMOTE'
set -euo pipefail
k='sudo -n /usr/local/bin/k3s kubectl'
available_bytes=$(free -b | awk '/Mem:/{print $7}')
swap_used_bytes=$(free -b | awk '/Swap:/{print $3}')
read -r root_size_bytes root_available_bytes < <(df -B1 --output=size,avail / | awk 'NR==2{print $1,$2}')
root_free_percent=$((root_available_bytes * 100 / root_size_bytes))
pvc_request_bytes=$(
  ${k} get pvc -A -o json \
    | jq -r '.items[].spec.resources.requests.storage' \
    | while IFS= read -r quantity; do numfmt --from=iec-i "${quantity}"; done \
    | awk '{sum+=$1} END{printf "%.0f\n",sum+0}'
)
printf 'AVAILABLE_BYTES=%s\nSWAP_USED_BYTES=%s\nROOT_SIZE_BYTES=%s\nROOT_AVAILABLE_BYTES=%s\nROOT_FREE_PERCENT=%s\nPVC_REQUEST_BYTES=%s\n' \
  "${available_bytes}" "${swap_used_bytes}" "${root_size_bytes}" "${root_available_bytes}" \
  "${root_free_percent}" "${pvc_request_bytes}"
REMOTE
}

capacity_gate() {
  local prefix=$1 capacity=$2
  local available_bytes swap_used_bytes root_free_percent pvc_request_bytes
  available_bytes=$(awk -F= '$1=="AVAILABLE_BYTES"{print $2}' <<<"${capacity}")
  swap_used_bytes=$(awk -F= '$1=="SWAP_USED_BYTES"{print $2}' <<<"${capacity}")
  root_free_percent=$(awk -F= '$1=="ROOT_FREE_PERCENT"{print $2}' <<<"${capacity}")
  pvc_request_bytes=$(awk -F= '$1=="PVC_REQUEST_BYTES"{print $2}' <<<"${capacity}")
  [[ ${available_bytes} =~ ^[0-9]+$ && ${swap_used_bytes} =~ ^[0-9]+$ &&
     ${root_free_percent} =~ ^[0-9]+$ && ${pvc_request_bytes} =~ ^[0-9]+$ ]] \
    || fail capacity "${prefix} guest disk/RAM/PVC 측정값을 읽지 못했다."
  (( available_bytes >= available_stop_bytes )) || fail capacity "${prefix} k3s available RAM이 8 GiB 정지선 아래다."
  (( swap_used_bytes == 0 )) || fail capacity "${prefix} k3s swap 사용량이 0이 아니다."
  (( root_free_percent >= 20 )) || fail capacity "${prefix} k3s guest disk 여유가 20% 정지선 아래다."
  (( pvc_request_bytes < pvc_stop_bytes )) || fail capacity "${prefix} PVC 선언 합계가 120 GiB 정지선에 도달했다."
}

if [[ ${mode} == capacity-pre ]]; then
  capacity=$(measure_capacity)
  capacity_gate PRE "${capacity}"
  pvc_request_bytes=$(awk -F= '$1=="PVC_REQUEST_BYTES"{print $2}' <<<"${capacity}")
  projected_pvc_bytes=$((pvc_request_bytes + obs_pvc_bytes))
  (( projected_pvc_bytes < pvc_stop_bytes )) \
    || fail capacity 'OBS-01 9 GiB를 더하면 PVC 120 GiB 정지선에 도달한다.'
  printf '%s\n' "${capacity}" | sed 's/^/PRE_/'
  echo "OBS_DECLARED_PVC_BYTES=${obs_pvc_bytes} PROJECTED_PVC_REQUEST_BYTES=${projected_pvc_bytes}"
  echo 'CAPACITY_PRE=PASS'
  exit 0
fi

readonly expected_config_revision=${OBS01_EXPECTED_CONFIG_REVISION:?OBS 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS01_EXPECTED_ROOT_REVISION:?platform-root pointer commit SHA가 필요하다}
readonly pre_available_bytes=${OBS01_PRE_AVAILABLE_BYTES:?배포 전 available bytes가 필요하다}
readonly pre_root_free_percent=${OBS01_PRE_ROOT_FREE_PERCENT:?배포 전 guest disk 여유율이 필요하다}
readonly pre_pvc_request_bytes=${OBS01_PRE_PVC_REQUEST_BYTES:?배포 전 PVC 합계가 필요하다}
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail deployment 'immutable commit SHA 형식이 아니다.'
[[ ${pre_available_bytes} =~ ^[0-9]+$ && ${pre_root_free_percent} =~ ^[0-9]+$ &&
   ${pre_pvc_request_bytes} =~ ^[0-9]+$ ]] || fail capacity '배포 전 capacity 입력이 정수가 아니다.'

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
  if jq -e \
    --arg root "${expected_root_revision}" \
    --arg config "${expected_config_revision}" '
      ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
      ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs |
      $root_app.spec.source.targetRevision == $root and
      $root_app.status.sync.revision == $root and
      $root_app.status.sync.status == "Synced" and
      $root_app.status.health.status == "Healthy" and
      $obs.spec.source.targetRevision == $config and
      $obs.status.sync.revision == $config and
      $obs.status.sync.status == "Synced" and
      $obs.status.health.status == "Healthy"
    ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e \
  --arg root "${expected_root_revision}" \
  --arg config "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $obs.spec.source.targetRevision == $config and
    $obs.status.sync.revision == $config and
    $obs.status.sync.status == "Synced" and
    $obs.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null \
  || fail deployment 'platform-root 또는 obs child가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

for workload in \
  deployment/obs-operator \
  deployment/obs-kube-state-metrics \
  deployment/obs-grafana \
  deployment/obs-blackbox \
  daemonset/obs-prometheus-node-exporter \
  statefulset/prometheus-obs-prometheus \
  statefulset/alertmanager-obs-alertmanager
do
  remote_kubectl -n obs rollout status "${workload}" --timeout=180s >/dev/null \
    || fail deployment "${workload}가 Ready가 아니다."
done
echo 'Workloads=PASS operator prometheus alertmanager node-exporter kube-state-metrics grafana blackbox'

capacity=$(measure_capacity)
capacity_gate POST "${capacity}"
available_bytes=$(awk -F= '$1=="AVAILABLE_BYTES"{print $2}' <<<"${capacity}")
swap_used_bytes=$(awk -F= '$1=="SWAP_USED_BYTES"{print $2}' <<<"${capacity}")
root_free_percent=$(awk -F= '$1=="ROOT_FREE_PERCENT"{print $2}' <<<"${capacity}")
pvc_request_bytes=$(awk -F= '$1=="PVC_REQUEST_BYTES"{print $2}' <<<"${capacity}")
expected_pvc_bytes=$((pre_pvc_request_bytes + obs_pvc_bytes))
(( pvc_request_bytes == expected_pvc_bytes )) \
  || fail capacity '배포 전후 PVC 선언 합계 차이가 OBS-01 고정 9 GiB와 다르다.'
printf '%s\n' "${capacity}" | sed 's/^/POST_/'
echo "CAPACITY_POST=PASS PRE_AVAILABLE_BYTES=${pre_available_bytes} POST_AVAILABLE_BYTES=${available_bytes} DELTA_BYTES=$((available_bytes - pre_available_bytes)) PRE_ROOT_FREE_PERCENT=${pre_root_free_percent} POST_ROOT_FREE_PERCENT=${root_free_percent} PRE_PVC_REQUEST_BYTES=${pre_pvc_request_bytes} POST_PVC_REQUEST_BYTES=${pvc_request_bytes} OBS_PVC_BYTES=${obs_pvc_bytes} SWAP_USED_BYTES=${swap_used_bytes}"

prom_forward_port=${OBS01_PROM_FORWARD_PORT:-19090}
alert_forward_port=${OBS01_ALERT_FORWARD_PORT:-19093}
socket_dir=$(mktemp -d /tmp/obs-01-forward.XXXXXX)
socket_path=${socket_dir}/control
test_created=false
cleanup_done=false
cleanup() {
  if [[ ${cleanup_done} == false ]]; then
    if [[ ${test_created} == true ]]; then
      remote_kubectl -n obs delete prometheusrule/obs-01-delivery servicemonitor/obs-01-alert-sink \
        --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
      remote_kubectl delete namespace "${test_namespace}" --ignore-not-found=true \
        --wait=true --timeout=60s >/dev/null 2>&1 || true
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
  if curl -fsS "${prometheus_url}/-/ready" >/dev/null 2>&1 && \
     curl -fsS "${alertmanager_url}/-/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "${prometheus_url}/-/ready" >/dev/null \
  || fail metrics 'Prometheus API forward가 ready가 아니다.'
curl -fsS "${alertmanager_url}/-/ready" >/dev/null \
  || fail alert 'Alertmanager API forward가 ready가 아니다.'

flags=$(curl -fsS "${prometheus_url}/api/v1/status/flags")
jq -e '.status == "success" and .data["storage.tsdb.retention.time"] == "3d" and .data["storage.tsdb.retention.size"] == "6GiB"' \
  <<<"${flags}" >/dev/null \
  || fail capacity 'Prometheus running flags의 retention time/size가 3d/6GiB가 아니다.'
echo 'PrometheusRetention=PASS time=3d size=6GiB pvc=8Gi'

prom_query() {
  local query=$1 encoded
  encoded=$(jq -rn --arg value "${query}" '$value|@uri')
  curl -fsS "${prometheus_url}/api/v1/query?query=${encoded}"
}

observation_start_epoch=$(date -u +%s)
observation_deadline_epoch=$((observation_start_epoch + observation_seconds))

assert_query() {
  local evidence=$1 query=$2 result=''
  while (( $(date -u +%s) <= observation_deadline_epoch )); do
    result=$(prom_query "${query}" || true)
    if jq -e '.status == "success" and (.data.result | length) > 0' \
      <<<"${result}" >/dev/null 2>&1; then
      printf '%s=' "${evidence}"
      jq -c '[.data.result[] | {metric: .metric, value: .value[1]}]' <<<"${result}"
      return
    fi
    sleep 5
  done
  fail metrics "10분 고정 관측창에서 ${evidence} query 결과가 없다: ${query}"
}

assert_query NodeTarget 'min(up{service="obs-prometheus-node-exporter"}) == 1'
assert_query NodeSeries 'node_uname_info{service="obs-prometheus-node-exporter"}'
assert_query PVCTarget 'min(up{service="obs-kube-state-metrics"}) == 1'
assert_query PVCSeries 'kube_persistentvolumeclaim_info{service="obs-kube-state-metrics"}'
assert_query BackupTarget 'min(up{namespace="velero",service="velero"}) == 1'
assert_query BackupSeries 'velero_backup_total{namespace="velero",service="velero"}'
assert_query CertTarget 'min(up{service="obs-blackbox"}) == 1'
assert_query CertSuccess 'probe_success{service="obs-blackbox",target="traefik-certificate"} == 1'
assert_query CertExpiry 'probe_ssl_earliest_cert_expiry{service="obs-blackbox",target="traefik-certificate"} > time()'
assert_query LokiTarget 'min(up{namespace="loki",service="loki"}) == 1'
assert_query LokiSeries 'loki_build_info{namespace="loki",service="loki"}'
assert_query AlloyTarget 'min(up{namespace="loki",service="alloy"}) == 1'
assert_query AlloySeries 'alloy_build_info{namespace="loki",service="alloy"}'
echo 'Metrics=PASS node PVC backup certificate Loki Alloy'

if remote_kubectl get namespace "${test_namespace}" >/dev/null 2>&1; then
  fail alert "완료 증거 namespace ${test_namespace}가 이미 존재한다."
fi
test_created=true
remote_kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${test_namespace}
  labels:
    app.kubernetes.io/part-of: obs-01-verification
---
apiVersion: v1
kind: Pod
metadata:
  name: obs-01-alert-sink
  namespace: ${test_namespace}
  labels:
    app.kubernetes.io/name: obs-01-alert-sink
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: sink
      image: ${test_image}
      imagePullPolicy: IfNotPresent
      command: [python3, -u, -c]
      args:
        - |-
          import json
          from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

          class Handler(BaseHTTPRequestHandler):
              def log_message(self, *_):
                  return
              def do_GET(self):
                  if self.path == "/metrics":
                      body = b"# TYPE obs01_verification_trigger gauge\nobs01_verification_trigger 1\n"
                      self.send_response(200)
                      self.send_header("Content-Type", "text/plain; version=0.0.4")
                      self.send_header("Content-Length", str(len(body)))
                      self.end_headers()
                      self.wfile.write(body)
                  else:
                      self.send_response(404)
                      self.end_headers()
              def do_POST(self):
                  length = int(self.headers.get("Content-Length", "0"))
                  payload = json.loads(self.rfile.read(length) or b"{}")
                  for alert in payload.get("alerts", []):
                      if alert.get("labels", {}).get("alertname") == "OBS01Delivery":
                          print("RECEIVED alertname=OBS01Delivery status=" + alert.get("status", "unknown"), flush=True)
                  self.send_response(200)
                  self.end_headers()

          ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      ports:
        - name: http
          containerPort: 8080
      readinessProbe:
        httpGet:
          path: /metrics
          port: http
        periodSeconds: 2
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
      resources:
        requests:
          cpu: 5m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: obs-01-alert-sink
  namespace: ${test_namespace}
  labels:
    app.kubernetes.io/name: obs-01-alert-sink
spec:
  selector:
    app.kubernetes.io/name: obs-01-alert-sink
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: obs-01-alert-sink
  namespace: obs
  labels:
    release: obs
spec:
  namespaceSelector:
    matchNames: [${test_namespace}]
  selector:
    matchLabels:
      app.kubernetes.io/name: obs-01-alert-sink
  endpoints:
    - port: http
      path: /metrics
      interval: 10s
      scrapeTimeout: 5s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: obs-01-delivery
  namespace: obs
  labels:
    release: obs
spec:
  groups:
    - name: obs-01-delivery
      interval: 10s
      rules:
        - alert: OBS01Delivery
          expr: obs01_verification_trigger == 1
          for: 0m
          labels:
            severity: info
          annotations:
            summary: OBS-01 internal receiver verification
YAML
remote_kubectl -n "${test_namespace}" wait --for=condition=Ready pod/obs-01-alert-sink --timeout=90s >/dev/null \
  || fail alert '임시 webhook receiver Pod가 Ready가 아니다.'

delivery=false
while (( $(date -u +%s) <= observation_deadline_epoch )); do
  prometheus_alert=$(prom_query 'ALERTS{alertname="OBS01Delivery",alertstate="firing"} == 1' || true)
  alertmanager_alerts=$(curl -fsS "${alertmanager_url}/api/v2/alerts" || true)
  sink_log=$(remote_kubectl -n "${test_namespace}" logs pod/obs-01-alert-sink 2>/dev/null || true)
  if jq -e '.status == "success" and (.data.result | length) > 0' <<<"${prometheus_alert}" >/dev/null 2>&1 &&
     jq -e '[.[] | select(.labels.alertname == "OBS01Delivery" and .status.state == "active")] | length > 0' <<<"${alertmanager_alerts}" >/dev/null 2>&1 &&
     grep -qx 'RECEIVED alertname=OBS01Delivery status=firing' <<<"${sink_log}"; then
    delivery=true
    break
  fi
  sleep 5
done
[[ ${delivery} == true ]] \
  || fail alert '10분 고정 관측창에서 Prometheus→Alertmanager→receiver 수신 증거가 완성되지 않았다.'
echo "AlertDelivery=PASS prometheus=firing alertmanager=active receiver='RECEIVED alertname=OBS01Delivery status=firing' WINDOW_SECONDS=${observation_seconds}"

cleanup
trap - EXIT HUP INT TERM
echo 'TemporaryReceiverCleanup=PASS namespace=obs-01-test rule=obs-01-delivery servicemonitor=obs-01-alert-sink'
echo 'OBS01_VERIFY=PASS'
