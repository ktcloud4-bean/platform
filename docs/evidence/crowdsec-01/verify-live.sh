#!/usr/bin/env bash
# 승인·main 통합·Argo sync 뒤 CROWDSEC-01 기능과 기존 ingress 회귀를 읽기 전용 검증한다.
set -euo pipefail

: "${CROWDSEC_01_BASE_URL:?예: https://k3s-01.imcherry5778.xyz}"
: "${CROWDSEC_01_EXPECTED_CLIENT_IP:?INGRESS-01에서 검증한 client IP 경계를 지정해야 합니다}"
: "${CROWDSEC_01_EXPECTED_MAIN_SHA:?push 뒤 확인한 origin/main full SHA를 지정해야 합니다}"
: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

if (($# != 1)) || [[ ! -d $1 ]]; then
  printf '%s\n' '사용법: verify-live.sh <capture-live-baseline 결과-디렉터리>' >&2
  exit 2
fi
baseline=$(realpath "$1")
if [[ ! -f $baseline/metadata.env || ! -f $baseline/ingress-objects.json ||
      ! -f $baseline/traefik-replicasets.json ]]; then
  printf '%s\n' '오류: baseline 파일이 완전하지 않습니다.' >&2
  exit 2
fi

baseline_value() {
  local key=$1
  local -a values
  mapfile -t values < <(sed -n "s/^${key}=//p" "$baseline/metadata.env")
  ((${#values[@]} == 1)) || return 2
  printf '%s' "${values[0]}"
}

host=${CROWDSEC_01_BASE_URL#https://}
host=${host%%/*}
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
status() {
  local path=$1
  shift
  curl -sS -o /dev/null --max-time 10 -w '%{http_code}' "$@" \
    "${CROWDSEC_01_BASE_URL%/}$path" 2>/dev/null || true
}
assert_status() {
  local expected=$1
  local path=$2
  shift 2
  local actual
  actual=$(status "$path" "$@")
  [[ $actual == "$expected" ]] || {
    printf '실패: %s 응답은 %s, 기대값은 %s입니다.\n' "$path" "$actual" "$expected" >&2
    return 1
  }
}

current_objects=$(mktemp /tmp/crowdsec-01-ingress.XXXXXX)
trap 'rm -f -- "$current_objects"' EXIT
remote_kubectl get ingress,ingressroute.traefik.io,middleware.traefik.io -A -o json |
  jq -S '[.items[] | {apiVersion,kind,metadata:{namespace:.metadata.namespace,name:.metadata.name},spec}]' \
  > "$current_objects"
jq -e --slurpfile current "$current_objects" '
  all(.[]; . as $before | any($current[0][];
    .apiVersion == $before.apiVersion and .kind == $before.kind and
    .metadata == $before.metadata and .spec == $before.spec))
' "$baseline/ingress-objects.json" >/dev/null

traefik=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o json)
[[ $(jq '.items | length' <<< "$traefik") == 1 ]]
[[ $(jq -r '.items[0].metadata.uid' <<< "$traefik") != "$(baseline_value TRAEFIK_UID)" ]]
[[ $(jq -r '.items[0].status.containerStatuses[0].restartCount' <<< "$traefik") == 0 ]]
[[ $(jq -r '.items[0].spec.containers[0].image' <<< "$traefik") == "$(baseline_value TRAEFIK_IMAGE)" ]]
[[ $(jq -r '.items[0].status.containerStatuses[0].imageID' <<< "$traefik") == "$(baseline_value TRAEFIK_IMAGE_ID)" ]]

traefik_deployment=$(remote_kubectl -n kube-system get deployment traefik -o json)
[[ $(jq -r '.metadata.uid' <<< "$traefik_deployment") == "$(baseline_value TRAEFIK_DEPLOYMENT_UID)" ]]
expected_generation=$(( $(baseline_value TRAEFIK_DEPLOYMENT_GENERATION) + 1 ))
[[ $(jq -r '.metadata.generation' <<< "$traefik_deployment") == "$expected_generation" ]]
current_rs=$(remote_kubectl -n kube-system get replicaset -l app.kubernetes.io/name=traefik -o json)
new_rs_uid=$(comm -13 \
  <(jq -r '.[].metadata.uid' "$baseline/traefik-replicasets.json" | sort) \
  <(jq -r '.items[].metadata.uid' <<< "$current_rs" | sort))
[[ $(wc -l <<< "$new_rs_uid") == 1 && -n $new_rs_uid ]]
[[ $(jq -r '.items[0].metadata.ownerReferences[] | select(.kind == "ReplicaSet") | .uid' <<< "$traefik") == "$new_rs_uid" ]]

current_cert=$(openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null |
  openssl x509 -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//I')
[[ $current_cert == "$(baseline_value CERT_SHA256)" ]]
current_http=$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}\t%{redirect_url}' \
  "http://$host/ingress-01-regression?preserve=1")
[[ $current_http == "$(baseline_value HTTP_RESULT)" ]]
current_https=$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' \
  "https://$host/ingress-01-regression?preserve=1" || true)
[[ $current_https == "$(baseline_value HTTPS_STATUS)" ]]

assert_status 200 /crowdsec-01/control/normal
assert_status 200 /crowdsec-01/waf/normal
assert_status 403 /crowdsec-01/waf/attack -A masscan
assert_status 200 /crowdsec-01/waf/exception -A masscan
assert_status 403 /crowdsec-01/waf/exception -A nmap-nse
assert_status 403 '/crowdsec-01/waf/exception?variant=1' -A masscan
assert_status 403 /crowdsec-01/waf/not-exception -A masscan
assert_status 200 /crowdsec-01/control/attack -A masscan

whoami=$(curl -fsS --max-time 10 -H 'X-Forwarded-For: 203.0.113.77' \
  "${CROWDSEC_01_BASE_URL%/}/crowdsec-01/control/source-ip")
grep -Fq "X-Real-Ip: $CROWDSEC_01_EXPECTED_CLIENT_IP" <<< "$whoami"
grep -Fq "X-Forwarded-For: $CROWDSEC_01_EXPECTED_CLIENT_IP" <<< "$whoami"
if grep -Fq '203.0.113.77' <<< "$whoami"; then
  printf '%s\n' '실패: forged X-Forwarded-For가 backend에 남았습니다.' >&2
  exit 1
fi

decisions=$(remote_kubectl -n crowdsec-01 exec deploy/crowdsec-lapi -- cscli decisions list -o json)
jq -e 'length == 0' <<< "$decisions" >/dev/null
unset decisions whoami

apps=$(remote_kubectl -n argocd get application platform-root ingress crowdsec -o json)
jq -e --arg revision "$CROWDSEC_01_EXPECTED_MAIN_SHA" '
  all(.items[];
    .spec.source.targetRevision == "main" and
    .status.sync.revision == $revision and
    .status.sync.status == "Synced" and
    .status.health.status == "Healthy")
' \
  <<< "$apps" >/dev/null
remote_kubectl get node -o json |
  jq -e 'all(.items[]; any(.status.conditions[]; .type == "Ready" and .status == "True") and any(.status.conditions[]; .type == "DiskPressure" and .status == "False"))' >/dev/null
if remote_kubectl get pods -A -o json |
  jq -e 'any(.items[];
    (.status.phase != "Running" and .status.phase != "Succeeded") or
    (.status.phase == "Running" and
      ((.status.containerStatuses // [] | length) == 0 or
       any(.status.containerStatuses // []; .ready != true))))' >/dev/null; then
  printf '%s\n' '실패: Running/Succeeded가 아니거나 Ready가 아닌 Pod가 있습니다.' >&2
  exit 1
fi

secret_names=$(remote_kubectl -n crowdsec-01 get secret crowdsec-01-bootstrap \
  -o 'custom-columns=NAME:.metadata.name,TYPE:.type' --no-headers)
read -r secret_name secret_type <<< "$secret_names"
[[ $secret_name == crowdsec-01-bootstrap && $secret_type == Opaque ]]
secret_names=$(remote_kubectl -n kube-system get secret crowdsec-01-bouncer \
  -o 'custom-columns=NAME:.metadata.name,TYPE:.type' --no-headers)
read -r secret_name secret_type <<< "$secret_names"
[[ $secret_name == crowdsec-01-bouncer && $secret_type == Opaque ]]
unset secret_names secret_name secret_type

printf '%s\n' 'PASS: CROWDSEC-01 기능, decision 0, 기존 ingress object/TLS/301/source-IP, Argo와 cluster health를 검증했습니다.'
