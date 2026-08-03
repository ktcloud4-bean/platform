#!/usr/bin/env bash
# WAZUH-01 OPNsense Wazuh Agent 적용과 rollback.
#
# 공식 플러그인 os-wazuh-agent만 설치하고 Suricata `eve.json` 한 소스만 켠다.
# active response, remote command, rootcheck, syscollector, syscheck, syslog 수집은 모두 끈다.
# 방화벽 rule, NAT, DNS, Suricata 룰셋, 인터페이스는 바꾸지 않는다.
# authd 등록 password는 저장소 밖 mode 0600 입력에서 읽고 출력하지 않는다.
set -euo pipefail

readonly action=${1:-}
readonly recovery_point_arg=${2:-}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/wazuh
readonly env_file=${OPN_ENV_FILE:-${secret_root}/opnsense/env}
readonly plugin_name=os-wazuh-agent
readonly agent_name=${WAZUH01_AGENT_NAME:-opnsense-01}
readonly manager_address=${WAZUH01_MANAGER_ADDRESS:-10.10.20.10}
readonly manager_events_port=${WAZUH01_MANAGER_EVENTS_PORT:-31514}
readonly manager_auth_port=${WAZUH01_MANAGER_AUTH_PORT:-31515}
readonly recovery_root=${WAZUH01_RECOVERY_ROOT:-/home/imcherry/.local/state-backups}

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

fail() {
  echo "WAZUH-01 OPNsense 실패: $*" >&2
  exit 1
}

[[ ${action} == apply || ${action} == rollback ]] || usage
[[ ${action} != rollback || -n ${recovery_point_arg} ]] || usage

opn_tmp=''
cleanup() {
  [[ -n ${opn_tmp} && -d ${opn_tmp} ]] && rm -rf "${opn_tmp}"
  return 0
}
trap cleanup EXIT HUP INT TERM

