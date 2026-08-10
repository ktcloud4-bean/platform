#!/usr/bin/env bash
# BOARD-DEMO-01: Jenkins가 소비할 전용 Gitea deploy key·Harbor robot·Vault 경계를 만든다.
# shellcheck disable=SC2029
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법: gitops/tools/board-demo/provision-supply-chain.sh --check|--apply

--check: 안전한 상태만 조회하며 live 변경은 하지 않는다.
--apply: 선언한 private mirror에 read-only key, Harbor project robot, Vault 파생 경계를 생성한다.
기존 객체가 선언과 다르거나 일부만 존재하면 덮어쓰지 않고 중단한다.
EOF
}

mode=${1:-}
if [[ $mode != --check && $mode != --apply ]]; then
  usage >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly gitea_env=${SCM01_ENV_FILE:-$secret_root/gitea/env}
readonly harbor_env=${REG01_ENV_FILE:-$secret_root/harbor/env}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-$secret_root/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly gitea_port=${BOARD_DEMO_GITEA_PORT:-33125}
readonly harbor_port=${BOARD_DEMO_HARBOR_PORT:-33126}
readonly mirror_owner=ktcloud4-bean
readonly mirror_repo=board-app
readonly deploy_key_title=board-demo-jenkins
readonly harbor_project=board-demo
readonly robot_short=board-demo-jenkins
readonly agent_ssh_endpoint=gitea-ssh.gitea.svc.cluster.local
readonly agent_ssh_port=2222

repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly policy_file=$repo_root/infra/vault/scripts/policies/board-demo-jenkins.hcl

