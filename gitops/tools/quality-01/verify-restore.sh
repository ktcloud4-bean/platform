#!/usr/bin/env bash
# 완료 증거 3: primary DB dump를 별도 DB/Pod로 복원해 같은 project/analysis를 확인하고 제거한다.
# shellcheck disable=SC2029
set -Eeuo pipefail

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly env_file=${secret_root}/sonarqube/env
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly postgres_host=${POSTGRES_HOST:-rocky@10.10.50.10}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly restore_url=http://127.0.0.1:19001
readonly dump_path=/var/tmp/quality-01-sonarqube.dump
readonly port_forward_log=/tmp/quality01-restore-port-forward.log
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly server_entrypoint=${repo_root}/gitops/apps/sonarqube/server-entrypoint.sh
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

for required in "${env_file}" "${vault_token_file}"; do
  [[ -f "${required}" && ! -L "${required}" && "$(stat -c %a "${required}")" == 600 ]] || {
    echo "필수 입력이 없거나 regular mode 0600이 아니다: ${required}" >&2
    exit 1
  }
done

SONARQUBE_ADMIN_PASSWORD=
while IFS='=' read -r key value; do
  [[ "${key}" == SONARQUBE_ADMIN_PASSWORD ]] && SONARQUBE_ADMIN_PASSWORD=${value}
done <"${env_file}"
readonly SONARQUBE_ADMIN_PASSWORD
[[ -n "${SONARQUBE_ADMIN_PASSWORD}" ]]
restore_password="Aa1!$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-36)"
readonly restore_password
umask 077
local_temp_dir=$(mktemp -d)
readonly local_temp_dir
readonly restore_payload=${local_temp_dir}/restore.json
readonly netrc_file=${local_temp_dir}/netrc

kubectl_ssh() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}
vault_exec() {
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n'
    cat
  } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
      set -eu
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec sh -eu
    '"
}

