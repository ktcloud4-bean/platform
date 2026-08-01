#!/usr/bin/env bash
# packaged Traefik 3.7.4와 CrowdSec AppSec를 Docker 전용 네트워크에서 검증한다.
set -euo pipefail

readonly APPSEC_NETWORK=crowdsec-01-local-appsec-net
readonly EDGE_NETWORK=crowdsec-01-local-edge-net
readonly APPSEC=crowdsec-01-local-appsec
readonly LAPI=crowdsec-01-local-lapi
readonly TRAEFIK=crowdsec-01-local-traefik
readonly BACKEND=crowdsec-01-local-backend
readonly SEED=crowdsec-01-local-seed
readonly REGISTER=crowdsec-01-local-register
readonly INIT=crowdsec-01-local-init
readonly HOST_PORT=18120
readonly CROWDSEC_IMAGE='docker.io/crowdsecurity/crowdsec:v1.7.8@sha256:2f527c9bb8b367120eb08b82890aa912ce96bfa1ada93dda0721700e4b4e0dde'
readonly TRAEFIK_IMAGE='docker.io/rancher/mirrored-library-traefik:3.7.4@sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03'
readonly BACKEND_IMAGE='docker.io/traefik/whoami:v1.11.0@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
readonly REPO_ROOT
APP_DIR="$REPO_ROOT/gitops/apps/crowdsec"
readonly APP_DIR
scratch=''

cleanup() {
  docker rm -f "$TRAEFIK" "$APPSEC" "$LAPI" "$BACKEND" "$SEED" "$REGISTER" "$INIT" >/dev/null 2>&1 || true
  docker network rm "$EDGE_NETWORK" "$APPSEC_NETWORK" >/dev/null 2>&1 || true
  if [[ -n $scratch && -d $scratch ]]; then
    rm -rf -- "$scratch"
  fi
}
trap cleanup EXIT

for object in "$TRAEFIK" "$APPSEC" "$LAPI" "$BACKEND" "$SEED" "$REGISTER" "$INIT"; do
  if docker container inspect "$object" >/dev/null 2>&1; then
    printf '중단: 전용 컨테이너 이름 %s이 이미 사용 중이다.\n' "$object" >&2
    exit 2
  fi
done
for network in "$APPSEC_NETWORK" "$EDGE_NETWORK"; do
  if docker network inspect "$network" >/dev/null 2>&1; then
    printf '중단: 전용 Docker network %s이 이미 사용 중이다.\n' "$network" >&2
    exit 2
  fi
done

scratch=$(mktemp -d /tmp/crowdsec-01-compat.XXXXXX)
mkdir -p \
  "$scratch/base-config" \
  "$scratch/lapi-config" \
  "$scratch/lapi-data" \
  "$scratch/appsec-config/appsec-configs" \
  "$scratch/appsec-config/appsec-rules" \
  "$scratch/appsec-data"

docker create --name "$SEED" "$CROWDSEC_IMAGE" >/dev/null
docker cp "$SEED:/staging/etc/crowdsec/." "$scratch/base-config/"
docker rm "$SEED" >/dev/null
cp -a "$scratch/base-config/." "$scratch/lapi-config/"
cp -a "$scratch/base-config/." "$scratch/appsec-config/"

cp "$APP_DIR/files/appsec/acquis.yaml" "$scratch/appsec-config/acquis.yaml"
cp "$APP_DIR/files/appsec/configs/crowdsec-01-crs-inband.yaml" "$scratch/appsec-config/appsec-configs/"
cp "$APP_DIR/files/appsec/rules/"*.yaml "$scratch/appsec-config/appsec-rules/"
docker run --rm --name "$INIT" --entrypoint sh \
  -v "$APP_DIR/files/crs-snapshot.tar.gz:/snapshot/crs-snapshot.tar.gz:ro" \
  -v "$APP_DIR/crs-snapshot.tar.gz.SHA256:/snapshot/ARCHIVE.SHA256:ro" \
  -v "$scratch/appsec-data:/crs-data" \
  "$CROWDSEC_IMAGE" -c \
  'set -eu; cd /snapshot; sha256sum -c ARCHIVE.SHA256 >/dev/null; tar -xzf crs-snapshot.tar.gz -C /crs-data; cd /crs-data; sha256sum -c SHA256SUMS >/dev/null; test "$(find . -maxdepth 1 -type f ! -name SHA256SUMS | wc -l)" -eq 49'
