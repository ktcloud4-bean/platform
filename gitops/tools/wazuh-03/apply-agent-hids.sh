#!/usr/bin/env bash
# gitops/tools/wazuh-03/apply-agent-hids.sh
#
# WAZUH-03: OPNsense 기존 os-wazuh-agent(WAZUH-01이 suricata_eve_log만 켠 상태)의
# rootcheck·syscheck를 enabled=1로 전환한다. general·auth·logcollector·syscollector·
# active_response는 WAZUH-01이 검증한 값을 그대로 유지한다(재사용, 새 credential 없음).
#
# 이 OPNsense 플러그인의 settings API는 rootcheck·syscheck 각각 enabled 토글만
# 노출하고 감시 경로(directories) 필드가 없다 — GET /api/wazuhagent/settings/get으로
# 확인한 스키마 전체가 이렇다. 그래서 "감시 경로 최소화"는 이 플러그인이 내부에서
# 만드는 기본 ossec.conf 템플릿에 맡기고, 실제 감시 범위는 verify-live.sh가 manager에
# 쌓인 FIM alert의 path 필드로 사후 확인한다. 플러그인이 전체 파일시스템을 감시하는
# 것으로 확인되면 rootcheck·syscheck 중 이 파일이 다루지 않는 추가 축소 수단은 없다 —
# 그 경우 결과를 완료 증거에 그대로 기록한다.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-opnsense.sh
source "${script_dir}/lib-opnsense.sh"
trap wazuh03_cleanup EXIT HUP INT TERM

readonly action=${1:-}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/wazuh
readonly manager_address=${WAZUH03_MANAGER_ADDRESS:-10.10.20.10}
readonly manager_events_port=${WAZUH03_MANAGER_EVENTS_PORT:-31514}
readonly manager_auth_port=${WAZUH03_MANAGER_AUTH_PORT:-31515}
readonly agent_name=${WAZUH03_AGENT_NAME:-opnsense-01}

usage() {
  echo "사용법: $0 apply | rollback" >&2
  exit 2
}

[[ ${action} == apply || ${action} == rollback ]] || usage

service_status() {
  local output=${WAZUH03_API_TMP}/service-status.json
  wazuh03_api_json GET /api/wazuhagent/service/status "${output}"
  jq -r '.status // "unknown"' "${output}"
}

wait_for_running() {
  for _ in $(seq 1 60); do
    [[ $(service_status) == running ]] && return 0
    sleep 5
  done
  wazuh03_fail 'wazuh agent 서비스가 running이 아니다.'
}

set_rootcheck_syscheck() {
  local target=$1 body=${WAZUH03_API_TMP}/set.json get_before=${WAZUH03_API_TMP}/get-before.json
  local settings_body

  wazuh03_api_json GET /api/wazuhagent/settings/get "${get_before}"
  jq -e --arg server "${manager_address}" --arg port "${manager_events_port}" \
        --arg auth_port "${manager_auth_port}" --arg agent "${agent_name}" '
    .agent.general.enabled == "1" and
    .agent.general.server_address == $server and
    .agent.general.agent_name == $agent and
    .agent.general.port == $port and
    .agent.auth.port == $auth_port and
    .agent.logcollector.suricata_eve_log == "1" and
    .agent.logcollector.remote_commands == "0" and
    .agent.syscollector.enabled == "0" and
    .agent.active_response.enabled == "0" and
    .agent.active_response.remote_commands == "0"
  ' "${get_before}" >/dev/null \
    || wazuh03_fail 'WAZUH-01 기존 설정(general·auth·logcollector·syscollector·active_response)이 예상과 다르다.'

  [[ -f ${secret_dir}/authd-password && ! -L ${secret_dir}/authd-password ]] \
    || wazuh03_fail 'authd 등록 password 입력이 없다(WAZUH-01 provision.sh가 만든 파일 필요).'

  settings_body=$(jq -cn \
    --arg server "${manager_address}" \
    --arg agent "${agent_name}" \
    --arg port "${manager_events_port}" \
    --arg auth_port "${manager_auth_port}" \
    --arg target "${target}" \
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
        rootcheck: { enabled: $target },
        syscollector: { enabled: "0" },
        syscheck: { enabled: $target },
        active_response: { enabled: "0", remote_commands: "0" }
      }
    }')
  local settings_body_file=${WAZUH03_API_TMP}/settings-set-body.json
  printf '%s' "${settings_body}" > "${settings_body_file}"
  wazuh03_api_json POST /api/wazuhagent/settings/set "${body}" "${settings_body_file}"
  jq -e '.result == "saved"' "${body}" >/dev/null \
    || wazuh03_fail "설정 저장이 saved가 아니다: $(jq -c '.validations // .result' "${body}")"
  unset settings_body

  wazuh03_api_json POST /api/wazuhagent/service/reconfigure "${WAZUH03_API_TMP}/reconfigure.json"
  wait_for_running

  local get_after=${WAZUH03_API_TMP}/get-after.json
  wazuh03_api_json GET /api/wazuhagent/settings/get "${get_after}"
  jq -e --arg target "${target}" '
    .agent.general.enabled == "1" and
    .agent.rootcheck.enabled == $target and
    .agent.syscheck.enabled == $target and
    .agent.syscollector.enabled == "0" and
    .agent.active_response.enabled == "0" and
    .agent.active_response.remote_commands == "0" and
    .agent.logcollector.suricata_eve_log == "1"
  ' "${get_after}" >/dev/null \
    || wazuh03_fail '저장된 agent 설정이 계획과 다르다.'
  echo "AgentHIDS=PASS rootcheck=${target} syscheck=${target} active_response=0 syscollector=0"
}

case ${action} in
  apply)
    wazuh03_load_env "${WAZUH03_ENV_FILE:-${WAZUH03_DEFAULT_ENV_FILE}}"
    set_rootcheck_syscheck 1
    echo 'WAZUH03_AGENT_HIDS_APPLY=PASS'
    ;;
  rollback)
    wazuh03_load_env "${WAZUH03_ENV_FILE:-${WAZUH03_DEFAULT_ENV_FILE}}"
    set_rootcheck_syscheck 0
    echo 'WAZUH03_AGENT_HIDS_ROLLBACK=PASS'
    ;;
esac