load_env() {
  local mode owner_id key value line
  [[ ! -L ${env_file} && -f ${env_file} && -r ${env_file} ]] \
    || fail "OPNsense env 파일을 안전하게 읽을 수 없다: ${env_file}"
  mode=$(stat -c '%a' "${env_file}")
  owner_id=$(stat -c '%u' "${env_file}")
  [[ ${owner_id} == "$(id -u)" && $((10#${mode} % 100)) -eq 0 ]] \
    || fail 'OPNsense env 파일의 소유자 또는 권한이 안전하지 않다.'
  OPN_KEY=''; OPN_SECRET=''; OPN_URL=''
  while IFS= read -r line || [[ -n ${line} ]]; do
    line=${line%$'\r'}
    [[ ${line} == OPN_* && ${line} == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    value=${value%\"}; value=${value#\"}
    value=${value%\'}; value=${value#\'}
    case ${key} in
      OPN_KEY|OPN_SECRET|OPN_URL) printf -v "${key}" '%s' "${value}" ;;
    esac
  done <"${env_file}"
  OPN_URL=${OPN_URL:-https://opnsense.imcherry5778.xyz}
  [[ -n ${OPN_KEY} && -n ${OPN_SECRET} ]] || fail 'OPN_KEY와 OPN_SECRET이 필요하다.'
  [[ ${OPN_URL} == https://* && ${OPN_URL} != *'@'* ]] \
    || fail 'OPN_URL은 credential 없는 https URL이어야 한다.'
  opn_tmp=$(mktemp -d /tmp/wazuh-01-opnsense.XXXXXX)
  chmod 700 "${opn_tmp}"
  umask 077
  printf 'user = "%s:%s"\n' "${OPN_KEY//\"/\\\"}" "${OPN_SECRET//\"/\\\"}" >"${opn_tmp}/auth.conf"
  chmod 600 "${opn_tmp}/auth.conf"
}

api() {
  local method=$1 path=$2 output=$3 body=${4:-}
  local -a args=(-q --silent --show-error --fail -K "${opn_tmp}/auth.conf" -o "${output}")
  if [[ ${method} == POST ]]; then
    args+=(-X POST -H 'Content-Type: application/json' --data "${body:-{\}}")
  fi
  curl "${args[@]}" "${OPN_URL}${path}" || fail "API 호출 실패: ${method} ${path}"
  jq -e . "${output}" >/dev/null || fail "JSON이 아닌 API 응답이다: ${path}"
}

plugin_installed() {
  local info=${opn_tmp}/firmware-info.json
  api GET /api/core/firmware/info "${info}"
  jq -r --arg name "${plugin_name}" \
    '[.plugin[] | select(.name == $name)][0].installed // "0"' "${info}"
}

wait_for_plugin_state() {
  local expected=$1 running=${opn_tmp}/firmware-running.json
  for _ in $(seq 1 90); do
    api GET /api/core/firmware/running "${running}"
    if jq -e '.status == "ready"' "${running}" >/dev/null; then
      if [[ $(plugin_installed) == "${expected}" ]]; then
        return 0
      fi
    fi
    sleep 5
  done
  fail "${plugin_name} installed=${expected} 상태가 확인되지 않았다."
}

service_status() {
  local output=${opn_tmp}/service-status.json
  api GET /api/wazuhagent/service/status "${output}"
  jq -r '.status // "unknown"' "${output}"
}

make_recovery_point() {
  local point
  install -d -m 0700 "${recovery_root}"
  point=$(mktemp -d "${recovery_root}/wazuh-01-opnsense-XXXXXXXX")
  chmod 700 "${point}"
  # 이 endpoint는 JSON이 아니라 raw config XML을 돌려주므로 api() 헬퍼를 쓰지 않는다.
  curl -q --silent --show-error --fail -K "${opn_tmp}/auth.conf" \
    -o "${point}/config-before.xml" "${OPN_URL}/api/core/backup/download/this" \
    || fail '변경 전 config 사본을 받지 못했다.'
  chmod 600 "${point}/config-before.xml"
  grep -q '<opnsense>' "${point}/config-before.xml" \
    || fail '변경 전 config 사본이 OPNsense config XML이 아니다.'
  echo "${point}"
}

if [[ ${action} == apply ]]; then
  [[ -f ${secret_dir}/authd-password && ! -L ${secret_dir}/authd-password ]] \
    || fail 'authd 등록 password 입력이 없다. provision.sh apply를 먼저 실행한다.'
  load_env

  recovery_point=$(make_recovery_point)
  echo "RecoveryPoint=${recovery_point}"

  if [[ $(plugin_installed) != "1" ]]; then
    api POST "/api/core/firmware/install/${plugin_name}" "${opn_tmp}/install.json"
    wait_for_plugin_state 1
    echo "Plugin=INSTALLED name=${plugin_name}"
  else
    echo "Plugin=ALREADY-INSTALLED name=${plugin_name}"
  fi

  settings_body=$(jq -cn \
    --arg server "${manager_address}" \
    --arg agent "${agent_name}" \
    --arg port "${manager_events_port}" \
    --arg auth_port "${manager_auth_port}" \
    --rawfile password "${secret_dir}/authd-password" '
    {
      agent: {
        general: {
          enabled: "1",
          server_address: $server,
          agent_name: $agent,
          protocol: "tcp",
          port: $port,
          debug_level: "0"
        },
        auth: {
          password: ($password | rtrimstr("\n")),
          port: $auth_port
        },
        logcollector: {
          remote_commands: "0",
          syslog_programs: "",
          suricata_eve_log: "1"
        },
        rootcheck: { enabled: "0" },
        syscollector: { enabled: "0" },
        syscheck: { enabled: "0" },
        active_response: { enabled: "0", remote_commands: "0" }
      }
    }')
  api POST /api/wazuhagent/settings/set "${opn_tmp}/set.json" "${settings_body}"
  jq -e '.result == "saved"' "${opn_tmp}/set.json" >/dev/null \
    || fail "설정 저장이 saved가 아니다: $(jq -c '.validations // .result' "${opn_tmp}/set.json")"
  unset settings_body

  api POST /api/wazuhagent/service/reconfigure "${opn_tmp}/reconfigure.json"
  for _ in $(seq 1 60); do
    [[ $(service_status) == running ]] && break
    sleep 5
  done
  [[ $(service_status) == running ]] || fail 'wazuh agent 서비스가 running이 아니다.'

  # 저장된 의미값만 다시 읽어 확인한다. password는 읽지도 출력하지도 않는다.
  api GET /api/wazuhagent/settings/get "${opn_tmp}/get.json"
  jq -e --arg server "${manager_address}" --arg port "${manager_events_port}" \
        --arg auth_port "${manager_auth_port}" --arg agent "${agent_name}" '
    .agent.general.enabled == "1" and
    .agent.general.server_address == $server and
    .agent.general.agent_name == $agent and
    .agent.general.port == $port and
    .agent.auth.port == $auth_port and
    .agent.logcollector.suricata_eve_log == "1" and
    .agent.logcollector.remote_commands == "0" and
    .agent.rootcheck.enabled == "0" and
    .agent.syscollector.enabled == "0" and
    .agent.syscheck.enabled == "0" and
    .agent.active_response.enabled == "0" and
    .agent.active_response.remote_commands == "0"
  ' "${opn_tmp}/get.json" >/dev/null \
    || fail '저장된 agent 설정이 계획과 다르다.'
  echo "Settings=PASS server=${manager_address}:${manager_events_port} auth_port=${manager_auth_port} suricata_eve_log=1 active_response=0 rootcheck=0 syscollector=0 syscheck=0 remote_commands=0"
  echo 'WAZUH01_OPNSENSE_APPLY=PASS'
  exit 0
fi

load_env
[[ -d ${recovery_point_arg} ]] || fail "복구 지점 디렉터리가 없다: ${recovery_point_arg}"

if [[ $(plugin_installed) == "1" ]]; then
  api POST /api/wazuhagent/service/stop "${opn_tmp}/stop.json" || true
  disable_body=$(jq -cn '{agent: {general: {enabled: "0"}}}')
  api POST /api/wazuhagent/settings/set "${opn_tmp}/disable.json" "${disable_body}" || true
  api POST /api/wazuhagent/service/reconfigure "${opn_tmp}/reconfigure.json" || true
  api POST "/api/core/firmware/remove/${plugin_name}" "${opn_tmp}/remove.json"
  wait_for_plugin_state 0
  echo "Plugin=REMOVED name=${plugin_name}"
else
  echo "Plugin=ALREADY-ABSENT name=${plugin_name}"
fi
echo "WAZUH01_OPNSENSE_ROLLBACK=PASS recovery_point=${recovery_point_arg}"
