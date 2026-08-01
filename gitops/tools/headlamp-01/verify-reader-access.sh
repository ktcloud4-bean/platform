#!/usr/bin/env bash
set -euo pipefail

umask 077

K3S_SSH_TARGET="${K3S_SSH_TARGET:-rocky@k3s-01.imcherry5778.xyz}"
K3S_SSH_KNOWN_HOSTS="${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
HEADLAMP_LOCAL_PORT="${HEADLAMP_LOCAL_PORT:-8446}"
HEADLAMP_REMOTE_PORT="${HEADLAMP_REMOTE_PORT:-18446}"

for command_name in base64 curl jq shred ssh; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "필수 명령이 없습니다: $command_name" >&2
    exit 1
  fi
done

if [[ ! -f "$K3S_SSH_KNOWN_HOSTS" ]]; then
  echo "known_hosts 파일이 없습니다: $K3S_SSH_KNOWN_HOSTS" >&2
  exit 1
fi

verify_dir="$(mktemp -d /tmp/headlamp-01-verify.XXXXXX)"
token_file="$verify_dir/reader.token"
curl_config="$verify_dir/curl.conf"
response_file="$verify_dir/response.json"
port_forward_log="$verify_dir/port-forward.log"
port_forward_pid=""

cleanup() {
  local cleanup_status=$?
  trap - EXIT INT TERM

  if [[ -n "$port_forward_pid" ]] && kill -0 "$port_forward_pid" 2>/dev/null; then
    kill "$port_forward_pid" 2>/dev/null || true
    wait "$port_forward_pid" 2>/dev/null || true
  fi

  if [[ -d "$verify_dir" ]]; then
    find "$verify_dir" -type f -print0 | xargs -0 -r shred -u
    rmdir "$verify_dir" 2>/dev/null || true
  fi

  exit "$cleanup_status"
}
trap cleanup EXIT INT TERM

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$K3S_SSH_KNOWN_HOSTS"
)
remote_kubectl="sudo -n /usr/local/bin/k3s kubectl"

# remote_kubectl은 고정된 비밀 없는 명령 prefix만 client에서 확장한다.
# shellcheck disable=SC2029
ssh "${ssh_options[@]}" "$K3S_SSH_TARGET" \
  "$remote_kubectl -n headlamp create token headlamp-reader --duration=10m" \
  >"$token_file"
chmod 0600 "$token_file"

