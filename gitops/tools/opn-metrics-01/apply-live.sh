#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-opnsense.sh
source "${script_dir}/lib-opnsense.sh"
trap opn_metrics_cleanup EXIT HUP INT TERM

readonly action=${1:-}
readonly rule_description='OPN-METRICS-01: k3s-01 Prometheus에서 OPNsense node_exporter TCP 9100만 허용'
readonly rule_sequence='1020'

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

api_json() {
  local method=$1 path=$2 output=$3 body=${4:-}
  opn_metrics_api "${method}" "${path}" "${output}" "${body}"
  jq -e . "${output}" >/dev/null \
    || opn_metrics_fail "JSON이 아닌 API 응답이다: ${path}"
}

firmware_info() {
  local output=$1
  api_json GET /api/core/firmware/info "${output}"
  jq -e '[.plugin[] | select(.name == "os-node_exporter")] | length == 1' "${output}" >/dev/null \
    || opn_metrics_fail 'os-node_exporter package 정보를 하나로 결정하지 못했다.'
}

wait_for_plugin_state() {
  local expected=$1
  local running=${OPN_METRICS_API_TMP}/firmware-running.json
  local info=${OPN_METRICS_API_TMP}/firmware-info.json
  for _ in $(seq 1 60); do
    api_json GET /api/core/firmware/running "${running}"
    if jq -e '.status == "ready"' "${running}" >/dev/null; then
      firmware_info "${info}"
      if jq -e --arg expected "${expected}" \
        '[.plugin[] | select(.name == "os-node_exporter")][0].installed == $expected' \
        "${info}" >/dev/null; then
        return
      fi
    fi
    sleep 5
  done
  opn_metrics_fail "os-node_exporter installed=${expected} 상태가 5분 안에 확인되지 않았다."
}

find_owned_rules() {
  local output=$1
  api_json GET '/api/firewall/filter/search_rule?interface=opt2&show_all=1' "${output}"
  jq --arg description "${rule_description}" '
    [.rows[] | select(
      .description == $description or
      (.destination_net == "10.10.10.1" and .destination_port == "9100")
    )]
  ' "${output}"
}

validate_rule_row() {
  local rows_json=$1 expected_enabled=$2
  jq -e --arg enabled "${expected_enabled}" --arg description "${rule_description}" '
      length == 1 and
      .[0].enabled == $enabled and
      .[0].sequence == "1020" and
      .[0].action == "pass" and
      .[0].quick == "1" and
      .[0].interface == "opt2" and
      .[0].direction == "in" and
      .[0].ipprotocol == "inet" and
      .[0].protocol == "TCP" and
      .[0].source_net == "10.10.20.10" and
      .[0].source_port == "" and
      .[0].destination_net == "10.10.10.1" and
      .[0].destination_port == "9100" and
      .[0].log == "1" and
      .[0].description == $description
    ' <<<"${rows_json}" >/dev/null \
    || opn_metrics_fail "방화벽 rule 의미값이 계획과 다르다: enabled=${expected_enabled}"
}

validate_rule_runtime() {
  local rule_uuid=$1 output=${OPN_METRICS_API_TMP}/rule-runtime.json
  api_json GET /api/firewall/filter_util/rule_stats "${output}"
  jq -e --arg uuid "${rule_uuid}" '
    .status == "ok" and
    (.stats[$uuid].pf_rules | tonumber) >= 1
  ' "${output}" >/dev/null \
    || opn_metrics_fail 'uncached PF runtime에 생성 UUID가 없다.'
  jq -r --arg uuid "${rule_uuid}" \
    '"FirewallRuntime=PASS uuid=\($uuid) pf_rules=\(.stats[$uuid].pf_rules)"' "${output}"
}

