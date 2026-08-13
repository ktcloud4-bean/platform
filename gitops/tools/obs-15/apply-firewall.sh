#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-opnsense.sh
source "${script_dir}/lib-opnsense.sh"
trap obs15_cleanup EXIT HUP INT TERM

readonly action=${1:-}
readonly rule_sequence=1008
readonly rule_description='OBS-15: k3s-01에서 postgres-01 postgres_exporter TCP 9187만 허용'

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

api_json() {
  local method=$1 api_path=$2 output=$3 body_file=${4:-}
  obs15_api "${method}" "${api_path}" "${output}" "${body_file}"
  jq -e . "${output}" >/dev/null \
    || obs15_fail "JSON이 아닌 API 응답이다: ${api_path}"
}

find_interface_rules() {
  local output=$1
  api_json GET '/api/firewall/filter/search_rule?interface=opt2&show_all=1' "${output}"
  jq '.rows' "${output}"
}

find_owned_rules() {
  local output=$1
  find_interface_rules "${output}" | jq --arg description "${rule_description}" \
    '[.[] | select(.description == $description)]'
}

validate_rule_row() {
  local rows_json=$1 expected_enabled=$2
  jq -e --arg enabled "${expected_enabled}" --arg description "${rule_description}" \
    --arg seq "${rule_sequence}" '
      (. | length == 1) and
      .[0].enabled == $enabled and
      .[0].sequence == $seq and
      .[0].action == "pass" and
      .[0].quick == "1" and
      .[0].interface == "opt2" and
      .[0].direction == "in" and
      .[0].ipprotocol == "inet" and
      .[0].protocol == "TCP" and
      .[0].source_net == "10.10.20.10" and
      .[0].source_port == "" and
      .[0].destination_net == "10.10.50.10" and
      .[0].destination_port == "9187" and
      .[0].log == "1"
    ' <<<"${rows_json}" >/dev/null \
    || obs15_fail "방화벽 rule 의미값이 계획과 다르다: enabled=${expected_enabled}"
}

validate_rule_runtime() {
  local rule_uuid=$1 output=${OBS15_API_TMP}/rule-runtime.json
  api_json GET /api/firewall/filter_util/rule_stats "${output}"
  jq -e --arg uuid "${rule_uuid}" '
    .status == "ok" and (.stats[$uuid].pf_rules | tonumber) >= 1
  ' "${output}" >/dev/null \
    || obs15_fail 'uncached PF runtime에 생성 UUID가 없다.'
  jq -r --arg uuid "${rule_uuid}" \
    '"FirewallRuntime=PASS uuid=\($uuid) pf_rules=\(.stats[$uuid].pf_rules)"' "${output}"
}

