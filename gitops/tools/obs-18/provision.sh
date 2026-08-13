#!/usr/bin/env bash
# OBS-18 Alertmanager Slack Vault provisioning.
#
# 입력 webhook은 저장소 밖 mode 0600 파일 하나로만 받고, 전용 KV·policy·Kubernetes
# auth role에만 쓴다. 어떤 경로도 webhook 원문을 출력하지 않는다.
set -euo pipefail

readonly mode=${1:-check}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/obs
readonly webhook_file=${secret_dir}/alertmanager-slack-webhook-url
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly vault_policy=obs-alertmanager-slack
readonly vault_role=obs-alertmanager-slack
readonly vault_kv=kv/obs/alertmanager
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

exec 9>/tmp/obs-18-provision.lock
flock -n 9 || {
  echo 'provision 실패: 다른 OBS-18 provisioning이 실행 중이다.' >&2
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
  if [[ -f ${webhook_file} && ! -L ${webhook_file} && $(stat -c %a "${webhook_file}") == 600 ]]; then
    echo 'SecretInput=PRESENT'
  else
    echo 'SecretInput=ABSENT'
  fi
  if vault_check >/dev/null 2>&1; then
    echo "VaultRuntime=PASS policy=${vault_policy} role=${vault_role} kv=${vault_kv}"
  else
    echo 'VaultRuntime=ABSENT'
  fi
  exit 0
fi

if [[ ${mode} == rollback ]]; then
  # 전용 policy·role·KV만 제거한다. 기존 Grafana KV와 security Slack 경로는 건드리지
  # 않고, 저장소 밖 입력 파일도 다음 reapply를 위해 보존한다.
  with_token \
    "vault kv metadata delete ${vault_kv} >/dev/null 2>&1 || true
     vault delete auth/kubernetes/role/${vault_role} >/dev/null 2>&1 || true
     vault policy delete ${vault_policy} >/dev/null 2>&1 || true"
  if vault_check >/dev/null 2>&1; then
    echo 'provision 실패: rollback 뒤에도 OBS-18 policy/role/KV가 남아 있다.' >&2
    exit 1
  fi
  echo "Rollback=PASS policy=${vault_policy} role=${vault_role} kv=${vault_kv} removed"
  exit 0
fi

[[ -f ${webhook_file} && ! -L ${webhook_file} && $(stat -c %a "${webhook_file}") == 600 ]] || {
  echo "provision 실패: ${webhook_file}이 없거나 mode 0600이 아니다." >&2
  exit 1
}

# 값은 출력하지 않고 https://hooks.slack.com/services/의 Incoming Webhook 형식만
# 판정한다. proxy의 CONNECT allowlist와 같은 hostname을 사용한다.
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
  printf '\npath "kv/data/obs/alertmanager" {\n  capabilities = ["read"]\n}\n'
} | vault_exec "vault policy write ${vault_policy} - >/dev/null"

with_token \
  "vault write auth/kubernetes/role/${vault_role} \
     bound_service_account_names=obs-alertmanager \
     bound_service_account_namespaces=obs \
     audience=vault token_policies=${vault_policy} token_no_default_policy=true \
     token_ttl=10m token_max_ttl=30m >/dev/null"

payload=$(python3 -c 'import json,sys; sys.stdout.write(json.dumps({"slack_webhook_url": open(sys.argv[1]).read().strip()}))' "${webhook_file}")
{
  tr -d '\n' <"${vault_token_file}"
  printf '\n%s\n' "${payload}"
} | vault_exec \
  "umask 077; cat >/tmp/obs-18-alertmanager.json; \
   vault kv put ${vault_kv} @/tmp/obs-18-alertmanager.json >/dev/null; \
   rm -f /tmp/obs-18-alertmanager.json"
unset payload

vault_check >/dev/null || {
  echo 'provision 실패: Vault policy·role·KV 최종 확인에 실패했다.' >&2
  exit 1
}
echo "Provision=PASS policy=${vault_policy} role=${vault_role} kv=${vault_kv}"
