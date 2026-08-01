#!/usr/bin/env bash
# 폐기된 CORAZA-01 Docker 격리 재현 전용. 라이브 Kubernetes를 변경하지 않는다.
set -euo pipefail

readonly NETWORK=coraza-01-local
readonly BACKEND=coraza-01-local-backend
readonly TRAEFIK=coraza-01-local-traefik
readonly TRAEFIK_IMAGE='rancher/mirrored-library-traefik:3.7.4@sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03'
readonly BACKEND_IMAGE='traefik/whoami:v1.11.0@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

cleanup() {
  docker rm -f "$TRAEFIK" "$BACKEND" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}

if docker container inspect "$TRAEFIK" >/dev/null 2>&1 ||
   docker container inspect "$BACKEND" >/dev/null 2>&1 ||
   docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "중단: $NETWORK 또는 전용 컨테이너 이름이 이미 사용 중이다." >&2
  exit 2
fi

trap cleanup EXIT

docker network create "$NETWORK" >/dev/null
docker run -d --name "$BACKEND" --network "$NETWORK" \
  "$BACKEND_IMAGE" --port=8080 >/dev/null

run_traefik() {
  local dynamic_file=$1
  docker run -d --name "$TRAEFIK" --network "$NETWORK" \
    -p 127.0.0.1:18080:18080 \
    -v "$SCRIPT_DIR/local-static.yaml:/etc/traefik/traefik.yaml:ro" \
    -v "$SCRIPT_DIR/$dynamic_file:/etc/traefik/dynamic.yaml:ro" \
    "$TRAEFIK_IMAGE" >/dev/null
}

run_traefik local-dynamic-control.yaml
control_code=''
for _ in {1..15}; do
  control_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:18080/control 2>/dev/null || true)
  [[ "$control_code" == 200 ]] && break
  sleep 1
done

[[ "$control_code" == 200 ]]
[[ "$(docker inspect "$TRAEFIK" --format '{{.State.Running}}')" == true ]]
echo 'PASS: 고정 plugin은 middleware가 없을 때 로드되고 control route가 HTTP 200이다.'

docker rm -f "$TRAEFIK" >/dev/null

assert_split_stack_overflow() {
  local dynamic_file=$1
  local label=$2
  local running exit_code oom_killed traefik_logs

  run_traefik "$dynamic_file"
  sleep 5

  running=$(docker inspect "$TRAEFIK" --format '{{.State.Running}}')
  exit_code=$(docker inspect "$TRAEFIK" --format '{{.State.ExitCode}}')
  oom_killed=$(docker inspect "$TRAEFIK" --format '{{.State.OOMKilled}}')

  if [[ "$running" != false || "$exit_code" != 2 || "$oom_killed" != false ]]; then
    echo "예상과 다른 결과: running=$running exit=$exit_code oom=$oom_killed" >&2
    docker logs "$TRAEFIK" >&2
    exit 1
  fi

  traefik_logs="$(docker logs "$TRAEFIK" 2>&1)"
  if [[ "$traefik_logs" != *'fatal error: runtime: split stack overflow'* ]]; then
    echo '예상한 split stack overflow가 로그에 없다.' >&2
    printf '%s\n' "$traefik_logs" >&2
    exit 1
  fi

  docker rm -f "$TRAEFIK" >/dev/null
  echo "BLOCKED 재현: $label 초기화가 Traefik을 exit 2로 종료했다."
}

assert_split_stack_overflow local-dynamic-minimal.yaml '최소 Coraza middleware'
assert_split_stack_overflow local-dynamic.yaml '전체 CRS 및 좁은 예외 policy'
