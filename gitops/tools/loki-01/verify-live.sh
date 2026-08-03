#!/usr/bin/env bash
set -euo pipefail

readonly mode=${1:-verify}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly secret_file=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}/loki/env
readonly s3_ca=${S3_CA:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/apps/loki/files/s3.crt}
readonly bucket=loki-chunks
readonly test_image='docker.io/library/busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0'
readonly observation_seconds=1800
readonly retained_cap_bytes=$((14 * 1024 * 1024 * 1024))
readonly daily_cap_bytes=$((2 * 1024 * 1024 * 1024))
readonly pvc_stop_bytes=$((120 * 1024 * 1024 * 1024))
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
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

if [[ ${mode} == capacity-pre ]]; then
  capacity=$(measure_capacity)
  available_bytes=$(awk -F= '$1=="AVAILABLE_BYTES"{print $2}' <<<"${capacity}")
  swap_used_bytes=$(awk -F= '$1=="SWAP_USED_BYTES"{print $2}' <<<"${capacity}")
  root_free_percent=$(awk -F= '$1=="ROOT_FREE_PERCENT"{print $2}' <<<"${capacity}")
  pvc_request_bytes=$(awk -F= '$1=="PVC_REQUEST_BYTES"{print $2}' <<<"${capacity}")
  [[ ${available_bytes} =~ ^[0-9]+$ && ${swap_used_bytes} =~ ^[0-9]+$ &&
     ${root_free_percent} =~ ^[0-9]+$ && ${pvc_request_bytes} =~ ^[0-9]+$ ]] \
    || fail capacity 'guest disk/RAM/PVC 측정값을 읽지 못했다.'
  (( available_bytes >= available_stop_bytes )) || fail capacity 'k3s available RAM이 8 GiB 정지선 아래다.'
  (( swap_used_bytes == 0 )) || fail capacity 'k3s swap 사용량이 0이 아니다.'
  (( root_free_percent >= 20 )) || fail capacity 'k3s guest disk 여유가 20% 정지선 아래다.'
  (( pvc_request_bytes < pvc_stop_bytes )) || fail capacity 'PVC 선언 합계가 120 GiB 정지선에 도달했다.'
  printf '%s\n' "${capacity}" | sed 's/^/PRE_/'
  echo 'CAPACITY_PRE=PASS'
  exit 0
fi

