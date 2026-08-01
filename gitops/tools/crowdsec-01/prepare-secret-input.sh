#!/usr/bin/env bash
set -euo pipefail

# 비밀은 저장소 밖 mode 0600 파일에 둔다. `git clean -xfd`와 worktree 정리가 저장소 안
# 파일을 지우고, 실수로 commit할 경로에 아예 존재하지 않게 하기 위해서다.
# 위치는 KTC_SECRET_ROOT로 주입하며 위치인자가 있으면 그쪽이 항상 우선한다.
: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
output=${1:-"$KTC_SECRET_ROOT/crowdsec/env"}

if [[ -e $output || -L $output ]]; then
  printf '오류: 기존 경로를 덮어쓰지 않습니다: %s\n' "$output" >&2
  exit 2
fi

umask 077
install -d -m 700 "$(dirname "$output")"
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
