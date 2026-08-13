#!/usr/bin/env bash
# WAZUH-06 Vault provisioning.
#
# notifier 전용 Vault policy·Kubernetes auth role·kv/wazuh/security-notifier만 새로
# 만든다. WAZUH-01/02가 만든 indexer·manager·bootstrap·dashboard policy/role/kv와
# OBS의 운영 Slack 경로는 어느 모드에서도 건드리지 않는다.
#
# 입력은 저장소 밖 mode 0600 파일 하나다:
#   ${KTC_SECRET_ROOT}/wazuh/security-notifier-slack-webhook-url
# 이 스크립트는 어떤 모드에서도 webhook 값을 출력하지 않는다.
set -euo pipefail

readonly mode=${1:-check}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/wazuh
readonly webhook_file=${secret_dir}/security-notifier-slack-webhook-url
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly vault_policy=wazuh-06-notifier
readonly vault_role=wazuh-06-notifier
readonly vault_kv=kv/wazuh/security-notifier
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == check || ${mode} == apply || ${mode} == rollback ]] || {
  echo 'usage: provision.sh [check|apply|rollback]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'provision 실패: 인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
[[ -f ${vault_token_file} && ! -L ${vault_token_file} && $(stat -c %a "${vault_token_file}") == 600 ]] || {
  echo 'provision 실패: Vault root token file이 없거나 mode 0600이 아니다.' >&2
  exit 1
}

exec 9>/tmp/wazuh-06-provision.lock
flock -n 9 || {
  echo 'provision 실패: 다른 WAZUH-06 provisioning이 실행 중이다.' >&2
  exit 1
}

vault_exec() {
  local script=$1
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; ${script}'"
}

with_token() {
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec "$1"
}

vault_check() {
  with_token \
    "vault policy read ${vault_policy} >/dev/null &&
     vault read auth/kubernetes/role/${vault_role} >/dev/null &&
     vault kv get -field=slack_webhook_url ${vault_kv} >/dev/null"
}

if [[ ${mode} == check ]]; then
  if vault_check >/dev/null 2>&1; then
    echo "VaultRuntime=PASS policy=${vault_policy} role=${vault_role} kv=${vault_kv}"
  else
    echo 'VaultRuntime=ABSENT'
  fi
  exit 0
fi

if [[ ${mode} == rollback ]]; then
  # notifier 전용 policy·role·kv만 지운다. 다른 wazuh 경로와 로컬 입력 파일은
  # 건드리지 않는다.
  with_token \
    "vault kv metadata delete ${vault_kv} >/dev/null 2>&1 || true
     vault delete auth/kubernetes/role/${vault_role} >/dev/null 2>&1 || true
     vault policy delete ${vault_policy} >/dev/null 2>&1 || true"
  if vault_check >/dev/null 2>&1; then
    echo 'provision 실패: rollback 뒤에도 notifier policy/role/kv가 남아 있다.' >&2
    exit 1
  fi
  echo "Rollback=PASS policy=${vault_policy} role=${vault_role} kv=${vault_kv} removed"
  exit 0
fi

[[ -f ${webhook_file} && ! -L ${webhook_file} && $(stat -c %a "${webhook_file}") == 600 ]] || {
  echo "provision 실패: ${webhook_file}이 없거나 mode 0600이 아니다." >&2
  exit 1
}

# webhook 형식을 로컬에서 먼저 검증한다. 값은 출력하지 않고 판정만 남긴다 —
# notifier Pod의 EXPECTED_HOST 검증과 같은 기준이라 잘못된 값이 Vault에 들어가
# 첫 경보에서야 실패하는 일을 막는다.
python3 - "${webhook_file}" <<'PY'
import sys
import urllib.parse

with open(sys.argv[1], encoding="utf-8") as handle:
    hook = handle.read().strip()

parsed = urllib.parse.urlsplit(hook)
if (
    parsed.scheme != "https"
    or parsed.hostname != "hooks.slack.com"
    or parsed.port not in (None, 443)
    or not parsed.path.startswith("/services/")
    or parsed.query
    or parsed.fragment
):
    sys.exit("provision 실패: webhook 파일이 Slack Incoming Webhook 형식이 아니다.")
PY

{
  tr -d '\n' <"${vault_token_file}"
  printf '\npath "kv/data/%s" {\n  capabilities = ["read"]\n}\n' "wazuh/security-notifier"
} | vault_exec "vault policy write ${vault_policy} - >/dev/null"

with_token \
  "vault write auth/kubernetes/role/${vault_role} \
     bound_service_account_names=wazuh-06-notifier \
     bound_service_account_namespaces=wazuh \
     audience=vault token_policies=${vault_policy} token_no_default_policy=true \
     token_ttl=10m token_max_ttl=30m >/dev/null"

payload=$(python3 -c 'import json,sys; sys.stdout.write(json.dumps({"slack_webhook_url": open(sys.argv[1]).read().strip()}))' "${webhook_file}")

{
  tr -d '\n' <"${vault_token_file}"
  printf '\n%s\n' "${payload}"
} | vault_exec \
  "umask 077; cat >/tmp/wazuh-06-notifier.json; \
   vault kv put ${vault_kv} @/tmp/wazuh-06-notifier.json >/dev/null; \
   rm -f /tmp/wazuh-06-notifier.json"
unset payload

vault_check >/dev/null || {
  echo 'provision 실패: Vault policy·role·KV 최종 확인에 실패했다.' >&2
  exit 1
}
echo "Provision=PASS policy=${vault_policy} role=${vault_role} kv=${vault_kv}"
