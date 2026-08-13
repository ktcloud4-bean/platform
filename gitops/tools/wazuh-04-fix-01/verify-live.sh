#!/usr/bin/env bash
# WAZUH-04-FIX-01 라이브 검증. wazuh-04-relay Deployment를 실제로 재시작시켜
# client.keys가 정적으로 살아남는지, 같은 agent ID가 재등록 충돌 없이 다시
# Active로 붙는지 확인한다. ARGO-ROOT 잠금 아래 platform-root/wazuh가 검증
# SHA로 전환된 뒤에만 의미가 있다.
set -euo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)
readonly poll_interval=10
readonly poll_timeout=180

# shellcheck disable=SC2029
remote() {
  ssh "${ssh_options[@]}" "${k3s_host}" "$1"
}

agent_line() {
  remote "${kubectl_command} -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- /var/ossec/bin/agent_control -l" \
    | grep 'Name: wazuh-04-relay,'
}

before=$(agent_line) || { echo '실패: 재시작 전 wazuh-04-relay agent를 찾지 못했다.' >&2; exit 1; }
before_id=$(echo "${before}" | sed -E 's/^ *ID: ([0-9]+).*/\1/')
echo "재시작 전: ${before}"

remote "${kubectl_command} -n wazuh rollout restart deployment/wazuh-04-relay" >/dev/null
remote "${kubectl_command} -n wazuh rollout status deployment/wazuh-04-relay --timeout=120s" >/dev/null

new_pod=$(remote "${kubectl_command} -n wazuh get pods -l app.kubernetes.io/component=wazuh-04-relay -o jsonpath='{.items[0].metadata.name}'")
echo "새 pod: ${new_pod}"

remote "${kubectl_command} -n wazuh exec ${new_pod} -c wazuh-04-relay-agent -- grep -A1 '<enrollment>' /var/ossec/etc/ossec.conf" \
  | grep -q '<enabled>no</enabled>' \
  || { echo '실패: 새 pod의 ossec.conf에서 enrollment가 disabled가 아니다.' >&2; exit 1; }
echo 'ossec.conf enrollment: disabled 확인'

live_id=$(remote "${kubectl_command} -n wazuh exec ${new_pod} -c wazuh-04-relay-agent -- awk '{print \$1}' /var/ossec/etc/client.keys")
[[ ${live_id} == "${before_id}" ]] \
  || { echo "실패: 새 pod의 client.keys ID(${live_id})가 재시작 전 ID(${before_id})와 다르다 — 정적 렌더링이 아니라 재등록이 일어났다." >&2; exit 1; }
echo "client.keys ID 유지 확인: ${live_id}"

elapsed=0
status=''
while (( elapsed < poll_timeout )); do
  line=$(agent_line || true)
  status=$(echo "${line}" | grep -oE 'Active|Disconnected|Never connected' || true)
  [[ ${status} == Active ]] && break
  sleep "${poll_interval}"
  elapsed=$(( elapsed + poll_interval ))
done

[[ ${status} == Active ]] \
  || { echo "실패: ${poll_timeout}초 안에 Active로 복귀하지 못했다(마지막 상태: ${line})." >&2; exit 1; }
after_id=$(echo "${line}" | sed -E 's/^ *ID: ([0-9]+).*/\1/')
[[ ${after_id} == "${before_id}" ]] \
  || { echo "실패: 재시작 후 agent ID가 ${before_id}에서 ${after_id}로 바뀌었다 — 재등록이 일어났다는 뜻이다." >&2; exit 1; }
echo "재시작 후: ${line}"

dup=$(remote "${kubectl_command} -n wazuh logs ${new_pod} -c wazuh-04-relay-agent --tail=200" | grep -c 'Duplicate agent name' || true)
[[ ${dup} -eq 0 ]] \
  || { echo "실패: 새 pod 로그에 Duplicate agent name 오류가 ${dup}건 있다." >&2; exit 1; }
echo 'Duplicate agent name 오류: 0건'

echo "VerifyLive=PASS agent_id=${before_id} status=Active enrollment=disabled duplicate_errors=0"