check_private_file() {
  local path=$1
  [[ -f $path && ! -L $path ]] || {
    echo "일반 non-symlink 파일이 아니다: $path" >&2
    exit 1
  }
  [[ $(stat -c %u "$path") -eq $(id -u) && $(stat -c %a "$path") == 600 ]] || {
    echo "입력 파일은 호출자 소유 mode 0600이어야 한다: $path" >&2
    exit 1
  }
  case $path in
    "$repo_root"|"$repo_root"/*)
      echo "credential 입력은 저장소 밖이어야 한다: $path" >&2
      exit 1
      ;;
  esac
}

for input in "$gitea_env" "$harbor_env" "$vault_root_token_file"; do
  check_private_file "$input"
done
[[ -s $policy_file ]] || { echo "Vault policy 선언이 없다." >&2; exit 1; }

read_env_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"
}

gitea_admin_password=$(read_env_value "$gitea_env" GITEA_LOCAL_ADMIN_PASSWORD)
harbor_admin_password=$(read_env_value "$harbor_env" HARBOR_ADMIN_PASSWORD)
[[ -n $gitea_admin_password && -n $harbor_admin_password ]] || {
  echo "Gitea 또는 Harbor admin 입력이 비어 있다." >&2
  exit 1
}

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$known_hosts"
  -o PasswordAuthentication=no
)

kube() {
  ssh "${ssh_options[@]}" "$k3s_host" "$kubectl_command $*"
}

vault_exec() {
  {
    tr -d '\n' <"$vault_root_token_file"
    printf '\n'
    cat
  } | ssh "${ssh_options[@]}" "$k3s_host" \
    "$kubectl_command -n vault exec -i vault-0 -- sh -c '
      set -eu
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec sh -eu
    '"
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
gitea_pid=
harbor_pid=
cleanup() {
  local status=$?
  [[ -n $gitea_pid ]] && kill "$gitea_pid" 2>/dev/null || true
  [[ -n $harbor_pid ]] && kill "$harbor_pid" 2>/dev/null || true
  find "$temp_dir" -type f -delete 2>/dev/null || true
  rmdir "$temp_dir" 2>/dev/null || true
  unset gitea_admin_password harbor_admin_password
  return "$status"
}
trap cleanup EXIT INT TERM

gitea_curl=$temp_dir/gitea.curl
harbor_curl=$temp_dir/harbor.curl
printf 'user = "scm-recovery:%s"\nsilent\nshow-error\n' "$gitea_admin_password" >"$gitea_curl"
printf 'user = "admin:%s"\nsilent\nshow-error\n' "$harbor_admin_password" >"$harbor_curl"
unset gitea_admin_password harbor_admin_password

start_tunnel() {
  local name=$1 namespace=$2 service=$3 remote_port=$4 local_port=$5 probe=$6
  local target_ip pid
  target_ip=$(kube -n "$namespace" get service "$service" -o "jsonpath='{.spec.clusterIP}'")
  [[ $target_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "$name Service ClusterIP를 판정하지 못했다." >&2
    exit 1
  }
  ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
    -L "$local_port:$target_ip:$remote_port" "$k3s_host" \
    >"$temp_dir/$name-tunnel.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 45); do
    kill -0 "$pid" 2>/dev/null || break
    if curl --silent --show-error --fail --max-time 5 \
      "http://127.0.0.1:$local_port$probe" >/dev/null 2>&1; then
      printf '%s' "$pid"
      return 0
    fi
    sleep 1
  done
  echo "$name tunnel health timeout" >&2
  exit 1
}

gitea_pid=$(start_tunnel gitea gitea gitea-http 3000 "$gitea_port" /api/healthz)
harbor_pid=$(start_tunnel harbor harbor harbor 80 "$harbor_port" /api/v2.0/ping)
readonly gitea_api=http://127.0.0.1:$gitea_port/api/v1
readonly harbor_api=http://127.0.0.1:$harbor_port/api/v2.0

request_status() {
  local config=$1 method=$2 url=$3 response=$4 body=${5:-}
  local args=(--config "$config" --request "$method" --output "$response" --write-out '%{http_code}')
  if [[ -n $body ]]; then
    args+=(--header 'Content-Type: application/json' --data @"$body")
  fi
  curl "${args[@]}" "$url"
}

gitea_repo=$temp_dir/gitea-repo.json
status=$(request_status "$gitea_curl" GET \
  "$gitea_api/repos/$mirror_owner/$mirror_repo" "$gitea_repo")
[[ $status == 200 ]] || { echo "Gitea board mirror preflight HTTP $status" >&2; exit 1; }
jq -e '
  .full_name == "ktcloud4-bean/board-app" and .private == true and
  .mirror == true and .original_url == "https://github.com/ktcloud4-bean/board-app.git"
' "$gitea_repo" >/dev/null || {
  echo "Gitea source mirror 선언이 다르다." >&2
  exit 1
}

gitea_keys=$temp_dir/gitea-keys.json
status=$(request_status "$gitea_curl" GET \
  "$gitea_api/repos/$mirror_owner/$mirror_repo/keys" "$gitea_keys")
[[ $status == 200 ]] || { echo "Gitea deploy key 조회 HTTP $status" >&2; exit 1; }
key_count=$(jq --arg title "$deploy_key_title" '[.[] | select(.title == $title)] | length' "$gitea_keys")
[[ $key_count -le 1 ]] || { echo "동일 Gitea deploy key가 중복됐다." >&2; exit 1; }
key_state=$([[ $key_count == 1 ]] && echo present || echo absent)
if [[ $key_state == present ]]; then
  jq -e --arg title "$deploy_key_title" \
    '[.[] | select(.title == $title)] | length == 1 and .[0].read_only == true' \
    "$gitea_keys" >/dev/null || {
    echo "Gitea deploy key가 read-only가 아니다." >&2
    exit 1
  }
fi

harbor_project_json=$temp_dir/harbor-project.json
status=$(request_status "$harbor_curl" GET "$harbor_api/projects/$harbor_project" "$harbor_project_json")
[[ $status == 200 || $status == 404 ]] || {
  echo "Harbor project preflight HTTP $status" >&2
  exit 1
}
project_state=$([[ $status == 200 ]] && echo present || echo absent)
project_id=
if [[ $project_state == present ]]; then
  jq -e '.metadata.public == "false"' "$harbor_project_json" >/dev/null || {
    echo "Harbor board-demo project가 private가 아니다." >&2
    exit 1
  }
  project_id=$(jq -er '.project_id' "$harbor_project_json")
fi

robot_state=absent
harbor_robots=$temp_dir/harbor-robots.json
if [[ -n $project_id ]]; then
  status=$(request_status "$harbor_curl" GET \
    "$harbor_api/robots?page_size=100&q=Level%3Dproject%2CProjectID%3D$project_id" "$harbor_robots")
  [[ $status == 200 ]] || { echo "Harbor robot 조회 HTTP $status" >&2; exit 1; }
  robot_count=$(jq --arg short "$robot_short" \
    'if type == "array" then [ .[] | select(.name | endswith("+" + $short)) ] | length else 0 end' \
    "$harbor_robots")
  [[ $robot_count -le 1 ]] || { echo "동일 Harbor robot이 중복됐다." >&2; exit 1; }
  if [[ $robot_count == 1 ]]; then
    robot_state=present
  fi
fi

policy_json=$temp_dir/policy.json
if vault_exec <<'REMOTE' >"$policy_json"
if vault policy read -format=json board-demo-jenkins 2>/dev/null; then :; else printf '%s\n' '{"policy":null}'; fi
REMOTE
then
  :
else
  echo "Vault policy 조회에 실패했다." >&2
  exit 1
fi
policy_state=$(jq -r 'if .policy == null then "absent" else "present" end' "$policy_json")

role_json=$temp_dir/role.json
vault_exec <<'REMOTE' >"$role_json"
vault read -format=json auth/kubernetes/role/jenkins
REMOTE
role_matches() {
  local with_board=$1
  local expected='["e2e-01-jenkins","jenkins"]'
  [[ $with_board == true ]] && expected='["board-demo-jenkins","e2e-01-jenkins","jenkins"]'
  jq -e --argjson expected "$expected" '
    .data.bound_service_account_names == ["jenkins"] and
    .data.bound_service_account_namespaces == ["jenkins"] and
    .data.audience == "vault" and
    (.data.token_policies | sort) == $expected and
    .data.token_no_default_policy == true and
    .data.token_ttl == 600 and .data.token_max_ttl == 900
  ' "$role_json" >/dev/null
}

kv_state=absent
if vault_exec <<'REMOTE' >/dev/null 2>&1
for field in gitea_ssh_private_key gitea_known_hosts harbor_robot_name harbor_robot_secret; do
  value=$(vault kv get -field="$field" kv/board-demo/jenkins)
  test -n "$value"
done
REMOTE
then
  kv_state=present
fi

echo "BOARD-DEMO-01 supply-chain 상태: gitea-key=$key_state harbor-project=$project_state harbor-robot=$robot_state vault-policy=$policy_state vault-kv=$kv_state"

all_absent=false
if [[ $key_state == absent && $project_state == absent && $robot_state == absent && \
      $policy_state == absent && $kv_state == absent ]] && role_matches false; then
  all_absent=true
fi

verify_present() {
  [[ $key_state == present && $project_state == present && $robot_state == present && \
     $policy_state == present && $kv_state == present ]] || return 1
  jq -e --rawfile expected "$policy_file" '.policy == $expected' "$policy_json" >/dev/null
  role_matches true

  vault_key=$temp_dir/vault-gitea-key
  vault_exec <<'REMOTE' >"$vault_key"
vault kv get -field=gitea_ssh_private_key kv/board-demo/jenkins
REMOTE
  # Bash command substitution은 OpenSSH key의 종료 개행을 제거한다. Vault Agent
  # template는 개행을 다시 렌더링하므로, 여기서는 공개키 파생용 사본에만 보정한다.
  printf '\n' >>"$vault_key"
  chmod 0400 "$vault_key"
  ssh-keygen -yf "$vault_key" >"$temp_dir/vault-gitea-key.pub"
  expected_public=$(jq -r --arg title "$deploy_key_title" \
    '[.[] | select(.title == $title)][0].key' "$gitea_keys")
  cmp -s "$temp_dir/vault-gitea-key.pub" <(printf '%s\n' "$expected_public")
}

if [[ $mode == --check ]]; then
  if [[ $all_absent == true ]]; then
    echo "BOARD-DEMO-01 supply-chain: 모두 absent, --apply 가능"
    exit 0
  fi
  verify_present || {
    echo "BOARD-DEMO-01 supply-chain live state가 absent 또는 선언 일치가 아니다." >&2
    exit 1
  }
  echo "BOARD-DEMO-01 supply-chain: Gitea deploy key·Harbor robot·Vault policy/role/KV 일치"
  exit 0
fi

[[ $all_absent == true ]] || {
  echo "부분 존재 또는 Jenkins Vault role drift가 있어 덮어쓰지 않는다." >&2
  exit 1
}

ssh-keygen -q -t ed25519 -N '' -C "$deploy_key_title" -f "$temp_dir/id_ed25519"
key_payload=$temp_dir/key-payload.json
jq -n --arg key "$(<"$temp_dir/id_ed25519.pub")" --arg title "$deploy_key_title" \
  '{key:$key,title:$title,read_only:true}' >"$key_payload"
status=$(request_status "$gitea_curl" POST \
  "$gitea_api/repos/$mirror_owner/$mirror_repo/keys" "$temp_dir/key-create.json" "$key_payload")
[[ $status == 201 ]] || { echo "Gitea deploy key 생성 HTTP $status" >&2; exit 1; }

project_payload=$temp_dir/project-payload.json
jq -n --arg name "$harbor_project" '{project_name:$name,public:false}' >"$project_payload"
status=$(request_status "$harbor_curl" POST "$harbor_api/projects" \
  "$temp_dir/project-create.json" "$project_payload")
[[ $status == 201 ]] || { echo "Harbor project 생성 HTTP $status" >&2; exit 1; }

robot_payload=$temp_dir/robot-payload.json
jq -n --arg name "$robot_short" --arg project "$harbor_project" '{
  name:$name,
  description:"BOARD-DEMO-01 Jenkins agent push/pull robot",
  level:"project",
  disable:false,
  duration:-1,
  permissions:[{
    kind:"project",
    namespace:$project,
    access:[
      {resource:"repository",action:"pull",effect:"allow"},
      {resource:"repository",action:"push",effect:"allow"}
    ]
  }]
}' >"$robot_payload"
status=$(request_status "$harbor_curl" POST "$harbor_api/robots" \
  "$temp_dir/robot-create.json" "$robot_payload")
[[ $status == 201 ]] || { echo "Harbor robot 생성 HTTP $status" >&2; exit 1; }
jq -e '.name | type == "string" and length > 0' "$temp_dir/robot-create.json" >/dev/null
jq -e '.secret | type == "string" and length > 0' "$temp_dir/robot-create.json" >/dev/null

kube -n gitea exec deployment/gitea -c gitea -- sh -c \
  "'for file in /var/lib/gitea/data/ssh/gitea.*.pub; do [ ! -f \"\$file\" ] || cat \"\$file\"; done'" \
  >"$temp_dir/gitea-host-keys"
awk -v endpoint="[$agent_ssh_endpoint]:$agent_ssh_port" \
  'NF >= 2 {print endpoint" "$1" "$2}' "$temp_dir/gitea-host-keys" >"$temp_dir/gitea-known-hosts"
[[ -s $temp_dir/gitea-known-hosts ]] || { echo "Gitea SSH host key를 읽지 못했다." >&2; exit 1; }

runtime_json=$temp_dir/runtime.json
jq -n \
  --arg key "$(<"$temp_dir/id_ed25519")" \
  --arg hosts "$(<"$temp_dir/gitea-known-hosts")" \
  --arg robot_name "$(jq -r '.name' "$temp_dir/robot-create.json")" \
  --arg robot_secret "$(jq -r '.secret' "$temp_dir/robot-create.json")" \
  '{gitea_ssh_private_key:$key,gitea_known_hosts:$hosts,
    harbor_robot_name:$robot_name,harbor_robot_secret:$robot_secret}' >"$runtime_json"

{
  printf "cat >/tmp/board-demo-jenkins.hcl <<'BOARDDMOPOLICY'\n"
  cat "$policy_file"
  printf 'BOARDDMOPOLICY\n'
  printf "cat >/tmp/board-demo-jenkins.json <<'BOARDDMOKV'\n"
  cat "$runtime_json"
  printf 'BOARDDMOKV\n'
  cat <<'REMOTE'
trap 'find /tmp -maxdepth 1 -name "board-demo-jenkins.*" -type f -delete 2>/dev/null || true' EXIT
umask 077
vault policy write board-demo-jenkins /tmp/board-demo-jenkins.hcl >/dev/null
vault kv put kv/board-demo/jenkins @/tmp/board-demo-jenkins.json >/dev/null
vault write auth/kubernetes/role/jenkins   bound_service_account_names=jenkins   bound_service_account_namespaces=jenkins   audience=vault token_policies=jenkins,e2e-01-jenkins,board-demo-jenkins   token_no_default_policy=true token_ttl=10m token_max_ttl=15m >/dev/null
REMOTE
} | vault_exec >/dev/null

status=$(request_status "$gitea_curl" GET \
  "$gitea_api/repos/$mirror_owner/$mirror_repo/keys" "$gitea_keys")
[[ $status == 200 ]] || exit 1
key_count=$(jq --arg title "$deploy_key_title" '[.[] | select(.title == $title)] | length' "$gitea_keys")
key_state=$([[ $key_count == 1 ]] && echo present || echo absent)
status=$(request_status "$harbor_curl" GET "$harbor_api/projects/$harbor_project" "$harbor_project_json")
[[ $status == 200 ]] || exit 1
project_state=present
project_id=$(jq -er '.project_id' "$harbor_project_json")
status=$(request_status "$harbor_curl" GET \
  "$harbor_api/robots?page_size=100&q=Level%3Dproject%2CProjectID%3D$project_id" "$harbor_robots")
[[ $status == 200 ]] || exit 1
robot_count=$(jq --arg short "$robot_short" \
  'if type == "array" then [ .[] | select(.name | endswith("+" + $short)) ] | length else 0 end' \
  "$harbor_robots")
robot_state=$([[ $robot_count == 1 ]] && echo present || echo absent)
vault_exec <<'REMOTE' >"$policy_json"
vault policy read -format=json board-demo-jenkins
REMOTE
policy_state=present
vault_exec <<'REMOTE' >"$role_json"
vault read -format=json auth/kubernetes/role/jenkins
REMOTE
kv_state=present
verify_present || { echo "BOARD-DEMO-01 supply-chain 적용 후 검증 실패" >&2; exit 1; }
echo "BOARD-DEMO-01 supply-chain 적용 검증 통과: deploy-key=read-only harbor-project=private robot=project-scoped vault=separate-path"
