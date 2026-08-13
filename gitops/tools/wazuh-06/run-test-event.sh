#!/usr/bin/env bash
# WAZUH-06 임시 level 14 test event의 전체 수명주기.
#
# level>=14는 이 랩에서 평상시 0건이다(전체 보존 기간 실측: 최대 level 8). 그래서
# Slack 전달 경로는 승인된 임시 event 한 건으로만 판정할 수 있다. 이 스크립트는 그
# event를 만들고, 판정하고, 흔적을 지우는 일을 한 곳에서 소유한다.
#
#   stage    임시 rule 100129(level 14)를 running manager에 설치하고 analysisd를 재적재
#   fire     queue socket으로 정확히 한 건을 주입하고 notifier 전달 결과를 판정
#   status   임시 rule·test record가 지금 남아 있는지 조회
#   cleanup  임시 rule·alerts.json 기록·indexer 문서를 모두 제거하고 재적재
#
# 임시 rule은 의도적으로 Argo 선언(gitops/apps/wazuh/files/)에 넣지 않는다. main에
# 남으면 안 되는 검증용 객체이므로 라이브에만 존재했다가 cleanup으로 사라진다.
set -euo pipefail

readonly mode=${1:-status}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly secret_dir=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}/wazuh
readonly rule_id=100129
readonly rule_path=/var/ossec/etc/rules/wazuh-06-test.xml
readonly token=WAZUH06-TEST-EVENT
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == stage || ${mode} == fire || ${mode} == status || ${mode} == cleanup ]] || {
  echo 'usage: run-test-event.sh [stage|fire|status|cleanup]' >&2
  exit 2
}

fail() {
  echo "실패(${1}): ${2}" >&2
  exit 1
}

manager_sh() {
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n wazuh exec -i wazuh-manager-master-0 -c wazuh-manager -- sh -s"
}

manager_py() {
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n wazuh exec -i wazuh-manager-master-0 -c wazuh-manager -- \
     /var/ossec/framework/python/bin/python3 -"
}

kctl() {
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

indexer_delete_test_docs() {
  local port=${WAZUH06_INDEXER_FORWARD_PORT:-19298}
  local indexer_ip
  indexer_ip=$(kctl -n wazuh get service indexer -o 'jsonpath={.spec.clusterIP}')
  [[ ${indexer_ip} =~ ^[0-9.]+$ ]] || fail cleanup 'indexer ClusterIP를 읽지 못했다.'

  ssh "${ssh_options[@]}" -f -N -L "127.0.0.1:${port}:${indexer_ip}:9200" "${k3s_host}"
  local tunnel_pid
  tunnel_pid=$(pgrep -f "127.0.0.1:${port}:${indexer_ip}:9200" | head -1)
  # shellcheck disable=SC2064
  trap "kill ${tunnel_pid} 2>/dev/null || true" RETURN

  local curl_args=(
    -fsS --cacert "${secret_dir}/root-ca.pem"
    --cert "${secret_dir}/admin.pem" --key "${secret_dir}/admin-key.pem"
    -H 'Content-Type: application/json'
  )
  for _ in $(seq 1 20); do
    curl "${curl_args[@]}" "https://localhost:${port}/_cluster/health" >/dev/null 2>&1 && break
    sleep 1
  done

  curl "${curl_args[@]}" -X POST \
    "https://localhost:${port}/wazuh-alerts-4.x-*/_delete_by_query?refresh=true&ignore_unavailable=true" \
    --data "{\"query\":{\"term\":{\"rule.id\":\"${rule_id}\"}}}"
  echo
}

case ${mode} in
  stage)
    manager_sh <<SH
set -eu
cat >${rule_path} <<'XML'
<!--
  WAZUH-06 임시 검증 rule. gitops/tools/wazuh-06/run-test-event.sh가 라이브에만
  설치하고 cleanup에서 제거한다. Argo 선언에는 존재하지 않는다.

  100129는 D30 headroom(100123~100129)의 마지막 ID다. A90 범위(100100~100109) 밖이라
  index 라우팅은 기본 D30을 쓴다. no_full_log로 alert 자체에도 원문을 남기지 않는다.
-->
<group name="wazuh_d30,wazuh_06_test,">
  <rule id="${rule_id}" level="14">
    <match>${token}</match>
    <description>WAZUH-06 temporary level 14 notification test</description>
    <options>no_full_log</options>
  </rule>
