#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
output=${1:-"$repo_root/gitops/apps/crowdsec/.env"}

if [[ -e $output || -L $output ]]; then
  printf '오류: 기존 경로를 덮어쓰지 않습니다: %s\n' "$output" >&2
  exit 2
fi

umask 077
{
  printf 'CS_LAPI_SECRET='
  openssl rand -hex 32
  printf 'REGISTRATION_TOKEN='
  openssl rand -hex 32
  printf 'BOUNCER_KEY_CROWDSEC_01='
  openssl rand -hex 32
} > "$output"
chmod 600 "$output"

printf '생성 완료: %s (mode 0600, 값은 출력하지 않음)\n' "$output"
