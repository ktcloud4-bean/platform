#!/usr/bin/env bash
# BOARD-DEMO-01: GitHub source를 Gitea private pull-mirror로 생성·검증한다.
# 비밀값은 저장소 밖 mode 0600 입력에서만 읽고 출력하지 않는다.
# shellcheck disable=SC2029
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법: gitops/tools/board-demo/provision-mirror.sh --check|--apply

입력: $KTC_SECRET_ROOT/gitea-github-mirror.env (호출자 소유 mode 0600)
형식: GITHUB_MIRROR_TOKEN=github_pat_...

--check: GitHub main과 Gitea mirror의 안전한 상태·SHA만 확인한다.
--apply: 없는 Gitea 조직과 private pull-mirror를 만들고 즉시 동기화한다.
          기존 객체가 선언과 다르면 변경하지 않고 중단한다.
EOF
}

mode=${1:-}
if [[ ${mode} != --check && ${mode} != --apply ]]; then
  usage >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly mirror_env=${BOARD_DEMO_MIRROR_ENV:-${secret_root}/gitea-github-mirror.env}
readonly gitea_env=${SCM01_ENV_FILE:-${secret_root}/gitea/env}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly gitea_port=${BOARD_DEMO_GITEA_PORT:-33125}
readonly source_owner=ktcloud4-bean
readonly source_repo=board-app
readonly mirror_owner=ktcloud4-bean
readonly source_url=https://github.com/${source_owner}/${source_repo}.git

repo_root=$(git rev-parse --show-toplevel)
readonly repo_root

