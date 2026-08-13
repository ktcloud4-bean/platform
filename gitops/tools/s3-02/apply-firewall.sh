#!/usr/bin/env bash
# S3-02의 SeaweedFS admin 웹 UI 단일 경로(k3s-01 -> object-01 TCP 23646)만 OPNsense opt2
# ingress에 추가하거나 제거한다. 기존 S3-01(8333)·OBS-16(9325~9328) 규칙은
# 건드리지 않는다.
set -Eeuo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root
# OBS-15에서 검증한 credential file·strict TLS API transport를 재사용한다.
# shellcheck disable=SC1091 # sibling task의 검증된 strict-TLS OPNsense transport다.
source "${script_dir}/../obs-15/lib-opnsense.sh"
trap obs15_cleanup EXIT HUP INT TERM

s302_fail() {
  echo "S3-02 실패: $*" >&2
  exit 1
}

readonly action=${1:-}
# 1002~1021은 이미 꽉 찬 "k3s-01→비공개 목적지 개별 허용" 구간이고 1022는 그 뒤의
# quick 기본 차단(NET-04 NET04_NONPUBLIC_V4) rule이다. object-01도 비공개 목적지라
# 1022보다 뒤(예: 1024, OBS-18·NET-04 web egress처럼 공개 목적지용 구간)에 두면 차단
# rule에 먼저 매치돼 절대 평가되지 않는다. 그래서 빈 1000을 쓴다.
readonly sequence=1000
readonly description='S3-02: k3s-01에서 object-01 SeaweedFS admin 웹 UI TCP 23646만 허용'
readonly destination=10.10.50.20
readonly port=23646

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

api_json() {
  local method=$1 api_path=$2 output=$3 body_file=${4:-}
  obs15_api "${method}" "${api_path}" "${output}" "${body_file}"
  jq -e . "${output}" >/dev/null || s302_fail "JSON이 아닌 API 응답이다: ${api_path}"
}

all_rules() {
  local output=$1
  api_json GET '/api/firewall/filter/search_rule?interface=opt2&show_all=1' "${output}"
  jq '.rows' "${output}"
}

owned_row() {
  local rows=$1
  jq --arg description "${description}" '[.[] | select(.description == $description)]' <<<"${rows}"
}

validate_rule() {
  local rows=$1 enabled=$2 expected
  expected=$(owned_row "${rows}")
  jq -e \
    --arg enabled "${enabled}" \
    --arg sequence "${sequence}" \
    --arg destination "${destination}" \
    --arg port "${port}" '
      length == 1 and
      .[0].enabled == $enabled and .[0].sequence == $sequence and
      .[0].action == "pass" and .[0].quick == "1" and
      .[0].interface == "opt2" and .[0].direction == "in" and
      .[0].ipprotocol == "inet" and .[0].protocol == "TCP" and
      .[0].source_net == "10.10.20.10" and .[0].source_port == "" and
      .[0].destination_net == $destination and .[0].destination_port == $port and
      .[0].log == "1"
    ' <<<"${expected}" >/dev/null \
    || s302_fail "방화벽 rule 의미값이 계획과 다르다: enabled=${enabled}"
}

validate_runtime() {
  local state_dir=$1 stats uuid
  stats=${OBS15_API_TMP}/rule-stats.json
  api_json GET /api/firewall/filter_util/rule_stats "${stats}"
  uuid=$(<"${state_dir}/rule.uuid")
  jq -e --arg uuid "${uuid}" '.status == "ok" and (.stats[$uuid].pf_rules | tonumber) >= 1' "${stats}" >/dev/null \
    || s302_fail "PF runtime에 S3-02 rule이 없다"
}

