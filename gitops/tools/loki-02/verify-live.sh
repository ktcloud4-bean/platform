#!/usr/bin/env bash
# LOKI-02 live proof: six approved transient systemd failures, one bounded
# observation window, and no raw journal output.
set -euo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly secret_file="${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}/loki/env"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root
readonly s3_ca="${repo_root}/gitops/apps/loki/files/s3.crt"
readonly expected_root=${LOKI02_EXPECTED_ROOT_REVISION:?platform-root immutable SHA가 필요하다}
readonly expected_obs=${LOKI02_EXPECTED_OBS_REVISION:?obs immutable SHA가 필요하다}
readonly window_seconds=${LOKI02_WINDOW_SECONDS:-180}
readonly retained_cap_bytes=$((14 * 1024 * 1024 * 1024))
readonly daily_cap_bytes=$((2 * 1024 * 1024 * 1024))
readonly -a hosts=(k3s-01 postgres-01 object-01 warpgate-01 netbird-01 proxmox-01)
readonly -a ssh_targets=(
  rocky@k3s-01.imcherry5778.xyz
  rocky@postgres-01.imcherry5778.xyz
  rocky@object-01.imcherry5778.xyz
  rocky@warpgate-01.imcherry5778.xyz
  rocky@netbird-01.imcherry5778.xyz
  root@proxmox-01.imcherry5778.xyz
)
readonly -a ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  echo "LOKI-02 검증 실패 단계=$1 원인=$2" >&2
  exit 1
}

remote_kubectl() {
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || fail precondition '인증된 k3s SSH known_hosts가 없다.'
[[ ${expected_root} =~ ^[0-9a-f]{40}$ && ${expected_obs} =~ ^[0-9a-f]{40}$ ]] \
  || fail precondition 'immutable SHA 형식이 아니다.'
[[ ${window_seconds} =~ ^[0-9]+$ && ${window_seconds} -ge 150 ]] \
  || fail precondition '관측창은 Loki 2분 idle+30초 retain보다 길어야 한다.'
[[ -f ${secret_file} && ! -L ${secret_file} && $(stat -c %a "${secret_file}") == 600 ]] \
  || fail precondition 'Loki S3 secret input이 없거나 mode 0600이 아니다.'
[[ -f ${s3_ca} ]] || fail precondition '고정 S3 CA 파일이 없다.'

argo=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json)
jq -e --arg rootrev "${expected_root}" --arg obsrev "${expected_obs}" '
  ([.items[] | select(.metadata.name == "platform-root")][0]) as $root_app |
  ([.items[] | select(.metadata.name == "obs")][0]) as $obs_app |
  $root_app.spec.source.targetRevision == $rootrev and
  $root_app.status.sync.revision == $rootrev and $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $obsrev and
  $obs_app.status.sync.revision == $obsrev and $obs_app.status.sync.status == "Synced" and
  $obs_app.status.health.status == "Healthy"
' <<<"${argo}" >/dev/null || fail argo 'platform-root 또는 obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root} obs=${expected_obs}"

remote_kubectl -n obs rollout status deployment/obs-loki-host-gateway --timeout=60s >/dev/null \
  || fail gateway 'obs-loki-host-gateway Deployment가 Ready가 아니다.'
gateway=$(remote_kubectl -n obs get service obs-loki-host-gateway -o json)
jq -e '
  .spec.type == "LoadBalancer" and .spec.externalTrafficPolicy == "Local" and
  .status.loadBalancer.ingress[0].ip == "10.10.20.10" and
  ([.spec.loadBalancerSourceRanges[]] | sort) ==
    ["10.10.10.10/32","10.10.20.10/32","10.10.30.10/32","10.10.40.10/32","10.10.50.10/32","10.10.50.20/32"] and
  ([.spec.ports[] | select(.port == 3100 and .protocol == "TCP")] | length == 1)
' <<<"${gateway}" >/dev/null || fail gateway 'private LoadBalancer/source range/port가 계약과 다르다.'
echo 'Gateway=PASS private_lb=10.10.20.10:3100'

for i in "${!hosts[@]}"; do
  ssh "${ssh_options[@]}" "${ssh_targets[${i}]}" '
    systemctl is-active --quiet alloy-loki-02.service
    config=/etc/alloy-loki-02/config.alloy
    test "$(grep -c "loki.source.journal" "$config")" = 4
    test "$(grep -c "stage.output" "$config")" = 4
    ! grep -q "loki.source.file" "$config"
    grep -q "enabled = false" "$config"
  ' || fail agent "${hosts[${i}]} collector가 active/O7-only가 아니다."