printf '%s\n' \
  'name: crowdsec-01-no-remediation' \
  'filters:' \
  '  - "false"' \
  'decisions: []' \
  'on_success: continue' > "$scratch/lapi-config/profiles.yaml"
printf '%s\n' \
  'share_manual_decisions: false' \
  'share_custom: false' \
  'share_tainted: false' \
  'share_context: false' > "$scratch/lapi-config/console.yaml"
touch "$scratch/lapi-config/hub/.index.json" "$scratch/appsec-config/hub/.index.json"

umask 077
openssl rand -hex 32 > "$scratch/bouncer-key"
openssl rand -hex 32 > "$scratch/cs-lapi-secret"
openssl rand -hex 32 > "$scratch/registration-token"
{
  printf '%s\n' \
    'api:' \
    '  server:' \
    '    auto_registration:' \
    '      enabled: true'
  printf '      token: "'
  tr -d '\n' < "$scratch/registration-token"
  printf '%s\n' '"' '      allowed_ranges:' '        - "172.16.0.0/12"'
} > "$scratch/lapi-config/config.yaml.local"
{
  printf 'DISABLE_ONLINE_API=true\n'
  printf 'NO_HUB_UPGRADE=true\n'
  printf 'DISABLE_AGENT=true\n'
  printf 'CS_LAPI_SECRET='
  tr -d '\n' < "$scratch/cs-lapi-secret"
  printf '\nREGISTRATION_TOKEN='
  tr -d '\n' < "$scratch/registration-token"
  printf '\n'
  printf 'BOUNCER_KEY_CROWDSEC_01='
  tr -d '\n' < "$scratch/bouncer-key"
  printf '\n'
} > "$scratch/lapi.env"
{
  printf 'REGISTRATION_TOKEN='
  tr -d '\n' < "$scratch/registration-token"
  printf '\n'
} > "$scratch/register.env"
{
  printf 'DISABLE_LOCAL_API=true\n'
  printf 'DISABLE_ONLINE_API=true\n'
  printf 'LOCAL_API_URL=http://%s:8080\n' "$LAPI"
  printf 'NO_HUB_UPGRADE=true\n'
  printf 'COLLECTIONS=\n'
  printf 'APPSEC_CONFIGS=\n'
  printf 'APPSEC_RULES=\n'
} > "$scratch/appsec.env"

docker network create "$APPSEC_NETWORK" >/dev/null
docker network create "$EDGE_NETWORK" >/dev/null
docker run -d --name "$LAPI" --network "$APPSEC_NETWORK" \
  --env-file "$scratch/lapi.env" \
  -v "$APP_DIR/files/docker-start-custom.sh:/docker_start.sh:ro" \
  -v "$scratch/lapi-config:/etc/crowdsec" \
  -v "$scratch/lapi-data:/var/lib/crowdsec/data" \
  "$CROWDSEC_IMAGE" >/dev/null
docker run --rm --name "$REGISTER" --network "$APPSEC_NETWORK" --entrypoint sh \
  --env-file "$scratch/register.env" \
  -v "$scratch/appsec-config:/etc/crowdsec" \
  "$CROWDSEC_IMAGE" -c \
  'count=0; until nc crowdsec-01-local-lapi 8080 -z; do count=$((count + 1)); [ "$count" -lt 45 ] || exit 1; sleep 1; done; cscli lapi register --machine crowdsec-01-local-appsec -u http://crowdsec-01-local-lapi:8080 --token "$REGISTRATION_TOKEN"' \
  >/dev/null
docker run -d --name "$APPSEC" --network "$APPSEC_NETWORK" \
  --env-file "$scratch/appsec.env" \
  -e LEVEL_DEBUG=true \
  -v "$scratch/appsec-config:/etc/crowdsec" \
  -v "$scratch/appsec-data:/var/lib/crowdsec/data" \
  "$CROWDSEC_IMAGE" >/dev/null
docker network connect "$EDGE_NETWORK" "$APPSEC"
docker run -d --name "$BACKEND" --network "$EDGE_NETWORK" \
  "$BACKEND_IMAGE" --port=8080 >/dev/null