readonly expected_config_revision=${LOKI01_EXPECTED_CONFIG_REVISION:?Loki 설정 commit SHA가 필요하다}
readonly expected_root_revision=${LOKI01_EXPECTED_ROOT_REVISION:?platform-root pointer commit SHA가 필요하다}
readonly pre_available_bytes=${LOKI01_PRE_AVAILABLE_BYTES:?배포 전 available bytes가 필요하다}
readonly pre_root_free_percent=${LOKI01_PRE_ROOT_FREE_PERCENT:?배포 전 guest disk 여유율이 필요하다}
readonly pre_pvc_request_bytes=${LOKI01_PRE_PVC_REQUEST_BYTES:?배포 전 PVC 합계가 필요하다}
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail deployment 'immutable commit SHA 형식이 아니다.'
[[ ${pre_available_bytes} =~ ^[0-9]+$ && ${pre_root_free_percent} =~ ^[0-9]+$ &&
   ${pre_pvc_request_bytes} =~ ^[0-9]+$ ]] || fail capacity '배포 전 capacity 입력이 정수가 아니다.'

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root loki -o json 2>/dev/null || true)
  if jq -e \
    --arg root "${expected_root_revision}" \
    --arg config "${expected_config_revision}" '
      ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
      ([.items[] | select(.metadata.name == "loki")][0] // {}) as $loki |
      $root_app.spec.source.targetRevision == $root and
      $root_app.status.sync.revision == $root and
      $root_app.status.sync.status == "Synced" and
      $root_app.status.health.status == "Healthy" and
      $loki.spec.source.targetRevision == $config and
      $loki.status.sync.revision == $config and
      $loki.status.sync.status == "Synced" and
      $loki.status.health.status == "Healthy"
    ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e \
  --arg root "${expected_root_revision}" \
  --arg config "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "loki")][0] // {}) as $loki |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $loki.spec.source.targetRevision == $config and
    $loki.status.sync.revision == $config and
    $loki.status.sync.status == "Synced" and
    $loki.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null \
  || fail deployment 'platform-root 또는 loki child가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} loki=${expected_config_revision}"

remote_kubectl -n loki rollout status statefulset/loki --timeout=180s >/dev/null \
  || fail deployment 'Loki StatefulSet가 Ready가 아니다.'
remote_kubectl -n loki rollout status deployment/alloy --timeout=180s >/dev/null \
  || fail deployment 'Alloy Deployment가 Ready가 아니다.'

# 배포 직후 정지 기준은 이 한 번만 측정한다.
capacity=$(measure_capacity)
available_bytes=$(awk -F= '$1=="AVAILABLE_BYTES"{print $2}' <<<"${capacity}")
swap_used_bytes=$(awk -F= '$1=="SWAP_USED_BYTES"{print $2}' <<<"${capacity}")
root_free_percent=$(awk -F= '$1=="ROOT_FREE_PERCENT"{print $2}' <<<"${capacity}")
pvc_request_bytes=$(awk -F= '$1=="PVC_REQUEST_BYTES"{print $2}' <<<"${capacity}")
[[ ${available_bytes} =~ ^[0-9]+$ && ${swap_used_bytes} =~ ^[0-9]+$ &&
   ${root_free_percent} =~ ^[0-9]+$ && ${pvc_request_bytes} =~ ^[0-9]+$ ]] \
  || fail capacity '배포 직후 guest disk/RAM/PVC 측정값을 읽지 못했다.'
(( available_bytes >= available_stop_bytes )) || fail capacity '배포 직후 k3s available RAM이 8 GiB 정지선 아래다.'
(( swap_used_bytes == 0 )) || fail capacity '배포 직후 k3s swap 사용량이 0이 아니다.'
(( root_free_percent >= 20 )) || fail capacity '배포 직후 k3s guest disk 여유가 20% 정지선 아래다.'
(( pvc_request_bytes < pvc_stop_bytes )) || fail capacity '배포 직후 PVC 선언 합계가 120 GiB 정지선에 도달했다.'
printf '%s\n' "${capacity}" | sed 's/^/POST_/'
available_delta_bytes=$((available_bytes - pre_available_bytes))
(( pvc_request_bytes == pre_pvc_request_bytes )) \
  || fail capacity 'LOKI-01은 PVC 0개여야 하지만 배포 전후 PVC 선언 합계가 달라졌다.'
echo "CAPACITY_POST=PASS PRE_AVAILABLE_BYTES=${pre_available_bytes} POST_AVAILABLE_BYTES=${available_bytes} DELTA_BYTES=${available_delta_bytes} PRE_ROOT_FREE_PERCENT=${pre_root_free_percent} POST_ROOT_FREE_PERCENT=${root_free_percent} PRE_PVC_REQUEST_BYTES=${pre_pvc_request_bytes} POST_PVC_REQUEST_BYTES=${pvc_request_bytes}"

alloy_deployment=$(remote_kubectl -n loki get deployment alloy -o json)
alloy_config=$(remote_kubectl -n loki get configmap alloy -o json | jq -r '.data["config.alloy"]')
jq -e '
  ([.spec.template.spec.volumes[]? | has("hostPath")] | any) == false and
  ([.spec.template.spec.volumes[] | select(.name == "alloy-storage") |
    .emptyDir.medium == "Memory"] | length) == 1 and
  ([.spec.template.spec.containers[] | select(.name == "kubernetes-events") | .args[]] | join("\n") |
    contains(".message") | not) and
  ([.spec.template.spec.containers[] | select(.name == "kubernetes-events") | .args[]] | join("\n") |
    contains("resourceVersion") | not)
' <<<"${alloy_deployment}" >/dev/null \
  || fail masking 'Alloy가 hostPath/local disk를 쓰거나 Event 원문 field를 생성한다.'
[[ $(grep -c 'stage.output' <<<"${alloy_config}") -eq 5 &&
   $(grep -c 'source   = "safe_line"' <<<"${alloy_config}") -eq 5 &&
   $(grep -c 'loki.write "local"' <<<"${alloy_config}") -eq 1 ]] \
  || fail masking '실행 Alloy config의 allowlist output 수가 source 계약과 다르다.'
grep -q 'enabled = false' <<<"${alloy_config}" \
  || fail masking '실행 Alloy client WAL이 비활성화되지 않았다.'
if grep -Eq 'loki\.source\.file|stage\.replace' <<<"${alloy_config}"; then
  fail masking '실행 Alloy config에 node file source 또는 사후 replace masking이 있다.'
fi
echo 'MaskingSpool=PASS source=kubernetes_api alloy_storage=memory client_wal=disabled raw_event_message=absent'

loki_forward_port=${LOKI01_FORWARD_PORT:-13100}
s3_forward_port=${LOKI01_S3_FORWARD_PORT:-18335}
loki_socket_dir=$(mktemp -d /tmp/loki-01-forward.XXXXXX)
loki_socket=${loki_socket_dir}/control
test_namespace=''
cleanup_done=false
cleanup() {
  if [[ ${cleanup_done} == false ]]; then
    if [[ -n ${test_namespace} ]]; then
      remote_kubectl delete namespace "${test_namespace}" --wait=true --timeout=60s >/dev/null 2>&1 || true
    fi
    if [[ -S ${loki_socket} ]]; then
      ssh "${ssh_options[@]}" -S "${loki_socket}" -O exit "${k3s_host}" >/dev/null 2>&1 || true
    fi
    rmdir "${loki_socket_dir}" 2>/dev/null || true
    cleanup_done=true
  fi
}
trap cleanup EXIT HUP INT TERM

loki_service_ip=$(remote_kubectl -n loki get service loki -o jsonpath='{.spec.clusterIP}')
[[ ${loki_service_ip} =~ ^[0-9a-fA-F:.]+$ ]] || fail deployment 'Loki ClusterIP를 읽지 못했다.'
ssh "${ssh_options[@]}" -M -S "${loki_socket}" -fNT \
  -L "127.0.0.1:${loki_forward_port}:${loki_service_ip}:3100" \
  -L "127.0.0.1:${s3_forward_port}:10.10.50.20:8333" "${k3s_host}"
loki_url="http://127.0.0.1:${loki_forward_port}"
ready=false
for _ in $(seq 1 30); do
  if curl -fsS "${loki_url}/ready" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ ${ready} == true ]] || fail deployment 'Loki API forward가 ready가 아니다.'
