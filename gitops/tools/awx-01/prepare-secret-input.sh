#!/usr/bin/env bash
# AWX-01 사람이 소유하는 저장소 밖 입력 파일을 최초 한 번만 만든다.
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:?KTC_SECRET_ROOT가 필요하다}"
readonly secret_dir=${KTC_SECRET_ROOT}/awx
readonly env_file=${secret_dir}/env

case "${secret_dir}" in
  /|/home|/home/*/projects|/home/*/projects/*)
    echo "비밀 경로가 너무 넓거나 저장소 아래다: ${secret_dir}" >&2
    exit 1
    ;;
esac

umask 077
mkdir -p "${secret_dir}"
if [[ -e "${env_file}" ]]; then
  [[ -f "${env_file}" && "$(stat -c %a "${env_file}")" == 600 ]] || {
    echo "기존 ${env_file}은 일반 파일 mode 0600이어야 한다." >&2
    exit 1
  }
  echo "기존 AWX-01 입력을 보존했다: ${env_file}"
  exit 0
fi

db_password=$(openssl rand -hex 24)
admin_password=$(openssl rand -hex 24)
secret_key=$(openssl rand -hex 32)
oidc_client_secret=$(openssl rand -hex 24)
verifier_password=$(openssl rand -hex 24)
verifier_denied_password=$(openssl rand -hex 24)

{
  printf 'AWX_DB_PASSWORD=%s\n' "${db_password}"
  printf 'AWX_ADMIN_PASSWORD=%s\n' "${admin_password}"
  printf 'AWX_SECRET_KEY=%s\n' "${secret_key}"
  printf 'AWX_OIDC_CLIENT_SECRET=%s\n' "${oidc_client_secret}"
  printf 'AWX_VERIFIER_PASSWORD=%s\n' "${verifier_password}"
  printf 'AWX_VERIFIER_DENIED_PASSWORD=%s\n' "${verifier_denied_password}"
} >"${env_file}"
chmod 0600 "${env_file}"
unset db_password admin_password secret_key oidc_client_secret verifier_password verifier_denied_password
echo "AWX-01 입력을 만들었다: ${env_file} (mode 0600)"
