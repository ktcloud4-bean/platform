#!/usr/bin/env bash
# AWX-05 전용: canary account, Vault external lookup과 authenticated host key를 만든다.
# 비밀은 stdin/umask 077 임시 파일로만 취급하며 명령행·출력·Git에 넣지 않는다.
set -Eeuo pipefail

mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply || ${mode} == --refresh-lookup || ${mode} == --rollback ]] || {
  echo "사용법: $0 --check|--apply|--refresh-lookup|--rollback" >&2
  exit 2
}

readonly repo_root=$(git rev-parse --show-toplevel)
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly target_fqdn=k3s-01.imcherry5778.xyz
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly account=awx-canary
readonly account_home=/var/lib/awx-canary
readonly canary_policy=awx-ssh-canary-lookup
readonly canary_role=awx-05-ssh-canary-lookup
readonly base_revision=${AWX05_ROLLBACK_REVISION:-$(git rev-parse origin/main)}
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")
temp_dir=''
applied=false

require_inputs() {
  [[ -r ${root_token_file} && ! -L ${root_token_file} && $(stat -c %a "${root_token_file}") == 600 ]] || {
    echo "Vault root token 파일을 읽을 수 없거나 mode 0600이 아니다" >&2
    exit 1
  }
  [[ -r ${known_hosts} && ! -L ${known_hosts} ]] || {
    echo "인증된 k3s SSH known_hosts 파일을 읽을 수 없다" >&2
    exit 1
  }
}

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

vault_exec() {
  { tr -d '\n' <"${root_token_file}"; printf '\n'; cat; } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh -eu'"
}

vault_state() {
  vault_exec <<'EOF'
for item in \
  "policy:awx-ssh-canary-lookup" \
  "role:awx-05-ssh-canary-lookup" \
  "kv:awx/ssh-canary" \
  "kv:awx/ssh-canary-hostkeys" \
  "kv:awx/ssh-canary-lookup"; do
  kind=${item%%:*}
  name=${item#*:}
  case ${kind} in
    policy) vault policy read "${name}" >/dev/null 2>&1 && printf '%s=PRESENT\n' "${item}" || printf '%s=ABSENT\n' "${item}" ;;
    role) vault read "auth/approle/role/${name}" >/dev/null 2>&1 && printf '%s=PRESENT\n' "${item}" || printf '%s=ABSENT\n' "${item}" ;;
    kv) vault kv get "kv/${name}" >/dev/null 2>&1 && printf '%s=PRESENT\n' "${item}" || printf '%s=ABSENT\n' "${item}" ;;
  esac
done
EOF
}

target_state() {
  ssh "${ssh_options[@]}" "${k3s_host}" '
    set -eu
    if getent passwd awx-canary >/dev/null; then
      entry=$(getent passwd awx-canary)
      printf "account=PRESENT uid=%s home=%s shell=%s\\n" "$(cut -d: -f3 <<<"${entry}")" "$(cut -d: -f6 <<<"${entry}")" "$(cut -d: -f7 <<<"${entry}")"
    else
      printf "account=ABSENT\\n"
    fi
    printf "swap_devices="; awk "NR>1 {count++} END {print count+0}" /proc/swaps
    awk "/MemAvailable:/ {printf \"guest_available_bytes=%d\\n\", \$2*1024}" /proc/meminfo
    systemctl is-active sshd | sed "s/^/sshd=/"
  '
}

check() {
  require_inputs
  local target vault
  target=$(target_state)
  vault=$(vault_state)
  printf '%s\n%s\n' "${target}" "${vault}"
  awk -F= '/^guest_available_bytes=/{if ($2 < 8589934592) exit 1}' <<<"${target}" || {
    echo "AWX-05 중지: guest available이 8 GiB 미만이다" >&2
    exit 1
  }
  grep -qx 'swap_devices=0' <<<"${target}" || { echo "AWX-05 중지: swap이 0이 아니다" >&2; exit 1; }
  grep -qx 'sshd=active' <<<"${target}" || { echo "AWX-05 중지: sshd가 active가 아니다" >&2; exit 1; }
}

write_policy() {
  local name=$1 file=$2
  {
    printf "cat > /tmp/awx05-policy.hcl <<'HCL'\n"
    cat "${file}"
    printf "HCL\nvault policy write %q /tmp/awx05-policy.hcl >/dev/null\nrm -f /tmp/awx05-policy.hcl\n" "${name}"
  } | vault_exec
}