s3_ready=false
for _ in $(seq 1 10); do
  if nc -z 127.0.0.1 "${s3_forward_port}"; then
    s3_ready=true
    break
  fi
  sleep 1
done
[[ ${s3_ready} == true ]] || fail storage 'S3 SSH forward가 ready가 아니다.'

[[ -f ${secret_file} && ! -L ${secret_file} && $(stat -c %a "${secret_file}") == 600 ]] \
  || fail storage 'Loki S3 secret input이 없거나 mode 0600이 아니다.'
[[ -f ${s3_ca} ]] || fail storage '고정 S3 CA 파일이 없다.'
# shellcheck disable=SC1090
source "${secret_file}"
[[ -n ${LOKI_S3_ACCESS_KEY:-} && -n ${LOKI_S3_SECRET_KEY:-} ]] \
  || fail storage 'Loki S3 secret input 형식이 잘못됐다.'
export AWS_ACCESS_KEY_ID=${LOKI_S3_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${LOKI_S3_SECRET_KEY}

s3_size_bytes() {
  python3 - "${bucket}" "${s3_forward_port}" "${s3_ca}" <<'PY'
import datetime
import hashlib
import hmac
import http.client
import os
from pathlib import Path
import socket
import ssl
import sys
import urllib.parse
import xml.etree.ElementTree as ET

bucket, connect_port, ca_file = sys.argv[1:]
host, port, region = "s3.imcherry5778.xyz", 8333, "us-east-1"
access, secret = os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"]
method, query = "GET", "list-type=2"
uri = "/" + urllib.parse.quote(bucket, safe="")
now = datetime.datetime.now(datetime.timezone.utc)
amz_date, date = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
payload_hash = hashlib.sha256(b"").hexdigest()
host_header = f"{host}:{port}"
headers_text = f"host:{host_header}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
signed = "host;x-amz-content-sha256;x-amz-date"
canonical = "\n".join([method, uri, query, headers_text, signed, payload_hash])
scope = f"{date}/{region}/s3/aws4_request"
to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])

