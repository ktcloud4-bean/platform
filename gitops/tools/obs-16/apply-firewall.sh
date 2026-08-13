#!/usr/bin/env bash
# OBS-16의 다섯 native metrics 경로만 OPNsense opt2 ingress에 추가하거나 제거한다.
set -Eeuo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
readonly script_dir
repo_root=$(git -C "${script_dir}" rev-parse --show-toplevel)
readonly repo_root
# OBS-15에서 검증한 credential file·strict TLS API transport를 재사용한다.
# shellcheck disable=SC1091 # sibling task의 검증된 strict-TLS OPNsense transport다.
source "${script_dir}/../obs-15/lib-opnsense.sh"
trap obs15_cleanup EXIT HUP INT TERM

obs15_fail() {
  echo "OBS-16 실패: $*" >&2
  exit 1
}

readonly action=${1:-}
readonly -a sequences=(1009 1010 1011 1014 1016)
readonly -a descriptions=(
  'OBS-16: k3s-01에서 object-01 SeaweedFS master metrics TCP 9325만 허용'
  'OBS-16: k3s-01에서 object-01 SeaweedFS volume metrics TCP 9326만 허용'
  'OBS-16: k3s-01에서 object-01 SeaweedFS filer metrics TCP 9327만 허용'
  'OBS-16: k3s-01에서 object-01 SeaweedFS S3 metrics TCP 9328만 허용'
  'OBS-16: k3s-01에서 netbird-01 management metrics TCP 9090만 허용'
)
readonly -a destinations=(10.10.50.20 10.10.50.20 10.10.50.20 10.10.50.20 10.10.40.10)
readonly -a ports=(9325 9326 9327 9328 9090)

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

api_json() {
  local method=$1 api_path=$2 output=$3 body_file=${4:-}
  obs15_api "${method}" "${api_path}" "${output}" "${body_file}"
  jq -e . "${output}" >/dev/null || obs15_fail "JSON이 아닌 API 응답이다: ${api_path}"
}

all_rules() {
  local output=$1
  api_json GET '/api/firewall/filter/search_rule?interface=opt2&show_all=1' "${output}"
  jq '.rows' "${output}"
}

owned_row() {
  local rows=$1 description=$2
  jq --arg description "${description}" '[.[] | select(.description == $description)]' <<<"${rows}"
}

validate_rule() {
  local rows=$1 index=$2 enabled=$3 expected
  expected=$(owned_row "${rows}" "${descriptions[${index}]}")
  jq -e \
    --arg enabled "${enabled}" \
    --arg sequence "${sequences[${index}]}" \
    --arg destination "${destinations[${index}]}" \
    --arg port "${ports[${index}]}" '
      length == 1 and
      .[0].enabled == $enabled and .[0].sequence == $sequence and
      .[0].action == "pass" and .[0].quick == "1" and
      .[0].interface == "opt2" and .[0].direction == "in" and
      .[0].ipprotocol == "inet" and .[0].protocol == "TCP" and
      .[0].source_net == "10.10.20.10" and .[0].source_port == "" and
      .[0].destination_net == $destination and .[0].destination_port == $port and
      .[0].log == "1"
    ' <<<"${expected}" >/dev/null \
    || obs15_fail "방화벽 rule 의미값이 계획과 다르다: index=${index} enabled=${enabled}"
}

validate_runtime() {
  local state_dir=$1 stats index uuid
  stats=${OBS15_API_TMP}/rule-stats.json
  api_json GET /api/firewall/filter_util/rule_stats "${stats}"
  for index in "${!descriptions[@]}"; do
    uuid=$(<"${state_dir}/rule-${index}.uuid")
    jq -e --arg uuid "${uuid}" '.status == "ok" and (.stats[$uuid].pf_rules | tonumber) >= 1' "${stats}" >/dev/null \
      || obs15_fail "PF runtime에 OBS-16 rule이 없다: index=${index}"
  done
}

