#!/usr/bin/env bash
# shellcheck disable=SC2029
# CI-01: Jenkins가 소비하는 저장소 밖 동적 객체만 선언한다.
#   Gitea  scm-recovery/ci01-build-smoke repo와 read-only deploy key
#   Harbor ci01-evidence / ci01-denied project와 project-scoped robot
#   Vault  jenkins policy / Kubernetes auth role / kv/jenkins/runtime
# 비밀값은 출력하지 않는다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법: KTC_SECRET_ROOT=<저장소 밖 root> gitops/tools/ci-01/provision.sh --check|--apply|--destroy

--check   안전한 메타데이터만 읽고 아무것도 바꾸지 않는다.
--apply   absent 상태에서 CI-01 객체를 만든다. 기존 객체가 선언과 다르면 중단한다.
--seed    기존 repo의 seed 3개를 저장소 선언과 같게 맞춘다. 다른 객체는 건드리지 않는다.
--destroy CI-01이 만든 객체만 제거한다. 다른 repo/project/Vault 경로는 건드리지 않는다.
EOF
}

mode=${1:-}
if [[ ${mode} != --check && ${mode} != --apply && ${mode} != --seed && ${mode} != --destroy ]]; then
  usage >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly jenkins_env=${CI01_ENV_FILE:-${secret_root}/jenkins/env}
readonly gitea_env=${SCM01_ENV_FILE:-${secret_root}/gitea/env}
readonly harbor_env=${REG01_ENV_FILE:-${secret_root}/harbor/env}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly gitea_port=${CI01_GITEA_PORT:-33021}
readonly harbor_port=${CI01_HARBOR_PORT:-33022}
readonly repo_owner=scm-recovery
readonly repo_name=ci01-build-smoke
readonly deploy_key_title=ci-01-jenkins
readonly evidence_project=ci01-evidence
readonly denied_project=ci01-denied
readonly robot_short=ci01-jenkins
readonly agent_ssh_endpoint=gitea-ssh.gitea.svc.cluster.local
readonly agent_ssh_port=2222

repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly seed_dir=${repo_root}/gitops/tools/ci-01/seed
readonly policy_file=${repo_root}/infra/vault/scripts/policies/jenkins.hcl

