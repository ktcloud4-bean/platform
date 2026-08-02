#!/usr/bin/env bash
# UPDATE-01: Renovate bot, 단일 repository collaborator, Vault runtime bundle을 선언한다.
# shellcheck disable=SC2029
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법: gitops/tools/update-01/provision.sh --check|--apply|--destroy

--check   안전한 메타데이터와 선언 일치만 읽고 변경하지 않는다.
--apply   absent 상태에서 Renovate bot/PAT/SSH key, 단일 collaborator, Vault policy/role/KV를 만든다.
--destroy Application과 workload가 제거된 뒤 UPDATE-01이 만든 동적 객체만 rollback한다.

비밀값은 출력하지 않는다. 기존 Gitea local admin 입력과 Vault root token은 저장소 밖 mode 0600
파일에서 읽고, 새 bot password/PAT/private key는 mode 0700 임시 디렉터리에서 Vault로 직접 옮긴다.
EOF
}

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply && "${mode}" != --destroy ]]; then
  usage >&2
  exit 2
fi

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly gitea_env=${SCM01_ENV_FILE:-"$KTC_SECRET_ROOT/gitea/env"}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-"$KTC_SECRET_ROOT/vault-root.token"}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly local_port=${UPDATE01_LOCAL_PORT:-33010}
readonly bot_name=renovate
readonly target_owner=scm-recovery
readonly target_repo=platform-smoke
readonly token_name=update-01-renovate
readonly host_key_alias=gitea-internal-update-01
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly policy_file=${repo_root}/infra/vault/scripts/policies/renovate.hcl

ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

check_private_file() {
  local path=$1
  [[ -f "${path}" && ! -L "${path}" ]] || {
    echo "일반 non-symlink 파일이 아니다: ${path}" >&2
    exit 1
  }
  [[ "$(stat -c %u "${path}")" -eq "$(id -u)" && "$(stat -c %a "${path}")" == 600 ]] || {
    echo "파일은 호출자 소유 mode 0600이어야 한다: ${path}" >&2
    exit 1
  }
}

