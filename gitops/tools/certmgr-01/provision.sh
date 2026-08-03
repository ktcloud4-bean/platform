#!/usr/bin/env bash
# CERTMGR-01 Vault PKI role·policy·Kubernetes auth role provisioning.
# root token은 stdin으로만 Vault Pod에 전달하며 출력하거나 명령 인자에 넣지 않는다.
set -euo pipefail

readonly mode=${1:-check}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
readonly repo_root
readonly policy_file=${repo_root}/infra/vault/scripts/policies/cert-manager-vault-issuer.hcl
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
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
[[ -f ${vault_token_file} && ! -L ${vault_token_file} &&
   $(stat -c %a "${vault_token_file}") == 600 ]] || {
  echo 'provision 실패: Vault root token file이 없거나 mode 0600이 아니다.' >&2
  exit 1
}
[[ -f ${policy_file} && ! -L ${policy_file} ]] || {
  echo 'provision 실패: cert-manager Vault policy 선언이 없다.' >&2
  exit 1
}

exec 9>/tmp/certmgr-01-vault-config.lock
flock -n 9 || {
  echo 'provision 실패: 다른 CERTMGR-01 Vault 구성이 실행 중이다.' >&2
  exit 1
}

vault_root_script() {
  # 첫 줄은 root token, 그 뒤는 호출자의 script다. token은 원격 shell 변수에만 둔다.
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'" \
    < <({ tr -d '\n' <"${vault_token_file}"; printf '\n'; cat; })
}

check_runtime() {
  vault_root_script <<'REMOTE'
set -eu
vault policy read cert-manager-vault-issuer >/dev/null
vault read auth/kubernetes/role/cert-manager-vault-issuer >/dev/null
vault read pki/roles/cert-manager-internal-workload >/dev/null
REMOTE
}

if [[ ${mode} == check ]]; then
  if check_runtime; then
    echo 'VaultRuntime=PASS policy=cert-manager-vault-issuer auth_role=cert-manager-vault-issuer pki_role=cert-manager-internal-workload'
  else
    echo 'VaultRuntime=ABSENT'
  fi
  exit 0
fi

if [[ ${mode} == rollback ]]; then
  vault_root_script <<'REMOTE'
set -eu
vault delete auth/kubernetes/role/cert-manager-vault-issuer >/dev/null 2>&1 || true
vault policy delete cert-manager-vault-issuer >/dev/null 2>&1 || true
vault delete pki/roles/cert-manager-internal-workload >/dev/null 2>&1 || true
REMOTE
  if check_runtime >/dev/null 2>&1; then
    echo 'Rollback 실패: CERTMGR-01 Vault 구성이 남아 있다.' >&2
    exit 1
  fi
  echo 'VaultRollback=PASS removed=auth-role,policy,pki-role'
  exit 0
fi

# shellcheck disable=SC2029
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c \
  'read -r VAULT_TOKEN; export VAULT_TOKEN; vault policy write cert-manager-vault-issuer - >/dev/null'" \
  < <({ tr -d '\n' <"${vault_token_file}"; printf '\n'; cat "${policy_file}"; })

vault_root_script <<'REMOTE'
set -eu
vault write pki/roles/cert-manager-internal-workload \
  allowed_domains="svc.cluster.local,cluster.local" \
  allow_subdomains=true allow_bare_domains=false allow_glob_domains=false \
  allow_any_name=false enforce_hostnames=true allow_ip_sans=false \
  key_type=ec key_bits=256 ttl=72h max_ttl=720h >/dev/null
vault write auth/kubernetes/role/cert-manager-vault-issuer \
  bound_service_account_names="cert-manager-vault-issuer" \
  bound_service_account_namespaces="cert-manager" \
  audience="vault://vault-internal" \
  token_policies="cert-manager-vault-issuer" \
  token_no_default_policy=true \
  token_ttl=1m token_max_ttl=5m >/dev/null
REMOTE

check_runtime || {
  echo 'provision 실패: Vault policy·auth role·PKI role 최종 확인에 실패했다.' >&2
  exit 1
}
echo 'VaultProvision=PASS policy=cert-manager-vault-issuer auth_role=cert-manager-vault-issuer pki_role=cert-manager-internal-workload'
