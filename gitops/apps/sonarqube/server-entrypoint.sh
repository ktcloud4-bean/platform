#!/usr/bin/env bash
set -Eeuo pipefail

readonly runtime_env=/vault/secrets/runtime.env
[[ -r "${runtime_env}" ]] || {
  echo "Vault Agent가 렌더링한 runtime.env를 읽을 수 없다." >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "${runtime_env}"
set +a

: "${SONAR_JDBC_PASSWORD:?SONAR_JDBC_PASSWORD가 비어 있다}"
exec /opt/sonarqube/docker/entrypoint.sh
