#!/usr/bin/env bash
# gitops/tools/wazuh-03/apply-firewall.sh
#
# WAZUH-03: postgres-01·object-01·warpgate-01·netbird-01에서 k3s-01(Wazuh manager
# NodePort 31514/31515)로 가는 cross-VLAN PASS 규칙 3건과 포트 alias 1건을 만든다.
#
# proxmox-01(lan/MGMT)은 새 규칙이 없다 — lan 인터페이스는 여전히 "Default allow
# LAN to any rule"(seq=1)이라 이미 통과한다. k3s-01 자신은 manager와 같은 호스트라
# OPNsense를 거치지 않는다. object-01·postgres-01은 기존 NET04_DATA_HOSTS alias를
# source_net으로 재사용해 규칙 하나로 둘 다 허용한다(alias 신규 생성 없음).
#
# 대상 포트 두 개는 NET04_WEB_PORTS와 같은 방식으로 새 port alias
# WAZUH03_AGENT_PORTS(31514, 31515)에 담아 규칙마다 하나만 필요하게 한다.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-opnsense.sh
source "${script_dir}/lib-opnsense.sh"
trap wazuh03_cleanup EXIT HUP INT TERM

readonly action=${1:-}

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

readonly ALIAS_NAME=WAZUH03_AGENT_PORTS
readonly ALIAS_CONTENT=$'31514\n31515'
readonly ALIAS_DESCRIPTION="WAZUH-03: 6개 host agent가 쓰는 Wazuh manager 등록·수집 NodePort"

readonly RULE_NAMES=(warpgate-01 netbird-01 data-hosts)
declare -A RULE_INTERFACE=(
  [warpgate-01]=opt3
  [netbird-01]=opt4
  [data-hosts]=opt5
)
declare -A RULE_SOURCE=(
  [warpgate-01]=10.10.30.10
  [netbird-01]=10.10.40.10
  [data-hosts]=NET04_DATA_HOSTS
)
declare -A RULE_SEQ=(
  [warpgate-01]=1121
  [netbird-01]=1219
  [data-hosts]=1313
)
rule_description() {
  local label=$1
  case ${label} in
    data-hosts) echo "WAZUH-03: DATA 실제 host(postgres-01·object-01)에서 Wazuh manager 등록·수집 포트만 허용" ;;
    *) echo "WAZUH-03: ${label}에서 Wazuh manager 등록·수집 포트만 허용" ;;
  esac
}

find_owned_alias() {
  local output=$1 empty_body=${WAZUH03_API_TMP}/empty-body.json
  printf '{}' > "${empty_body}"
  wazuh03_api_json POST /api/firewall/alias/search_item "${output}" "${empty_body}"
  jq --arg name "${ALIAS_NAME}" '[.rows[] | select(.name == $name)]' "${output}"
}

find_owned_rules() {
  local output=$1
  wazuh03_api_json GET '/api/firewall/filter/search_rule?show_all=1' "${output}"
  jq '[.rows[] | select(.description | startswith("WAZUH-03:"))]' "${output}"
}