apply_live() {
  local rules_file rows state_root state_dir body response uuid

  "${repo_root}/infra/opnsense/scripts/check-drift.sh"
  rules_file=${OBS15_API_TMP}/rules-pre.json
  rows=$(all_rules "${rules_file}")
  jq -e --arg description "${description}" '[.[] | select(.description == $description)] | length == 0' <<<"${rows}" >/dev/null \
    || s302_fail "동일 description의 S3-02 rule이 이미 있다"
  jq -e --arg sequence "${sequence}" '[.[] | select(.sequence == $sequence)] | length == 0' <<<"${rows}" >/dev/null \
    || s302_fail "opt2 sequence가 이미 사용 중이다: ${sequence}"

  state_root=/home/imcherry/.local/state-backups
  install -d -m 700 "${state_root}"
  state_dir=$(mktemp -d "${state_root}/s3-02-XXXXXXXX")
  chmod 700 "${state_dir}"
  echo "복구 지점=${state_dir}"

  body=${OBS15_API_TMP}/rule.json
  jq -n \
    --arg description "${description}" \
    --arg sequence "${sequence}" \
    --arg destination "${destination}" \
    --arg port "${port}" '{rule:{
      enabled:"0", statetype:"keep", sequence:$sequence, action:"pass", quick:"1",
      interface:"opt2", direction:"in", ipprotocol:"inet", protocol:"TCP",
      source_net:"10.10.20.10", source_port:"", destination_net:$destination,
      destination_port:$port, gateway:"", log:"1", description:$description
    }}' >"${body}"
  response=${OBS15_API_TMP}/rule-add.json
  api_json POST /api/firewall/filter/add_rule "${response}" "${body}"
  uuid=$(jq -r '.uuid // empty' "${response}")
  [[ ${uuid} =~ ^[0-9a-f-]{36}$ ]] || s302_fail "생성된 rule UUID를 읽지 못했다"
  printf '%s\n' "${uuid}" >"${state_dir}/rule.uuid"
  chmod 600 "${state_dir}/rule.uuid"

  rows=$(all_rules "${rules_file}")
  validate_rule "${rows}" 0
  echo "FirewallStage=PASS"

  response=${OBS15_API_TMP}/rule-enable.json
  api_json POST "/api/firewall/filter/toggle_rule/${uuid}/1" "${response}"
  response=${OBS15_API_TMP}/rules-apply.json
  api_json POST /api/firewall/filter/apply "${response}"
  rows=$(all_rules "${rules_file}")
  validate_rule "${rows}" 1
  validate_runtime "${state_dir}"
  echo "FirewallApply=PASS STATE_DIR=${state_dir}"
}

rollback_live() {
  local state_dir=${2:-} uuid response rules_file rows
  [[ ${state_dir} == /home/imcherry/.local/state-backups/s3-02-* && ! -L ${state_dir} && -d ${state_dir} ]] \
    || s302_fail '명시적인 S3-02 복구 지점이 필요하다.'
  [[ -r ${state_dir}/rule.uuid ]] || s302_fail "복구 UUID 파일이 없다"
  uuid=$(<"${state_dir}/rule.uuid")
  [[ ${uuid} =~ ^[0-9a-f-]{36}$ ]] || s302_fail "복구 UUID 형식이 안전하지 않다"

  response=${OBS15_API_TMP}/rule-disable.json
  api_json POST "/api/firewall/filter/toggle_rule/${uuid}/0" "${response}"
  response=${OBS15_API_TMP}/rollback-apply-disabled.json
  api_json POST /api/firewall/filter/apply "${response}"
  response=${OBS15_API_TMP}/rule-delete.json
  api_json POST "/api/firewall/filter/del_rule/${uuid}" "${response}"
  response=${OBS15_API_TMP}/rollback-apply-deleted.json
  api_json POST /api/firewall/filter/apply "${response}"

  rules_file=${OBS15_API_TMP}/rules-rollback.json
  rows=$(all_rules "${rules_file}")
  jq -e --arg description "${description}" '[.[] | select(.description == $description)] | length == 0' <<<"${rows}" >/dev/null \
    || s302_fail "rollback 뒤 S3-02 rule이 남아 있다"
  echo "FirewallRollback=PASS"
}

case ${action} in
  apply)
    obs15_load_env "${S302_ENV_FILE:-${OBS15_DEFAULT_ENV_FILE}}"
    apply_live
    ;;
  rollback)
    obs15_load_env "${S302_ENV_FILE:-${OBS15_DEFAULT_ENV_FILE}}"
    rollback_live "$@"
    ;;
  *) usage ;;
esac
