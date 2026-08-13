#!/usr/bin/env bash
# WAZUH-04-FIX-01: 매니저에 이미 살아 있는 wazuh-04-relay agent의 client.keys 한 줄을
# 그대로 재사용해 kv/wazuh/manager에 새 필드(wazuh_04_relay_client_keys)로 저장한다.
# manage_agents/agent-auth로 새 enrollment를 만들지 않는다 — 기존 등록을 옮겨 담을
# 뿐이다. 이 스크립트는 어떤 모드에서도 key 값을 출력하지 않는다.
set -euo pipefail

readonly mode=${1:-check}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly agent_name=wazuh-04-relay
readonly vault_field=wazuh_04_relay_client_keys
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == check || ${mode} == apply ]] || {
  echo 'usage: apply-client-keys.sh [check|apply]' >&2
  exit 2
}
[[ -f ${vault_token_file} && ! -L ${vault_token_file} && $(stat -c %a "${vault_token_file}") == 600 ]] || {
  echo '실패: Vault root token file이 없거나 mode 0600이 아니다.' >&2
  exit 1
}

# shellcheck disable=SC2029
manager_has_line() {
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- grep -qE '^[0-9]+ ${agent_name} ' /var/ossec/etc/client.keys"
}

# shellcheck disable=SC2029
vault_has_field() {
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault kv get -field=${vault_field} kv/wazuh/manager' >/dev/null 2>&1"
}

if [[ ${mode} == check ]]; then
  if manager_has_line; then
    echo "ManagerClientKeys=PRESENT agent=${agent_name}"
  else
    echo "ManagerClientKeys=ABSENT agent=${agent_name}" >&2
    exit 1
  fi
  if vault_has_field; then
    echo "VaultField=PRESENT field=${vault_field}"
  else
    echo "VaultField=ABSENT field=${vault_field}"
  fi
  exit 0
fi

# apply: 매니저 live client.keys에서 해당 agent 줄을 읽어(로컬에 저장하지 않고
# 이 스크립트 프로세스 메모리에만 잠깐 존재) kv/wazuh/manager의 기존 필드는 그대로
# 두고 이 필드 하나만 patch한다.
manager_has_line || {
  echo "실패: 매니저 client.keys에 ${agent_name} 등록이 없다 — 재등록을 먼저 확인하라." >&2
  exit 1
}
# shellcheck disable=SC2029
line=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n wazuh exec wazuh-manager-master-0 -c wazuh-manager -- grep -E '^[0-9]+ ${agent_name} ' /var/ossec/etc/client.keys")

# shellcheck disable=SC2029
{ tr -d '\n' <"${vault_token_file}"; printf '\n%s\n' "${line}"; } | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; read -r CKEY; export VAULT_TOKEN; vault kv patch kv/wazuh/manager ${vault_field}=\"\$CKEY\" >/dev/null'"

echo "Applied=PASS field=${vault_field}"