apply_live() {
  local info rules rows_json backup revision install_response config_body config_response
  local service_response rule_body add_response rule_uuid toggle_response apply_response
  local state_root state_dir

  "${repo_root}/infra/opnsense/scripts/check-drift.sh"
  info=${OPN_METRICS_API_TMP}/firmware-info-pre.json
  firmware_info "${info}"
  jq -e '[.plugin[] | select(.name == "os-node_exporter")][0].installed == "0"' "${info}" >/dev/null \
    || opn_metrics_fail 'os-node_exporter가 이미 설치돼 있어 작업 전 전제와 다르다.'
  rules=${OPN_METRICS_API_TMP}/rules-pre.json
  rows_json=$(find_owned_rules "${rules}")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || opn_metrics_fail '동일 description 또는 목적지·port의 기존 rule이 있다.'

  state_root=/home/imcherry/.local/state-backups
  install -d -m 700 "${state_root}"
  state_dir=$(mktemp -d "${state_root}/opn-metrics-01-XXXXXXXX")
  chmod 700 "${state_dir}"
  backup=${state_dir}/config-before.xml
  opn_metrics_api GET /api/core/backup/download/this "${backup}"
  chmod 600 "${backup}"
  sha256sum "${backup}" > "${state_dir}/config-before.sha256"
  chmod 600 "${state_dir}/config-before.sha256"
  revision=$(python3 - "${backup}" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
print(root.findtext('./revision/time') or 'unknown')
PY
  )
  printf '0\n' > "${state_dir}/plugin-was-installed"
  printf '%s\n' "${revision}" > "${state_dir}/config-revision"
  chmod 600 "${state_dir}/plugin-was-installed" "${state_dir}/config-revision"
  echo "복구 지점=${state_dir} config_revision=${revision}"

  install_response=${OPN_METRICS_API_TMP}/install.json
  api_json POST /api/core/firmware/install/os-node_exporter "${install_response}"
  jq -e '.status == "ok" and (.msg_uuid | type == "string" and length > 0)' \
    "${install_response}" >/dev/null \
    || opn_metrics_fail 'os-node_exporter 설치 작업이 시작되지 않았다.'
  wait_for_plugin_state 1
  echo 'ExporterPackage=PASS os-node_exporter=1.2 node_exporter=1.11.0_3'

  config_body=${OPN_METRICS_API_TMP}/node-exporter-config.json
  jq -n '{general:{
    enabled:"1",
    listenaddress:"10.10.10.1",
    listenport:"9100",
    cpu:"1",
    exec:"0",
    filesystem:"0",
    loadavg:"0",
    meminfo:"1",
    netdev:"1",
    time:"0",
    devstat:"0",
    interrupts:"0",
    ntp:"0",
    zfs:"0"
  }}' > "${config_body}"
  config_response=${OPN_METRICS_API_TMP}/node-exporter-set.json
  api_json POST /api/nodeexporter/general/set "${config_response}" "${config_body}"
  service_response=${OPN_METRICS_API_TMP}/node-exporter-reconfigure.json
  api_json POST /api/nodeexporter/service/reconfigure "${service_response}"
  config_response=${OPN_METRICS_API_TMP}/node-exporter-get.json
  api_json GET /api/nodeexporter/general/get "${config_response}"
  jq -e '.general | {
      enabled,listenaddress,listenport,cpu,exec,filesystem,loadavg,meminfo,netdev,time,devstat,interrupts,ntp,zfs
    } == {
      enabled:"1",listenaddress:"10.10.10.1",listenport:"9100",cpu:"1",exec:"0",
      filesystem:"0",loadavg:"0",meminfo:"1",netdev:"1",time:"0",devstat:"0",
      interrupts:"0",ntp:"0",zfs:"0"
    }' "${config_response}" >/dev/null \
    || opn_metrics_fail 'node_exporter 저장 설정이 최소 collector 계획과 다르다.'
  service_response=${OPN_METRICS_API_TMP}/node-exporter-status.json
  api_json GET /api/nodeexporter/service/status "${service_response}"
  jq -e '(.status // "") | test("running"; "i")' "${service_response}" >/dev/null \
    || opn_metrics_fail 'node_exporter service가 running이 아니다.'
  echo 'ExporterConfig=PASS bind=MGMT:9100 collectors=cpu,meminfo,netdev'

  rule_body=${OPN_METRICS_API_TMP}/rule.json
  jq -n --arg description "${rule_description}" '{rule:{
    enabled:"0",
    statetype:"keep",
    sequence:"1020",
    action:"pass",
    quick:"1",
    interface:"opt2",
    direction:"in",
    ipprotocol:"inet",
    protocol:"TCP",
    source_net:"10.10.20.10",
    source_port:"",
    destination_net:"10.10.10.1",
    destination_port:"9100",
    gateway:"",
    log:"1",
    description:$description
  }}' > "${rule_body}"
  add_response=${OPN_METRICS_API_TMP}/rule-add.json
  api_json POST /api/firewall/filter/add_rule "${add_response}" "${rule_body}"
  rule_uuid=$(jq -r '.uuid // empty' "${add_response}")
  [[ ${rule_uuid} =~ ^[0-9a-f-]{36}$ ]] \
    || opn_metrics_fail '생성된 방화벽 rule UUID를 읽지 못했다.'
  printf '%s\n' "${rule_uuid}" > "${state_dir}/rule-uuid"
  chmod 600 "${state_dir}/rule-uuid"
  rows_json=$(find_owned_rules "${rules}")
  validate_rule_row "${rows_json}" 0
  echo "FirewallStage=PASS uuid=${rule_uuid} sequence=${rule_sequence} enabled=0"

  toggle_response=${OPN_METRICS_API_TMP}/rule-toggle.json
  api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/1" "${toggle_response}"
  apply_response=${OPN_METRICS_API_TMP}/rule-apply.json
  api_json POST /api/firewall/filter/apply "${apply_response}"
  rows_json=$(find_owned_rules "${rules}")
  validate_rule_row "${rows_json}" 1
  validate_rule_runtime "${rule_uuid}"
  echo "FirewallApply=PASS uuid=${rule_uuid} sequence=${rule_sequence}"
  echo "STATE_DIR=${state_dir}"
}

