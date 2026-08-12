#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-opnsense.sh
source "${script_dir}/lib-opnsense.sh"
trap obs11_cleanup EXIT HUP INT TERM

readonly action=${1:-}

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

# OBS-11: k3s-01(PLATFORM/opt2)에서 fleet 5개 대상 node_exporter TCP 9100만 허용.
# 목적지는 모두 opt2의 기존 NET-04 비공개 목적지 BLOCK(seq=1022)보다 앞선 sequence를 쓴다.
readonly RULE_NAMES=(proxmox-01 postgres-01 object-01 warpgate-01 netbird-01)
declare -A RULE_DEST=(
  [proxmox-01]=10.10.10.10
  [postgres-01]=10.10.50.10
  [object-01]=10.10.50.20
  [warpgate-01]=10.10.30.10
  [netbird-01]=10.10.40.10
)
declare -A RULE_SEQ=(
  [proxmox-01]=1003
  [postgres-01]=1004
  [object-01]=1005
  [warpgate-01]=1006
  [netbird-01]=1007
)
rule_description() {
  echo "OBS-11: k3s-01에서 ${1} node_exporter TCP 9100만 허용"
}

api_json() {
  local method=$1 path=$2 output=$3 body=${4:-}
  obs11_api "${method}" "${path}" "${output}" "${body}"
  jq -e . "${output}" >/dev/null \
    || obs11_fail "JSON이 아닌 API 응답이다: ${path}"
}

find_owned_rules() {
  local output=$1
  api_json GET '/api/firewall/filter/search_rule?interface=opt2&show_all=1' "${output}"
  jq '
    [.rows[] | select(.description | startswith("OBS-11:"))]
  ' "${output}"
}

validate_rule_row() {
  local name=$1 rows_json=$2 expected_enabled=$3
  local description dest seq
  description=$(rule_description "${name}")
  dest=${RULE_DEST[${name}]}
  seq=${RULE_SEQ[${name}]}
  jq -e --arg enabled "${expected_enabled}" --arg description "${description}" \
    --arg dest "${dest}" --arg seq "${seq}" '
      [.[] | select(.description == $description)] as $m
      | ($m | length == 1) and
        ($m[0].enabled == $enabled) and
        ($m[0].sequence == $seq) and
        ($m[0].action == "pass") and
        ($m[0].quick == "1") and
        ($m[0].interface == "opt2") and
        ($m[0].direction == "in") and
        ($m[0].ipprotocol == "inet") and
        ($m[0].protocol == "TCP") and
        ($m[0].source_net == "10.10.20.10") and
        ($m[0].source_port == "") and
        ($m[0].destination_net == $dest) and
        ($m[0].destination_port == "9100") and
        ($m[0].log == "1")
    ' <<<"${rows_json}" >/dev/null \
    || obs11_fail "${name} 방화벽 rule 의미값이 계획과 다르다: enabled=${expected_enabled}"
}

validate_rule_runtime() {
  local rule_uuid=$1 output=${OBS11_API_TMP}/rule-runtime.json
  api_json GET /api/firewall/filter_util/rule_stats "${output}"
  jq -e --arg uuid "${rule_uuid}" '
    .status == "ok" and
    (.stats[$uuid].pf_rules | tonumber) >= 1
  ' "${output}" >/dev/null \
    || obs11_fail 'uncached PF runtime에 생성 UUID가 없다.'
  jq -r --arg uuid "${rule_uuid}" \
    '"FirewallRuntime=PASS uuid=\($uuid) pf_rules=\(.stats[$uuid].pf_rules)"' "${output}"
}