validate_alias_row() {
  local rows_json=$1
  jq -e --arg name "${ALIAS_NAME}" --arg content "${ALIAS_CONTENT}" '
    [.[] | select(.name == $name)] as $m
    | ($m | length == 1) and
      ($m[0].type == "port") and
      ($m[0].enabled == "1") and
      (($m[0].content // "") == $content)
  ' <<<"${rows_json}" >/dev/null \
    || wazuh03_fail 'alias 의미값이 계획과 다르다.'
}

validate_rule_row() {
  local name=$1 rows_json=$2 expected_enabled=$3
  local description iface source seq
  description=$(rule_description "${name}")
  iface=${RULE_INTERFACE[${name}]}
  source=${RULE_SOURCE[${name}]}
  seq=${RULE_SEQ[${name}]}
  jq -e --arg enabled "${expected_enabled}" --arg description "${description}" \
    --arg iface "${iface}" --arg source "${source}" --arg seq "${seq}" '
      [.[] | select(.description == $description)] as $m
      | ($m | length == 1) and
        ($m[0].enabled == $enabled) and
        ($m[0].sequence == $seq) and
        ($m[0].action == "pass") and
        ($m[0].quick == "1") and
        ($m[0].interface == $iface) and
        ($m[0].direction == "in") and
        ($m[0].ipprotocol == "inet") and
        ($m[0].protocol == "TCP") and
        ($m[0].source_net == $source) and
        ($m[0].source_port == "") and
        ($m[0].destination_net == "10.10.20.10") and
        ($m[0].destination_port == "WAZUH03_AGENT_PORTS") and
        ($m[0].log == "1")
    ' <<<"${rows_json}" >/dev/null \
    || wazuh03_fail "${name} 방화벽 rule 의미값이 계획과 다르다: enabled=${expected_enabled}"
}

apply_live() {
  local rows_json state_root state_dir name description iface source seq
  local alias_body add_response alias_uuid reconfigure_response
  local rule_body rule_add_response rule_uuid toggle_response apply_response

  "${repo_root}/infra/opnsense/scripts/check-drift.sh"

  rows_json=$(find_owned_alias "${WAZUH03_API_TMP}/alias-pre.json")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || wazuh03_fail "alias ${ALIAS_NAME}가 이미 있다."
  rows_json=$(find_owned_rules "${WAZUH03_API_TMP}/rules-pre.json")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || wazuh03_fail '동일 description의 WAZUH-03 rule이 이미 있다.'

  state_root=/home/imcherry/.local/state-backups
  install -d -m 700 "${state_root}"
  state_dir=$(mktemp -d "${state_root}/wazuh-03-firewall-XXXXXXXX")
  chmod 700 "${state_dir}"
  : > "${state_dir}/rule-uuids"
  chmod 600 "${state_dir}/rule-uuids"
  echo "복구 지점=${state_dir}"

  alias_body=${WAZUH03_API_TMP}/alias-body.json
  jq -n --arg name "${ALIAS_NAME}" --arg content "${ALIAS_CONTENT}" \
    --arg description "${ALIAS_DESCRIPTION}" '{alias:{
      enabled: "1", name: $name, type: "port", content: $content, description: $description
    }}' > "${alias_body}"
  add_response=${WAZUH03_API_TMP}/alias-add.json
  wazuh03_api_json POST /api/firewall/alias/add_item "${add_response}" "${alias_body}"
  alias_uuid=$(jq -r '.uuid // empty' "${add_response}")
  [[ ${alias_uuid} =~ ^[0-9a-f-]{36}$ ]] \
    || wazuh03_fail "alias 생성 UUID를 읽지 못했다."
  printf 'alias %s\n' "${alias_uuid}" >> "${state_dir}/rule-uuids"
  reconfigure_response=${WAZUH03_API_TMP}/alias-reconfigure.json
  wazuh03_api_json POST /api/firewall/alias/reconfigure "${reconfigure_response}"
  rows_json=$(find_owned_alias "${WAZUH03_API_TMP}/alias-post.json")
  validate_alias_row "${rows_json}"
  echo "AliasApply=PASS name=${ALIAS_NAME} uuid=${alias_uuid}"

  for name in "${RULE_NAMES[@]}"; do
    iface=${RULE_INTERFACE[${name}]}
    source=${RULE_SOURCE[${name}]}
    seq=${RULE_SEQ[${name}]}
    description=$(rule_description "${name}")

    rule_body=${WAZUH03_API_TMP}/rule-${name}.json
    jq -n --arg description "${description}" --arg iface "${iface}" \
      --arg source "${source}" --arg seq "${seq}" '{rule:{
      enabled:"0",
      statetype:"keep",
      sequence:$seq,
      action:"pass",
      quick:"1",
      interface:$iface,
      direction:"in",
      ipprotocol:"inet",
      protocol:"TCP",
      source_net:$source,
      source_port:"",
      destination_net:"10.10.20.10",
      destination_port:"WAZUH03_AGENT_PORTS",
      gateway:"",
      log:"1",
      description:$description
    }}' > "${rule_body}"
    rule_add_response=${WAZUH03_API_TMP}/rule-add-${name}.json
    wazuh03_api_json POST /api/firewall/filter/add_rule "${rule_add_response}" "${rule_body}"
    rule_uuid=$(jq -r '.uuid // empty' "${rule_add_response}")
    [[ ${rule_uuid} =~ ^[0-9a-f-]{36}$ ]] \
      || wazuh03_fail "${name}: 생성된 방화벽 rule UUID를 읽지 못했다."
    printf 'rule %s %s\n' "${name}" "${rule_uuid}" >> "${state_dir}/rule-uuids"
    rows_json=$(find_owned_rules "${WAZUH03_API_TMP}/rules-staged.json")
    validate_rule_row "${name}" "${rows_json}" 0
    echo "FirewallStage=PASS name=${name} uuid=${rule_uuid} sequence=${seq} enabled=0"

    toggle_response=${WAZUH03_API_TMP}/rule-toggle-${name}.json
    wazuh03_api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/1" "${toggle_response}"
    apply_response=${WAZUH03_API_TMP}/rule-apply-${name}.json
    wazuh03_api_json POST /api/firewall/filter/apply "${apply_response}"
    rows_json=$(find_owned_rules "${WAZUH03_API_TMP}/rules-enabled.json")
    validate_rule_row "${name}" "${rows_json}" 1
    echo "FirewallApply=PASS name=${name} uuid=${rule_uuid} sequence=${seq}"
  done

  echo "STATE_DIR=${state_dir}"
}