</group>
XML
chown root:wazuh ${rule_path}
chmod 0660 ${rule_path}
/var/ossec/bin/wazuh-control restart >/dev/null 2>&1
sleep 5
/var/ossec/bin/wazuh-control status | grep -E 'analysisd|integratord'
SH
    echo "Stage=PASS rule ${rule_id}(level 14) 설치, analysisd 재적재"
    ;;

  fire)
    before=$(kctl -n wazuh logs deployment/wazuh-06-notifier -c wazuh-06-notifier --tail=-1 | wc -l)

    manager_py <<PY
import socket

# analysisd queue socket에 정확히 한 건만 넣는다. localfile을 추가하지 않으므로
# 선언된 ossec.conf는 손대지 않는다.
message = "1:wazuh-06-test:${token} approved single notification probe"
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.connect("/var/ossec/queue/sockets/queue")
sock.send(message.encode("utf-8"))
sock.close()
print("injected=1")
PY

    echo '주입 후 최대 60초까지 notifier 전달 결과를 기다린다.'
    verdict=''
    for _ in $(seq 1 12); do
      sleep 5
      verdict=$(kctl -n wazuh logs deployment/wazuh-06-notifier -c wazuh-06-notifier --tail=-1 \
        | tail -n "+$((before + 1))" | grep -E 'Slack 전송' || true)
      [[ -n ${verdict} ]] && break
    done
    [[ -n ${verdict} ]] || fail fire 'notifier가 60초 안에 Slack 전송을 기록하지 않았다.'
    grep -q 'Slack 전송 완료' <<<"${verdict}" \
      || fail fire "notifier가 Slack 전송에 실패했다: ${verdict}"
    grep -q "rule=${rule_id}" <<<"${verdict}" \
      || fail fire "notifier가 다른 rule을 전송했다: ${verdict}"
    grep -q 'test=True' <<<"${verdict}" \
      || fail fire "notifier가 test 표시를 붙이지 않았다: ${verdict}"
    echo "Fire=PASS ${verdict}"

    # alert 자체에 원문이 없는지 manager 쪽 기록으로 확인한다.
    raw=$(manager_sh <<SH
set -eu
line=\$(grep -h "\"id\":\"${rule_id}\"" /var/ossec/logs/alerts/alerts.json | tail -1)
[ -n "\$line" ] || { echo 'alert=MISSING'; exit 1; }
case "\$line" in
  *'"full_log"'*) echo 'full_log=PRESENT'; exit 1 ;;
  *) echo 'full_log=absent' ;;
esac
case "\$line" in
  *"${token}"*) echo 'raw_token=PRESENT'; exit 1 ;;
  *) echo 'raw_token=absent' ;;
esac
SH
    ) || fail fire "alert 원문 판정 실패: ${raw}"
    echo "AlertRedaction=PASS ${raw//$'\n'/ }"
    echo
    echo '사람 확인이 남았다: Slack #security-alerts 채널에서'
    echo "  [TEST][SECURITY][CRITICAL] @channel / rule ${rule_id} (level 14)"
    echo '메시지 한 건과, 그 안에 원문 로그·IP·사용자명이 없음을 확인한다.'
    ;;

  status)
    manager_sh <<SH
set -eu
if [ -f ${rule_path} ]; then echo 'temp_rule=PRESENT'; else echo 'temp_rule=absent'; fi
count=\$(grep -hc "\"id\":\"${rule_id}\"" /var/ossec/logs/alerts/alerts.json 2>/dev/null || true)
echo "alerts_json_records=\${count:-0}"
SH
    ;;

  cleanup)
    manager_sh <<SH
set -eu
rm -f ${rule_path}
# alerts.json/alerts.log에서 test record만 지운다. 다른 기록은 그대로 둔다.
for f in /var/ossec/logs/alerts/alerts.json /var/ossec/logs/alerts/alerts.log; do
  [ -f "\$f" ] || continue
  grep -v "${token}" "\$f" | grep -v "\"id\":\"${rule_id}\"" > "\$f.wazuh06" || true
  cat "\$f.wazuh06" > "\$f"
  rm -f "\$f.wazuh06"
done
/var/ossec/bin/wazuh-control restart >/dev/null 2>&1
sleep 5
if [ -f ${rule_path} ]; then echo 'temp_rule=STILL_PRESENT'; exit 1; fi
echo 'temp_rule=removed'
count=\$(grep -hc "\"id\":\"${rule_id}\"" /var/ossec/logs/alerts/alerts.json 2>/dev/null || true)
echo "alerts_json_records=\${count:-0}"
[ "\${count:-0}" = "0" ] || exit 1
SH

    echo 'indexer에서 test 문서를 지운다.'
    indexer_delete_test_docs

    echo 'Cleanup=PASS 임시 rule·alerts.json 기록·indexer 문서 제거'
    ;;
esac