def digest(signing_key: bytes, value: str) -> bytes:
    return hmac.new(signing_key, value.encode(), hashlib.sha256).digest()

signing_key = digest(digest(digest(digest(("AWS4" + secret).encode(), date), region), "s3"), "aws4_request")
signature = hmac.new(signing_key, to_sign.encode(), hashlib.sha256).hexdigest()
headers = {
    "Authorization": f"AWS4-HMAC-SHA256 Credential={access}/{scope},SignedHeaders={signed},Signature={signature}",
    "Host": host_header,
    "x-amz-content-sha256": payload_hash,
    "x-amz-date": amz_date,
}
context = ssl.create_default_context(cafile=str(Path(ca_file)))
connection = http.client.HTTPSConnection(host, port, context=context, timeout=15)

def connect() -> None:
    raw = socket.create_connection(("127.0.0.1", int(connect_port)), timeout=15)
    connection.sock = context.wrap_socket(raw, server_hostname=host)

connection.connect = connect
connection.request(method, uri + "?" + query, headers=headers)
response = connection.getresponse()
body = response.read()
if response.status != 200:
    raise SystemExit(f"LOKI-01 S3 inventory: unexpected HTTP {response.status}")
root = ET.fromstring(body)
if (root.findtext(".//{*}IsTruncated") or "false").lower() == "true":
    raise SystemExit("LOKI-01 S3 inventory가 한 page를 넘어 결정론적으로 판정할 수 없다")
print(sum(int(item.findtext("{*}Size") or "0") for item in root.findall(".//{*}Contents")))
PY
}

window_start_epoch=$(date -u +%s)
window_start_ns=$(date -u +%s%N)
window_start_rfc3339=$(date -u +%Y-%m-%dT%H:%M:%SZ)
s3_start_bytes=$(s3_size_bytes)
[[ ${s3_start_bytes} =~ ^[0-9]+$ ]] || fail storage '관측창 시작 S3 크기를 읽지 못했다.'

test_suffix=$(date -u +%Y%m%d%H%M%S)
test_namespace="loki-01-test-${test_suffix}"
test_pod="loki-01-event-${test_suffix}"
remote_kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${test_namespace}
  labels:
    app.kubernetes.io/part-of: loki-01-verification