docker run -d --name "$TRAEFIK" --network "$EDGE_NETWORK" \
  -p "127.0.0.1:${HOST_PORT}:18080" \
  -v "$SCRIPT_DIR/local-static.yaml:/etc/traefik/traefik.yaml:ro" \
  -v "$SCRIPT_DIR/local-dynamic.yaml:/etc/traefik/dynamic.yaml:ro" \
  -v "$scratch/bouncer-key:/run/secrets/crowdsec-01/bouncer-key:ro" \
  "$TRAEFIK_IMAGE" >/dev/null

status() {
  local path=$1
  shift
  curl -sS -o /dev/null -w '%{http_code}' "$@" "http://127.0.0.1:${HOST_PORT}$path" 2>/dev/null || true
}

wait_status() {
  local expected=$1
  local path=$2
  shift 2
  local actual=''
  for _ in {1..45}; do
    actual=$(status "$path" "$@")
    [[ $actual == "$expected" ]] && return 0
    if [[ $(docker inspect "$TRAEFIK" --format '{{.State.Running}}' 2>/dev/null || true) != true ||
          $(docker inspect "$APPSEC" --format '{{.State.Running}}' 2>/dev/null || true) != true ||
          $(docker inspect "$LAPI" --format '{{.State.Running}}' 2>/dev/null || true) != true ]]; then
      break
    fi
    sleep 1
  done
  printf '실패: %s 응답은 %s, 기대값은 %s다.\n' "$path" "$actual" "$expected" >&2
  docker logs "$TRAEFIK" >&2 || true
  docker logs "$APPSEC" >&2 || true
  docker logs "$LAPI" >&2 || true
  return 1
}

assert_status() {
  local expected=$1
  local path=$2
  shift 2
  local actual
  actual=$(status "$path" "$@")
  if [[ $actual != "$expected" ]]; then
    printf '실패: %s 응답은 %s, 기대값은 %s다.\n' "$path" "$actual" "$expected" >&2
    return 1
  fi
}

wait_status 200 /crowdsec-01/control
wait_status 200 /crowdsec-01/waf/normal
assert_status 403 /crowdsec-01/waf/attack -A masscan
assert_status 200 /crowdsec-01/waf/exception -A masscan
assert_status 403 /crowdsec-01/waf/exception -A nmap-nse
assert_status 403 '/crowdsec-01/waf/exception?variant=1' -A masscan
assert_status 403 /crowdsec-01/waf/not-exception -A masscan
assert_status 200 /crowdsec-01/control/attack -A masscan

docker logs "$APPSEC" > "$scratch/crowdsec.log" 2>&1
if ! grep -q '913100' "$scratch/crowdsec.log"; then
  printf '%s\n' '실패: AppSec 로그에서 기대한 CRS rule ID 913100을 찾지 못했다.' >&2
  tail -n 200 "$scratch/crowdsec.log" >&2
  exit 1
fi

decisions=$(docker exec "$LAPI" cscli decisions list -o json)
jq -e 'length == 0' <<< "$decisions" >/dev/null
unset decisions
(
  cd "$scratch/appsec-data"
  sha256sum --quiet -c SHA256SUMS
)

[[ $(docker inspect "$TRAEFIK" --format '{{.State.Running}}') == true ]]
[[ $(docker inspect "$TRAEFIK" --format '{{.State.OOMKilled}}') == false ]]
[[ $(docker inspect "$TRAEFIK" --format '{{.RestartCount}}') == 0 ]]

docker stop "$APPSEC" >/dev/null
wait_status 403 /crowdsec-01/waf/normal
assert_status 200 /crowdsec-01/control/fail-policy
[[ $(docker inspect "$TRAEFIK" --format '{{.State.Running}}') == true ]]

docker start "$APPSEC" >/dev/null
wait_status 200 /crowdsec-01/waf/recovered

printf '%s\n' \
  'PASS: packaged Traefik 3.7.4 고정 image에서 bouncer v1.7.1/hash가 로드됐다.' \
  'PASS: 정상 200, CRS 913100 공격 403, exact URI+UA 예외만 200, control 공격 200이다.' \
  'PASS: IP decision은 0개이며 AppSec 중단 시 WAF test route만 fail-closed 403, control은 200이다.' \
  'PASS: Traefik은 running, OOMKilled=false, restart=0이고 AppSec 재기동 뒤 WAF 200으로 복구됐다.'