apply_live() {
  local rules rows_json state_root state_dir name description dest seq
  local rule_body add_response rule_uuid toggle_response apply_response

  "${repo_root}/infra/opnsense/scripts/check-drift.sh"
  rules=${OBS11_API_TMP}/rules-pre.json
  rows_json=$(find_owned_rules "${rules}")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || obs11_fail '동일 description의 OBS-11 rule이 이미 있다.'

  state_root=/home/imcherry/.local/state-backups
  install -d -m 700 "${state_root}"
  state_dir=$(mktemp -d "${state_root}/obs-11-XXXXXXXX")
  chmod 700 "${state_dir}"
  : > "${state_dir}/rule-uuids"
  chmod 600 "${state_dir}/rule-uuids"
  echo "복구 지점=${state_dir}"

  for name in "${RULE_NAMES[@]}"; do
    dest=${RULE_DEST[${name}]}
    seq=${RULE_SEQ[${name}]}
    description=$(rule_description "${name}")

    rule_body=${OBS11_API_TMP}/rule-${name}.json
    jq -n --arg description "${description}" --arg dest "${dest}" --arg seq "${seq}" '{rule:{
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
      destination_net:$dest,
      destination_port:"9100",
      gateway:"",
      log:"1",
      description:$description
    }}' > "${rule_body}"
    add_response=${OBS11_API_TMP}/rule-add-${name}.json
    api_json POST /api/firewall/filter/add_rule "${add_response}" "${rule_body}"
    rule_uuid=$(jq -r '.uuid // empty' "${add_response}")
    [[ ${rule_uuid} =~ ^[0-9a-f-]{36}$ ]] \
      || obs11_fail "${name}: 생성된 방화벽 rule UUID를 읽지 못했다."
    printf '%s %s\n' "${name}" "${rule_uuid}" >> "${state_dir}/rule-uuids"
    rows_json=$(find_owned_rules "${rules}")
    validate_rule_row "${name}" "${rows_json}" 0
    echo "FirewallStage=PASS name=${name} uuid=${rule_uuid} sequence=${seq} enabled=0"

    toggle_response=${OBS11_API_TMP}/rule-toggle-${name}.json
    api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/1" "${toggle_response}"
    apply_response=${OBS11_API_TMP}/rule-apply-${name}.json
    api_json POST /api/firewall/filter/apply "${apply_response}"
    rows_json=$(find_owned_rules "${rules}")
    validate_rule_row "${name}" "${rows_json}" 1
    validate_rule_runtime "${rule_uuid}"
    echo "FirewallApply=PASS name=${name} uuid=${rule_uuid} sequence=${seq}"
  done

  echo "STATE_DIR=${state_dir}"
}

rollback_live() {
  local state_dir=${2:-}
  local rules rows_json response name rule_uuid

  [[ -n ${state_dir} && ${state_dir} == /home/imcherry/.local/state-backups/obs-11-* ]] \
    || obs11_fail '명시적인 OBS-11 복구 지점이 필요하다.'
  [[ ! -L ${state_dir} && -d ${state_dir} && -r ${state_dir}/rule-uuids ]] \
    || obs11_fail '복구 지점이 안전하지 않다.'

  while read -r name rule_uuid; do
    [[ -n ${name} && -n ${rule_uuid} ]] || continue
    rules=${OBS11_API_TMP}/rules-rollback-${name}.json
    rows_json=$(find_owned_rules "${rules}")
    if jq -e --arg uuid "${rule_uuid}" '[.[] | select(.uuid == $uuid)] | length == 1' \
      <<<"${rows_json}" >/dev/null; then
      response=${OBS11_API_TMP}/rollback-toggle-${name}.json
      api_json POST "/api/firewall/filter/toggle_rule/${rule_uuid}/0" "${response}"
      response=${OBS11_API_TMP}/rollback-apply-disabled-${name}.json
      api_json POST /api/firewall/filter/apply "${response}"
      response=${OBS11_API_TMP}/rollback-delete-${name}.json
      api_json POST "/api/firewall/filter/del_rule/${rule_uuid}" "${response}"
      response=${OBS11_API_TMP}/rollback-apply-deleted-${name}.json
      api_json POST /api/firewall/filter/apply "${response}"
      echo "FirewallRollback=PASS name=${name} removed_uuid=${rule_uuid}"
    else
      echo "FirewallRollback=SKIP name=${name} uuid=${rule_uuid} (이미 없음)"
    fi
  done < "${state_dir}/rule-uuids"

  rules=${OBS11_API_TMP}/rules-rollback-final.json
  rows_json=$(find_owned_rules "${rules}")
  jq -e 'length == 0' <<<"${rows_json}" >/dev/null \
    || obs11_fail 'rollback 뒤에도 OBS-11 소유 rule이 남아 있다.'
  echo "RollbackReference=${state_dir}"
}

case ${action} in
  apply)
    obs11_load_env "${OBS11_ENV_FILE:-${OBS11_DEFAULT_ENV_FILE}}"
    apply_live
    ;;
  rollback)
    obs11_load_env "${OBS11_ENV_FILE:-${OBS11_DEFAULT_ENV_FILE}}"
    rollback_live "$@"
    ;;
  *) usage ;;
esac