tunnel_pid=
cleanup() {
  if [[ -n "${tunnel_pid}" ]]; then
    kill "${tunnel_pid}" 2>/dev/null || true
    wait "${tunnel_pid}" 2>/dev/null || true
  fi
  kubectl_ssh -n sonarqube delete deployment sonarqube-restore --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  kubectl_ssh -n sonarqube delete service sonarqube-restore --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl_ssh -n sonarqube delete pvc sonarqube-restore-data --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  kubectl_ssh -n sonarqube delete configmap sonarqube-restore-vault-agent --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl_ssh -n sonarqube delete configmap sonarqube-restore-scripts --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl_ssh -n sonarqube delete serviceaccount sonarqube-restore --ignore-not-found=true >/dev/null 2>&1 || true
  vault_exec <<'REMOTE' >/dev/null 2>&1 || true
vault kv metadata delete kv/sonarqube/restore 2>/dev/null || true
vault delete auth/kubernetes/role/sonarqube-restore 2>/dev/null || true
vault policy delete sonarqube-restore 2>/dev/null || true
REMOTE
  printf '%s\n' \
    'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '\''sonarqube_restore'\'' AND pid <> pg_backend_pid();' \
    'DROP DATABASE IF EXISTS sonarqube_restore;' \
    'DROP ROLE IF EXISTS sonarqube_restore_user;' | \
    ssh "${ssh_options[@]}" "${postgres_host}" \
      "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres" >/dev/null 2>&1 || true
  ssh "${ssh_options[@]}" "${postgres_host}" "sudo find ${dump_path} -delete" >/dev/null 2>&1 || true
  find "${port_forward_log}" -delete 2>/dev/null || true
  if [[ -d "${local_temp_dir}" ]]; then
    find "${local_temp_dir}" -type f -delete 2>/dev/null || true
    rmdir "${local_temp_dir}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

restore_exists=$(ssh "${ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres psql -XAt -d postgres -c \"SELECT count(*) FROM pg_database WHERE datname='sonarqube_restore'\"")
[[ "${restore_exists}" == 0 ]] || {
  echo "기존 sonarqube_restore DB가 있어 덮어쓰지 않는다." >&2
  exit 1
}

ssh "${ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres pg_dump -Fc --no-owner --no-acl -f ${dump_path} sonarqube"
printf "CREATE ROLE sonarqube_restore_user LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;\nCREATE DATABASE sonarqube_restore OWNER sonarqube_restore_user;\nREVOKE CONNECT ON DATABASE sonarqube_restore FROM PUBLIC;\nGRANT CONNECT ON DATABASE sonarqube_restore TO sonarqube_restore_user;\n" \
  "${restore_password}" | ssh "${ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres" >/dev/null
ssh "${ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres pg_restore --exit-on-error --no-owner --no-acl --role=sonarqube_restore_user -d sonarqube_restore ${dump_path}"

vault_exec <<'REMOTE'
cat > /tmp/sonarqube-restore.hcl <<'HCL'
path "kv/data/sonarqube/restore" {
  capabilities = ["read"]
}
HCL
vault policy write sonarqube-restore /tmp/sonarqube-restore.hcl >/dev/null
find /tmp/sonarqube-restore.hcl -delete
vault write auth/kubernetes/role/sonarqube-restore \
  bound_service_account_names=sonarqube-restore \
  bound_service_account_namespaces=sonarqube \
  audience=vault token_policies=sonarqube-restore token_no_default_policy=true \
  token_ttl=15m token_max_ttl=1h >/dev/null
REMOTE
jq -n --arg db_password "${restore_password}" \
  '{db_password: $db_password}' >"${restore_payload}"
{
  tr -d '\n' <"${vault_token_file}"
  printf '\n'
  cat "${restore_payload}"
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
    set -eu
    read -r VAULT_TOKEN
    export VAULT_TOKEN
    umask 077
    trap \"find /tmp/quality01-restore.json -delete\" EXIT
    cat > /tmp/quality01-restore.json
    vault kv put kv/sonarqube/restore @/tmp/quality01-restore.json >/dev/null
  '"

ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n sonarqube create configmap sonarqube-restore-scripts \
    --from-file=server-entrypoint.sh=/dev/stdin --dry-run=client -o yaml | \
   ${kubectl_command} label --local -f - \
    app.kubernetes.io/name=sonarqube \
    app.kubernetes.io/component=restore-verification -o yaml | \
   ${kubectl_command} apply -f -" <"${server_entrypoint}" >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" \
  <"${repo_root}/gitops/tools/quality-01/restore-manifest.yaml" >/dev/null
if ! kubectl_ssh -n sonarqube rollout status deployment/sonarqube-restore --timeout=600s >/dev/null; then
  kubectl_ssh -n sonarqube logs deployment/sonarqube-restore --all-containers=true --prefix=true >&2 || true
  exit 1
fi

ssh "${ssh_options[@]}" -L 19001:127.0.0.1:19001 "${k3s_host}" \
  "${kubectl_command} -n sonarqube port-forward service/sonarqube-restore 19001:9000 --address=127.0.0.1" \
  >"${port_forward_log}" 2>&1 &
tunnel_pid=$!
for _ in $(seq 1 30); do
  curl --silent --show-error --fail "${restore_url}/api/system/status" 2>/dev/null | \
    jq -e '.status == "UP"' >/dev/null && break
  sleep 1
done
curl --silent --show-error --fail "${restore_url}/api/system/status" | jq -e '.status == "UP"' >/dev/null

printf 'machine 127.0.0.1 login admin password %s\n' "${SONARQUBE_ADMIN_PASSWORD}" >"${netrc_file}"
for project in quality01-pass quality01-fail; do
  project_json=$(curl --silent --show-error --fail --netrc-file "${netrc_file}" \
    --get --data-urlencode "projects=${project}" "${restore_url}/api/projects/search")
  analyses_json=$(curl --silent --show-error --fail --netrc-file "${netrc_file}" \
    --get --data-urlencode "project=${project}" --data-urlencode ps=1 \
    "${restore_url}/api/project_analyses/search")
  jq -e --arg key "${project}" '[.components[] | select(.key == $key)] | length == 1' \
    <<<"${project_json}" >/dev/null
  jq -e '.analyses | length == 1' <<<"${analyses_json}" >/dev/null
  printf 'QUALITY-01 restore 조회: project=%s analysis=%s\n' \
    "${project}" "$(jq -r '.analyses[0].date' <<<"${analyses_json}")"
done
find "${netrc_file}" -delete

cleanup
trap - EXIT INT TERM
remaining=$(kubectl_ssh -n sonarqube get deployment,service,pvc,configmap,serviceaccount \
  -l app.kubernetes.io/component=restore-verification --ignore-not-found -o name)
[[ -z "${remaining}" ]] || {
  echo "restore 검증 Kubernetes 자원이 남았다: ${remaining}" >&2
  exit 1
}
echo "QUALITY-01 restore 인스턴스·PVC·DB·role·Vault 검증 자원을 제거했다."
