#!/usr/bin/env bash
# LOKI-02: cross-VLAN host가 private Loki gateway(10.10.20.10:3100)에만 쓴다.
# Rules[new] sequence는 자동 재계산될 수 있으므로 각 rule을 NET-04 block 직전으로 이동한다.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
# shellcheck source=lib-opnsense.sh
source "$script_dir/lib-opnsense.sh"
trap loki02_cleanup EXIT HUP INT TERM

action=''
if (( $# > 0 )); then action=$1; fi
readonly rule_names='warpgate-01 netbird-01 data-hosts'

usage() {
  echo "사용법: $0 apply | rollback <복구-지점>" >&2
  exit 2
}

rule_interface() {
  case $1 in warpgate-01) echo opt3 ;; netbird-01) echo opt4 ;; data-hosts) echo opt5 ;; *) loki02_fail "알 수 없는 rule: $1" ;; esac
}

rule_source() {
  case $1 in warpgate-01) echo 10.10.30.10 ;; netbird-01) echo 10.10.40.10 ;; data-hosts) echo NET04_DATA_HOSTS ;; *) loki02_fail "알 수 없는 rule: $1" ;; esac
}

rule_description() {
  case $1 in
    data-hosts) echo 'LOKI-02: DATA 실제 host(postgres-01·object-01)에서 private Loki gateway TCP 3100만 허용' ;;
    warpgate-01|netbird-01) echo "LOKI-02: $1에서 private Loki gateway TCP 3100만 허용" ;;
    *) loki02_fail "알 수 없는 rule: $1" ;;
  esac
}

block_description() {
  case $1 in
    warpgate-01) echo 'NET-04: warpgate-01에서 비공개·특수용 IPv4 기본 차단·기록' ;;
    netbird-01) echo 'NET-04: netbird-01에서 비공개·특수용 IPv4 기본 차단·기록' ;;
    data-hosts) echo 'NET-04: DATA 실제 host에서 비공개·특수용 IPv4 기본 차단·기록' ;;
    *) loki02_fail "알 수 없는 rule: $1" ;;
  esac
}

all_rules() {
  local output=$1
  loki02_api_json GET '/api/firewall/filter/search_rule?show_all=1' "$output"
  jq '.rows' "$output"
}

owned_rules() {
  jq '[.[] | select(.description | startswith("LOKI-02:"))]' <<<"$1"
}

anchor_uuid() {
  local name=$1 rows_json=$2 description iface source
  description=$(block_description "$name")
  iface=$(rule_interface "$name")
  source=$(rule_source "$name")
  jq -er --arg description "$description" --arg iface "$iface" --arg source "$source" '
    [.[] | select(.description == $description and .interface == $iface and .source_net == $source and
      .action == "block" and .quick == "1" and .destination_net == "NET04_NONPUBLIC_V4")]
    | if length == 1 then .[0].uuid else error("NET-04 block anchor가 유일하지 않다") end
  ' <<<"$rows_json"
}

validate_rule() {
  local name=$1 rows_json=$2 expected_enabled=$3 description iface source
  description=$(rule_description "$name")
  iface=$(rule_interface "$name")
  source=$(rule_source "$name")
  jq -e --arg enabled "$expected_enabled" --arg description "$description" --arg iface "$iface" --arg source "$source" '
    [.[] | select(.description == $description)] as $m
    | ($m | length == 1) and
      ($m[0].enabled == $enabled) and ($m[0].action == "pass") and ($m[0].quick == "1") and
      ($m[0].interface == $iface) and ($m[0].direction == "in") and
      ($m[0].ipprotocol == "inet") and ($m[0].protocol == "TCP") and
      ($m[0].source_net == $source) and ($m[0].source_port == "") and
      ($m[0].destination_net == "10.10.20.10") and ($m[0].destination_port == "3100") and
      ($m[0].log == "1")
  ' <<<"$rows_json" >/dev/null || loki02_fail "$name rule 의미값이 계획과 다르다: enabled=$expected_enabled"
}

validate_before_anchor() {
  local name=$1 rows_json=$2 description anchor
  description=$(rule_description "$name")
  anchor=$(block_description "$name")
  jq -e --arg description "$description" --arg anchor "$anchor" '
    ([.[] | select(.description == $description)] | length == 1) and
    ([.[] | select(.description == $anchor)] | length == 1) and
    (([.[] | select(.description == $description)][0].sequence | tonumber) <
     ([.[] | select(.description == $anchor)][0].sequence | tonumber))
  ' <<<"$rows_json" >/dev/null || loki02_fail "$name rule이 NET-04 non-public block 앞에 없다."
}

uuid_for_name() {
  awk -v name="$1" '$1 == "rule" && $2 == name { print $3 }' "$2/rule-uuids"
}

