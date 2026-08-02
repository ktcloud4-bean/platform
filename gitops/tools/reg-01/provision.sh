#!/usr/bin/env bash
# shellcheck disable=SC2029
# REG-01 외부 상태(PostgreSQL, SeaweedFS S3, Vault)만 계획·적용한다.
set -Eeuo pipefail

mode=${1:-}
if [[ ${mode} != --check && ${mode} != --apply ]]; then
  echo "사용법: KTC_SECRET_ROOT=<저장소 밖 root> $0 --check|--apply" >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly env_file=${secret_root}/harbor/env
readonly vault_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly pg_known_hosts=${PG_SSH_KNOWN_HOSTS:-/home/imcherry/.ansible/pg01/known_hosts}
readonly s3_known_hosts=${S3_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts_s3_01}
readonly k3s_known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly k3s_host=${K3S_HOST:-rocky@10.10.20.10}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly policy_file=${repo_root}/infra/vault/scripts/policies/harbor.hcl

for private_file in "${env_file}" "${vault_token_file}"; do
  [[ -f ${private_file} && ! -L ${private_file} ]] || {
    echo "일반 private file이 아니다: ${private_file}" >&2
    exit 1
  }
  [[ $(stat -c %a "${private_file}") == 600 ]] || {
    echo "private file은 mode 0600이어야 한다: ${private_file}" >&2
    exit 1
  }
done
for known_hosts in "${pg_known_hosts}" "${s3_known_hosts}" "${k3s_known_hosts}"; do
  [[ -r ${known_hosts} ]] || { echo "known_hosts를 읽을 수 없다: ${known_hosts}" >&2; exit 1; }
done