for private_input in "${gitea_env}" "${vault_root_token_file}"; do
  case "${private_input}" in
    "${repo_root}"|"${repo_root}"/*)
      echo "credential 입력은 저장소 밖이어야 한다: ${private_input}" >&2
      exit 1
      ;;
  esac
  check_private_file "${private_input}"
done
[[ -s "${policy_file}" ]]

gitea_admin_password=$(awk -F= '$1=="GITEA_LOCAL_ADMIN_PASSWORD"{print substr($0,index($0,"=")+1)}' "${gitea_env}")
[[ "${gitea_admin_password}" =~ ^[A-Za-z0-9]{32,}$ ]] || {
  echo "Gitea local admin 입력 형식이 선언과 다르다" >&2
  exit 1
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
admin_curl=${temp_dir}/admin.curl
bot_curl=${temp_dir}/bot.curl
pat_curl=${temp_dir}/pat.curl
api_response=${temp_dir}/api.json
user_json=${temp_dir}/user.json
permission_json=${temp_dir}/permission.json
policy_json=${temp_dir}/policy.json
role_json=${temp_dir}/role.json
kv_json=${temp_dir}/kv.json
bot_password_file=${temp_dir}/bot-password
private_key=${temp_dir}/id_ed25519
public_key=${private_key}.pub
gitea_host_keys=${temp_dir}/gitea-host-keys
runtime_known_hosts=${temp_dir}/known_hosts
runtime_payload=${temp_dir}/runtime.json
token_response=${temp_dir}/token.json
token_file=${temp_dir}/token
port_forward_pid=
created_user=false
created_collaborator=false
created_vault=false
transaction_complete=false

printf 'user = "scm-recovery:%s"\nheader = "Host: git.imcherry5778.xyz"\nheader = "X-Forwarded-Proto: https"\nsilent\nshow-error\n' \
  "${gitea_admin_password}" >"${admin_curl}"
unset gitea_admin_password

kube() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

vault_exec() {
  {
    tr -d '\n' <"${vault_root_token_file}"
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

stop_port_forward() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
    port_forward_pid=
  fi
}

start_port_forward() {
  local target_ip
  target_ip=$(kube -n gitea get service gitea-http -o "jsonpath='{.spec.clusterIP}'")
  [[ "${target_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "Gitea Service ClusterIP를 판정하지 못했다" >&2
    exit 1
  }
  ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
    -L "${local_port}:${target_ip}:3000" "${k3s_host}" \
    >"${temp_dir}/port-forward.log" 2>&1 &
  port_forward_pid=$!
  for _ in $(seq 1 45); do
    kill -0 "${port_forward_pid}" 2>/dev/null || break
    if curl --silent --show-error --fail \
      --header 'Host: git.imcherry5778.xyz' --header 'X-Forwarded-Proto: https' \
      "http://127.0.0.1:${local_port}/api/healthz" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "Gitea 내부 API tunnel health timeout" >&2
  exit 1
}

rollback_partial_apply() {
  set +e
  if [[ "${created_vault}" == true ]]; then
    vault_exec <<'REMOTE' >/dev/null
vault kv metadata delete kv/renovate/runtime >/dev/null 2>&1 || true
vault delete auth/kubernetes/role/renovate >/dev/null 2>&1 || true
vault policy delete renovate >/dev/null 2>&1 || true
REMOTE
  fi
  if [[ "${created_collaborator}" == true ]]; then
    curl --config "${admin_curl}" --request DELETE --output /dev/null \
      "http://127.0.0.1:${local_port}/api/v1/repos/${target_owner}/${target_repo}/collaborators/${bot_name}" || true
  fi
  if [[ "${created_user}" == true ]]; then
    curl --config "${admin_curl}" --request DELETE --output /dev/null \
      "http://127.0.0.1:${local_port}/api/v1/admin/users/${bot_name}?purge=true" || true
  fi
}

cleanup() {
  local status=$?
  if [[ "${status}" -ne 0 && "${transaction_complete}" == false ]]; then
    rollback_partial_apply
  fi
  stop_port_forward
  rm -rf "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

start_port_forward
readonly api_base=http://127.0.0.1:${local_port}/api/v1

user_status=$(curl --config "${admin_curl}" --output "${user_json}" --write-out '%{http_code}' \
  "${api_base}/users/${bot_name}")
[[ "${user_status}" == 200 || "${user_status}" == 404 ]] || {
  echo "Renovate bot preflight HTTP ${user_status}" >&2
  exit 1
}

permission_status=$(curl --config "${admin_curl}" --output "${permission_json}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_owner}/${target_repo}/collaborators/${bot_name}/permission")
[[ "${permission_status}" == 200 || "${permission_status}" == 404 ]] || {
  echo "Renovate collaborator preflight HTTP ${permission_status}" >&2
  exit 1
}

vault_exec <<'REMOTE' >"${policy_json}"
if vault policy read -format=json renovate 2>/dev/null; then :; else printf '%s\n' '{"policy":null}'; fi
REMOTE
vault_exec <<'REMOTE' >"${role_json}"
if vault read -format=json auth/kubernetes/role/renovate 2>/dev/null; then :; else printf '%s\n' '{"data":null}'; fi
REMOTE
vault_exec <<'REMOTE' >"${kv_json}"
if vault kv get -format=json kv/renovate/runtime 2>/dev/null; then :; else printf '%s\n' '{"data":null}'; fi
REMOTE

role_matches() {
  jq -e '
    .data.bound_service_account_names == ["renovate"] and
    .data.bound_service_account_namespaces == ["renovate"] and
    .data.audience == "vault" and .data.token_policies == ["renovate"] and
    .data.token_no_default_policy == true and .data.token_ttl == 600 and
    .data.token_max_ttl == 900
  ' "${role_json}" >/dev/null
}

all_absent=false
if [[ "${user_status}" == 404 && "${permission_status}" == 404 ]] \
  && jq -e '.policy == null' "${policy_json}" >/dev/null \
  && jq -e '.data == null' "${role_json}" >/dev/null \
  && jq -e '.data == null' "${kv_json}" >/dev/null; then
  all_absent=true
fi

existing_matches() {
  [[ "${user_status}" == 200 && "${permission_status}" == 200 ]] || return 1
  jq -e '
    .login == "renovate" and .full_name == "Renovate Bot" and
    .email == "renovate-bot@imcherry5778.xyz" and .active == true and
    .is_admin == false and .restricted == true and .visibility == "private"
  ' "${user_json}" >/dev/null || { echo "UPDATE-01 mismatch: bot metadata" >&2; return 1; }
  jq -e '.permission == "write"' "${permission_json}" >/dev/null \
    || { echo "UPDATE-01 mismatch: collaborator permission" >&2; return 1; }
  jq -e --rawfile expected "${policy_file}" '.policy == $expected' "${policy_json}" >/dev/null \
    || { echo "UPDATE-01 mismatch: Vault policy" >&2; return 1; }
  role_matches || { echo "UPDATE-01 mismatch: Vault Kubernetes auth role" >&2; return 1; }
  jq -e '
    (.data.data | keys | sort) ==
    (["gitea_token","ssh_known_hosts","ssh_private_key"] | sort)
  ' "${kv_json}" >/dev/null || { echo "UPDATE-01 mismatch: Vault KV key set" >&2; return 1; }

  jq -r '.data.data.gitea_token' "${kv_json}" >"${token_file}"
  jq -r '.data.data.ssh_private_key' "${kv_json}" >"${private_key}"
  jq -r '.data.data.ssh_known_hosts' "${kv_json}" >"${runtime_known_hosts}"
  chmod 0600 "${token_file}" "${private_key}" "${runtime_known_hosts}"
  [[ -s "${token_file}" && -s "${private_key}" && -s "${runtime_known_hosts}" ]] \
    || { echo "UPDATE-01 mismatch: Vault KV runtime field empty" >&2; return 1; }
  ssh-keygen -y -f "${private_key}" >"${public_key}" \
    || { echo "UPDATE-01 mismatch: SSH private key format" >&2; return 1; }
  curl --config "${admin_curl}" --output "${api_response}" \
    "${api_base}/users/${bot_name}/keys"
  jq -r '.[].key | split(" ")[:2] | join(" ")' "${api_response}" \
    | grep -Fxq "$(awk '{print $1" "$2}' "${public_key}")" \
    || { echo "UPDATE-01 mismatch: bot SSH public key" >&2; return 1; }
  awk -v alias="${host_key_alias}" '
    NF == 3 && $1 == alias && $2 ~ /^ssh-(ed25519|rsa)$/ { good++ }
    END { exit(good > 0 ? 0 : 1) }
  ' "${runtime_known_hosts}" || { echo "UPDATE-01 mismatch: pinned SSH host key format" >&2; return 1; }

  printf 'header = "Authorization: token %s"\nheader = "Host: git.imcherry5778.xyz"\nheader = "X-Forwarded-Proto: https"\nsilent\nshow-error\n' \
    "$(tr -d '\n' <"${token_file}")" >"${pat_curl}"
  pat_user_status=$(curl --config "${pat_curl}" --output "${api_response}" --write-out '%{http_code}' \
    "${api_base}/user")
  [[ "${pat_user_status}" == 200 ]] \
    || { echo "UPDATE-01 mismatch: PAT user API HTTP ${pat_user_status}" >&2; return 1; }
  jq -e '.login == "renovate" and .is_admin == false and .restricted == true' "${api_response}" >/dev/null \
    || { echo "UPDATE-01 mismatch: PAT identity" >&2; return 1; }
  pat_repo_status=$(curl --config "${pat_curl}" --output "${api_response}" --write-out '%{http_code}' \
    "${api_base}/repos/${target_owner}/${target_repo}")
  [[ "${pat_repo_status}" == 200 ]] \
    || { echo "UPDATE-01 mismatch: PAT target repo HTTP ${pat_repo_status}" >&2; return 1; }
  jq -e '.permissions.push == true and .permissions.admin == false' "${api_response}" >/dev/null \
    || { echo "UPDATE-01 mismatch: PAT target repo permissions" >&2; return 1; }
}

if [[ "${mode}" == --check ]]; then
  if [[ "${all_absent}" == true ]]; then
    echo "UPDATE-01 --check: bot/collaborator/Vault runtime 전부 absent, 적용 가능"
  elif existing_matches; then
    echo "UPDATE-01 --check: restricted non-admin bot, 단일 write collaborator, Vault policy/role/KV 일치"
  else
    echo "UPDATE-01 live 상태가 absent 또는 선언 일치가 아니다. 변경하지 않는다." >&2
    exit 1
  fi
  transaction_complete=true
  exit 0
fi

if [[ "${mode}" == --destroy ]]; then
  existing_matches || {
    echo "UPDATE-01 소유 객체가 정확히 일치하지 않아 rollback하지 않는다." >&2
    exit 1
  }
  application_status=$(kube -n argocd get application renovate --ignore-not-found -o name)
  [[ -z "${application_status}" ]] || {
    echo "Application/renovate가 남아 있어 credential을 제거하지 않는다." >&2
    exit 1
  }
  curl --config "${admin_curl}" --request DELETE --output /dev/null \
    "${api_base}/repos/${target_owner}/${target_repo}/collaborators/${bot_name}"
  curl --config "${admin_curl}" --request DELETE --output /dev/null \
    "${api_base}/admin/users/${bot_name}?purge=true"
  vault_exec <<'REMOTE' >/dev/null
vault kv metadata delete kv/renovate/runtime >/dev/null
vault delete auth/kubernetes/role/renovate >/dev/null
vault policy delete renovate >/dev/null
REMOTE
  transaction_complete=true
  echo "UPDATE-01 rollback: collaborator, bot, Vault KV/role/policy 제거 완료"
  exit 0
fi

[[ "${all_absent}" == true ]] || {
  echo "UPDATE-01 --apply는 전부 absent인 최초 상태에서만 실행한다." >&2
  exit 1
}

openssl rand -hex 32 >"${bot_password_file}"
ssh-keygen -q -t ed25519 -N '' -C update-01-renovate -f "${private_key}"

jq -n --rawfile password "${bot_password_file}" '
  {
    username:"renovate",
    login_name:"renovate",
    full_name:"Renovate Bot",
    email:"renovate-bot@imcherry5778.xyz",
    password:($password | rtrimstr("\n")),
    must_change_password:false,
    restricted:true,
    send_notify:false,
    source_id:0,
    visibility:"private"
  }
' >"${temp_dir}/create-user.json"
create_user_status=$(curl --config "${admin_curl}" --request POST \
  --header 'Content-Type: application/json' --data-binary "@${temp_dir}/create-user.json" \
  --output "${api_response}" --write-out '%{http_code}' "${api_base}/admin/users")
[[ "${create_user_status}" == 201 ]] || {
  echo "Renovate bot 생성 실패: HTTP ${create_user_status}" >&2
  exit 1
}
created_user=true
jq -e '.login == "renovate" and .is_admin == false and .restricted == true' "${api_response}" >/dev/null || {
  jq '{login,is_admin,restricted,active,visibility}' "${api_response}" >&2
  echo "Renovate bot 생성 응답이 non-admin restricted 선언과 다르다" >&2
  exit 1
}
echo "UPDATE-01 apply stage: bot=created"

jq -n --rawfile key "${public_key}" \
  '{title:"update-01-renovate",key:($key|rtrimstr("\n")),read_only:false}' \
  >"${temp_dir}/create-key.json"
create_key_status=$(curl --config "${admin_curl}" --request POST \
  --header 'Content-Type: application/json' --data-binary "@${temp_dir}/create-key.json" \
  --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/admin/users/${bot_name}/keys")
[[ "${create_key_status}" == 201 ]] || {
  echo "Renovate SSH public key 생성 실패: HTTP ${create_key_status}" >&2
  exit 1
}
echo "UPDATE-01 apply stage: ssh-public-key=created"

printf '{"permission":"write"}\n' >"${temp_dir}/collaborator.json"
collaborator_status=$(curl --config "${admin_curl}" --request PUT \
  --header 'Content-Type: application/json' --data-binary "@${temp_dir}/collaborator.json" \
  --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_owner}/${target_repo}/collaborators/${bot_name}")
[[ "${collaborator_status}" == 204 ]] || {
  echo "Renovate collaborator 생성 실패: HTTP ${collaborator_status}" >&2
  exit 1
}
created_collaborator=true
echo "UPDATE-01 apply stage: collaborator=write"

printf 'user = "renovate:%s"\nheader = "Host: git.imcherry5778.xyz"\nheader = "X-Forwarded-Proto: https"\nsilent\nshow-error\n' \
  "$(tr -d '\n' <"${bot_password_file}")" >"${bot_curl}"
jq -n --arg name "${token_name}" '
  {
    name:$name,
    scopes:["write:repository","read:user","write:issue","read:organization"]
  }
' >"${temp_dir}/create-token.json"
create_token_status=$(curl --config "${bot_curl}" --request POST \
  --header 'Content-Type: application/json' --data-binary "@${temp_dir}/create-token.json" \
  --output "${token_response}" --write-out '%{http_code}' \
  "${api_base}/users/${bot_name}/tokens")
[[ "${create_token_status}" == 201 ]] || {
  echo "Renovate PAT 생성 실패: HTTP ${create_token_status}" >&2
  exit 1
}
jq -e '
  .name == "update-01-renovate" and
  (.scopes | sort) == (["write:repository","read:user","write:issue","read:organization"] | sort) and
  (.sha1 | type == "string" and length >= 32)
' "${token_response}" >/dev/null || {
  jq '{name,scopes,token_present:(.sha1 | type == "string" and length >= 32)}' "${token_response}" >&2
  echo "Renovate PAT 생성 응답이 최소 scope 선언과 다르다" >&2
  exit 1
}
jq -r '.sha1' "${token_response}" >"${token_file}"
echo "UPDATE-01 apply stage: pat=created"

kube -n gitea exec deployment/gitea -c gitea -- sh -c \
  "'for file in /var/lib/gitea/data/ssh/gitea.*.pub; do [ ! -f \"\$file\" ] || cat \"\$file\"; done'" \
  >"${gitea_host_keys}"
awk -v alias="${host_key_alias}" 'NF >= 2 {print alias" "$1" "$2}' \
  "${gitea_host_keys}" >"${runtime_known_hosts}"
[[ -s "${runtime_known_hosts}" ]]
echo "UPDATE-01 apply stage: ssh-host-keys=pinned"

jq -n \
  --rawfile gitea_token "${token_file}" \
  --rawfile ssh_private_key "${private_key}" \
  --rawfile ssh_known_hosts "${runtime_known_hosts}" \
  '{
    gitea_token:($gitea_token|rtrimstr("\n")),
    ssh_private_key:$ssh_private_key,
    ssh_known_hosts:$ssh_known_hosts
  }' >"${runtime_payload}"

{
  printf "cat > /tmp/update01-renovate-policy.hcl <<'HCL'\n"
  cat "${policy_file}"
  printf "HCL\n"
  cat <<'REMOTE'
vault policy write renovate /tmp/update01-renovate-policy.hcl >/dev/null
rm -f /tmp/update01-renovate-policy.hcl
vault write auth/kubernetes/role/renovate \
  bound_service_account_names=renovate \
  bound_service_account_namespaces=renovate \
  audience=vault token_policies=renovate token_no_default_policy=true \
  token_ttl=10m token_max_ttl=15m >/dev/null
REMOTE
} | vault_exec
created_vault=true
echo "UPDATE-01 apply stage: vault-policy-role=created"

{
  tr -d '\n' <"${vault_root_token_file}"
  printf '\n'
  cat "${runtime_payload}"
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
    set -eu
    umask 077
    read -r VAULT_TOKEN
    export VAULT_TOKEN
    trap \"rm -f /tmp/update01-runtime.json\" EXIT
    cat > /tmp/update01-runtime.json
    vault kv put kv/renovate/runtime @/tmp/update01-runtime.json >/dev/null
  '"
echo "UPDATE-01 apply stage: vault-kv=created"

vault_exec <<'REMOTE' >"${policy_json}"
vault policy read -format=json renovate
REMOTE
vault_exec <<'REMOTE' >"${role_json}"
vault read -format=json auth/kubernetes/role/renovate
REMOTE
vault_exec <<'REMOTE' >"${kv_json}"
vault kv get -format=json kv/renovate/runtime
REMOTE
user_status=$(curl --config "${admin_curl}" --output "${user_json}" --write-out '%{http_code}' \
  "${api_base}/users/${bot_name}")
permission_status=$(curl --config "${admin_curl}" --output "${permission_json}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_owner}/${target_repo}/collaborators/${bot_name}/permission")
existing_matches || {
  echo "UPDATE-01 최종 선언 일치 검증 실패" >&2
  exit 1
}

transaction_complete=true
echo "UPDATE-01 apply: restricted non-admin bot, 단일 write collaborator, 최소 PAT scope, Vault policy/role/KV 적용 검증 통과"
