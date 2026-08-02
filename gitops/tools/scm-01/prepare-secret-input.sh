#!/usr/bin/env bash
# SCM-01 외부 입력을 새 파일일 때만 생성한다. 기존 env는 절대 덮어쓰지 않는다.
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
output=${1:-"$KTC_SECRET_ROOT/gitea/env"}

case "${output}" in
  /*) ;;
  *) echo "입력 파일은 절대 경로여야 한다: ${output}" >&2; exit 1 ;;
esac
if [[ -e "${output}" || -L "${output}" ]]; then
  echo "기존 SCM-01 입력을 덮어쓰지 않는다: ${output}" >&2
  exit 1
fi

install -d -m 0700 "$(dirname "${output}")"
umask 077
temp_file=$(mktemp "$(dirname "${output}")/.scm-01-env.XXXXXX")
cleanup() {
  rm -f "${temp_file}"
}
trap cleanup EXIT INT TERM

random_alnum() {
  local length=$1
  openssl rand -base64 "$((length * 2))" | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "${length}"
}

random_gitea_jwt() {
  # Gitea generate.NewJwtSecretWithBase64(): 32 bytes, raw URL-safe Base64 (padding 없음).
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
}

{
  printf 'GITEA_DB_PASSWORD=%s\n' "$(random_alnum 40)"
  printf 'GITEA_LOCAL_ADMIN_PASSWORD=%s\n' "$(random_alnum 40)"
  printf 'GITEA_OIDC_CLIENT_SECRET=%s\n' "$(random_alnum 48)"
  printf 'GITEA_SECRET_KEY=%s\n' "$(openssl rand -hex 32)"
  printf 'GITEA_INTERNAL_TOKEN=%s\n' "$(openssl rand -hex 32)"
  printf 'GITEA_JWT_SECRET=%s\n' "$(random_gitea_jwt)"
  printf 'GITEA_WEBHOOK_SECRET=%s\n' "$(openssl rand -hex 32)"
} >"${temp_file}"
chmod 0600 "${temp_file}"
mv "${temp_file}" "${output}"
trap - EXIT INT TERM
echo "SCM-01 외부 입력 생성 완료: ${output} (mode 0600)"