umask 077
temp_root=$(mktemp -d)
readonly temp_root
cleanup() {
  if [[ ${bootstrap_active:-false} == true ]]; then
    echo "오류 정리: 일회성 S3 Admin identity를 제거한다." >&2
    ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${s3_known_hosts} -o PasswordAuthentication=no" \
      ansible-playbook -i "${temp_root}/inventory" \
      "${repo_root}/infra/ansible/playbooks/harbor-s3-identity.yml" \
      -e "@${temp_root}/private/s3-vars.json" -e harbor_s3_phase=final >/dev/null || true
  fi
  [[ -n ${s3_tunnel_pid:-} ]] && kill "${s3_tunnel_pid}" 2>/dev/null || true
  [[ ${temp_root} == /tmp/* ]] && rm -rf -- "${temp_root}"
}
bootstrap_active=false
s3_tunnel_pid=
trap cleanup EXIT INT TERM

python3 "${repo_root}/gitops/tools/reg-01/render-private-inputs.py" \
  --env-file "${env_file}" --output-dir "${temp_root}/private" >/dev/null
{
  printf '[postgres_nodes]\npostgres-01 ansible_host=10.10.50.10 ansible_user=rocky\n\n'
  printf '[object_nodes]\nobject-01 ansible_host=10.10.50.20 ansible_user=rocky\n'
} >"${temp_root}/inventory"
chmod 600 "${temp_root}/inventory"

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${k3s_known_hosts}"
  -o PasswordAuthentication=no
)

vault_capture() {
  local output=$1
  local command=$2
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; ${command}'" \
    >"${output}"
}

vault_state_check() {
  local live=${temp_root}/vault-live.json
  local policy_live=${temp_root}/policy-live.hcl
  if vault_capture "${policy_live}" 'vault policy read harbor' 2>/dev/null; then
    cmp -s "${policy_file}" "${policy_live}" || {
      echo "live Harbor Vault policy가 선언과 다르다. 변경하지 않는다." >&2
      exit 1
    }
    echo "Vault policy: match"
  else
    echo "Vault policy: absent -> add"
  fi
  if vault_capture "${live}" 'vault read -format=json auth/kubernetes/role/harbor' 2>/dev/null; then
    jq -e '
      .data.bound_service_account_names == ["harbor"] and
      .data.bound_service_account_namespaces == ["harbor"] and
      .data.audience == "vault" and
      .data.token_policies == ["harbor"] and
      .data.token_no_default_policy == true and
      .data.token_ttl == 900 and .data.token_max_ttl == 3600
    ' "${live}" >/dev/null || {
      echo "live Harbor Vault Kubernetes role이 선언과 다르다. 변경하지 않는다." >&2
      exit 1
    }
    echo "Vault Kubernetes role: match"
  else
    echo "Vault Kubernetes role: absent -> add"
  fi
  if vault_capture "${live}" 'vault kv get -format=json kv/harbor/runtime' 2>/dev/null; then
    jq -S '.data.data' "${live}" >"${temp_root}/vault-live-runtime.json"
    jq -S . "${temp_root}/private/vault-runtime.json" >"${temp_root}/vault-desired-runtime.json"
    if cmp -s "${temp_root}/vault-live-runtime.json" "${temp_root}/vault-desired-runtime.json"; then
      echo "Vault KV runtime: match"
    else
      jq -S 'del(.token_private_key)' "${temp_root}/vault-live-runtime.json" \
        >"${temp_root}/vault-live-runtime-public.json"
      jq -S 'del(.token_private_key)' "${temp_root}/vault-desired-runtime.json" \
        >"${temp_root}/vault-desired-runtime-public.json"
      jq -r '.token_private_key' "${temp_root}/vault-live-runtime.json" \
        >"${temp_root}/vault-live-token-key.pem"
      jq -r '.token_private_key' "${temp_root}/vault-desired-runtime.json" \
        >"${temp_root}/vault-desired-token-key.pem"
      if cmp -s "${temp_root}/vault-live-runtime-public.json" \
          "${temp_root}/vault-desired-runtime-public.json" && \
        openssl pkey -pubout -in "${temp_root}/vault-live-token-key.pem" \
          -out "${temp_root}/vault-live-token-key.pub" 2>/dev/null && \
        openssl pkey -pubout -in "${temp_root}/vault-desired-token-key.pem" \
          -out "${temp_root}/vault-desired-token-key.pub" 2>/dev/null && \
        cmp -s "${temp_root}/vault-live-token-key.pub" \
          "${temp_root}/vault-desired-token-key.pub"; then
        echo "Vault KV runtime: 같은 RSA 공개키의 PKCS#1 PEM 정규화 대기"
      else
        echo "live kv/harbor/runtime 값이 저장소 밖 입력과 다르다. 변경하지 않는다." >&2
        exit 1
      fi
    fi
  else
    echo "Vault KV runtime: absent -> add"
  fi
}

vault_apply() {
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; cat "${policy_file}"; } | \
    ssh "${ssh_options[@]}" "${k3s_host}" \
      "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault policy write harbor - >/dev/null'"
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault write auth/kubernetes/role/harbor bound_service_account_names=harbor bound_service_account_namespaces=harbor audience=vault token_policies=harbor token_no_default_policy=true token_ttl=15m token_max_ttl=1h >/dev/null'"
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; cat "${temp_root}/private/vault-runtime.json"; } | \
    ssh "${ssh_options[@]}" "${k3s_host}" \
      "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; umask 077; cat >/tmp/reg-01-runtime.json; vault kv put kv/harbor/runtime @/tmp/reg-01-runtime.json >/dev/null; rm -f /tmp/reg-01-runtime.json'"
  echo "Vault policy/role/KV 적용 완료 (값 미출력)"
}

pushd "${repo_root}/infra/ansible" >/dev/null
ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${pg_known_hosts} -o PasswordAuthentication=no" \
  ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-postgres.yml \
  -e "@${temp_root}/private/postgres-vars.json" --syntax-check >/dev/null
ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${s3_known_hosts} -o PasswordAuthentication=no" \
  ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-s3-identity.yml \
  -e "@${temp_root}/private/s3-vars.json" --syntax-check >/dev/null
ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${s3_known_hosts} -o PasswordAuthentication=no" \
  ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-seaweedfs-capacity.yml \
  --syntax-check >/dev/null

vault_state_check
if [[ ${mode} == --check ]]; then
  ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${pg_known_hosts} -o PasswordAuthentication=no" \
    ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-postgres.yml \
    -e "@${temp_root}/private/postgres-vars.json" --check --diff
  ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${s3_known_hosts} -o PasswordAuthentication=no" \
    ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-s3-identity.yml \
    -e "@${temp_root}/private/s3-vars.json" -e harbor_s3_phase=final --check --diff
  ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${s3_known_hosts} -o PasswordAuthentication=no" \
    ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-seaweedfs-capacity.yml \
    --check --diff
  echo "REG-01 외부 상태 계획 완료. 변경은 적용하지 않았다."
  popd >/dev/null
  exit 0
fi

ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${s3_known_hosts} -o PasswordAuthentication=no" \
  ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-seaweedfs-capacity.yml

ssh "${ssh_options[@]}" -N -o ExitOnForwardFailure=yes \
  -L 18333:10.10.50.20:8333 "${k3s_host}" \
  >"${temp_root}/s3-tunnel.log" 2>&1 &
s3_tunnel_pid=$!
for _ in {1..20}; do
  if python3 - 127.0.0.1 18333 2>/dev/null <<'PY'
import socket, sys
with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1):
    pass
PY
  then
    break
  fi
  sleep 1
done
kill -0 "${s3_tunnel_pid}"
python3 - 127.0.0.1 18333 <<'PY'
import socket, sys
with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2):
    pass
PY

ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${pg_known_hosts} -o PasswordAuthentication=no" \
  ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-postgres.yml \
  -e "@${temp_root}/private/postgres-vars.json"
bootstrap_active=true
ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${s3_known_hosts} -o PasswordAuthentication=no" \
  ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-s3-identity.yml \
  -e "@${temp_root}/private/s3-vars.json" -e harbor_s3_phase=bootstrap
python3 "${repo_root}/gitops/tools/reg-01/s3-client.py" --env-file "${env_file}" \
  --ca-file "${repo_root}/gitops/apps/harbor/files/s3.crt" \
  --connect-host 127.0.0.1 --connect-port 18333 create
ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${s3_known_hosts} -o PasswordAuthentication=no" \
  ansible-playbook -i "${temp_root}/inventory" playbooks/harbor-s3-identity.yml \
  -e "@${temp_root}/private/s3-vars.json" -e harbor_s3_phase=final
bootstrap_active=false
python3 "${repo_root}/gitops/tools/reg-01/s3-client.py" --env-file "${env_file}" \
  --ca-file "${repo_root}/gitops/apps/harbor/files/s3.crt" \
  --connect-host 127.0.0.1 --connect-port 18333 head
python3 "${repo_root}/gitops/tools/reg-01/s3-client.py" --env-file "${env_file}" \
  --ca-file "${repo_root}/gitops/apps/harbor/files/s3.crt" \
  --connect-host 127.0.0.1 --connect-port 18333 deny-other
vault_apply
vault_state_check
popd >/dev/null
echo "REG-01 외부 상태 적용 완료"
