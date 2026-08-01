#!/usr/bin/env bash
# 승인 뒤 live test/control route의 ADR-0012 성능 gate를 측정한다. Kubernetes에는 쓰지 않는다.
set -euo pipefail

: "${CROWDSEC_01_BASE_URL:?예: https://k3s-01.imcherry5778.xyz}"
: "${CROWDSEC_01_CONNECT_IP:?canonical host의 현재 내부 IPv4를 지정해야 합니다}"
: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

readonly REQUESTS=1000
readonly CONCURRENCY=10
readonly ROUNDS=3
readonly CONTROL_PATH=/crowdsec-01/control/benchmark
readonly WAF_PATH=/crowdsec-01/waf/benchmark
readonly FORMAT='%{http_code}\t%{time_total}\t%{remote_ip}\t%{http_version}\t%{num_connects}'

if [[ ! -f $K3S_SSH_KNOWN_HOSTS ]]; then
  printf '%s\n' '오류: trusted known_hosts 파일이 없습니다.' >&2
  exit 2
fi
if (($# > 1)); then
  printf '%s\n' '사용법: benchmark-live.sh [결과-디렉터리]' >&2
  exit 2
fi

if [[ $CROWDSEC_01_BASE_URL != https://* ||
      ! $CROWDSEC_01_CONNECT_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' '오류: strict TLS HTTPS base URL과 내부 IPv4가 필요합니다.' >&2
  exit 2
fi
host=${CROWDSEC_01_BASE_URL#https://}
host=${host%%/*}
if [[ ! $host =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf '%s\n' '오류: base URL에는 port나 path 없이 canonical hostname만 사용합니다.' >&2
  exit 2
fi
readonly host

if (($# == 1)); then
  if [[ -e $1 ]]; then
    printf '오류: 기존 결과 경로를 덮어쓰지 않습니다: %s\n' "$1" >&2
    exit 2
  fi
  mkdir -m 700 -- "$1"
  result_dir=$(realpath "$1")
else
  result_dir=$(mktemp -d /tmp/crowdsec-01-benchmark.XXXXXX)
fi
readonly result_dir

ssh_base=(
  ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$K3S_SSH_KNOWN_HOSTS"
  -o PasswordAuthentication=no
  -o ConnectTimeout=10
  "$K3S_SSH_TARGET"
)

remote_kubectl() {
  local remote_command
  printf -v remote_command '%q ' sudo -n /usr/local/bin/k3s kubectl "$@"
  "${ssh_base[@]}" "$remote_command"
}

metric_snapshot() {
  # shellcheck disable=SC2016
  "${ssh_base[@]}" '
    set -eu
    k="sudo -n /usr/local/bin/k3s kubectl"
    pod=$($k -n kube-system get pod \
      -l app.kubernetes.io/name=traefik \
      -o jsonpath="{.items[0].metadata.name}")
    node=$($k get node -o jsonpath="{.items[0].metadata.name}")
    cpu=$($k -n kube-system top pod "$pod" --containers --no-headers | \
      awk '\''$2 == "traefik" {print $3}'\'')
    memory=$($k get --raw "/api/v1/nodes/$node/proxy/stats/summary" | \
      jq -e -r --arg pod "$pod" \
      ".pods[] | select(.podRef.namespace == \"kube-system\" and .podRef.name == \$pod) |
       .containers[] | select(.name == \"traefik\") |
       select((.memory.rssBytes | type) == \"number\" and
              (.memory.workingSetBytes | type) == \"number\") |
       [.memory.rssBytes, .memory.workingSetBytes] | @tsv")
    node_percent=$($k top node --no-headers | awk '\''NR == 1 {print $3}'\'')
    test -n "$cpu" && test -n "$memory" && test -n "$node_percent"
    printf "%s\t%s\n%s\n" "$cpu" "$memory" "$node_percent"
  '
}

cpu_m() {
  awk -v value="$1" 'BEGIN {
    if (value ~ /n$/) {sub(/n$/, "", value); printf "%.3f", value / 1000000}
    else if (value ~ /u$/) {sub(/u$/, "", value); printf "%.3f", value / 1000}
    else if (value ~ /m$/) {sub(/m$/, "", value); printf "%.3f", value}
    else {printf "%.3f", value * 1000}
  }'
}

memory_mib() {
  awk -v value="$1" 'BEGIN {
    if (value ~ /Ki$/) {sub(/Ki$/, "", value); printf "%.3f", value / 1024}
    else if (value ~ /Mi$/) {sub(/Mi$/, "", value); printf "%.3f", value}
    else if (value ~ /Gi$/) {sub(/Gi$/, "", value); printf "%.3f", value * 1024}
    else {printf "%.3f", value / 1048576}
  }'
}

append_metric() {
  local phase=$1
  local snapshot cpu_raw rss_raw working_set_raw node_percent
  snapshot=$(metric_snapshot)
  read -r cpu_raw rss_raw working_set_raw < <(sed -n '1p' <<< "$snapshot")
  node_percent=$(sed -n '2p' <<< "$snapshot" | tr -d '%')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "$phase" "$(cpu_m "$cpu_raw")" \
    "$(memory_mib "$rss_raw")" "$(memory_mib "$working_set_raw")" \
    "$node_percent" >> "$result_dir/metrics.tsv"
}

sampler_pid=''
stop_file="$result_dir/.stop-sampler"
start_sampler() {
  local phase=$1
  rm -f -- "$stop_file"
  (
    while [[ ! -e $stop_file ]]; do
      append_metric "$phase"
      sleep 1
    done
  ) &
  sampler_pid=$!
}

stop_sampler() {
  touch "$stop_file"
  if [[ -n $sampler_pid ]]; then
    wait "$sampler_pid"
    sampler_pid=''
  fi
}

cleanup() {
  if [[ -n $sampler_pid ]]; then
    touch "$stop_file"
    wait "$sampler_pid" 2>/dev/null || true
  fi
  rm -f -- "$stop_file"
}
trap cleanup EXIT

run_batch() {
  local phase=$1
  local path=$2
  local raw="$result_dir/$phase.raw.tsv"
  local url="${CROWDSEC_01_BASE_URL%/}$path"
  local per_worker=$((REQUESTS / CONCURRENCY))
  local worker_dir="$result_dir/$phase-workers"
  local count failures connections wrong_ip wrong_version p95

  mkdir -m 700 -- "$worker_dir"

  start_sampler "$phase"
  # worker마다 첫 transfer로 연결을 수립하고, 같은 curl/HTTP2 연결의 이후 100건만 측정한다.
  # shellcheck disable=SC2016
  seq "$CONCURRENCY" | xargs -P "$CONCURRENCY" -I '{}' sh -c '
    set -eu
    worker=$1
    per_worker=$2
    url=$3
    host=$4
    connect_ip=$5
    format=$6
    worker_dir=$7
    set --
    count=0
    while [ "$count" -le "$per_worker" ]; do
      set -- "$@" -o /dev/null "$url"
      count=$((count + 1))
    done
    curl -sS --http2 --max-time 10 --resolve "$host:443:$connect_ip" \
      -w "$format\n" "$@" 2>"$worker_dir/$worker.stderr" | \
      awk -v worker="$worker" '\''NR > 1 {printf "%s\t%d\t%s\n", worker, NR - 1, $0}'\'' \
      > "$worker_dir/$worker.tsv"
  ' _ '{}' "$per_worker" "$url" "$host" "$CROWDSEC_01_CONNECT_IP" \
    "$FORMAT" "$worker_dir"
  stop_sampler

  : > "$raw"
  for worker in $(seq 1 "$CONCURRENCY"); do
    cat "$worker_dir/$worker.tsv" >> "$raw"
  done
  count=$(wc -l < "$raw")
  failures=$(awk -F '\t' '$3 != 200 {count++} END {print count + 0}' "$raw")
  connections=$(awk -F '\t' '{count += $7} END {print count + 0}' "$raw")
  wrong_ip=$(awk -F '\t' -v expected="$CROWDSEC_01_CONNECT_IP" \
    '$5 != expected {count++} END {print count + 0}' "$raw")
  wrong_version=$(awk -F '\t' '$6 != "2" {count++} END {print count + 0}' "$raw")
  p95=$(awk -F '\t' '{print $4 * 1000}' "$raw" | sort -n | \
    awk -v rank=$(( (REQUESTS * 95 + 99) / 100 )) 'NR == rank {printf "%.3f", $1}')
  if [[ $count != "$REQUESTS" || $failures != 0 || $connections != 0 ||
        $wrong_ip != 0 || $wrong_version != 0 || -z $p95 ]]; then
    printf '실패: %s count=%s failures=%s new_connections=%s wrong_ip=%s wrong_http2=%s p95=%s\n' \
      "$phase" "$count" "$failures" "$connections" "$wrong_ip" "$wrong_version" "$p95" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$count" "$failures" "$connections" "$p95" >> "$result_dir/latency.tsv"
}

resolved=$(getent ahostsv4 "$host" | awk 'NR == 1 {print $1}')
[[ $resolved == "$CROWDSEC_01_CONNECT_IP" ]] || {
  printf '오류: 현재 DNS IPv4 %s가 기대값 %s와 다릅니다.\n' \
    "$resolved" "$CROWDSEC_01_CONNECT_IP" >&2
  exit 1
}
ip route get "$CROWDSEC_01_CONNECT_IP" > "$result_dir/client-route.txt"
ping -c 10 -W 2 "$CROWDSEC_01_CONNECT_IP" > "$result_dir/client-ping.txt"

printf 'phase\tcount\tfailures\tmeasured_new_connections\tp95_ms\n' > "$result_dir/latency.tsv"
printf 'timestamp\tphase\ttraefik_cpu_m\ttraefik_rss_mib\ttraefik_working_set_mib\tnode_cpu_percent\n' \
  > "$result_dir/metrics.tsv"
{
  printf 'CAPTURED_AT=%s\n' "$(date -Iseconds)"
  printf 'BASE_URL=%s\n' "$CROWDSEC_01_BASE_URL"
  printf 'HOST=%s\n' "$host"
  printf 'CONNECT_IP=%s\n' "$CROWDSEC_01_CONNECT_IP"
  printf 'REQUESTS=%s\n' "$REQUESTS"
  printf 'CONCURRENCY=%s\n' "$CONCURRENCY"
  printf 'ROUNDS=%s\n' "$ROUNDS"
  printf 'MEMORY_SOURCE=%s\n' 'kubelet-stats-summary-rssBytes'
  printf 'CURL_VERSION=%s\n' "$(curl --version | sed -n '1p')"
} > "$result_dir/metadata.env"

pod_before=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
  -o 'jsonpath={.items[0].metadata.uid}:{.items[0].status.containerStatuses[0].restartCount}')
append_metric baseline
baseline_rss=$(awk -F '\t' '$2 == "baseline" {print $4}' "$result_dir/metrics.tsv" | tail -n 1)

round_rss=()
for round in $(seq 1 "$ROUNDS"); do
  if ((round % 2 == 1)); then
    run_batch "round${round}-control" "$CONTROL_PATH"
    run_batch "round${round}-waf" "$WAF_PATH"
  else
    run_batch "round${round}-waf" "$WAF_PATH"
    run_batch "round${round}-control" "$CONTROL_PATH"
  fi
  append_metric "round${round}-end"
  round_rss+=("$(awk -F '\t' -v phase="round${round}-end" '$2 == phase {print $4}' "$result_dir/metrics.tsv" | tail -n 1)")
done

sleep 60
append_metric idle-60s
idle_rss=$(awk -F '\t' '$2 == "idle-60s" {print $4}' "$result_dir/metrics.tsv" | tail -n 1)

pod_after=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
  -o 'jsonpath={.items[0].metadata.uid}:{.items[0].status.containerStatuses[0].restartCount}')
[[ $pod_before == "$pod_after" ]] || { printf '%s\n' '실패: benchmark 중 Traefik Pod UID 또는 restartCount가 바뀌었습니다.' >&2; exit 1; }

awk -F '\t' 'NR > 1 && $1 ~ /-waf$/ {if ($5 > 100) exit 1}' "$result_dir/latency.tsv" || {
  printf '%s\n' '실패: WAF p95 절대값이 100ms를 초과했습니다.' >&2
  exit 1
}
for round in $(seq 1 "$ROUNDS"); do
  control=$(awk -F '\t' -v phase="round${round}-control" '$1 == phase {print $5}' "$result_dir/latency.tsv")
  waf=$(awk -F '\t' -v phase="round${round}-waf" '$1 == phase {print $5}' "$result_dir/latency.tsv")
  awk -v control="$control" -v waf="$waf" 'BEGIN {exit !((waf - control) <= 20)}' || {
    printf '실패: round %s WAF p95 증분이 20ms를 초과했습니다.\n' "$round" >&2
    exit 1
  }
done

control_cpu=$(awk -F '\t' 'NR > 1 && $2 ~ /-control$/ {sum += $3; n++} END {if (n) printf "%.3f", sum/n}' "$result_dir/metrics.tsv")
waf_cpu=$(awk -F '\t' 'NR > 1 && $2 ~ /-waf$/ {sum += $3; n++} END {if (n) printf "%.3f", sum/n}' "$result_dir/metrics.tsv")
waf_peak=$(awk -F '\t' 'NR > 1 && $2 ~ /-waf$/ {if ($3 > max) max=$3} END {printf "%.3f", max}' "$result_dir/metrics.tsv")
node_peak=$(awk -F '\t' 'NR > 1 {if ($6 > max) max=$6} END {printf "%.3f", max}' "$result_dir/metrics.tsv")

awk -v control="$control_cpu" -v waf="$waf_cpu" 'BEGIN {exit !((waf - control) <= 750)}' || {
  printf '%s\n' '실패: Traefik 평균 CPU 증분이 750m을 초과했습니다.' >&2
  exit 1
}
awk -v peak="$waf_peak" 'BEGIN {exit !(peak <= 1000)}' || {
  printf '%s\n' '실패: Traefik peak CPU가 1000m을 초과했습니다.' >&2
  exit 1
}
awk -v peak="$node_peak" 'BEGIN {exit !(peak < 50)}' || {
  printf '%s\n' '실패: Node CPU가 50% 이상입니다.' >&2
  exit 1
}
awk -v before="$baseline_rss" -v after="$idle_rss" 'BEGIN {exit !((after - before) < 64)}' || {
  printf '%s\n' '실패: 60초 idle Traefik RSS 잔류 증가가 64Mi 이상입니다.' >&2
  exit 1
}
awk -v a="${round_rss[0]}" -v b="${round_rss[1]}" -v c="${round_rss[2]}" \
  'BEGIN {exit !(a < b && b < c)}' && {
    printf '%s\n' '실패: round 종료 RSS가 3회 연속 단조 증가했습니다.' >&2
    exit 1
  }

printf 'PASS: 요청 실패 0, round별 WAF p95 증분/절대 기준, CPU/RSS/Node/restart 기준을 통과했습니다.\n'
printf '결과: %s\n' "$result_dir"