rollback_live() {
  local state_dir=${2:-}
  local kind a b rows_json response

  [[ -n ${state_dir} && ${state_dir} == /home/imcherry/.local/state-backups/wazuh-03-firewall-* ]] \
    || wazuh03_fail '명시적인 WAZUH-03 복구 지점이 필요하다.'
  [[ ! -L ${state_dir} && -d ${state_dir} && -r ${state_dir}/rule-uuids ]] \
    || wazuh03_fail '복구 지점이 안전하지 않다.'

  while read -r kind a b; do
    [[ -n ${kind} ]] || continue
    if [[ ${kind} == rule ]]; then
      local name=${a} rule_uuid=${b}
      rows_json=$(find_owned_rules "${WAZUH03_API_TMP}/rules-rollback-${name}.json")
      if jq -e --arg uuid "${rule_uuid}" '[.[] | select(.uuid == $uuid)] | length == 1' \
        <<<"${rows_json}" >/dev/null; then
        response=${WAZUH03_API_TMP}/rollback-toggle-${name}.json
        wazuh03_api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/0" "${response}"
        response=${WAZUH03_API_TMP}/rollback-apply-disabled-${name}.json
        wazuh03_api_json POST /api/firewall/filter/apply "${response}"
        response=${WAZUH03_API_TMP}/rollback-delete-${name}.json
        wazuh03_api_json POST "/api/firewall/filter/del_rule/${rule_uuid}" "${response}"
        response=${WAZUH03_API_TMP}/rollback-apply-deleted-${name}.json
        wazuh03_api_json POST /api/firewall/filter/apply "${response}"
        echo "FirewallRollback=PASS name=${name} removed_uuid=${rule_uuid}"
      else
        echo "FirewallRollback=SKIP name=${name} uuid=${rule_uuid} (이미 없음)"
      fi
    elif [[ ${kind} == alias ]]; then
      local alias_uuid=${a}
      rows_json=$(find_owned_alias "${WAZUH03_API_TMP}/alias-rollback.json")
      if jq -e --arg uuid "${alias_uuid}" '[.[] | select(.uuid == $uuid)] | length == 1' \
        <<<"${rows_json}" >/dev/null; then
        response=${WAZUH03_API_TMP}/alias-rollback-delete.json
        wazuh03_api_json POST "/api/firewall/alias/del_item/${alias_uuid}" "${response}"
        response=${WAZUH03_API_TMP}/alias-rollback-reconfigure.json
        wazuh03_api_json POST /api/firewall/alias/reconfigure "${response}"
        echo "AliasRollback=PASS uuid=${alias_uuid}"
      else
        echo "AliasRollback=SKIP uuid=${alias_uuid} (이미 없음)"
      fi
    fi
  done < "${state_dir}/rule-uuids"

  rows_json=$(find_owned_rules "${WAZUH03_API_TMP}/rules-rollback-final.json")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || wazuh03_fail 'rollback 뒤에도 WAZUH-03 소유 rule이 남아 있다.'
  rows_json=$(find_owned_alias "${WAZUH03_API_TMP}/alias-rollback-final.json")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || wazuh03_fail 'rollback 뒤에도 WAZUH-03 소유 alias가 남아 있다.'
  echo "RollbackReference=${state_dir}"
}

case ${action} in
  apply)
    wazuh03_load_env "${WAZUH03_ENV_FILE:-${WAZUH03_DEFAULT_ENV_FILE}}"
    apply_live
    ;;
  rollback)
    wazuh03_load_env "${WAZUH03_ENV_FILE:-${WAZUH03_DEFAULT_ENV_FILE}}"
    rollback_live "$@"
    ;;
  *) usage ;;
esac