check_private_file() {
  local path=$1
  [[ -f ${path} && ! -L ${path} ]] || {
    echo "일반 non-symlink 파일이 아니다: ${path}" >&2
    exit 1
  }
  [[ $(stat -c %u "${path}") -eq $(id -u) && $(stat -c %a "${path}") == 600 ]] || {
    echo "입력 파일은 호출자 소유 mode 0600이어야 한다: ${path}" >&2
    exit 1
  }
  case ${path} in
    "${repo_root}"|"${repo_root}"/*)
      echo "credential 입력은 저장소 밖이어야 한다: ${path}" >&2
      exit 1
      ;;
  esac
}

check_private_file "${mirror_env}"
check_private_file "${gitea_env}"

awk '
  BEGIN { count=0; valid=1 }
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  /^GITHUB_MIRROR_TOKEN=github_pat_[A-Za-z0-9_]+$/ { count++; next }
  { valid=0 }
  END { exit !(valid && count == 1) }
' "${mirror_env}" || {
  echo "GITHUB_MIRROR_TOKEN 입력 형식이 올바르지 않다." >&2
  exit 1
}

read_env_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"
}

github_token=$(read_env_value "${mirror_env}" GITHUB_MIRROR_TOKEN)
gitea_admin_password=$(read_env_value "${gitea_env}" GITEA_LOCAL_ADMIN_PASSWORD)
[[ -n ${github_token} && -n ${gitea_admin_password} ]] || {
  echo "필수 credential 입력이 비어 있다." >&2
  exit 1
}

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)

kube() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
gitea_pid=
cleanup() {
  local status=$?
  [[ -n ${gitea_pid} ]] && kill "${gitea_pid}" 2>/dev/null || true
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
  unset github_token gitea_admin_password
  return "${status}"
}
trap cleanup EXIT INT TERM

gitea_curl=${temp_dir}/gitea.curl
github_curl=${temp_dir}/github.curl
printf 'user = "scm-recovery:%s"\nsilent\nshow-error\n' "${gitea_admin_password}" >"${gitea_curl}"
printf 'header = "Authorization: Bearer %s"\nsilent\nshow-error\n' "${github_token}" >"${github_curl}"
unset gitea_admin_password

start_gitea_tunnel() {
  local target_ip
  target_ip=$(kube -n gitea get service gitea-http -o "jsonpath='{.spec.clusterIP}'")
  [[ ${target_ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "Gitea Service ClusterIP를 판정하지 못했다." >&2
    exit 1
  }
  ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
    -L "${gitea_port}:${target_ip}:3000" "${k3s_host}" \
    >"${temp_dir}/gitea-tunnel.log" 2>&1 &
  gitea_pid=$!

  for _ in $(seq 1 45); do
    kill -0 "${gitea_pid}" 2>/dev/null || break
    if curl --silent --show-error --fail --max-time 5 \
      "http://127.0.0.1:${gitea_port}/api/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Gitea tunnel health timeout" >&2
  exit 1
}

start_gitea_tunnel
readonly gitea_api=http://127.0.0.1:${gitea_port}/api/v1
readonly github_api=https://api.github.com

request_status() {
  local config=$1 method=$2 url=$3 response=$4 body=${5:-}
  local args=(--config "${config}" --request "${method}" --output "${response}" --write-out '%{http_code}')
  if [[ -n ${body} ]]; then
    args+=(--header 'Content-Type: application/json' --data @"${body}")
  fi
  curl "${args[@]}" "${url}"
}

github_ref=${temp_dir}/github-ref.json
status=$(request_status "${github_curl}" GET \
  "${github_api}/repos/${source_owner}/${source_repo}/git/ref/heads/main" "${github_ref}")
[[ ${status} == 200 ]] || {
  echo "GitHub source main 조회 HTTP ${status}" >&2
  exit 1
}
github_sha=$(jq -er '.object.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' "${github_ref}")
unset github_token

org_response=${temp_dir}/org.json
status=$(request_status "${gitea_curl}" GET "${gitea_api}/orgs/${mirror_owner}" "${org_response}")
[[ ${status} == 200 || ${status} == 404 ]] || {
  echo "Gitea organization preflight HTTP ${status}" >&2
  exit 1
}
org_state=$([[ ${status} == 200 ]] && echo present || echo absent)
if [[ ${org_state} == present ]]; then
  jq -e --arg owner "${mirror_owner}" '.username == $owner' "${org_response}" >/dev/null || {
    echo "Gitea organization 선언이 다르다." >&2
    exit 1
  }
fi

repo_response=${temp_dir}/repo.json
status=$(request_status "${gitea_curl}" GET \
  "${gitea_api}/repos/${mirror_owner}/${source_repo}" "${repo_response}")
[[ ${status} == 200 || ${status} == 404 ]] || {
  echo "Gitea mirror preflight HTTP ${status}" >&2
  exit 1
}
repo_state=$([[ ${status} == 200 ]] && echo present || echo absent)
if [[ ${repo_state} == present ]]; then
  jq -e --arg source "${source_url}" '
    .full_name == "ktcloud4-bean/board-app" and .private == true and
    .mirror == true and .original_url == $source
  ' "${repo_response}" >/dev/null || {
    echo "Gitea board-app가 선언한 private pull-mirror와 다르다." >&2
    exit 1
  }
fi

echo "BOARD-DEMO-01 mirror 상태: github-main=${github_sha} organization=${org_state} repo=${repo_state}"

if [[ ${mode} == --check && ${repo_state} == absent ]]; then
  exit 0
fi

if [[ ${mode} == --apply && ${org_state} == absent ]]; then
  org_payload=${temp_dir}/org-payload.json
  jq -n --arg username "${mirror_owner}" \
    '{username:$username,full_name:$username,description:"GitHub source pull mirrors",visibility:"private"}' \
    >"${org_payload}"
  status=$(request_status "${gitea_curl}" POST "${gitea_api}/orgs" \
    "${temp_dir}/org-create.json" "${org_payload}")
  [[ ${status} == 201 ]] || {
    echo "Gitea organization 생성 HTTP ${status}" >&2
    exit 1
  }
fi

if [[ ${mode} == --apply && ${repo_state} == absent ]]; then
  mirror_payload=${temp_dir}/mirror-payload.json
  github_token=$(read_env_value "${mirror_env}" GITHUB_MIRROR_TOKEN)
  jq -n \
    --arg clone_addr "${source_url}" \
    --arg repo_name "${source_repo}" \
    --arg repo_owner "${mirror_owner}" \
    --arg token "${github_token}" \
    '{clone_addr:$clone_addr,repo_name:$repo_name,repo_owner:$repo_owner,
      description:"GitHub ktcloud4-bean/board-app source mirror",private:true,
      mirror:true,mirror_interval:"30m",service:"github",auth_username:"x-access-token",
      auth_password:$token,auth_token:$token}' >"${mirror_payload}"
  unset github_token
  status=$(request_status "${gitea_curl}" POST "${gitea_api}/repos/migrate" \
    "${temp_dir}/mirror-create.json" "${mirror_payload}")
  [[ ${status} == 201 ]] || {
    echo "Gitea pull-mirror 생성 HTTP ${status}" >&2
    exit 1
  }
fi

branch_response=${temp_dir}/branch.json
mirror_sha=
for _ in $(seq 1 45); do
  status=$(request_status "${gitea_curl}" POST \
    "${gitea_api}/repos/${mirror_owner}/${source_repo}/mirror-sync" \
    "${temp_dir}/mirror-sync.json")
  [[ ${status} == 200 || ${status} == 204 || ${status} == 409 ]] || {
    echo "Gitea mirror sync HTTP ${status}" >&2
    exit 1
  }
  status=$(request_status "${gitea_curl}" GET \
    "${gitea_api}/repos/${mirror_owner}/${source_repo}/branches/main" "${branch_response}")
  if [[ ${status} == 200 ]]; then
    mirror_sha=$(jq -er '.commit.id | select(type == "string" and test("^[0-9a-f]{40}$"))' "${branch_response}")
    [[ ${mirror_sha} == "${github_sha}" ]] && break
  fi
  sleep 1
done
[[ ${mirror_sha} == "${github_sha}" ]] || {
  echo "Gitea mirror SHA가 GitHub main과 일치하지 않는다." >&2
  exit 1
}

echo "BOARD-DEMO-01 mirror 검증 통과: owner=${mirror_owner} repo=${source_repo} private=true mirror=true main-sha=${mirror_sha}"
