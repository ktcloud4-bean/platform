#!/usr/bin/env bash
# LOKI-02 전용 OPNsense API helper. credential은 curl config에만 잠시 둔다.
set -euo pipefail

readonly LOKI02_DEFAULT_URL='https://opnsense.imcherry5778.xyz'
readonly LOKI02_DEFAULT_ENV_FILE="${KTC_SECRET_ROOT:-${HOME}/secrets/ktcloud4-bean}/opnsense/env"

loki02_fail() {
  echo "LOKI-02 실패: $*" >&2
  exit 1
}

loki02_curl_escape() {
  local escaped=${1//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf '%s' "${escaped}"
}

loki02_load_env() {
  local env_file=${1:-${LOKI02_DEFAULT_ENV_FILE}}
  local line trimmed key value mode owner_id
  declare -A seen=()

  export -n OPN_KEY OPN_SECRET 2>/dev/null || true
  [[ ! -L ${env_file} && -f ${env_file} && -r ${env_file} ]] \
    || loki02_fail "OPNsense env 파일을 안전하게 읽을 수 없다: ${env_file}"
  mode=$(stat -c '%a' "${env_file}")
  owner_id=$(stat -c '%u' "${env_file}")
  [[ ${owner_id} == "$(id -u)" && $((10#${mode} % 100)) -eq 0 ]] \
    || loki02_fail "OPNsense env 파일의 소유자 또는 권한이 안전하지 않다: ${env_file}"

  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line%$'\r'}
    trimmed=${line#"${line%%[![:space:]]*}"}
    case ${trimmed} in ''|'#'*) continue ;; esac
    [[ ${line} == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    [[ ${key} == OPN_* ]] || continue
    case ${key} in OPN_KEY|OPN_SECRET|OPN_URL|OPN_CACERT) ;; *) loki02_fail "허용되지 않은 OPN_* 항목: ${key}" ;; esac
    [[ -z ${seen[${key}]+x} ]] || loki02_fail "중복된 OPN_* 항목: ${key}"
    seen[${key}]=1
    if [[ ${value} == \"*\" && ${#value} -ge 2 ]] || [[ ${value} == \'*\' && ${#value} -ge 2 ]]; then
      value=${value:1:${#value}-2}
    elif [[ ${value} == \"* || ${value} == *\" || ${value} == \'* || ${value} == *\' ]]; then
      loki02_fail "닫히지 않은 따옴표: ${key}"
    fi
    printf -v "${key}" '%s' "${value}"
  done < "${env_file}"

  OPN_URL=${OPN_URL:-${LOKI02_DEFAULT_URL}}
  OPN_CACERT=${OPN_CACERT:-}
  [[ -n ${OPN_KEY:-} && -n ${OPN_SECRET:-} ]] || loki02_fail 'OPN_KEY와 OPN_SECRET이 필요하다.'
  [[ ${OPN_KEY} != *:* && ${OPN_KEY} != *$'\n'* && ${OPN_KEY} != *$'\r'* ]] || loki02_fail 'OPN_KEY 형식이 안전하지 않다.'
  [[ ${OPN_SECRET} != *$'\n'* && ${OPN_SECRET} != *$'\r'* ]] || loki02_fail 'OPN_SECRET 형식이 안전하지 않다.'
  [[ ${OPN_URL} == https://* && ${OPN_URL} != *'@'* ]] || loki02_fail 'OPN_URL은 credential 없는 https URL이어야 한다.'
  [[ -z ${OPN_CACERT} || -r ${OPN_CACERT} ]] || loki02_fail 'OPN_CACERT를 읽을 수 없다.'

  LOKI02_API_TMP=$(mktemp -d /tmp/loki-02-api.XXXXXX)
  chmod 700 "${LOKI02_API_TMP}"
  LOKI02_AUTH_CONFIG=${LOKI02_API_TMP}/curl-auth.conf
  umask 077
  printf 'user = "%s:%s"\n' "$(loki02_curl_escape "${OPN_KEY}")" "$(loki02_curl_escape "${OPN_SECRET}")" > "${LOKI02_AUTH_CONFIG}"
  chmod 600 "${LOKI02_AUTH_CONFIG}"
  export -n OPN_KEY OPN_SECRET 2>/dev/null || true
}

loki02_cleanup() {
  [[ -n ${LOKI02_API_TMP:-} && -d ${LOKI02_API_TMP} ]] && rm -rf -- "${LOKI02_API_TMP}"
}

loki02_api_json() {
  local method=$1 path=$2 output=$3 body_file=${4:-}
  local -a tls_options=() body_options=()
  [[ ${path} == /api/* ]] || loki02_fail "허용되지 않은 API path다: ${path}"
  case ${method} in GET|POST) ;; *) loki02_fail "허용되지 않은 HTTP method다: ${method}" ;; esac
  [[ -z ${OPN_CACERT:-} ]] || tls_options=(--cacert "${OPN_CACERT}")
  if [[ -n ${body_file} ]]; then
    [[ -f ${body_file} ]] || loki02_fail "API body 파일이 없다: ${body_file}"
    body_options=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  elif [[ ${method} == POST ]]; then
    body_options=(--data '')
  fi
  curl -q --silent --show-error --fail --connect-timeout 10 --max-time 300 \
    --config "${LOKI02_AUTH_CONFIG}" "${tls_options[@]}" --request "${method}" \
    "${body_options[@]}" "${OPN_URL%/}${path}" -o "${output}"
  jq -e . "${output}" >/dev/null || loki02_fail "JSON이 아닌 API 응답이다: ${path}"
}
