#!/usr/bin/env bash
# BOARD-DEMO-01 전용 PostgreSQL/Vault runtime 선언. 비밀 원문은 출력하지 않는다.
# shellcheck disable=SC2029
set -Eeuo pipefail

mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply ]] || { echo '사용법: provision-runtime.sh --check|--apply' >&2; exit 2; }
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly vault_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly known_hosts=${POSTGRES_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly postgres_host=${POSTGRES_HOST:-rocky@postgres-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly policy_file=${repo_root}/infra/vault/scripts/policies/board-demo-runtime.hcl
readonly bootstrap_policy_file=${repo_root}/infra/vault/scripts/policies/board-demo-bootstrap.hcl
readonly playbook=${repo_root}/infra/ansible/playbooks/board-demo-postgres.yml

for input in "${vault_token_file}" "${known_hosts}" "${policy_file}" "${bootstrap_policy_file}" "${playbook}"; do
  [[ -f ${input} && ! -L ${input} ]] || { echo "BOARD-DEMO-01 runtime 입력 없음: ${input}" >&2; exit 1; }
done
[[ $(stat -c %a "${vault_token_file}") == 600 ]] || { echo 'Vault token은 mode 0600이어야 한다.' >&2; exit 1; }
readonly ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" -o PasswordAuthentication=no)
readonly postgres_ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" -o HostKeyAlias=10.10.50.10 -o PasswordAuthentication=no)

vault_exec() {
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; cat; } | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'set -eu; read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh -eu'"
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() { rc=$?; find "${temp_dir}" -type f -delete 2>/dev/null || true; rmdir "${temp_dir}" 2>/dev/null || true; unset db_password; return "${rc}"; }
trap cleanup EXIT INT TERM

vault_exec <<'REMOTE' >"${temp_dir}/runtime.json"
if vault kv get -format=json kv/board-demo/runtime 2>/dev/null; then :; else printf '%s\n' '{"data":null}'; fi
REMOTE

runtime_state=absent
if jq -e '.data == null' "${temp_dir}/runtime.json" >/dev/null; then
  echo 'BOARD-DEMO-01 runtime 상태: vault-kv=absent'
  [[ ${mode} == --apply ]] || { echo 'BOARD-DEMO-01 runtime: --check 변경=0'; exit 0; }
  db_password=$(openssl rand -base64 36 | tr -d '\n')
  [[ ${#db_password} -ge 24 ]]
  jq -n --arg password "${db_password}" '{db_type:"postgres",db_primary_host:"postgres-01.imcherry5778.xyz",db_primary_port:"5432",db_user:"board_demo_user",db_password:$password,db_name:"board_demo",db_replica_hosts:""}' >"${temp_dir}/runtime-desired.json"
  runtime_state=create
else
  jq -e '.data.data.db_type == "postgres" and .data.data.db_primary_host == "postgres-01.imcherry5778.xyz" and .data.data.db_primary_port == "5432" and .data.data.db_user == "board_demo_user" and .data.data.db_name == "board_demo" and .data.data.db_replica_hosts == "" and (.data.data.db_password | type == "string" and length >= 24)' "${temp_dir}/runtime.json" >/dev/null || { echo 'BOARD-DEMO-01 runtime: 기존 Vault KV가 선언과 다르다.' >&2; exit 1; }
  jq '.data.data' "${temp_dir}/runtime.json" >"${temp_dir}/runtime-desired.json"
  db_password=$(jq -er '.db_password' "${temp_dir}/runtime-desired.json")
  runtime_state=present
  echo 'BOARD-DEMO-01 runtime 상태: vault-kv=present'
fi

# Pod는 자기 KV 하나만 읽는다. Harbor robot은 BOARD-DEMO-01 Jenkins 전용 project
# credential에서, Cosign trust는 SIGN-01 active/previous 공개키에서 파생한다.
vault_exec <<'REMOTE' >"${temp_dir}/board-jenkins.json"
vault kv get -format=json kv/board-demo/jenkins
REMOTE
vault_exec <<'REMOTE' >"${temp_dir}/jenkins-runtime.json"
vault kv get -format=json kv/jenkins/runtime
REMOTE
jq -e '
  (.data.data.harbor_robot_name | type == "string" and length > 0) and
  (.data.data.harbor_robot_secret | type == "string" and length > 0)
' "${temp_dir}/board-jenkins.json" >/dev/null || {
  echo 'BOARD-DEMO-01 runtime: Jenkins Harbor robot 입력이 없다.' >&2
  exit 1
}
jq -e '
  (.data.data.cosign_public_key | type == "string" and length > 0) and
  (.data.data.cosign_previous_public_key | type == "string" and length > 0)
' "${temp_dir}/jenkins-runtime.json" >/dev/null || {
  echo 'BOARD-DEMO-01 runtime: SIGN-01 Cosign 공개키 입력이 없다.' >&2
  exit 1
}
jq -n --slurpfile board_jenkins "${temp_dir}/board-jenkins.json" \
  --slurpfile jenkins_runtime "${temp_dir}/jenkins-runtime.json" '{
    harbor_robot_name: $board_jenkins[0].data.data.harbor_robot_name,
    harbor_robot_secret: $board_jenkins[0].data.data.harbor_robot_secret,
    cosign_public_key: $jenkins_runtime[0].data.data.cosign_public_key,
    cosign_previous_public_key: $jenkins_runtime[0].data.data.cosign_previous_public_key
  }
' >"${temp_dir}/bootstrap-desired.json"

vault_exec <<'REMOTE' >"${temp_dir}/bootstrap.json"
if vault kv get -format=json kv/board-demo/bootstrap 2>/dev/null; then :; else printf '%s\n' '{"data":null}'; fi
REMOTE
bootstrap_state=present
if jq -e '.data == null' "${temp_dir}/bootstrap.json" >/dev/null; then
  bootstrap_state=absent
fi

runtime_needs_write=false
if [[ ${runtime_state} == create ]] || ! jq -e --slurpfile desired "${temp_dir}/runtime-desired.json" '.data.data == $desired[0]' "${temp_dir}/runtime.json" >/dev/null; then
  runtime_needs_write=true
fi
bootstrap_needs_write=false
if [[ ${bootstrap_state} == absent ]] || ! jq -e --slurpfile desired "${temp_dir}/bootstrap-desired.json" '.data.data == $desired[0]' "${temp_dir}/bootstrap.json" >/dev/null; then
  bootstrap_needs_write=true
fi

jq -n --arg password "${db_password}" '{pg_board_demo_password:$password,pg_board_demo_database:"board_demo",pg_board_demo_role:"board_demo_user"}' >"${temp_dir}/postgres-vars.json"
unset db_password
printf '[postgres_nodes]\npostgres-01 ansible_host=postgres-01.imcherry5778.xyz ansible_user=rocky\n' >"${temp_dir}/inventory"
run_ansible() {
  ANSIBLE_CONFIG="${repo_root}/infra/ansible/ansible.cfg" ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${known_hosts} -o HostKeyAlias=10.10.50.10 -o PasswordAuthentication=no" ansible-playbook -i "${temp_dir}/inventory" "${playbook}" -e "@${temp_dir}/postgres-vars.json" "$@"
}
pushd "${repo_root}/infra/ansible" >/dev/null
run_ansible --syntax-check >/dev/null
if [[ ${mode} == --check ]]; then
  run_ansible --check --diff
  popd >/dev/null
  echo "BOARD-DEMO-01 runtime 계획 통과: vault-runtime=${runtime_state} vault-bootstrap=${bootstrap_state} live 변경=0"
  exit 0
fi
run_ansible
popd >/dev/null

if [[ ${runtime_needs_write} == true ]]; then
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; cat "${temp_dir}/runtime-desired.json"; } | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'set -eu; read -r VAULT_TOKEN; export VAULT_TOKEN; umask 077; cat >/tmp/board-demo-runtime.json; vault kv put kv/board-demo/runtime @/tmp/board-demo-runtime.json >/dev/null; rm -f /tmp/board-demo-runtime.json'"
fi
if [[ ${bootstrap_needs_write} == true ]]; then
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; cat "${temp_dir}/bootstrap-desired.json"; } | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'set -eu; read -r VAULT_TOKEN; export VAULT_TOKEN; umask 077; cat >/tmp/board-demo-bootstrap.json; vault kv put kv/board-demo/bootstrap @/tmp/board-demo-bootstrap.json >/dev/null; rm -f /tmp/board-demo-bootstrap.json'"
fi
{
  printf "cat >/tmp/board-demo-runtime.hcl <<'HCL'\n"
  cat "${policy_file}"
  printf 'HCL\n'
  printf '%s\n' 'vault policy write board-demo-runtime /tmp/board-demo-runtime.hcl >/dev/null'
  printf '%s\n' 'rm -f /tmp/board-demo-runtime.hcl'
  printf "cat >/tmp/board-demo-bootstrap.hcl <<'HCL'\n"
  cat "${bootstrap_policy_file}"
  printf 'HCL\n'
  printf '%s\n' 'vault policy write board-demo-bootstrap /tmp/board-demo-bootstrap.hcl >/dev/null'
  printf '%s\n' 'rm -f /tmp/board-demo-bootstrap.hcl'
  printf '%s\n' 'vault write auth/kubernetes/role/board-demo bound_service_account_names=board-demo bound_service_account_namespaces=board-demo audience=vault token_policies=board-demo-runtime token_no_default_policy=true token_ttl=15m token_max_ttl=1h >/dev/null'
  printf '%s\n' 'vault write auth/kubernetes/role/board-demo-bootstrap bound_service_account_names=board-demo-vault-bootstrap bound_service_account_namespaces=board-demo audience=vault token_policies=board-demo-bootstrap token_no_default_policy=true token_ttl=15m token_max_ttl=1h >/dev/null'
} | vault_exec

db_state=$(ssh "${postgres_ssh_options[@]}" "${postgres_host}" "sudo -u postgres psql -XAt -d postgres -c \"SELECT rolname||'|'||rolsuper||'|'||rolcreatedb||'|'||rolcreaterole||'|'||rolreplication||'|'||rolbypassrls||'|'||rolcanlogin FROM pg_roles WHERE rolname='board_demo_user'; SELECT datname||'|'||pg_get_userbyid(datdba) FROM pg_database WHERE datname='board_demo';\"")
[[ ${db_state} == $'board_demo_user|false|false|false|false|false|true\nboard_demo|board_demo_user' ]] || { echo 'BOARD-DEMO-01 runtime: PostgreSQL role/database 최종 상태가 다르다.' >&2; exit 1; }
echo "BOARD-DEMO-01 runtime 적용 통과: postgres-role/database=present vault-runtime=${runtime_state} vault-bootstrap=${bootstrap_state} vault-policy/roles=present"