apply_live() {
  local rows_json state_dir name description iface source body response uuid anchor
  "$repo_root/infra/opnsense/scripts/check-drift.sh"
  rows_json=$(all_rules "$LOKI02_API_TMP/rules-pre.json")
  jq -e 'length == 0' <<<"$(owned_rules "$rows_json")" >/dev/null || loki02_fail '기존 LOKI-02 rule이 있어 apply를 중단한다.'
  for name in $rule_names; do anchor_uuid "$name" "$rows_json" >/dev/null; done

  install -d -m 700 /home/imcherry/.local/state-backups
  state_dir=$(mktemp -d /home/imcherry/.local/state-backups/loki-02-firewall-XXXXXXXX)
  chmod 700 "$state_dir"
  : > "$state_dir/rule-uuids"
  chmod 600 "$state_dir/rule-uuids"
  echo "복구 지점=$state_dir"

  for name in $rule_names; do
    description=$(rule_description "$name")
    iface=$(rule_interface "$name")
    source=$(rule_source "$name")
    rows_json=$(all_rules "$LOKI02_API_TMP/rules-anchor-$name.json")
    anchor=$(anchor_uuid "$name" "$rows_json")
    body="$LOKI02_API_TMP/rule-$name.json"
    jq -n --arg description "$description" --arg iface "$iface" --arg source "$source" '{rule:{
      enabled:"0", statetype:"keep", action:"pass", quick:"1", interface:$iface, direction:"in",
      ipprotocol:"inet", protocol:"TCP", source_net:$source, source_port:"",
      destination_net:"10.10.20.10", destination_port:"3100", gateway:"", log:"1", description:$description
    }}' > "$body"
    response="$LOKI02_API_TMP/rule-add-$name.json"
    loki02_api_json POST /api/firewall/filter/add_rule "$response" "$body"
    uuid=$(jq -r '.uuid // empty' "$response")
    [[ $uuid =~ ^[0-9a-f-]{36}$ ]] || loki02_fail "$name: 생성 UUID를 읽지 못했다."
    printf 'rule %s %s %s\n' "$name" "$uuid" "$anchor" >> "$state_dir/rule-uuids"
    rows_json=$(all_rules "$LOKI02_API_TMP/rules-staged-$name.json")
    validate_rule "$name" "$rows_json" 0
    response="$LOKI02_API_TMP/rule-move-$name.json"
    loki02_api_json POST "/api/firewall/filter/move_rule_before/$uuid/$anchor" "$response"
    jq -e '.status == "ok"' "$response" >/dev/null || loki02_fail "$name: rule 순서 이동 API가 성공하지 않았다."
    rows_json=$(all_rules "$LOKI02_API_TMP/rules-moved-$name.json")
    validate_rule "$name" "$rows_json" 0
    validate_before_anchor "$name" "$rows_json"
    echo "FirewallStage=PASS name=$name uuid=$uuid enabled=0"
  done

  for name in $rule_names; do
    uuid=$(uuid_for_name "$name" "$state_dir")
    [[ $uuid =~ ^[0-9a-f-]{36}$ ]] || loki02_fail "$name: 복구 UUID가 안전하지 않다."
    response="$LOKI02_API_TMP/rule-toggle-$name.json"
    loki02_api_json POST "/api/firewall/filter/toggle_rule/$uuid/1" "$response"
  done
  response="$LOKI02_API_TMP/rule-apply.json"
  loki02_api_json POST /api/firewall/filter/apply "$response"
  rows_json=$(all_rules "$LOKI02_API_TMP/rules-enabled.json")
  for name in $rule_names; do
    validate_rule "$name" "$rows_json" 1
    validate_before_anchor "$name" "$rows_json"
    echo "FirewallApply=PASS name=$name uuid=$(uuid_for_name "$name" "$state_dir")"
  done
  echo "STATE_DIR=$state_dir"
}

rollback_live() {
  local state_dir=$2 kind name uuid anchor rows_json response
  [[ $state_dir == /home/imcherry/.local/state-backups/loki-02-firewall-* ]] || loki02_fail '명시적인 LOKI-02 복구 지점이 필요하다.'
  [[ ! -L $state_dir && -d $state_dir && -r $state_dir/rule-uuids ]] || loki02_fail '복구 지점이 안전하지 않다.'
  rows_json=$(all_rules "$LOKI02_API_TMP/rules-rollback-pre.json")
  while read -r kind name uuid anchor; do
    [[ -n $kind && $kind == rule && $uuid =~ ^[0-9a-f-]{36}$ ]] || loki02_fail '복구 지점 형식이 안전하지 않다.'
    if jq -e --arg uuid "$uuid" '[.[] | select(.uuid == $uuid)] | length == 1' <<<"$rows_json" >/dev/null; then
      response="$LOKI02_API_TMP/rollback-toggle-$name.json"
      loki02_api_json POST "/api/firewall/filter/toggle_rule/$uuid/0" "$response"
    fi
  done < "$state_dir/rule-uuids"
  loki02_api_json POST /api/firewall/filter/apply "$LOKI02_API_TMP/rollback-apply-disabled.json"
  rows_json=$(all_rules "$LOKI02_API_TMP/rules-rollback-disabled.json")
  while read -r kind name uuid anchor; do
    if jq -e --arg uuid "$uuid" '[.[] | select(.uuid == $uuid)] | length == 1' <<<"$rows_json" >/dev/null; then
      loki02_api_json POST "/api/firewall/filter/del_rule/$uuid" "$LOKI02_API_TMP/rollback-delete-$name.json"
      echo "FirewallRollback=PASS name=$name removed_uuid=$uuid"
    fi
  done < "$state_dir/rule-uuids"
  loki02_api_json POST /api/firewall/filter/apply "$LOKI02_API_TMP/rollback-apply-deleted.json"
  rows_json=$(all_rules "$LOKI02_API_TMP/rules-rollback-final.json")
  jq -e 'length == 0' <<<"$(owned_rules "$rows_json")" >/dev/null || loki02_fail 'rollback 뒤에도 LOKI-02 rule이 남아 있다.'
  echo "RollbackReference=$state_dir"
}

case $action in
  apply) loki02_load_env; apply_live ;;
  rollback) (( $# == 2 )) || usage; loki02_load_env; rollback_live "$@" ;;
  *) usage ;;
esac