jwt_payload="$(cut -d. -f2 "$token_file" | tr '_-' '/+')"
case $((${#jwt_payload} % 4)) in
  2) jwt_payload="${jwt_payload}==" ;;
  3) jwt_payload="${jwt_payload}=" ;;
esac
jwt_claims="$(printf '%s' "$jwt_payload" | base64 -d 2>/dev/null)"
issued_at="$(jq -er '.iat' <<<"$jwt_claims")"
expires_at="$(jq -er '.exp' <<<"$jwt_claims")"
token_ttl=$((expires_at - issued_at))
unset jwt_payload jwt_claims issued_at expires_at

if ((token_ttl != 600)); then
  echo "TokenRequest TTL이 600초가 아닙니다: ${token_ttl}초" >&2
  exit 1
fi
echo "TOKEN_TTL_SECONDS=$token_ttl"

{
  printf 'silent\nshow-error\nheader = "Authorization: Bearer '
  tr -d '\r\n' <"$token_file"
  printf '"\n'
} >"$curl_config"
chmod 0600 "$curl_config"

ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:${HEADLAMP_LOCAL_PORT}:127.0.0.1:${HEADLAMP_REMOTE_PORT}" \
  "$K3S_SSH_TARGET" \
  "$remote_kubectl -n headlamp port-forward --address=127.0.0.1 service/headlamp ${HEADLAMP_REMOTE_PORT}:80" \
  >"$port_forward_log" 2>&1 &
port_forward_pid=$!

for _ in {1..30}; do
  if ! kill -0 "$port_forward_pid" 2>/dev/null; then
    echo "port-forward가 종료됐습니다." >&2
    sed -n '1,80p' "$port_forward_log" >&2
    exit 1
  fi
  if curl --silent --fail --output /dev/null \
    "http://127.0.0.1:${HEADLAMP_LOCAL_PORT}/"; then
    break
  fi
  sleep 1
done

base_url="http://127.0.0.1:${HEADLAMP_LOCAL_PORT}/clusters/main"

request() {
  local method=$1
  local path=$2
  local content_type=${3:-}
  local body=${4:-}
  local curl_args=(
    --config "$curl_config"
    --request "$method"
    --output "$response_file"
    --write-out '%{http_code}'
  )

  if [[ -n "$content_type" ]]; then
    curl_args+=(--header "Content-Type: $content_type")
  fi
  if [[ -n "$body" ]]; then
    curl_args+=(--data-binary "$body")
  fi

  curl "${curl_args[@]}" "${base_url}${path}"
}

expect_status() {
  local label=$1
  local expected=$2
  shift 2
  local actual
  actual="$(request "$@")"
  if [[ "$actual" != "$expected" ]]; then
    echo "$label: expected=$expected actual=$actual" >&2
    jq -c '{kind,apiVersion,reason,message,code}' "$response_file" 2>/dev/null >&2 || true
    exit 1
  fi
  echo "$label=$actual"
}

expect_status ALLOW_NAMESPACES 200 GET /api/v1/namespaces
jq -e '.items | length > 0' "$response_file" >/dev/null

expect_status ALLOW_HEADLAMP_PODS 200 GET /api/v1/namespaces/headlamp/pods
pod_name="$(jq -er '.items | map(select(.metadata.labels["app.kubernetes.io/name"] == "headlamp")) | first | .metadata.name' "$response_file")"

expect_status ALLOW_HEADLAMP_LOG 200 GET "/api/v1/namespaces/headlamp/pods/${pod_name}/log?tailLines=5"
expect_status DENY_SECRETS 403 GET /api/v1/namespaces/headlamp/secrets

create_body='{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"headlamp-01-denied","namespace":"headlamp"},"data":{"probe":"dry-run"}}'
expect_status DENY_CREATE 403 POST '/api/v1/namespaces/headlamp/configmaps?dryRun=All' application/json "$create_body"

token_request_body='{"apiVersion":"authentication.k8s.io/v1","kind":"TokenRequest","spec":{"expirationSeconds":600}}'
expect_status DENY_TOKEN_REQUEST 403 POST \
  '/api/v1/namespaces/headlamp/serviceaccounts/headlamp-reader/token' \
  application/json "$token_request_body"

expect_status GET_SERVICE_FOR_DRY_RUN 200 GET /api/v1/namespaces/headlamp/services/headlamp
service_body="$(jq -c . "$response_file")"
expect_status DENY_UPDATE 403 PUT '/api/v1/namespaces/headlamp/services/headlamp?dryRun=All' application/json "$service_body"
unset service_body

expect_status DENY_DELETE 403 DELETE '/api/v1/namespaces/headlamp/services/headlamp?dryRun=All'
expect_status DENY_EXEC 403 POST "/api/v1/namespaces/headlamp/pods/${pod_name}/exec?container=headlamp&command=true&stdout=true"
unset pod_name create_body token_request_body

runtime_pods_permission="$(
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "$K3S_SSH_TARGET" \
  "$remote_kubectl auth can-i get pods --all-namespaces --as=system:serviceaccount:headlamp:headlamp" || true
)"
runtime_logs_permission="$(
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "$K3S_SSH_TARGET" \
  "$remote_kubectl auth can-i get pods/log --all-namespaces --as=system:serviceaccount:headlamp:headlamp" || true
)"
runtime_create_permission="$(
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "$K3S_SSH_TARGET" \
  "$remote_kubectl auth can-i create deployments.apps --all-namespaces --as=system:serviceaccount:headlamp:headlamp" || true
)"

if [[ "$runtime_pods_permission" != no || "$runtime_logs_permission" != no || "$runtime_create_permission" != no ]]; then
  echo "Headlamp runtime ServiceAccount에 예상 밖 리소스 권한이 있습니다." >&2
  exit 1
fi
echo "RUNTIME_SA_GET_PODS=no"
echo "RUNTIME_SA_GET_LOGS=no"
echo "RUNTIME_SA_CREATE_DEPLOYMENTS=no"

legacy_token_secret_count="$(
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "$K3S_SSH_TARGET" \
  "$remote_kubectl get secrets -n headlamp -o custom-columns=TYPE:.type --no-headers" \
  | awk '$1 == "kubernetes.io/service-account-token" { count++ } END { print count + 0 }')"
if [[ "$legacy_token_secret_count" != 0 ]]; then
  echo "장기 ServiceAccount token Secret이 존재합니다: ${legacy_token_secret_count}개" >&2
  exit 1
fi
echo "SERVICE_ACCOUNT_TOKEN_SECRETS=0"