check_private_file() {
  local path=$1
  [[ -f ${path} && ! -L ${path} ]] || { echo "일반 non-symlink 파일이 아니다: ${path}" >&2; exit 1; }
  [[ $(stat -c %u "${path}") -eq $(id -u) && $(stat -c %a "${path}") == 600 ]] || {
    echo "파일은 호출자 소유 mode 0600이어야 한다: ${path}" >&2
    exit 1
  }
  case ${path} in
    "${repo_root}" | "${repo_root}"/*)
      echo "credential 입력은 저장소 밖이어야 한다: ${path}" >&2
      exit 1
      ;;
  esac
}

for private_input in "${jenkins_env}" "${gitea_env}" "${harbor_env}" "${vault_root_token_file}"; do
  check_private_file "${private_input}"
done
[[ -s ${policy_file} ]] || { echo "Vault policy 선언이 없다: ${policy_file}" >&2; exit 1; }
for seed in Jenkinsfile Containerfile app.sh; do
  [[ -s ${seed_dir}/${seed} ]] || { echo "seed 파일이 없다: ${seed_dir}/${seed}" >&2; exit 1; }
done

read_env_value() {
  awk -F= -v key="$2" '$1==key{print substr($0, index($0,"=")+1); exit}' "$1"
}

jenkins_admin_password=$(read_env_value "${jenkins_env}" JENKINS_ADMIN_PASSWORD)
gitea_admin_password=$(read_env_value "${gitea_env}" GITEA_LOCAL_ADMIN_PASSWORD)
harbor_admin_password=$(read_env_value "${harbor_env}" HARBOR_ADMIN_PASSWORD)
for name in jenkins_admin_password gitea_admin_password harbor_admin_password; do
  [[ -n ${!name} ]] || { echo "입력 값이 비어 있다: ${name}" >&2; exit 1; }
done
[[ ${jenkins_admin_password} =~ ^[0-9a-f]{64}$ ]] || {
  echo "JENKINS_ADMIN_PASSWORD 형식이 선언과 다르다" >&2
  exit 1
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
gitea_curl=${temp_dir}/gitea.curl
harbor_curl=${temp_dir}/harbor.curl
printf 'user = "%s:%s"\nsilent\nshow-error\n' "${repo_owner}" "${gitea_admin_password}" >"${gitea_curl}"
printf 'user = "admin:%s"\nsilent\nshow-error\n' "${harbor_admin_password}" >"${harbor_curl}"
unset gitea_admin_password harbor_admin_password

gitea_pid=
harbor_pid=
created_repo=false
created_deploy_key=false
created_projects=()
created_robot_id=
created_vault=false
transaction_complete=false

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)

kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

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

rollback_partial_apply() {
  set +e
  echo "부분 적용을 되돌린다." >&2
  if [[ ${created_vault} == true ]]; then
    vault_exec <<'REMOTE' >/dev/null 2>&1
vault kv metadata delete kv/jenkins/runtime || true
vault delete auth/kubernetes/role/jenkins || true
vault policy delete jenkins || true
REMOTE
  fi
  if [[ -n ${created_robot_id} ]]; then
    curl --config "${harbor_curl}" --request DELETE --output /dev/null \
      "http://127.0.0.1:${harbor_port}/api/v2.0/robots/${created_robot_id}"
  fi
  local project
  for project in "${created_projects[@]+"${created_projects[@]}"}"; do
    curl --config "${harbor_curl}" --request DELETE --output /dev/null \
      "http://127.0.0.1:${harbor_port}/api/v2.0/projects/${project}"
  done
  if [[ ${created_repo} == true ]]; then
    curl --config "${gitea_curl}" --request DELETE --output /dev/null \
      "http://127.0.0.1:${gitea_port}/api/v1/repos/${repo_owner}/${repo_name}"
  elif [[ ${created_deploy_key} == true ]]; then
    echo "deploy key만 남았을 수 있다. --destroy로 정리한다." >&2
  fi
}

cleanup() {
  local status=$?
  if [[ ${status} -ne 0 && ${mode} == --apply && ${transaction_complete} == false ]]; then
    rollback_partial_apply
  fi
  [[ -n ${gitea_pid} ]] && kill "${gitea_pid}" 2>/dev/null
  [[ -n ${harbor_pid} ]] && kill "${harbor_pid}" 2>/dev/null
  rm -rf -- "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

start_tunnel() {
  local name=$1 namespace=$2 service=$3 remote_port=$4 local_port=$5 probe=$6
  local target_ip
  target_ip=$(kube -n "${namespace}" get service "${service}" -o "jsonpath='{.spec.clusterIP}'")
  [[ ${target_ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "${name} Service ClusterIP를 판정하지 못했다" >&2
    exit 1
  }
  ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
    -L "${local_port}:${target_ip}:${remote_port}" "${k3s_host}" \
    >"${temp_dir}/${name}-tunnel.log" 2>&1 &
  local pid=$!

  for _ in $(seq 1 45); do
    kill -0 "${pid}" 2>/dev/null || break
    if curl --silent --show-error --fail --max-time 5 "http://127.0.0.1:${local_port}${probe}" >/dev/null 2>&1; then
      printf '%s' "${pid}"
      return 0
    fi
    sleep 1
  done
  echo "${name} tunnel health timeout" >&2
  sed -n '1,40p' "${temp_dir}/${name}-tunnel.log" >&2
  exit 1
}

gitea_pid=$(start_tunnel gitea gitea gitea-http 3000 "${gitea_port}" /api/healthz)
harbor_pid=$(start_tunnel harbor harbor harbor 80 "${harbor_port}" /api/v2.0/ping)
readonly gitea_api=http://127.0.0.1:${gitea_port}/api/v1
readonly harbor_api=http://127.0.0.1:${harbor_port}/api/v2.0

http_status() {
  local config=$1 method=$2 url=$3 body=${4:-}
  local args=(--config "${config}" --request "${method}" --output "${temp_dir}/response.json" --write-out '%{http_code}')
  if [[ -n ${body} ]]; then
    args+=(--header 'Content-Type: application/json' --data @"${body}")
  fi
  curl "${args[@]}" "${url}"
}

# ---------------------------------------------------------------- 상태 판정
repo_status=$(http_status "${gitea_curl}" GET "${gitea_api}/repos/${repo_owner}/${repo_name}")
[[ ${repo_status} == 200 || ${repo_status} == 404 ]] || {
  echo "Gitea repo preflight HTTP ${repo_status}" >&2
  exit 1
}
repo_state=$([[ ${repo_status} == 200 ]] && echo present || echo absent)

deploy_key_id=
if [[ ${repo_state} == present ]]; then
  http_status "${gitea_curl}" GET "${gitea_api}/repos/${repo_owner}/${repo_name}/keys" >/dev/null
  deploy_key_id=$(jq -r --arg title "${deploy_key_title}" \
    'map(select(.title == $title)) | if length == 1 then .[0].id else empty end' "${temp_dir}/response.json")
fi

project_states=()
evidence_project_id=
for project in "${evidence_project}" "${denied_project}"; do
  status=$(http_status "${harbor_curl}" GET "${harbor_api}/projects/${project}")
  [[ ${status} == 200 || ${status} == 404 ]] || {
    echo "Harbor project preflight HTTP ${status} (${project})" >&2
    exit 1
  }
  if [[ ${status} == 200 && ${project} == "${evidence_project}" ]]; then
    evidence_project_id=$(jq -r '.project_id' "${temp_dir}/response.json")
  fi
  project_states+=("${project}=$([[ ${status} == 200 ]] && echo present || echo absent)")
done

# Harbor 2.15의 project robot 조회는 Level과 ProjectID를 함께 요구한다.
robot_id=
if [[ -n ${evidence_project_id} ]]; then
  http_status "${harbor_curl}" GET \
    "${harbor_api}/robots?page_size=100&q=Level%3Dproject%2CProjectID%3D${evidence_project_id}" >/dev/null
  robot_id=$(jq -r --arg short "${robot_short}" \
    'if type == "array" then map(select(.name | endswith("+" + $short))) | if length == 1 then .[0].id else empty end else empty end' \
    "${temp_dir}/response.json")
fi

vault_state=$(vault_exec <<'REMOTE'
present=""
vault policy read jenkins >/dev/null 2>&1 && present="${present}policy "
vault read auth/kubernetes/role/jenkins >/dev/null 2>&1 && present="${present}role "
vault kv get kv/jenkins/runtime >/dev/null 2>&1 && present="${present}kv "
printf '%s\n' "${present:-none}"
REMOTE
)

echo "CI-01 상태: gitea-repo=${repo_state} deploy-key=$([[ -n ${deploy_key_id} ]] && echo present || echo absent)"
echo "CI-01 상태: harbor ${project_states[*]} robot=$([[ -n ${robot_id} ]] && echo present || echo absent)"
echo "CI-01 상태: vault=${vault_state}"

if [[ ${mode} == --check ]]; then
  transaction_complete=true
  exit 0
fi

# ---------------------------------------------------------------- seed 동기화
if [[ ${mode} == --seed ]]; then
  [[ ${repo_state} == present ]] || { echo "seed 대상 repo가 없다" >&2; exit 1; }
  changed=0
  for seed in Jenkinsfile Containerfile app.sh; do
    status=$(http_status "${gitea_curl}" GET \
      "${gitea_api}/repos/${repo_owner}/${repo_name}/contents/${seed}?ref=main")
    [[ ${status} == 200 ]] || { echo "seed ${seed} 조회 HTTP ${status}" >&2; exit 1; }
    current=$(jq -r '.content' "${temp_dir}/response.json" | tr -d '\n')
    desired=$(base64 -w0 <"${seed_dir}/${seed}")
    if [[ ${current} == "${desired}" ]]; then
      echo "CI-01 seed: ${seed}=match"
      continue
    fi
    jq -n --arg content "${desired}" --arg sha "$(jq -r '.sha' "${temp_dir}/response.json")" \
      --arg message "CI-01 seed sync ${seed}" \
      '{content: $content, sha: $sha, message: $message, branch: "main"}' >"${temp_dir}/seed.json"
    status=$(http_status "${gitea_curl}" PUT \
      "${gitea_api}/repos/${repo_owner}/${repo_name}/contents/${seed}" "${temp_dir}/seed.json")
    [[ ${status} == 200 ]] || { echo "seed ${seed} 갱신 HTTP ${status}" >&2; exit 1; }
    changed=$((changed + 1))
    echo "CI-01 seed: ${seed}=updated"
  done
  echo "CI-01 seed 동기화 완료: changed=${changed}"
  transaction_complete=true
  exit 0
fi

# ---------------------------------------------------------------- destroy
if [[ ${mode} == --destroy ]]; then
  if [[ -n ${robot_id} ]]; then
    http_status "${harbor_curl}" DELETE "${harbor_api}/robots/${robot_id}" >/dev/null
    echo "CI-01 destroy: harbor robot 제거"
  fi
  for project in "${evidence_project}" "${denied_project}"; do
    status=$(http_status "${harbor_curl}" GET "${harbor_api}/projects/${project}")
    if [[ ${status} == 200 ]]; then
      repositories=$(jq -r '.repo_count // 0' "${temp_dir}/response.json")
      if [[ ${repositories} != 0 ]]; then
        http_status "${harbor_curl}" GET "${harbor_api}/projects/${project}/repositories?page_size=100" >/dev/null
        for name in $(jq -r '.[].name' "${temp_dir}/response.json"); do
          encoded=${name#"${project}/"}
          http_status "${harbor_curl}" DELETE "${harbor_api}/projects/${project}/repositories/${encoded}" >/dev/null
        done
      fi
      http_status "${harbor_curl}" DELETE "${harbor_api}/projects/${project}" >/dev/null
      echo "CI-01 destroy: harbor project ${project} 제거"
    fi
  done
  if [[ ${repo_state} == present ]]; then
    http_status "${gitea_curl}" DELETE "${gitea_api}/repos/${repo_owner}/${repo_name}" >/dev/null
    echo "CI-01 destroy: gitea repo 제거"
  fi
  vault_exec <<'REMOTE' >/dev/null
vault kv metadata delete kv/jenkins/runtime || true
vault delete auth/kubernetes/role/jenkins || true
vault policy delete jenkins || true
REMOTE
  echo "CI-01 destroy: vault policy/role/kv 제거"
  transaction_complete=true
  exit 0
fi

# ---------------------------------------------------------------- apply
[[ ${repo_state} == absent ]] || {
  echo "이미 존재하는 repo를 덮어쓰지 않는다: ${repo_owner}/${repo_name}" >&2
  exit 1
}
[[ -z ${robot_id} ]] || { echo "이미 존재하는 CI-01 robot을 덮어쓰지 않는다" >&2; exit 1; }
for state in "${project_states[@]}"; do
  [[ ${state} == *=absent ]] || { echo "이미 존재하는 project를 덮어쓰지 않는다: ${state}" >&2; exit 1; }
done
[[ ${vault_state} == none ]] || { echo "이미 존재하는 Vault 객체를 덮어쓰지 않는다: ${vault_state}" >&2; exit 1; }

# 1. Gitea repo와 seed
jq -n --arg name "${repo_name}" \
  '{name: $name, private: true, auto_init: true, default_branch: "main", description: "CI-01 pipeline 기준선 smoke source"}' \
  >"${temp_dir}/repo.json"
status=$(http_status "${gitea_curl}" POST "${gitea_api}/user/repos" "${temp_dir}/repo.json")
[[ ${status} == 201 ]] || { echo "Gitea repo 생성 HTTP ${status}" >&2; exit 1; }
created_repo=true
echo "CI-01 apply: gitea repo=created"

for seed in Jenkinsfile Containerfile app.sh; do
  jq -n --arg content "$(base64 -w0 <"${seed_dir}/${seed}")" --arg message "CI-01 seed ${seed}" \
    '{content: $content, message: $message, branch: "main"}' >"${temp_dir}/seed.json"
  status=$(http_status "${gitea_curl}" POST \
    "${gitea_api}/repos/${repo_owner}/${repo_name}/contents/${seed}" "${temp_dir}/seed.json")
  [[ ${status} == 201 ]] || { echo "seed ${seed} 생성 HTTP ${status}" >&2; exit 1; }
done
echo "CI-01 apply: gitea seed=3 files"

# 2. read-only deploy key
ssh-keygen -q -t ed25519 -N '' -C "${deploy_key_title}" -f "${temp_dir}/id_ed25519"
jq -n --arg key "$(<"${temp_dir}/id_ed25519.pub")" --arg title "${deploy_key_title}" \
  '{key: $key, title: $title, read_only: true}' >"${temp_dir}/key.json"
status=$(http_status "${gitea_curl}" POST "${gitea_api}/repos/${repo_owner}/${repo_name}/keys" "${temp_dir}/key.json")
[[ ${status} == 201 ]] || { echo "deploy key 등록 HTTP ${status}" >&2; exit 1; }
jq -e '.read_only == true' "${temp_dir}/response.json" >/dev/null || {
  echo "등록된 deploy key가 read-only가 아니다" >&2
  exit 1
}
created_deploy_key=true
echo "CI-01 apply: gitea deploy-key=read-only"

# 3. Gitea SSH host key를 제품이 이미 소유한 값에서 그대로 고정한다.
kube -n gitea exec deployment/gitea -c gitea -- sh -c \
  "'for file in /var/lib/gitea/data/ssh/gitea.*.pub; do [ ! -f \"\$file\" ] || cat \"\$file\"; done'" \
  >"${temp_dir}/host-keys"
awk -v endpoint="[${agent_ssh_endpoint}]:${agent_ssh_port}" \
  'NF >= 2 {print endpoint" "$1" "$2}' "${temp_dir}/host-keys" >"${temp_dir}/known_hosts"
[[ -s ${temp_dir}/known_hosts ]] || { echo "Gitea host key를 읽지 못했다" >&2; exit 1; }
echo "CI-01 apply: gitea host-key=pinned($(wc -l <"${temp_dir}/known_hosts"))"

# 4. Harbor project 2개와 project-scoped robot
for project in "${evidence_project}" "${denied_project}"; do
  jq -n --arg name "${project}" '{project_name: $name, public: false}' >"${temp_dir}/project.json"
  status=$(http_status "${harbor_curl}" POST "${harbor_api}/projects" "${temp_dir}/project.json")
  [[ ${status} == 201 ]] || { echo "Harbor project ${project} 생성 HTTP ${status}" >&2; exit 1; }
  created_projects+=("${project}")
done
echo "CI-01 apply: harbor projects=2"

jq -n --arg short "${robot_short}" --arg project "${evidence_project}" '{
  name: $short,
  description: "CI-01 Jenkins agent push/pull robot",
  level: "project",
  disable: false,
  duration: -1,
  permissions: [{
    kind: "project",
    namespace: $project,
    access: [
      {resource: "repository", action: "pull", effect: "allow"},
      {resource: "repository", action: "push", effect: "allow"}
    ]
  }]
}' >"${temp_dir}/robot.json"
status=$(http_status "${harbor_curl}" POST "${harbor_api}/robots" "${temp_dir}/robot.json")
[[ ${status} == 201 ]] || { echo "Harbor robot 생성 HTTP ${status}" >&2; exit 1; }
created_robot_id=$(jq -r '.id' "${temp_dir}/response.json")
jq -e '.name and .secret' "${temp_dir}/response.json" >/dev/null || {
  echo "Harbor robot 응답에 credential이 없다" >&2
  exit 1
}
cp "${temp_dir}/response.json" "${temp_dir}/robot-credential.json"
echo "CI-01 apply: harbor robot=project-scoped(${evidence_project})"

# 5. Vault policy / role / KV
jq -n \
  --arg admin "${jenkins_admin_password}" \
  --arg key "$(<"${temp_dir}/id_ed25519")" \
  --arg hosts "$(<"${temp_dir}/known_hosts")" \
  --arg robot_name "$(jq -r '.name' "${temp_dir}/robot-credential.json")" \
  --arg robot_secret "$(jq -r '.secret' "${temp_dir}/robot-credential.json")" \
  '{admin_password: $admin, gitea_ssh_private_key: $key, gitea_known_hosts: $hosts,
    harbor_robot_name: $robot_name, harbor_robot_secret: $robot_secret}' \
  >"${temp_dir}/runtime.json"
unset jenkins_admin_password

{
  printf 'cat >/tmp/jenkins.hcl <<%s\n' "'CI01POLICY'"
  cat "${policy_file}"
  printf "CI01POLICY\n"
  printf 'vault policy write jenkins /tmp/jenkins.hcl >/dev/null\n'
  printf 'rm -f /tmp/jenkins.hcl\n'
  printf 'vault write auth/kubernetes/role/jenkins \\\n'
  printf '  bound_service_account_names=jenkins \\\n'
  printf '  bound_service_account_namespaces=jenkins \\\n'
  printf '  audience=vault token_policies=jenkins token_no_default_policy=true \\\n'
  printf '  token_ttl=10m token_max_ttl=15m >/dev/null\n'
  printf 'cat >/tmp/jenkins-runtime.json <<%s\n' "'CI01RUNTIME'"
  cat "${temp_dir}/runtime.json"
  printf "\nCI01RUNTIME\n"
  printf 'vault kv put kv/jenkins/runtime @/tmp/jenkins-runtime.json >/dev/null\n'
  printf 'rm -f /tmp/jenkins-runtime.json\n'
} | vault_exec >/dev/null
created_vault=true
echo "CI-01 apply: vault policy/role/kv=created"

vault_exec <<'REMOTE' >"${temp_dir}/vault-verify.json"
vault read -format=json auth/kubernetes/role/jenkins
REMOTE
jq -e '
  .data.bound_service_account_names == ["jenkins"] and
  .data.bound_service_account_namespaces == ["jenkins"] and
  .data.audience == "vault" and
  .data.token_policies == ["jenkins"] and
  .data.token_no_default_policy == true
' "${temp_dir}/vault-verify.json" >/dev/null || {
  echo "저장된 Vault role이 선언과 다르다" >&2
  exit 1
}

vault_exec <<'REMOTE' >"${temp_dir}/kv-keys.json"
vault kv get -format=json kv/jenkins/runtime
REMOTE
jq -e '(.data.data | keys | sort) == ["admin_password","gitea_known_hosts","gitea_ssh_private_key","harbor_robot_name","harbor_robot_secret"]' \
  "${temp_dir}/kv-keys.json" >/dev/null || {
  echo "kv/jenkins/runtime key 집합이 선언과 다르다" >&2
  exit 1
}

transaction_complete=true
echo "CI-01 apply 완료: gitea repo/deploy-key, harbor project 2 + robot, vault policy/role/kv"
