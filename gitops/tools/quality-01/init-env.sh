#!/usr/bin/env bash
# QUALITY-01의 사람이 보관할 두 자격증명을 저장소 밖 단일 env 파일로 만든다.
set -Eeuo pipefail

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly component_dir=${secret_root}/sonarqube
readonly env_file=${component_dir}/env

case "${secret_root}" in
  /|/home|/home/*/projects|/home/*/projects/*)
    echo "KTC_SECRET_ROOT가 너무 넓거나 저장소 경로다: ${secret_root}" >&2
    exit 1
    ;;
esac
[[ "${secret_root}" = /* ]] || {
  echo "KTC_SECRET_ROOT는 절대 경로여야 한다." >&2
  exit 1
}

validate() {
  [[ -f "${env_file}" && ! -L "${env_file}" ]] || return 1
  [[ "$(stat -c %a "${env_file}")" == 600 ]] || return 1
  [[ "$(stat -c %u "${env_file}")" == "$(id -u)" ]] || return 1
  grep -Eq '^SONARQUBE_DB_PASSWORD=[A-Za-z0-9]{40}$' "${env_file}"
  grep -Eq '^SONARQUBE_ADMIN_PASSWORD=Aa1![A-Za-z0-9]{36}$' "${env_file}"
}

if [[ -e "${env_file}" ]]; then
  validate || {
    echo "기존 ${env_file}의 파일 형식·소유자·mode 0600 계약이 맞지 않는다." >&2
    exit 1
  }
  echo "QUALITY-01 비밀 입력이 이미 유효하다: ${env_file}"
  exit 0
fi

umask 077
mkdir -p "${component_dir}"
chmod 0700 "${component_dir}"
{
  printf 'SONARQUBE_DB_PASSWORD='
  openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-40
  printf '\nSONARQUBE_ADMIN_PASSWORD='
  printf 'Aa1!'
  openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-36
  printf '\n'
} >"${env_file}"
chmod 0600 "${env_file}"
validate || {
  echo "생성된 QUALITY-01 env 검증에 실패했다." >&2
  exit 1
}
echo "QUALITY-01 비밀 입력을 만들었다: ${env_file} (mode 0600)"