put_vault_file() {
  local path=$1 field=$2 source=$3
  { tr -d '\n' <"${root_token_file}"; printf '\n'; cat "${source}"; } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'set -eu; umask 077; read -r VAULT_TOKEN; export VAULT_TOKEN; cat > /tmp/awx05-value; vault kv put ${path} ${field}=@/tmp/awx05-value >/dev/null; rm -f /tmp/awx05-value'"
}

restore_policies() {
  local revision=$1
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || { echo "AWX05_ROLLBACK_REVISION은 40자리 commit SHA여야 한다" >&2; return 1; }
  local file
  for file in awx.hcl awx-provisioner.hcl; do
    {
      printf "cat > /tmp/awx05-policy.hcl <<'HCL'\n"
      git show "${revision}:infra/vault/scripts/policies/${file}"
      printf "HCL\nvault policy write %q /tmp/awx05-policy.hcl >/dev/null\nrm -f /tmp/awx05-policy.hcl\n" "${file%.hcl}"
    } | vault_exec
  done
}

rollback() {
  require_inputs
  ssh "${ssh_options[@]}" "${k3s_host}" "sudo -n /usr/sbin/userdel --remove ${account} 2>/dev/null || test \$? -eq 6"
  remote_kubectl -n awx exec -i deploy/awx-web -c awx-web -- awx-manage shell <<'PY'
from awx.main.models import Credential, CredentialInputSource, Inventory, JobTemplate, Organization

org = Organization.objects.filter(name="Platform").first()
if org:
    JobTemplate.objects.filter(name="AWX-05 k3s-01 SSH canary", organization=org).delete()
    for credential in Credential.objects.filter(
        name__in=["AWX-05 Vault Machine lookup", "AWX-05 k3s-01 SSH canary"], organization=org
    ):
        CredentialInputSource.objects.filter(target_credential=credential).delete()
        credential.delete()
    Inventory.objects.filter(name="AWX-05 k3s-01 SSH canary", organization=org).delete()
PY
  vault_exec <<EOF
vault kv metadata delete kv/awx/ssh-canary >/dev/null 2>&1 || true
vault kv metadata delete kv/awx/ssh-canary-hostkeys >/dev/null 2>&1 || true
vault kv metadata delete kv/awx/ssh-canary-lookup >/dev/null 2>&1 || true
vault delete auth/approle/role/${canary_role} >/dev/null 2>&1 || true
vault policy delete ${canary_policy} >/dev/null 2>&1 || true
EOF
  restore_policies "${base_revision}"
  printf 'AWX05_ROLLBACK=PASS account=%s vault_paths=3 role=%s policy=%s baseline=%s\n' \
    "${account}" "${canary_role}" "${canary_policy}" "${base_revision}"
}

refresh_lookup() {
  require_inputs
  vault_exec <<EOF
vault read auth/approle/role/${canary_role} >/dev/null
vault kv get kv/awx/ssh-canary >/dev/null
vault read -field=role_id auth/approle/role/${canary_role}/role-id >/tmp/awx05-role-id
vault write -field=secret_id -f auth/approle/role/${canary_role}/secret-id >/tmp/awx05-secret-id
vault kv put kv/awx/ssh-canary-lookup vault_role_id=@/tmp/awx05-role-id vault_secret_id=@/tmp/awx05-secret-id >/dev/null
rm -f /tmp/awx05-role-id /tmp/awx05-secret-id
EOF
  vault_exec <<'EOF'
role_id=$(vault kv get -field=vault_role_id kv/awx/ssh-canary-lookup)
secret_id=$(vault kv get -field=vault_secret_id kv/awx/ssh-canary-lookup)
token=$(env -u VAULT_TOKEN vault write -field=token auth/approle/login role_id="$role_id" secret_id="$secret_id")
VAULT_TOKEN="$token" vault kv get -field=ssh_private_key kv/awx/ssh-canary >/dev/null
EOF
  printf 'AWX05_LOOKUP_REFRESH=PASS role=%s path=kv/awx/ssh-canary-lookup\n' "${canary_role}"
}