done
echo 'HostAgent=PASS count=6 journald_sources=4 raw_file_source=0 client_wal=disabled'

socket_dir=$(mktemp -d /tmp/loki-02-forward.XXXXXX)
socket=${socket_dir}/control
cleanup() {
  ssh "${ssh_options[@]}" -S "${socket}" -O exit "${k3s_host}" >/dev/null 2>&1 || true
  rmdir "${socket_dir}" 2>/dev/null || true
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY LOKI_S3_ACCESS_KEY LOKI_S3_SECRET_KEY
}
trap cleanup EXIT HUP INT TERM

loki_ip=$(remote_kubectl -n loki get service loki -o jsonpath='{.spec.clusterIP}')
[[ ${loki_ip} =~ ^[0-9a-fA-F:.]+$ ]] || fail forward 'Loki ClusterIP를 읽지 못했다.'
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -M -S "${socket}" -fNT \
  -L "127.0.0.1:13102:${loki_ip}:3100" \
  -L '127.0.0.1:18335:10.10.50.20:8333' "${k3s_host}"
curl -fsS http://127.0.0.1:13102/ready >/dev/null || fail forward 'Loki SSH forward가 ready가 아니다.'

# shellcheck disable=SC1090
source "${secret_file}"
export AWS_ACCESS_KEY_ID=${LOKI_S3_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${LOKI_S3_SECRET_KEY}

s3_size_bytes() {
  python3 - "${s3_ca}" <<'PY'
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

ca_file = sys.argv[1]
bucket, host, port, region = "loki-chunks", "s3.imcherry5778.xyz", 8333, "us-east-1"
access, secret = os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"]
method = "GET"
uri = "/" + urllib.parse.quote(bucket, safe="")
payload_hash = hashlib.sha256(b"").hexdigest()
host_header = f"{host}:{port}"
signed = "host;x-amz-content-sha256;x-amz-date"
def digest(key, value):
    return hmac.new(key, value.encode(), hashlib.sha256).digest()
context = ssl.create_default_context(cafile=str(Path(ca_file)))
token, total = None, 0
while True:
    params = [("list-type", "2")]
    if token:
        params.append(("continuation-token", token))
    query = "&".join(
        f"{urllib.parse.quote(key, safe='-_.~')}={urllib.parse.quote(value, safe='-_.~')}"
        for key, value in sorted(params)
    )
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date, date = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    headers_text = f"host:{host_header}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
    canonical = "\n".join([method, uri, query, headers_text, signed, payload_hash])
    scope = f"{date}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = digest(digest(digest(digest(("AWS4" + secret).encode(), date), region), "s3"), "aws4_request")
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    headers = {
        "Authorization": f"AWS4-HMAC-SHA256 Credential={access}/{scope},SignedHeaders={signed},Signature={signature}",
        "Host": host_header, "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date,
    }
    connection = http.client.HTTPSConnection(host, port, context=context, timeout=15)
    def connect():
        raw = socket.create_connection(("127.0.0.1", 18335), timeout=15)
        connection.sock = context.wrap_socket(raw, server_hostname=host)
    connection.connect = connect
    connection.request(method, uri + "?" + query, headers=headers)
    response = connection.getresponse()
    body = response.read()
    if response.status != 200:
        raise SystemExit(f"S3 inventory HTTP {response.status}")
    root = ET.fromstring(body)
    total += sum(int(item.findtext("{*}Size") or "0") for item in root.findall(".//{*}Contents"))
    if (root.findtext(".//{*}IsTruncated") or "false").lower() != "true":
        break
    token = root.findtext(".//{*}NextContinuationToken")
    if not token:
        raise SystemExit("S3 inventory continuation token is missing")
print(total)
PY
}

start_epoch=$(date -u +%s)
start_ns=$(date -u +%s%N)
start_bytes=$(s3_size_bytes)
[[ ${start_bytes} =~ ^[0-9]+$ ]] || fail storage '관측창 시작 S3 크기를 읽지 못했다.'
echo "StorageWindow=START seconds=${window_seconds} s3_start_bytes=${start_bytes}"

for i in "${!hosts[@]}"; do
  if [[ ${ssh_targets[${i}]} == root@* ]]; then
    trigger=(systemd-run --unit=loki-02-o7-verify --collect --wait /usr/bin/false)
  else
    trigger=(sudo -n systemd-run --unit=loki-02-o7-verify --collect --wait /usr/bin/false)
  fi
  if ssh "${ssh_options[@]}" "${ssh_targets[${i}]}" "${trigger[@]}" >/dev/null 2>&1; then
    fail trigger "${hosts[${i}]} transient unit이 성공 종료됐다."
  else
    trigger_status=$?
    [[ ${trigger_status} -eq 1 ]] || fail trigger "${hosts[${i}]} transient unit 실행 자체가 실패했다(status=${trigger_status})."
  fi
done
echo 'TransientFailure=PASS count=6 unit=loki-02-o7-verify auto_collect=true'

query_host_streams() {
  curl -fsS --get http://127.0.0.1:13102/loki/api/v1/query_range \
    --data-urlencode 'query={source="host",event_class="operation",retention="O7"}' \
    --data-urlencode "start=${start_ns}" \
    --data-urlencode "end=$(date -u +%s%N)" \
    --data-urlencode 'direction=forward' \
    --data-urlencode 'limit=5000'
}

host_result=''
for _ in $(seq 1 24); do
  host_result=$(query_host_streams)
  if jq -e --args '
    .status == "success" and .data.resultType == "streams" and
    ([.data.result[].stream.hostname] | unique | sort) == ($ARGS.positional | sort) and
    all(.data.result[];
      (.stream | keys | sort) == ["event_class","hostname","retention","source","unit"] and
      .stream.source == "host" and .stream.event_class == "operation" and .stream.retention == "O7" and
      .stream.unit == "systemd.service" and
      any(.values[]; (.[1] | fromjson? | .["event.action"] == "systemd_unit_failure")))
  ' "${hosts[@]}" <<<"${host_result}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --args '
  .status == "success" and .data.resultType == "streams" and
  ([.data.result[].stream.hostname] | unique | sort) == ($ARGS.positional | sort) and
  all(.data.result[];
    (.stream | keys | sort) == ["event_class","hostname","retention","source","unit"] and
    .stream.source == "host" and .stream.event_class == "operation" and .stream.retention == "O7" and
    .stream.unit == "systemd.service" and
    any(.values[]; (.[1] | fromjson? | .["event.action"] == "systemd_unit_failure")))
' "${hosts[@]}" <<<"${host_result}" >/dev/null || fail loki '여섯 host의 고정 O7 systemd record/label을 받지 못했다.'
records=$(jq '[.data.result[].values | length] | add // 0' <<<"${host_result}")
echo "LokiHostStream=PASS hosts=6 records=${records} labels=hostname,unit,source,event_class,retention"

remaining=$((window_seconds - ($(date -u +%s) - start_epoch)))
while (( remaining > 0 )); do
  sleep_seconds=30
  (( remaining < sleep_seconds )) && sleep_seconds=${remaining}
  sleep "${sleep_seconds}"
  remaining=$((window_seconds - ($(date -u +%s) - start_epoch)))
  (( remaining < 0 )) && remaining=0
  echo "StorageWindow=PROGRESS remaining_seconds=${remaining}"
done

end_epoch=$(date -u +%s)
end_bytes=$(s3_size_bytes)
[[ ${end_bytes} =~ ^[0-9]+$ && ${end_bytes} -ge ${start_bytes} ]] \
  || fail storage '관측창 종료 S3 크기가 유효하지 않다.'
delta_bytes=$((end_bytes - start_bytes))
actual_seconds=$((end_epoch - start_epoch))
daily_projected_bytes=$(((delta_bytes * 86400 + actual_seconds - 1) / actual_seconds))
(( delta_bytes > 0 )) || fail storage 'O7 표본 뒤 S3 저장 증가량이 0이다.'
(( end_bytes <= retained_cap_bytes )) || fail storage 'retained S3가 14 GiB 상한을 넘었다.'
(( daily_projected_bytes <= daily_cap_bytes )) || fail storage 'S3 증가량 일환산이 2 GiB 상한을 넘었다.'
echo "StorageWindow=PASS seconds=${actual_seconds} start_bytes=${start_bytes} end_bytes=${end_bytes} delta_bytes=${delta_bytes} daily_projected_bytes=${daily_projected_bytes}"

final_argo=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json)
jq -e --arg rootrev "${expected_root}" --arg obsrev "${expected_obs}" '
  ([.items[] | select(.metadata.name == "platform-root")][0]) as $root_app |
  ([.items[] | select(.metadata.name == "obs")][0]) as $obs_app |
  $root_app.spec.source.targetRevision == $rootrev and $root_app.status.sync.revision == $rootrev and
  $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $obsrev and $obs_app.status.sync.revision == $obsrev and
  $obs_app.status.sync.status == "Synced" and $obs_app.status.health.status == "Healthy"
' <<<"${final_argo}" >/dev/null || fail argo '관측 종료 시 immutable root/obs 상태가 다르다.'
echo "ArgoFinal=PASS root=${expected_root} obs=${expected_obs}"
