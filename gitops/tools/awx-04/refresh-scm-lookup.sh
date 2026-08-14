#!/usr/bin/env bash
# AWX-04-FIX-01: stale AppRole bootstrap input만 Vault에서 교체한다.
set -Eeuo pipefail

mode=${1:-}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}

[[ ${mode} == --apply || ${mode} == --check ]] || { echo "사용법: $0 --apply|--check" >&2; exit 2; }
[[ -r ${root_token_file} && ! -L ${root_token_file} ]] || { echo "Vault root token 파일을 읽을 수 없다" >&2; exit 1; }

vault_exec() {
  { cat "${root_token_file}"; cat; } | ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'"
}

case ${mode} in
  --apply)
    vault_exec <<'EOF'
set -eu
cleanup() { rm -f /tmp/awx04-role-id /tmp/awx04-secret-id; }
trap cleanup EXIT
vault read -field=role_id auth/approle/role/awx-04-scm-lookup/role-id >/tmp/awx04-role-id
vault write -field=secret_id -f auth/approle/role/awx-04-scm-lookup/secret-id >/tmp/awx04-secret-id
vault kv put kv/awx/scm-lookup vault_role_id=@/tmp/awx04-role-id vault_secret_id=@/tmp/awx04-secret-id >/dev/null
EOF
    printf 'AWX04_FIX_LOOKUP_APPLY=PASS path=kv/awx/scm-lookup\n'
    ;;
  --check)
    vault_exec <<'EOF'
set -eu
role_id=$(vault kv get -field=vault_role_id kv/awx/scm-lookup)
secret_id=$(vault kv get -field=vault_secret_id kv/awx/scm-lookup)
token=$(vault write -field=token auth/approle/login role_id="$role_id" secret_id="$secret_id")
VAULT_TOKEN="$token" vault kv get -field=gitea_deploy_key kv/awx/scm >/dev/null
EOF
    printf 'AWX04_FIX_LOOKUP_CHECK=PASS lookup=approle key_read=authorized\n'
    ;;
esac
