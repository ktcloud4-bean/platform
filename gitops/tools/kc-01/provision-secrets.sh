#!/usr/bin/env bash
# KC-01의 외부 비밀 파일을 만들고 정확히 두 Vault KV 경로와 keycloak_user만 갱신한다.
# seal/unseal, init, Raft, 다른 DB/role은 다루지 않는다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법:
  KC01_SECRET_DIR=<저장소 밖 디렉터리> \
  VAULT_ROOT_TOKEN_FILE=<mode 0600 root token 파일> \
  ./gitops/tools/kc-01/provision-secrets.sh --apply

이미 적용한 자격증명을 의도적으로 회전할 때만 --rotate를 사용한다.
EOF
}

mode=${1:-}
if [[ "${mode}" != --apply && "${mode}" != --rotate ]]; then
  usage >&2
  exit 2
fi

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
: "${VAULT_ROOT_TOKEN_FILE:?저장소 밖 Vault root token 파일이 필요하다}"
readonly k3s_host=${K3S_HOST:-rocky@10.10.20.10}
readonly postgres_host=${POSTGRES_HOST:-rocky@10.10.50.10}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly marker_file=${KC01_SECRET_DIR}/.provisioned

case "${KC01_SECRET_DIR}" in
  /|/home|/home/*/projects|/home/*/projects/*)
    echo "KC01_SECRET_DIR가 너무 넓거나 저장소 경로다: ${KC01_SECRET_DIR}" >&2
    exit 1
    ;;
esac
[[ "${KC01_SECRET_DIR}" = /* ]] || {
  echo "KC01_SECRET_DIR는 절대 경로여야 한다." >&2
  exit 1
}
[[ -r "${VAULT_ROOT_TOKEN_FILE}" ]] || {
  echo "Vault root token 파일을 읽을 수 없다." >&2
  exit 1
}
if [[ -e "${marker_file}" && "${mode}" != --rotate ]]; then
  echo "이미 적용된 디렉터리다. 회전 의도라면 --rotate를 사용한다." >&2
  exit 1
fi

umask 077
mkdir -p "${KC01_SECRET_DIR}"
chmod 0700 "${KC01_SECRET_DIR}"

generate_password() {
  local candidate
  while true; do
    candidate=$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-40)
    if [[ ${#candidate} -eq 40 && "${candidate}" =~ [A-Z] && "${candidate}" =~ [a-z] && "${candidate}" =~ [0-9] ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
}

generate_totp() {
  openssl rand 20 | base32 | tr -d '=\n'
  printf '\n'
}

ensure_secret() {
  local name=$1
  local kind=$2
  local target=${KC01_SECRET_DIR}/${name}
  if [[ "${mode}" == --rotate || ! -e "${target}" ]]; then
    if [[ "${kind}" == totp ]]; then
      generate_totp >"${target}"
    else
      generate_password >"${target}"
    fi
  fi
  chmod 0600 "${target}"
  [[ -s "${target}" ]] || {
    echo "비밀 파일이 비어 있다: ${target}" >&2
    exit 1
  }
}

for password_file in \
  db-password bootstrap-client-secret verify-client-secret \
  daily-password privileged-password local-admin-password; do
  ensure_secret "${password_file}" password
done
for totp_file in daily-totp privileged-totp local-admin-totp; do
  ensure_secret "${totp_file}" totp
done

runtime_payload=$(mktemp)
readonly runtime_payload
bootstrap_payload=$(mktemp)
readonly bootstrap_payload
cleanup() {
  rm -f "${runtime_payload}" "${bootstrap_payload}"
}
trap cleanup EXIT

jq -n \
  --rawfile db_password "${KC01_SECRET_DIR}/db-password" \
  '{db_password: ($db_password | rtrimstr("\n"))}' >"${runtime_payload}"
jq -n \
  --rawfile bootstrap_client_secret "${KC01_SECRET_DIR}/bootstrap-client-secret" \
  --rawfile verify_client_secret "${KC01_SECRET_DIR}/verify-client-secret" \
  --rawfile daily_password "${KC01_SECRET_DIR}/daily-password" \
  --rawfile daily_totp "${KC01_SECRET_DIR}/daily-totp" \
  --rawfile privileged_password "${KC01_SECRET_DIR}/privileged-password" \
  --rawfile privileged_totp "${KC01_SECRET_DIR}/privileged-totp" \
  --rawfile local_admin_password "${KC01_SECRET_DIR}/local-admin-password" \
  --rawfile local_admin_totp "${KC01_SECRET_DIR}/local-admin-totp" \
  '{
    bootstrap_client_secret: ($bootstrap_client_secret | rtrimstr("\n")),
    verify_client_secret: ($verify_client_secret | rtrimstr("\n")),
    daily_password: ($daily_password | rtrimstr("\n")),
    daily_totp: ($daily_totp | rtrimstr("\n")),
    privileged_password: ($privileged_password | rtrimstr("\n")),
    privileged_totp: ($privileged_totp | rtrimstr("\n")),
    local_admin_password: ($local_admin_password | rtrimstr("\n")),
    local_admin_totp: ($local_admin_totp | rtrimstr("\n"))
  }' >"${bootstrap_payload}"

vault_kv_write() {
  local path=$1
  local payload=$2
  {
    tr -d '\n' <"${VAULT_ROOT_TOKEN_FILE}"
    printf '\n'
    cat "${payload}"
  } | ssh -o BatchMode=yes "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
      set -eu
      umask 077
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      trap \"rm -f /tmp/kc01-kv.json\" EXIT
      cat > /tmp/kc01-kv.json
      vault kv put kv/${path} @/tmp/kc01-kv.json >/dev/null
    '"
}

echo "KC-01: Vault kv/keycloak/runtime과 kv/keycloak/bootstrap을 갱신합니다."
vault_kv_write keycloak/runtime "${runtime_payload}"
vault_kv_write keycloak/bootstrap "${bootstrap_payload}"

echo "KC-01: PostgreSQL log_statement와 keycloak_user 경계를 확인합니다."
postgres_facts=$(
  ssh -o BatchMode=yes "${postgres_host}" \
    "sudo -n -u postgres psql -XAt --set=ON_ERROR_STOP=1 postgres" <<'SQL'
SHOW log_statement;
SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolcanlogin
FROM pg_roles WHERE rolname = $$keycloak_user$$;
SQL
)
awk -F'|' '
  NR == 1 && $0 != "none" { exit 10 }
  NR == 2 && $0 != "keycloak_user|f|f|f|f|t" { exit 11 }
  END { if (NR != 2) exit 12 }
' <<<"${postgres_facts}"
unset postgres_facts

echo "KC-01: keycloak_user 비밀번호만 회전합니다."
remote_password_file=$(ssh -o BatchMode=yes "${postgres_host}" 'umask 077; mktemp')
cleanup_remote_password() {
  ssh -o BatchMode=yes "${postgres_host}" "rm -f '${remote_password_file}'" >/dev/null 2>&1 || true
}
trap 'cleanup_remote_password; cleanup' EXIT
tr -d '\n' <"${KC01_SECRET_DIR}/db-password" | \
  ssh -o BatchMode=yes "${postgres_host}" "cat > '${remote_password_file}'"
ssh -o BatchMode=yes "${postgres_host}" \
  "bash -s -- '${remote_password_file}'" <<'REMOTE'
set -Eeuo pipefail
umask 077
password_file=$1
keycloak_password=$(cat "${password_file}")
[[ "${keycloak_password}" =~ ^[A-Za-z0-9]{40}$ ]]
sql_file=$(mktemp)
pass_file=$(mktemp)
cleanup() {
  rm -f "${password_file}" "${sql_file}" "${pass_file}"
}
trap cleanup EXIT
printf "ALTER ROLE keycloak_user PASSWORD '%s';\n" "${keycloak_password}" >"${sql_file}"
sudo -n -u postgres psql -Xq --set=ON_ERROR_STOP=1 postgres <"${sql_file}"
printf 'postgres-01.imcherry5778.xyz:5432:*:keycloak_user:%s\n' \
  "${keycloak_password}" >"${pass_file}"
chmod 0600 "${pass_file}"
unset keycloak_password

PGPASSFILE="${pass_file}" \
PGSSLMODE=verify-full \
PGSSLROOTCERT=/etc/pki/tls/certs/postgres-01-bootstrap.crt \
psql -XAt --set=ON_ERROR_STOP=1 \
  -h postgres-01.imcherry5778.xyz -U keycloak_user -d keycloak \
  -c "SELECT current_database(), current_user, ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid();" \
  | grep -Eq '^keycloak\|keycloak_user\|t\|TLSv1\.[23]$'

if PGPASSFILE="${pass_file}" PGSSLMODE=disable \
  psql -XAt -h postgres-01.imcherry5778.xyz -U keycloak_user -d keycloak \
  -c 'SELECT 1' >/dev/null 2>&1; then
  echo "비 TLS 접속이 예상과 달리 허용됐다." >&2
  exit 1
fi
if PGPASSFILE="${pass_file}" PGSSLMODE=verify-full \
  PGSSLROOTCERT=/etc/pki/tls/certs/postgres-01-bootstrap.crt \
  psql -XAt -h postgres-01.imcherry5778.xyz -U keycloak_user -d verify_db \
  -c 'SELECT 1' >/dev/null 2>&1; then
  echo "keycloak_user가 verify_db에 접속했다." >&2
  exit 1
fi
REMOTE

date -u +'%Y-%m-%dT%H:%M:%SZ' >"${marker_file}"
chmod 0600 "${marker_file}"
echo "KC-01: Vault 쓰기와 keycloak_user verify-full 양성/음성 검증이 끝났습니다."