apply_live() {
  local rules_file rows state_root state_dir index body response uuid

  "${repo_root}/infra/opnsense/scripts/check-drift.sh"
  rules_file=${OBS15_API_TMP}/rules-pre.json
  rows=$(all_rules "${rules_file}")
  for index in "${!descriptions[@]}"; do
    jq -e --arg description "${descriptions[${index}]}" '[.[] | select(.description == $description)] | length == 0' <<<"${rows}" >/dev/null \
      || obs15_fail "동일 description의 OBS-16 rule이 이미 있다: index=${index}"
    jq -e --arg sequence "${sequences[${index}]}" '[.[] | select(.sequence == $sequence)] | length == 0' <<<"${rows}" >/dev/null \
      || obs15_fail "opt2 sequence가 이미 사용 중이다: ${sequences[${index}]}"
  done

  state_root=/home/imcherry/.local/state-backups
  install -d -m 700 "${state_root}"
  state_dir=$(mktemp -d "${state_root}/obs-16-XXXXXXXX")
  chmod 700 "${state_dir}"
  echo "복구 지점=${state_dir}"

  for index in "${!descriptions[@]}"; do
    body=${OBS15_API_TMP}/rule-${index}.json
    jq -n \
      --arg description "${descriptions[${index}]}" \
      --arg sequence "${sequences[${index}]}" \
      --arg destination "${destinations[${index}]}" \
      --arg port "${ports[${index}]}" '{rule:{
        enabled:"0", statetype:"keep", sequence:$sequence, action:"pass", quick:"1",
        interface:"opt2", direction:"in", ipprotocol:"inet", protocol:"TCP",
        source_net:"10.10.20.10", source_port:"", destination_net:$destination,
        destination_port:$port, gateway:"", log:"1", description:$description
      }}' >"${body}"
    response=${OBS15_API_TMP}/rule-${index}-add.json
    api_json POST /api/firewall/filter/add_rule "${response}" "${body}"
    uuid=$(jq -r '.uuid // empty' "${response}")
    [[ ${uuid} =~ ^[0-9a-f-]{36}$ ]] || obs15_fail "생성된 rule UUID를 읽지 못했다: index=${index}"
    printf '%s\n' "${uuid}" >"${state_dir}/rule-${index}.uuid"
    chmod 600 "${state_dir}/rule-${index}.uuid"
  done
  rows=$(all_rules "${rules_file}")
  for index in "${!descriptions[@]}"; do validate_rule "${rows}" "${index}" 0; done
  echo "FirewallStage=PASS rules=${#descriptions[@]}"

  for index in "${!descriptions[@]}"; do
    uuid=$(<"${state_dir}/rule-${index}.uuid")
    response=${OBS15_API_TMP}/rule-${index}-enable.json
    api_json POST "/api/firewall/filter/toggle_rule/${uuid}/1" "${response}"
  done
  response=${OBS15_API_TMP}/rules-apply.json
  api_json POST /api/firewall/filter/apply "${response}"
  rows=$(all_rules "${rules_file}")
  for index in "${!descriptions[@]}"; do validate_rule "${rows}" "${index}" 1; done
  validate_runtime "${state_dir}"
  echo "FirewallApply=PASS rules=${#descriptions[@]} STATE_DIR=${state_dir}"
}

rollback_live() {
  local state_dir=${2:-} index uuid response rules_file rows
  [[ ${state_dir} == /home/imcherry/.local/state-backups/obs-16-* && ! -L ${state_dir} && -d ${state_dir} ]] \
    || obs15_fail '명시적인 OBS-16 복구 지점이 필요하다.'
  for index in "${!descriptions[@]}"; do
    [[ -r ${state_dir}/rule-${index}.uuid ]] || obs15_fail "복구 UUID 파일이 없다: index=${index}"
    uuid=$(<"${state_dir}/rule-${index}.uuid")
    [[ ${uuid} =~ ^[0-9a-f-]{36}$ ]] || obs15_fail "복구 UUID 형식이 안전하지 않다: index=${index}"
    response=${OBS15_API_TMP}/rule-${index}-disable.json
    api_json POST "/api/firewall/filter/toggle_rule/${uuid}/0" "${response}"
  done
  response=${OBS15_API_TMP}/rollback-apply-disabled.json
  api_json POST /api/firewall/filter/apply "${response}"
  for index in "${!descriptions[@]}"; do
    uuid=$(<"${state_dir}/rule-${index}.uuid")
    response=${OBS15_API_TMP}/rule-${index}-delete.json
    api_json POST "/api/firewall/filter/del_rule/${uuid}" "${response}"
  done
  response=${OBS15_API_TMP}/rollback-apply-deleted.json
  api_json POST /api/firewall/filter/apply "${response}"
  rules_file=${OBS15_API_TMP}/rules-rollback.json
  rows=$(all_rules "${rules_file}")
  for index in "${!descriptions[@]}"; do
    jq -e --arg description "${descriptions[${index}]}" '[.[] | select(.description == $description)] | length == 0' <<<"${rows}" >/dev/null \
      || obs15_fail "rollback 뒤 OBS-16 rule이 남아 있다: index=${index}"
  done
  echo "FirewallRollback=PASS rules=${#descriptions[@]}"
}

case ${action} in
  apply)
    obs15_load_env "${OBS16_ENV_FILE:-${OBS15_DEFAULT_ENV_FILE}}"
    apply_live
    ;;
  rollback)
    obs15_load_env "${OBS16_ENV_FILE:-${OBS15_DEFAULT_ENV_FILE}}"
    rollback_live "$@"
    ;;
  *) usage ;;
esac