apply_live() {
  local rules_json owned_rules state_root state_dir rule_body add_response rule_uuid response

  "${repo_root}/infra/opnsense/scripts/check-drift.sh"
  rules_json=${OBS15_API_TMP}/rules-pre.json
  owned_rules=$(find_owned_rules "${rules_json}")
  jq -e 'length == 0' <<<"${owned_rules}" >/dev/null \
    || obs15_fail '동일 description의 OBS-15 rule이 이미 있다.'
  jq -e --arg seq "${rule_sequence}" '.rows | [.[] | select(.sequence == $seq)] | length == 0' \
    "${rules_json}" >/dev/null \
    || obs15_fail "opt2 sequence ${rule_sequence}을 이미 다른 rule이 사용한다."

  state_root=/home/imcherry/.local/state-backups
  install -d -m 700 "${state_root}"
  state_dir=$(mktemp -d "${state_root}/obs-15-XXXXXXXX")
  chmod 700 "${state_dir}"
  : > "${state_dir}/rule-uuid"
  chmod 600 "${state_dir}/rule-uuid"
  echo "복구 지점=${state_dir}"

  rule_body=${OBS15_API_TMP}/rule.json
  jq -n --arg description "${rule_description}" --arg seq "${rule_sequence}" '{rule:{
    enabled:"0",
    statetype:"keep",
    sequence:$seq,
    action:"pass",
    quick:"1",
    interface:"opt2",
    direction:"in",
    ipprotocol:"inet",
    protocol:"TCP",
    source_net:"10.10.20.10",
    source_port:"",
    destination_net:"10.10.50.10",
    destination_port:"9187",
    gateway:"",
    log:"1",
    description:$description
  }}' > "${rule_body}"
  add_response=${OBS15_API_TMP}/rule-add.json
  api_json POST /api/firewall/filter/add_rule "${add_response}" "${rule_body}"
  rule_uuid=$(jq -r '.uuid // empty' "${add_response}")
  [[ ${rule_uuid} =~ ^[0-9a-f-]{36}$ ]] \
    || obs15_fail '생성된 방화벽 rule UUID를 읽지 못했다.'
  printf '%s\n' "${rule_uuid}" > "${state_dir}/rule-uuid"
  owned_rules=$(find_owned_rules "${rules_json}")
  validate_rule_row "${owned_rules}" 0
  echo "FirewallStage=PASS uuid=${rule_uuid} sequence=${rule_sequence} enabled=0"

  response=${OBS15_API_TMP}/rule-toggle.json
  api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/1" "${response}"
  response=${OBS15_API_TMP}/rule-apply.json
  api_json POST /api/firewall/filter/apply "${response}"
  owned_rules=$(find_owned_rules "${rules_json}")
  validate_rule_row "${owned_rules}" 1
  validate_rule_runtime "${rule_uuid}"
  echo "FirewallApply=PASS uuid=${rule_uuid} sequence=${rule_sequence}"
  echo "STATE_DIR=${state_dir}"
}

rollback_live() {
  local state_dir=${2:-} rule_uuid rules_json owned_rules response

  [[ -n ${state_dir} && ${state_dir} == /home/imcherry/.local/state-backups/obs-15-* ]] \
    || obs15_fail '명시적인 OBS-15 복구 지점이 필요하다.'
  [[ ! -L ${state_dir} && -d ${state_dir} && -r ${state_dir}/rule-uuid ]] \
    || obs15_fail '복구 지점이 안전하지 않다.'
  rule_uuid=$(<"${state_dir}/rule-uuid")
  [[ ${rule_uuid} =~ ^[0-9a-f-]{36}$ ]] || obs15_fail '복구 지점의 rule UUID 형식이 안전하지 않다.'

  rules_json=${OBS15_API_TMP}/rules-rollback.json
  owned_rules=$(find_owned_rules "${rules_json}")
  if jq -e --arg uuid "${rule_uuid}" '[.[] | select(.uuid == $uuid)] | length == 1' \
    <<<"${owned_rules}" >/dev/null; then
    response=${OBS15_API_TMP}/rollback-toggle.json
    api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/0" "${response}"
    response=${OBS15_API_TMP}/rollback-apply-disabled.json
    api_json POST /api/firewall/filter/apply "${response}"
    response=${OBS15_API_TMP}/rollback-delete.json
    api_json POST "/api/firewall/filter/del_rule/${rule_uuid}" "${response}"
    response=${OBS15_API_TMP}/rollback-apply-deleted.json
    api_json POST /api/firewall/filter/apply "${response}"
    echo "FirewallRollback=PASS removed_uuid=${rule_uuid}"
  else
    echo "FirewallRollback=SKIP uuid=${rule_uuid} (이미 없음)"
  fi

  owned_rules=$(find_owned_rules "${rules_json}")
  jq -e 'length == 0' <<<"${owned_rules}" >/dev/null \
    || obs15_fail 'rollback 뒤에도 OBS-15 소유 rule이 남아 있다.'
  echo "RollbackReference=${state_dir}"
}

case ${action} in
  apply)
    obs15_load_env "${OBS15_ENV_FILE:-${OBS15_DEFAULT_ENV_FILE}}"
    apply_live
    ;;
  rollback)
    obs15_load_env "${OBS15_ENV_FILE:-${OBS15_DEFAULT_ENV_FILE}}"
    rollback_live "$@"
    ;;
  *) usage ;;
esac
