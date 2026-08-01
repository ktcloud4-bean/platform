#!/usr/bin/env bash
# 현재 ingress를 변경하지 않고 cold DNS/TCP/TLS와 warmed keep-alive 요청 지연을 분리한다.
# shellcheck disable=SC2016 # remote/xargs의 작은 shell program은 호출 측 확장을 금지한다.
set -euo pipefail

: "${CROWDSEC_PERF_URL:?측정할 내부 HTTPS URL을 지정해야 합니다}"
: "${CROWDSEC_PERF_EXPECTED_STATUS:?기대 HTTP status를 지정해야 합니다}"
: "${CROWDSEC_PERF_CONNECT_IP:?canonical host의 현재 내부 IPv4를 지정해야 합니다}"
: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

readonly REQUESTS=${CROWDSEC_PERF_REQUESTS:-1000}
readonly CONCURRENCY=10
readonly NODE_SAMPLES=${CROWDSEC_PERF_NODE_SAMPLES:-100}
readonly REUSE_ROUNDS=${CROWDSEC_PERF_REUSE_ROUNDS:-3}
readonly FORMAT='%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}\t%{remote_ip}\t%{http_version}\t%{num_connects}'

if (($# != 1)); then
  printf '%s\n' '사용법: measure-ingress-latency.sh <새-결과-디렉터리>' >&2
  exit 2
fi
if [[ -e $1 ]]; then
  printf '오류: 기존 결과 경로를 덮어쓰지 않습니다: %s\n' "$1" >&2
  exit 2
fi
if [[ ! -f $K3S_SSH_KNOWN_HOSTS ]]; then
  printf '%s\n' '오류: trusted known_hosts 파일이 없습니다.' >&2
  exit 2
fi
if [[ $CROWDSEC_PERF_URL != https://* ]]; then
  printf '%s\n' '오류: strict TLS를 검증할 HTTPS URL만 허용합니다.' >&2
  exit 2
fi
if [[ ! $CROWDSEC_PERF_EXPECTED_STATUS =~ ^[1-5][0-9][0-9]$ ||
      ! $CROWDSEC_PERF_CONNECT_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ||
      ! $REQUESTS =~ ^[1-9][0-9]*$ || ! $NODE_SAMPLES =~ ^[1-9][0-9]*$ ||
      ! $REUSE_ROUNDS =~ ^[1-9][0-9]*$ ||
      $((REQUESTS % CONCURRENCY)) -ne 0 ]]; then
  printf '%s\n' '오류: status, IPv4, 표본 수 또는 concurrency 나눗셈 조건이 올바르지 않습니다.' >&2
  exit 2
fi

host=${CROWDSEC_PERF_URL#https://}
host=${host%%/*}
if [[ ! $host =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf '%s\n' '오류: URL hostname 형식이 올바르지 않습니다.' >&2
  exit 2
fi

mkdir -m 700 -- "$1"
result_dir=$(realpath "$1")
readonly result_dir host

ssh_base=(
  ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$K3S_SSH_KNOWN_HOSTS"
  -o PasswordAuthentication=no
  -o ConnectTimeout=10
  "$K3S_SSH_TARGET"
)

live_invariant() {
  "${ssh_base[@]}" '
    set -eu
    k="sudo -n /usr/local/bin/k3s kubectl"
    $k -n argocd get application platform-root ingress -o json | jq -cS \
      "[.items[] | {name:.metadata.name,target:.spec.source.targetRevision,revision:.status.sync.revision,sync:.status.sync.status,health:.status.health.status}]"
    $k -n kube-system get helmchartconfig traefik -o json | jq -cS \
      "{generation:.metadata.generation,resourceVersion:.metadata.resourceVersion}"
    $k -n kube-system get pod -l app.kubernetes.io/name=traefik -o json | jq -cS \
      "{count:(.items|length),uid:.items[0].metadata.uid,restarts:.items[0].status.containerStatuses[0].restartCount,ready:.items[0].status.containerStatuses[0].ready,imageID:.items[0].status.containerStatuses[0].imageID}"
  '
}

before=$(live_invariant)
printf '%s\n' "$before" > "$result_dir/live-before.jsonl"
resolved=$(getent ahostsv4 "$host" | awk 'NR == 1 {print $1}')
[[ $resolved == "$CROWDSEC_PERF_CONNECT_IP" ]] || {
  printf '오류: 현재 DNS IPv4 %s가 기대값 %s와 다릅니다.\n' \
    "$resolved" "$CROWDSEC_PERF_CONNECT_IP" >&2
  exit 1
}
ip route get "$CROWDSEC_PERF_CONNECT_IP" > "$result_dir/client-route.txt"
ping -c 10 -W 2 "$CROWDSEC_PERF_CONNECT_IP" > "$result_dir/client-ping.txt"

{
  printf 'CAPTURED_AT=%s\n' "$(date -Iseconds)"
  printf 'URL=%s\n' "$CROWDSEC_PERF_URL"
  printf 'HOST=%s\n' "$host"
  printf 'CONNECT_IP=%s\n' "$CROWDSEC_PERF_CONNECT_IP"
  printf 'EXPECTED_STATUS=%s\n' "$CROWDSEC_PERF_EXPECTED_STATUS"
  printf 'REQUESTS=%s\n' "$REQUESTS"
  printf 'CONCURRENCY=%s\n' "$CONCURRENCY"
  printf 'NODE_SAMPLES=%s\n' "$NODE_SAMPLES"
  printf 'REUSE_ROUNDS=%s\n' "$REUSE_ROUNDS"
  printf 'CURL_VERSION=%s\n' "$(curl --version | sed -n '1p')"
} > "$result_dir/metadata.env"

run_fresh() {
  local mode=$1
  local raw="$result_dir/${mode}.raw.tsv"
  seq "$REQUESTS" | xargs -P "$CONCURRENCY" -I '{}' sh -c '
    sample=$1
    url=$2
    host=$3
    connect_ip=$4
    mode=$5
    format=$6
    if [ "$mode" = fresh-resolve ]; then
      row=$(curl -sS -o /dev/null --http2 --max-time 10 \
        --resolve "$host:443:$connect_ip" -w "$format" "$url" 2>/dev/null || true)
    else
      row=$(curl -sS -o /dev/null --http2 --max-time 10 \
        -w "$format" "$url" 2>/dev/null || true)
    fi
    if [ -z "$row" ]; then row="000\t0\t0\t0\t0\t10\t-\t-\t0"; fi
    printf "%s\t1\t%s\n" "$sample" "$row"
  ' _ '{}' "$CROWDSEC_PERF_URL" "$host" "$CROWDSEC_PERF_CONNECT_IP" \
    "$mode" "$FORMAT" > "$raw"
}

run_reuse() {
  local round=$1
  local mode="reuse-resolve-round${round}"
  local per_worker=$((REQUESTS / CONCURRENCY))
  local raw="$result_dir/${mode}.raw.tsv"
  local worker_dir="$result_dir/${mode}-workers"
  mkdir -m 700 -- "$worker_dir"
  seq "$CONCURRENCY" | xargs -P "$CONCURRENCY" -I '{}' sh -c '
    worker=$1
    per_worker=$2
    url=$3
    host=$4
    connect_ip=$5
    format=$6
    worker_dir=$7
    set --
    # 첫 transfer는 각 worker의 DNS/TCP/TLS warm-up이며 결과에서 제외한다.
    count=0
    while [ "$count" -le "$per_worker" ]; do
      set -- "$@" -o /dev/null "$url"
      count=$((count + 1))
    done
    curl -sS --http2 --max-time 10 --resolve "$host:443:$connect_ip" \
      -w "$format\n" "$@" 2>/dev/null | awk -v worker="$worker" \
      '\''NR > 1 {printf "%s\t%d\t%s\n", worker, NR - 1, $0}'\'' \
      > "$worker_dir/$worker.tsv"
  ' _ '{}' "$per_worker" "$CROWDSEC_PERF_URL" "$host" \
    "$CROWDSEC_PERF_CONNECT_IP" "$FORMAT" "$worker_dir"
  : > "$raw"
  for worker in $(seq 1 "$CONCURRENCY"); do
    cat "$worker_dir/$worker.tsv" >> "$raw"
  done
}

run_node_fresh() {
  "${ssh_base[@]}" bash -s -- "$CROWDSEC_PERF_URL" "$host" \
    "$CROWDSEC_PERF_CONNECT_IP" "$NODE_SAMPLES" <<'REMOTE' \
    > "$result_dir/node-fresh-resolve.raw.tsv"
set -euo pipefail
url=$1
host=$2
connect_ip=$3
samples=$4
format='%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}\t%{remote_ip}\t%{http_version}\t%{num_connects}'
for sample in $(seq 1 "$samples"); do
  row=$(curl -sS -o /dev/null --http2 --max-time 10 \
    --resolve "$host:443:$connect_ip" -w "$format" "$url" 2>/dev/null || true)
  if [[ -z $row ]]; then row=$'000\t0\t0\t0\t0\t10\t-\t-\t0'; fi
  printf '%s\t1\t%s\n' "$sample" "$row"
done
REMOTE
}

percentile() {
  local derived=$1
  local column=$2
  local percent=$3
  local count rank
  count=$(wc -l < "$derived")
  rank=$(( (count * percent + 99) / 100 ))
  sort -n -k "${column},${column}" "$derived" | awk -v rank="$rank" -v column="$column" \
    'NR == rank {printf "%.3f", $column}'
}

summarize() {
  local mode=$1
  local expected_count=$2
  local raw="$result_dir/${mode}.raw.tsv"
  local derived="$result_dir/${mode}.derived.tsv"
  local count failures connections wrong_ip wrong_version
  count=$(wc -l < "$raw")
  failures=$(awk -F '\t' -v expected="$CROWDSEC_PERF_EXPECTED_STATUS" \
    '$3 != expected {failures++} END {print failures + 0}' "$raw")
  connections=$(awk -F '\t' '{connections += $11} END {print connections + 0}' "$raw")
  wrong_ip=$(awk -F '\t' -v expected="$CROWDSEC_PERF_CONNECT_IP" \
    '$9 != expected {wrong++} END {print wrong + 0}' "$raw")
  wrong_version=$(awk -F '\t' '$10 != "2" {wrong++} END {print wrong + 0}' "$raw")
  if [[ $count != "$expected_count" || $failures != 0 || $wrong_ip != 0 ||
        $wrong_version != 0 ]]; then
    printf '실패: %s count=%s failures=%s wrong_ip=%s wrong_http_version=%s\n' \
      "$mode" "$count" "$failures" "$wrong_ip" "$wrong_version" >&2
    return 1
  fi
  awk -F '\t' 'BEGIN {OFS="\t"} {
    dns=$4*1000; tcp=($5-$4)*1000; tls=($6-$5)*1000;
    app=($7-$6)*1000; total=$8*1000;
    printf "%.6f\t%.6f\t%.6f\t%.6f\t%.6f\n", total,dns,tcp,tls,app
  }' "$raw" > "$derived"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$mode" "$count" "$failures" "$connections" \
    "$(percentile "$derived" 1 50)" "$(percentile "$derived" 1 95)" \
    "$(percentile "$derived" 1 99)" "$(percentile "$derived" 2 95)" \
    "$(percentile "$derived" 3 95)" "$(percentile "$derived" 4 95)" \
    "$(percentile "$derived" 5 95)" "$CROWDSEC_PERF_EXPECTED_STATUS" \
    >> "$result_dir/summary.tsv"
}

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  mode count failures measured_new_connections p50_total_ms p95_total_ms p99_total_ms \
  p95_dns_ms p95_tcp_ms p95_tls_ms p95_app_ms expected_status > "$result_dir/summary.tsv"

run_fresh fresh-dns
run_fresh fresh-resolve
for round in $(seq 1 "$REUSE_ROUNDS"); do
  run_reuse "$round"
done
run_node_fresh
summarize fresh-dns "$REQUESTS"
summarize fresh-resolve "$REQUESTS"
for round in $(seq 1 "$REUSE_ROUNDS"); do
  summarize "reuse-resolve-round${round}" "$REQUESTS"
done
summarize node-fresh-resolve "$NODE_SAMPLES"

after=$(live_invariant)
printf '%s\n' "$after" > "$result_dir/live-after.jsonl"
if [[ $after != "$before" ]]; then
  printf '%s\n' '실패: 측정 중 Argo, HCC 또는 Traefik Pod 불변 조건이 깨졌습니다.' >&2
  exit 1
fi

printf '%s\n' 'PASS: live ingress를 변경하지 않고 cold DNS/TCP/TLS와 warmed keep-alive 지연을 분리했습니다.'
cat "$result_dir/summary.tsv"
printf '결과: %s\n' "$result_dir"
