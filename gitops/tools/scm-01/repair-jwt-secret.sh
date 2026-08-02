#!/usr/bin/env bash
# 초기 SCM-01 생성기의 64자 hex JWT만 Gitea raw URL-safe Base64로 1회 교체한다.
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly env_file=${SCM01_ENV_FILE:-"$KTC_SECRET_ROOT/gitea/env"}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root

[[ -f "${env_file}" && ! -L "${env_file}" ]] || {
  echo "SCM-01 env는 일반 non-symlink 파일여야 한다." >&2
  exit 1
}
[[ "$(stat -c %u "${env_file}")" -eq "$(id -u)" && "$(stat -c %a "${env_file}")" == 600 ]] || {
  echo "SCM-01 env는 호출자 소유 mode 0600이어야 한다." >&2
  exit 1
}
case "$(realpath -m "${env_file}")" in
  "${repo_root}"|"${repo_root}"/*)
    echo "SCM-01 env는 저장소 밖에 있어야 한다." >&2
    exit 1
    ;;
esac

[[ "$(awk -F= '$1=="GITEA_JWT_SECRET"{n++} END{print n+0}' "${env_file}")" -eq 1 ]] || {
  echo "GITEA_JWT_SECRET가 정확히 1건이 아니다." >&2
  exit 1
}
legacy_value=$(awk -F= '$1=="GITEA_JWT_SECRET"{print substr($0,index($0,"=")+1)}' "${env_file}")
[[ "${legacy_value}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "초기 생성기의 64자 소문자 hex JWT가 아니므로 변경하지 않는다." >&2
  exit 1
}

new_value=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')
[[ "${#new_value}" -eq 43 && "${new_value}" =~ ^[A-Za-z0-9_-]+$ ]]

umask 077
temp_file=$(mktemp "$(dirname "${env_file}")/.scm-01-jwt.XXXXXX")
cleanup() {
  rm -f "${temp_file}"
}
trap cleanup EXIT INT TERM

before_non_jwt=$(awk '$0 !~ /^GITEA_JWT_SECRET=/' "${env_file}" | sha256sum | awk '{print $1}')
awk -v replacement="GITEA_JWT_SECRET=${new_value}" '
  /^GITEA_JWT_SECRET=/{print replacement; next}
  {print}
' "${env_file}" >"${temp_file}"
chmod 0600 "${temp_file}"
after_non_jwt=$(awk '$0 !~ /^GITEA_JWT_SECRET=/' "${temp_file}" | sha256sum | awk '{print $1}')
[[ "${before_non_jwt}" == "${after_non_jwt}" ]]
[[ "$(awk -F= '$1=="GITEA_JWT_SECRET"{print length($2)}' "${temp_file}")" -eq 43 ]]

mv "${temp_file}" "${env_file}"
trap - EXIT INT TERM
echo "SCM-01 외부 env의 legacy JWT 1건을 Gitea raw URL-safe Base64로 교체했다."