rollback_live() {
  local state_dir=${2:-}
  local rule_uuid rules rows_json response body info
  [[ -n ${state_dir} && ${state_dir} == /home/imcherry/.local/state-backups/opn-metrics-01-* ]] \
    || opn_metrics_fail '명시적인 OPN-METRICS-01 복구 지점이 필요하다.'
  [[ ! -L ${state_dir} && -d ${state_dir} && -r ${state_dir}/plugin-was-installed ]] \
    || opn_metrics_fail '복구 지점이 안전하지 않다.'

  rules=${OPN_METRICS_API_TMP}/rules-rollback.json
  rows_json=$(find_owned_rules "${rules}")
  if jq -e 'length == 1' <<<"${rows_json}" >/dev/null; then
    rule_uuid=$(jq -r '.[0].uuid' <<<"${rows_json}")
    if [[ -r ${state_dir}/rule-uuid ]]; then
      [[ ${rule_uuid} == "$(<"${state_dir}/rule-uuid")" ]] \
        || opn_metrics_fail '라이브 rule UUID가 복구 지점의 소유 UUID와 다르다.'
    fi
    response=${OPN_METRICS_API_TMP}/rollback-toggle.json
    api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/0" "${response}"
    response=${OPN_METRICS_API_TMP}/rollback-apply-disabled.json
    api_json POST /api/firewall/filter/apply "${response}"
    response=${OPN_METRICS_API_TMP}/rollback-delete.json
    api_json POST "/api/firewall/filter/del_rule/${rule_uuid}" "${response}"
    response=${OPN_METRICS_API_TMP}/rollback-apply-deleted.json
    api_json POST /api/firewall/filter/apply "${response}"
    rows_json=$(find_owned_rules "${rules}")
    jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
      || opn_metrics_fail '소유 방화벽 rule 삭제 뒤에도 동일 rule이 남아 있다.'
    echo "FirewallRollback=PASS removed_uuid=${rule_uuid}"
  elif ! jq -e 'length == 0' <<<"${rows_json}" >/dev/null; then
    opn_metrics_fail 'rollback 대상 방화벽 rule을 하나로 결정하지 못했다.'
  fi

  if [[ $(<"${state_dir}/plugin-was-installed") == 0 ]]; then
    info=${OPN_METRICS_API_TMP}/firmware-info-rollback.json
    firmware_info "${info}"
    if jq -e '[.plugin[] | select(.name == "os-node_exporter")][0].installed == "1"' "${info}" >/dev/null; then
      body=${OPN_METRICS_API_TMP}/node-exporter-disable.json
      jq -n '{general:{enabled:"0"}}' > "${body}"
      response=${OPN_METRICS_API_TMP}/node-exporter-disable-response.json
      api_json POST /api/nodeexporter/general/set "${response}" "${body}"
      response=${OPN_METRICS_API_TMP}/node-exporter-reconfigure-disable.json
      api_json POST /api/nodeexporter/service/reconfigure "${response}"
      response=${OPN_METRICS_API_TMP}/node-exporter-remove.json
      api_json POST /api/core/firmware/remove/os-node_exporter "${response}"
      jq -e '.status == "ok" and (.msg_uuid | type == "string" and length > 0)' \
        "${response}" >/dev/null \
        || opn_metrics_fail 'os-node_exporter 제거 작업이 시작되지 않았다.'
      wait_for_plugin_state 0
      echo 'ExporterRollback=PASS os-node_exporter removed'
    fi
  else
    opn_metrics_fail '이 작업 전부터 있던 exporter 설정의 자동 rollback은 지원하지 않는다.'
  fi
  echo "RollbackReference=${state_dir}"
}

case ${action} in
  apply)
    opn_metrics_load_env "${OPN_METRICS_ENV_FILE:-${OPN_METRICS_DEFAULT_ENV_FILE}}"
    apply_live
    ;;
  rollback)
    opn_metrics_load_env "${OPN_METRICS_ENV_FILE:-${OPN_METRICS_DEFAULT_ENV_FILE}}"
    rollback_live "$@"
    ;;
  *) usage ;;
esac
