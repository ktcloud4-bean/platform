#!/usr/bin/env bash
# gitops/tools/wazuh-03/lib-opnsense.sh
# gitops/tools/obs-11/lib-opnsense.sh와 동일한 구조의 WAZUH-03 전용 사본이다.
# 이 저장소는 도구별 lib를 공유하지 않고 작업 디렉터리마다 자기 것을 둔다.

set -euo pipefail

readonly WAZUH03_DEFAULT_URL='https://opnsense.imcherry5778.xyz'
readonly WAZUH03_DEFAULT_ENV_FILE="${KTC_SECRET_ROOT:-${HOME}/secrets/ktcloud4-bean}/opnsense/env"

wazuh03_fail() {
  echo "WAZUH-03 실패: $*" >&2
  exit 1
}

wazuh03_load_env() {
  local env_file=${1:-${WAZUH03_DEFAULT_ENV_FILE}}
  local line trimmed line_number key value mode owner_id
  declare -A seen=()

  export -n OPN_KEY OPN_SECRET 2>/dev/null || true
  [[ ! -L ${env_file} && -f ${env_file} && -r ${env_file} ]] \
    || wazuh03_fail "OPNsense env 파일을 안전하게 읽을 수 없다: ${env_file}"
  mode=$(stat -c '%a' "${env_file}")
  owner_id=$(stat -c '%u' "${env_file}")
  [[ ${owner_id} == "$(id -u)" && $((10#${mode} % 100)) -eq 0 ]] \
    || wazuh03_fail "OPNsense env 파일의 소유자 또는 권한이 안전하지 않다: ${env_file}"

  line_number=0
  while IFS= read -r line || [[ -n ${line} ]]; do
    line_number=$((line_number + 1))
    line=${line%$'\r'}
    trimmed=${line#"${line%%[![:space:]]*}"}
    case ${trimmed} in
      ''|'#'*) continue ;;
    esac
    [[ ${line} == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    [[ ${key} == OPN_* ]] || continue
    case ${key} in
      OPN_KEY|OPN_SECRET|OPN_URL|OPN_CACERT) ;;
      *) wazuh03_fail "${env_file}:${line_number}: 허용되지 않은 OPN_* 항목이다: ${key}" ;;
    esac
    [[ -z ${seen[${key}]+x} ]] \
      || wazuh03_fail "${env_file}:${line_number}: 중복된 항목이다: ${key}"
    seen[${key}]=1
    if [[ ${value} == \" || ${value} == \' ]]; then
      wazuh03_fail "${env_file}:${line_number}: 따옴표가 닫히지 않았다: ${key}"
    elif [[ ${value} == \"*\" && ${value} == *\" ]] \
      || [[ ${value} == \'*\' && ${value} == *\' ]]; then
      value=${value:1:${#value}-2}
    elif [[ ${value} == \"* || ${value} == *\" || ${value} == \'* || ${value} == *\' ]]; then
      wazuh03_fail "${env_file}:${line_number}: 따옴표가 닫히지 않았다: ${key}"
    fi
    if ! [[ -v ${key} ]]; then
      printf -v "${key}" '%s' "${value}"
    fi
  done < "${env_file}"

  OPN_URL=${OPN_URL:-${WAZUH03_DEFAULT_URL}}
  OPN_CACERT=${OPN_CACERT:-}
  [[ -n ${OPN_KEY:-} && -n ${OPN_SECRET:-} ]] \
    || wazuh03_fail 'OPN_KEY와 OPN_SECRET이 필요하다.'
  [[ ${OPN_KEY} != *:* && ${OPN_KEY} != *$'\n'* && ${OPN_KEY} != *$'\r'* ]] \
    || wazuh03_fail 'OPN_KEY 형식이 안전하지 않다.'
  [[ ${OPN_SECRET} != *$'\n'* && ${OPN_SECRET} != *$'\r'* ]] \
    || wazuh03_fail 'OPN_SECRET 형식이 안전하지 않다.'
  [[ ${OPN_URL} == https://* && ${OPN_URL} != *'@'* ]] \
    || wazuh03_fail 'OPN_URL은 credential 없는 https URL이어야 한다.'
  if [[ -n ${OPN_CACERT} ]]; then
    [[ -f ${OPN_CACERT} && -r ${OPN_CACERT} ]] \
      || wazuh03_fail 'OPN_CACERT를 읽을 수 없다.'
  fi

  WAZUH03_API_TMP=$(mktemp -d /tmp/wazuh-03-api.XXXXXX)
  chmod 700 "${WAZUH03_API_TMP}"
  WAZUH03_AUTH_CONFIG=${WAZUH03_API_TMP}/curl-auth.conf
  umask 077
  printf 'user = "%s:%s"\n' \
    "$(wazuh03_curl_escape "${OPN_KEY}")" \
    "$(wazuh03_curl_escape "${OPN_SECRET}")" > "${WAZUH03_AUTH_CONFIG}"
  chmod 600 "${WAZUH03_AUTH_CONFIG}"
  export -n OPN_KEY OPN_SECRET 2>/dev/null || true
}

wazuh03_curl_escape() {
  local escaped=${1//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf '%s' "${escaped}"
}

wazuh03_cleanup() {
  if [[ -n ${WAZUH03_API_TMP:-} && -d ${WAZUH03_API_TMP} ]]; then
    rm -rf -- "${WAZUH03_API_TMP}"
  fi
}

wazuh03_api() {
  local method=$1 path=$2 output=$3 body_file=${4:-}
  local -a tls_options=()
  [[ ${path} == /api/* ]] || wazuh03_fail "허용되지 않은 API path다: ${path}"
  case ${method} in
    GET|POST) ;;
    *) wazuh03_fail "허용되지 않은 HTTP method다: ${method}" ;;
  esac
  if [[ -n ${OPN_CACERT:-} ]]; then
    tls_options=(--cacert "${OPN_CACERT}")
  fi
  local -a body_options=()
  if [[ -n ${body_file} ]]; then
    [[ -f ${body_file} ]] || wazuh03_fail "API body 파일이 없다: ${body_file}"
    body_options=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  elif [[ ${method} == POST ]]; then
    body_options=(--data '')
  fi
  curl -q --silent --show-error --fail \
    --connect-timeout 10 --max-time 300 \
    --config "${WAZUH03_AUTH_CONFIG}" \
    "${tls_options[@]}" --request "${method}" \
    "${body_options[@]}" \
    "${OPN_URL%/}${path}" -o "${output}"
}

wazuh03_api_json() {
  local method=$1 path=$2 output=$3 body_file=${4:-}
  wazuh03_api "${method}" "${path}" "${output}" "${body_file}"
  jq -e . "${output}" >/dev/null \
    || wazuh03_fail "JSON이 아닌 API 응답이다: ${path}"
}
