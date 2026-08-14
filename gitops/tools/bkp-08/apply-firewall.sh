#!/usr/bin/env bash
# BKP-08: warpgate-01 (10.10.30.10) 및 netbird-01 (10.10.40.10)에서
# object-01 (10.10.50.20) TLS S3 TCP 8333으로 향하는 OPNsense PASS 규칙 2건을 관리한다.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root

# shellcheck disable=SC1091
source "${script_dir}/../obs-15/lib-opnsense.sh"
trap obs15_cleanup EXIT HUP INT TERM

readonly action=${1:-}

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

bkp08_fail() {
  echo "BKP-08 방화벽 실패: $*" >&2
  exit 1
}

api_json() {
  local method=$1 api_path=$2 output=$3 body_file=${4:-}
  obs15_api "${method}" "${api_path}" "${output}" "${body_file}"
  jq -e . "${output}" >/dev/null || bkp08_fail "JSON이 아닌 API 응답이다: ${api_path}"
}

readonly RULE_NAMES=(warpgate-01 netbird-01)
declare -A RULE_INTERFACE=(
  [warpgate-01]=opt3
  [netbird-01]=opt4
)
declare -A RULE_SOURCE=(
  [warpgate-01]=10.10.30.10
  [netbird-01]=10.10.40.10
)
declare -A RULE_SEQ=(
  [warpgate-01]=1122
  [netbird-01]=1497
)

rule_description() {
  local label=$1
  echo "BKP-08: ${label}에서 object-01 TLS S3 TCP 8333만 허용"
}

all_rules() {
  local output=$1
  api_json GET '/api/firewall/filter/search_rule?show_all=1' "${output}"
  jq '.rows' "${output}"
}

find_owned_rules() {
  local output=$1
  local rows
  rows=$(all_rules "${output}")
  jq '[.[] | select(.description | startswith("BKP-08:"))]' <<<"${rows}"
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
        ($m[0].destination_net == "10.10.50.20") and
        ($m[0].destination_port == "8333") and
        ($m[0].log == "1")
    ' <<<"${rows_json}" >/dev/null \
    || bkp08_fail "${name} 방화벽 rule 의미값이 계획과 다르다: enabled=${expected_enabled}"
}

apply_live() {
  local rows_json state_root state_dir name description iface source seq
  local rule_body rule_add_response rule_uuid toggle_response apply_response

  "${repo_root}/infra/opnsense/scripts/check-drift.sh"

  rows_json=$(find_owned_rules "${OBS15_API_TMP}/rules-pre.json")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || bkp08_fail '동일 description의 BKP-08 rule이 이미 존재한다.'

  state_root=/home/imcherry/.local/state-backups
  install -d -m 700 "${state_root}"
  state_dir=$(mktemp -d "${state_root}/bkp-08-firewall-XXXXXXXX")
  chmod 700 "${state_dir}"
  : > "${state_dir}/rule-uuids"
  chmod 600 "${state_dir}/rule-uuids"
  echo "복구 지점=${state_dir}"

  for name in "${RULE_NAMES[@]}"; do
    iface=${RULE_INTERFACE[${name}]}
    source=${RULE_SOURCE[${name}]}
    seq=${RULE_SEQ[${name}]}
    description=$(rule_description "${name}")

    rule_body=${OBS15_API_TMP}/rule-${name}.json
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
      destination_net:"10.10.50.20",
      destination_port:"8333",
      gateway:"",
      log:"1",
      description:$description
    }}' > "${rule_body}"

    rule_add_response=${OBS15_API_TMP}/rule-add-${name}.json
    api_json POST /api/firewall/filter/add_rule "${rule_add_response}" "${rule_body}"
    rule_uuid=$(jq -r '.uuid // empty' "${rule_add_response}")
    [[ ${rule_uuid} =~ ^[0-9a-f-]{36}$ ]] \
      || bkp08_fail "${name}: 생성된 방화벽 rule UUID를 읽지 못했다."
    printf 'rule %s %s\n' "${name}" "${rule_uuid}" >> "${state_dir}/rule-uuids"

    rows_json=$(all_rules "${OBS15_API_TMP}/rules-staged.json")
    validate_rule_row "${name}" "${rows_json}" 0
    echo "FirewallStage=PASS name=${name} uuid=${rule_uuid} sequence=${seq} enabled=0"

    toggle_response=${OBS15_API_TMP}/rule-toggle-${name}.json
    api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/1" "${toggle_response}"
    apply_response=${OBS15_API_TMP}/rule-apply-${name}.json
    api_json POST /api/firewall/filter/apply "${apply_response}"

    rows_json=$(all_rules "${OBS15_API_TMP}/rules-enabled.json")
    validate_rule_row "${name}" "${rows_json}" 1
    echo "FirewallApply=PASS name=${name} uuid=${rule_uuid} sequence=${seq}"
  done

  echo "STATE_DIR=${state_dir}"
}

rollback_live() {
  local state_dir=${2:-}
  local kind a b rows_json response

  [[ -n ${state_dir} && ${state_dir} == /home/imcherry/.local/state-backups/bkp-08-firewall-* ]] \
    || bkp08_fail '명시적인 BKP-08 복구 지점이 필요하다.'
  [[ ! -L ${state_dir} && -d ${state_dir} && -r ${state_dir}/rule-uuids ]] \
    || bkp08_fail '복구 지점이 안전하지 않다.'

  while read -r kind a b; do
    [[ -n ${kind} ]] || continue
    if [[ ${kind} == rule ]]; then
      local name=${a} rule_uuid=${b}
      rows_json=$(all_rules "${OBS15_API_TMP}/rules-rollback-${name}.json")
      if jq -e --arg uuid "${rule_uuid}" '[.[] | select(.uuid == $uuid)] | length == 1' \
        <<<"${rows_json}" >/dev/null; then
        response=${OBS15_API_TMP}/rollback-toggle-${name}.json
        api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/0" "${response}"
        response=${OBS15_API_TMP}/rollback-apply-disabled-${name}.json
        api_json POST /api/firewall/filter/apply "${response}"
        response=${OBS15_API_TMP}/rollback-delete-${name}.json
        api_json POST "/api/firewall/filter/del_rule/${rule_uuid}" "${response}"
        response=${OBS15_API_TMP}/rollback-apply-deleted-${name}.json
        api_json POST /api/firewall/filter/apply "${response}"
        echo "FirewallRollback=PASS name=${name} removed_uuid=${rule_uuid}"
      else
        echo "FirewallRollback=SKIP name=${name} uuid=${rule_uuid} (이미 없음)"
      fi
    fi
  done < "${state_dir}/rule-uuids"

  rows_json=$(find_owned_rules "${OBS15_API_TMP}/rules-rollback-final.json")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || bkp08_fail 'rollback 뒤에도 BKP-08 소유 rule이 남아 있다.'
  echo "RollbackReference=${state_dir}"
}

case ${action} in
  apply)
    obs15_load_env "${BKP08_ENV_FILE:-${OBS15_DEFAULT_ENV_FILE}}"
    apply_live
    ;;
  rollback)
    obs15_load_env "${BKP08_ENV_FILE:-${OBS15_DEFAULT_ENV_FILE}}"
    rollback_live "$@"
    ;;
  *) usage ;;
esac