apply() {
  check
  local initial_target initial_vault
  initial_target=$(target_state)
  initial_vault=$(vault_state)
  grep -qx 'account=ABSENT' <<<"${initial_target}" || { echo "기존 awx-canary account가 있어 자동 교체하지 않는다" >&2; exit 1; }
  ! grep -q '=PRESENT$' <<<"${initial_vault}" || { echo "기존 AWX-05 Vault 객체가 있어 자동 교체하지 않는다" >&2; exit 1; }

  umask 077
  temp_dir=$(mktemp -d)
  applied=false
  cleanup() {
    local status=$?
    [[ -z ${temp_dir} ]] || rm -rf "${temp_dir}"
    if [[ ${status} -ne 0 && ${applied} == true ]]; then
      rollback || true
    fi
    exit "${status}"
  }
  trap cleanup EXIT INT TERM

  ssh-keygen -q -t ed25519 -N '' -C awx-05-k3s-01 -f "${temp_dir}/id_ed25519"
  ssh-keygen -F "${target_fqdn}" -f "${known_hosts}" | awk '!/^#/' >"${temp_dir}/known_hosts"
  [[ -s ${temp_dir}/known_hosts ]]
  ssh-keygen -lf "${temp_dir}/known_hosts" >/dev/null
  printf 'from="10.42.0.0/24,10.10.20.10",restrict,no-pty %s\n' "$(<"${temp_dir}/id_ed25519.pub")" >"${temp_dir}/authorized_key"
  jq -n --rawfile key "${temp_dir}/authorized_key" '{awx05_authorized_key: ($key | rtrimstr("\n"))}' >"${temp_dir}/account-vars.json"

  ANSIBLE_CONFIG="${repo_root}/infra/ansible/ansible.cfg" \
  ANSIBLE_SSH_COMMON_ARGS="-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${known_hosts} -o PasswordAuthentication=no" \
  ansible-playbook -i "${target_fqdn}," --user rocky \
    -e "@${temp_dir}/account-vars.json" \
    "${repo_root}/infra/ansible/playbooks/awx-05-ssh-canary-account.yml"
  applied=true
  ssh "${ssh_options[@]}" "${k3s_host}" 'sudo -n sh -c '\''
    set -eu
    entry=$(getent passwd awx-canary)
    test "$(cut -d: -f6 <<<"${entry}")" = /var/lib/awx-canary
    test "$(cut -d: -f7 <<<"${entry}")" = /bin/bash
    ! id -nG awx-canary | tr " " "\\n" | grep -qx wheel
    test "$(stat -c %a /var/lib/awx-canary/.ssh/authorized_keys)" = 600
  '\'''

  write_policy awx "${repo_root}/infra/vault/scripts/policies/awx.hcl"
  write_policy awx-provisioner "${repo_root}/infra/vault/scripts/policies/awx-provisioner.hcl"
  write_policy "${canary_policy}" "${repo_root}/infra/vault/scripts/policies/${canary_policy}.hcl"
  put_vault_file kv/awx/ssh-canary ssh_private_key "${temp_dir}/id_ed25519"
  put_vault_file kv/awx/ssh-canary-hostkeys known_hosts "${temp_dir}/known_hosts"
  vault_exec <<EOF
vault write auth/approle/role/${canary_role} \\
  token_policies="${canary_policy}" token_no_default_policy=true \\
  token_ttl=10m token_max_ttl=15m secret_id_ttl=1h secret_id_num_uses=0 >/dev/null
umask 077
vault read -field=role_id auth/approle/role/${canary_role}/role-id >/tmp/awx05-role-id
vault write -field=secret_id -f auth/approle/role/${canary_role}/secret-id >/tmp/awx05-secret-id
vault kv put kv/awx/ssh-canary-lookup vault_role_id=@/tmp/awx05-role-id vault_secret_id=@/tmp/awx05-secret-id >/dev/null
rm -f /tmp/awx05-role-id /tmp/awx05-secret-id
EOF
  vault_exec <<'EOF'
role_id=$(vault kv get -field=vault_role_id kv/awx/ssh-canary-lookup)
secret_id=$(vault kv get -field=vault_secret_id kv/awx/ssh-canary-lookup)
token=$(env -u VAULT_TOKEN vault write -field=token auth/approle/login role_id="$role_id" secret_id="$secret_id")
VAULT_TOKEN="$token" vault kv get -field=ssh_private_key kv/awx/ssh-canary >/dev/null
EOF
  printf 'AWX05_PREPARE=PASS account=%s source=10.42.0.0/24,10.10.20.10 vault_lookup=%s hostkey=authenticated\n' \
    "${account}" "${canary_role}"
}

case ${mode} in
  --check) check ;;
  --apply) apply ;;
  --refresh-lookup) refresh_lookup ;;
  --rollback) rollback ;;
esac