---
apiVersion: v1
kind: Pod
metadata:
  name: ${test_pod}
  namespace: ${test_namespace}
  labels:
    app.kubernetes.io/name: loki-01-event
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  activeDeadlineSeconds: 60
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: event
      image: ${test_image}
      imagePullPolicy: IfNotPresent
      command: ["/bin/sh", "-c"]
      args: ["sleep 20"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          cpu: 20m
          memory: 16Mi
YAML
remote_kubectl -n "${test_namespace}" wait --for=condition=Ready "pod/${test_pod}" --timeout=60s >/dev/null \
  || fail sample 'core/v1 Event 표본을 만드는 비특권 Pod가 Ready가 아니다.'

echo "Observation=START seconds=${observation_seconds} start=${window_start_rfc3339} s3_start_bytes=${s3_start_bytes}"
elapsed=0
while (( elapsed < observation_seconds )); do
  sleep 60
  elapsed=$((elapsed + 60))
  echo "Observation=PROGRESS elapsed_seconds=${elapsed}"
done
window_end_epoch=$(date -u +%s)
window_end_ns=$(date -u +%s%N)
window_end_rfc3339=$(date -u +%Y-%m-%dT%H:%M:%SZ)
actual_window_seconds=$((window_end_epoch - window_start_epoch))
s3_end_bytes=$(s3_size_bytes)
[[ ${s3_end_bytes} =~ ^[0-9]+$ ]] || fail storage '관측창 종료 S3 크기를 읽지 못했다.'
(( s3_end_bytes >= s3_start_bytes )) || fail storage '관측창에서 S3 저장 크기가 감소해 증가량을 판정할 수 없다.'
s3_delta_bytes=$((s3_end_bytes - s3_start_bytes))
(( s3_delta_bytes > 0 )) || fail storage '고정 표본 뒤 S3 저장 후 증가량이 0이다.'
daily_projected_bytes=$(((s3_delta_bytes * 86400 + actual_window_seconds - 1) / actual_window_seconds))
(( s3_end_bytes <= retained_cap_bytes )) || fail storage 'retained S3 전체가 14 GiB hard cap을 넘었다.'
(( daily_projected_bytes <= daily_cap_bytes )) || fail storage 'S3 저장 후 증가량 환산이 2 GiB/일 hard cap을 넘었다.'
echo "StorageWindow=PASS start=${window_start_rfc3339} end=${window_end_rfc3339} seconds=${actual_window_seconds} start_bytes=${s3_start_bytes} end_bytes=${s3_end_bytes} delta_bytes=${s3_delta_bytes} daily_projected_bytes=${daily_projected_bytes} retained_cap_bytes=${retained_cap_bytes} daily_cap_bytes=${daily_cap_bytes}"

loki_query() {
  local query=$1
  curl -fsS --get "${loki_url}/loki/api/v1/query_range" \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${window_start_ns}" \
    --data-urlencode "end=${window_end_ns}" \
    --data-urlencode 'direction=forward' \
    --data-urlencode 'limit=5000'
}

sample=$(loki_query '{cluster="k3s-01"}')
jq -e '.status == "success" and .data.resultType == "streams"' <<<"${sample}" >/dev/null \
  || fail sample 'Loki 고정 표본 query가 성공하지 않았다.'
sample_count=$(jq '[.data.result[].values | length] | add // 0' <<<"${sample}")
(( sample_count > 0 && sample_count <= 5000 )) \
  || fail sample 'Loki 고정 표본이 비었다.'
jq -e '
  all(.data.result[];
    (.stream.retention == "O7" and .stream.event_class == "operation") and
    (.stream.event_ingested | type == "string") and
    all(.values[];
      (.[0] | test("^[0-9]+$")) and
      ((.[1] | fromjson?) as $line |
        $line["event.class"] == "operation" and
        ($line["event.source"] == "falco" or $line["event.source"] == "pomerium" or
         $line["event.source"] == "vault" or $line["event.source"] == "keycloak" or
         $line["event.source"] == "kubernetes") and
        ($line["event.action"] | type == "string") and
        $line["event.outcome"] == "unknown" and
        ($line["event.dataset"] | type == "string") and
        ($line["observer.name"] | type == "string") and
        $line["observer.type"] == "service" and
        $line["actor.kind"] == "none" and
        $line["correlation.kind"] == "none")))
' <<<"${sample}" >/dev/null \
  || fail labels 'O7 field/low-cardinality label/structured high-cardinality 계약이 고정 표본과 다르다.'
label_response=$(curl -fsS --get "${loki_url}/loki/api/v1/labels" \
  --data-urlencode "start=${window_start_ns}" --data-urlencode "end=${window_end_ns}")
jq -e '
  .status == "success" and
  (.data | sort) == ["app","cluster","container","event_class","level","namespace","retention"]
' <<<"${label_response}" >/dev/null \
  || fail labels 'Loki index label 목록이 저cardinality 7개 집합과 다르다.'
event_sample=$(loki_query '{app="kubernetes"}')
jq -e --arg ns "${test_namespace}" '
  .status == "success" and
  any(.data.result[];
    .stream.resource_namespace == $ns and
    ((.stream.resource_uid // "") | length > 0))
' <<<"${event_sample}" >/dev/null \
  || fail labels '고정 core/v1 Event의 resource UID가 structured metadata에 없다.'
echo "O7Sample=PASS direction=forward limit=5000 records=${sample_count} labels=cluster,namespace,app,container,level,event_class,retention structured_high_cardinality=present"

security_zero() {
  local name=$1 query=$2 result count
  result=$(loki_query "${query}")
  count=$(jq '[.data.result[].values | length] | add // 0' <<<"${result}")
  [[ ${count} == 0 ]] || fail security "${name} 보안 event가 Loki에 ${count}건 있다."
  echo "SecurityZero=PASS source=${name} records=0"
}
security_zero falco '{app="falco"} |~ "(?i)(output_fields|syscall|rule|evt.type)"'
security_zero pomerium '{app="pomerium"} |~ "(?i)(authorize|authenticate|identity_manager|session|request|email|user|allow|deny)"'
security_zero vault '{app="vault"} |~ "(?i)(request|response|auth|token|accessor)"'
security_zero keycloak '{app="keycloak"} |~ "(?i)(org.keycloak.events|userId|code_id|realmId|clientId)"'

running_config=$(curl -fsS "${loki_url}/config")
grep -Eq 'retention_period: (1w|168h(0m0s)?)' <<<"${running_config}" \
  || fail retention '실행 Loki config의 retention이 7일이 아니다.'
grep -Eq 'retention_enabled: true' <<<"${running_config}" \
  || fail retention '실행 compactor retention이 활성화되지 않았다.'
metrics=$(curl -fsS "${loki_url}/metrics")
last_retention_success=$(awk '$1 ~ /^loki_compactor_apply_retention_last_successful_run_timestamp_seconds(\{|$)/ {print $NF; exit}' <<<"${metrics}")
[[ ${last_retention_success} =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] \
  || fail retention 'compactor retention 성공 timestamp metric이 없다.'
last_retention_epoch=$(awk -v value="${last_retention_success}" 'BEGIN{printf "%.0f\n",value+0}')
(( last_retention_epoch >= window_start_epoch )) \
  || fail retention '관측창 중 compactor retention 성공 실행이 없다.'
echo "Retention=PASS period=168h compactor_last_success_epoch=${last_retention_epoch}"

final_argo=$(remote_kubectl -n argocd get applications.argoproj.io platform-root loki -o json)
jq -e \
  --arg root "${expected_root_revision}" \
  --arg config "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0]) as $root_app |
    ([.items[] | select(.metadata.name == "loki")][0]) as $loki |
    $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
    $loki.spec.source.targetRevision == $config and $loki.status.sync.revision == $config and
    $loki.status.sync.status == "Synced" and $loki.status.health.status == "Healthy"
  ' <<<"${final_argo}" >/dev/null \
  || fail deployment '관측 종료 시 root/loki가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "ArgoFinal=PASS root=${expected_root_revision} loki=${expected_config_revision}"

cleanup
remote_kubectl get namespace "${test_namespace}" >/dev/null 2>&1 \
  && fail cleanup '고정 표본 test namespace가 남았다.'
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY LOKI_S3_ACCESS_KEY LOKI_S3_SECRET_KEY
echo 'LOKI-01 live verification: PASS'
