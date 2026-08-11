#!/usr/bin/env bash
# SCM-02: platform repo 자체의 GitHub -> Gitea 읽기 전용 pull-mirror.
# Argo CD의 repoURL은 계속 GitHub만 가리키며, 이 mirror는 어떤 라이브 경로도
# 소비하지 않는다. GitHub이 SSOT임은 바뀌지 않는다.
# shellcheck disable=SC2029
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법: gitops/tools/scm-02/provision-mirror.sh --check|--apply

입력: $KTC_SECRET_ROOT/gitea-github-mirror.env (호출자 소유 mode 0600)
형식: GITHUB_MIRROR_TOKEN=github_pat_...

--check: GitHub main과 Gitea mirror의 안전한 상태·SHA만 확인한다.
--apply: 없는 경우에만 private pull-mirror를 만들고 GitHub main SHA와 즉시 동기화한다.
          기존 저장소가 선언과 다르면 변경하지 않고 중단한다.
EOF
}

mode=${1:-}
if [[ ${mode} != --check && ${mode} != --apply ]]; then
  usage >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly mirror_env=${SCM02_MIRROR_ENV:-${secret_root}/gitea-github-mirror.env}
readonly gitea_env=${SCM01_ENV_FILE:-${secret_root}/gitea/env}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly gitea_port=${SCM02_GITEA_PORT:-33129}
readonly source_owner=ktcloud4-bean
readonly source_repo=platform
readonly mirror_owner=ktcloud4-bean
readonly source_url=https://github.com/${source_owner}/${source_repo}.git

check_private_file() {
  local path=$1
  [[ -f ${path} && ! -L ${path} ]] || { echo "일반 non-symlink 파일이 아니다: ${path}" >&2; exit 1; }
  [[ $(stat -c %u "${path}") -eq $(id -u) && $(stat -c %a "${path}") == 600 ]] || {
    echo "입력 파일은 호출자 소유 mode 0600이어야 한다: ${path}" >&2
    exit 1
  }
}
check_private_file "${mirror_env}"
check_private_file "${gitea_env}"

read_env_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"
}

github_token=$(read_env_value "${mirror_env}" GITHUB_MIRROR_TOKEN)
[[ -n ${github_token} ]] || { echo "GITHUB_MIRROR_TOKEN 없음" >&2; exit 1; }

github_sha=$(curl --silent --show-error --fail \
  --header "Authorization: Bearer ${github_token}" \
  --header 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/${source_owner}/${source_repo}/commits/main" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha"])')
unset github_token
[[ ${github_sha} =~ ^[0-9a-f]{40}$ ]] || { echo "GitHub main SHA 조회 실패" >&2; exit 1; }

readonly ssh_options=(
  -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}" -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
gitea_pid=
token_name="scm-02-provision-temp-$$"
cleanup() {
  local status=$?
  [[ -n ${gitea_pid} ]] && kill "${gitea_pid}" 2>/dev/null || true
  # Gitea는 token 인증으로 자기 자신을 self-delete하는 요청을 401로 거부한다.
  # scm-recovery의 저장 비밀번호가 라이브와 불일치해 basic auth 경로도 못 쓴다.
  # write:repository 범위 임시 token(${token_name})은 postgres-01의 Gitea DB
  # access_token 테이블에서 직접 지운다: DELETE FROM access_token WHERE name='...'.
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
  return "${status}"
}
trap cleanup EXIT INT TERM

admin_token=$(kube -n gitea exec deployment/gitea -c gitea -- \
  gitea admin user generate-access-token --username scm-recovery \
  --token-name "${token_name}" --scopes "write:repository" \
  | awk -F': ' '{print $2}')
[[ -n ${admin_token} ]] || { echo "Gitea 임시 토큰 발급 실패" >&2; exit 1; }

target_ip=$(kube -n gitea get service gitea-http -o jsonpath='{.spec.clusterIP}')
[[ ${target_ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "gitea-http ClusterIP 조회 실패" >&2; exit 1; }
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
  -L "${gitea_port}:${target_ip}:3000" "${k3s_host}" \
  >"${temp_dir}/tunnel.log" 2>&1 &
gitea_pid=$!
readonly gitea_api="http://127.0.0.1:${gitea_port}/api/v1"
for _ in $(seq 1 30); do
  curl --silent --show-error --fail --max-time 5 "${gitea_api%/api/v1}/api/healthz" >/dev/null 2>&1 && break
  sleep 1
done

request_status() {
  local method=$1 url=$2 out=$3 body=${4:-}
  local args=(--silent --show-error --header "Authorization: token ${admin_token}"
    --request "${method}" --output "${out}" --write-out '%{http_code}')
  [[ -n ${body} ]] && args+=(--header 'Content-Type: application/json' --data "@${body}")
  curl "${args[@]}" "${url}"
}

repo_response=${temp_dir}/repo.json
status=$(request_status GET "${gitea_api}/repos/${mirror_owner}/${source_repo}" "${repo_response}")
[[ ${status} == 200 || ${status} == 404 ]] || { echo "Gitea mirror preflight HTTP ${status}" >&2; exit 1; }
repo_state=$([[ ${status} == 200 ]] && echo present || echo absent)
if [[ ${repo_state} == present ]]; then
  python3 -c "
import json,sys
d = json.load(open('${repo_response}'))
ok = d.get('full_name') == 'ktcloud4-bean/platform' and d.get('private') is True and d.get('mirror') is True and d.get('original_url') == '${source_url}'
sys.exit(0 if ok else 1)
" || { echo "Gitea platform mirror가 선언과 다르다." >&2; exit 1; }
fi

echo "SCM-02 mirror 상태: github-main=${github_sha} repo=${repo_state}"

if [[ ${mode} == --check && ${repo_state} == absent ]]; then
  exit 0
fi

if [[ ${mode} == --apply && ${repo_state} == absent ]]; then
  github_token=$(read_env_value "${mirror_env}" GITHUB_MIRROR_TOKEN)
  mirror_payload=${temp_dir}/mirror-payload.json
  python3 -c "
import json
json.dump({
  'clone_addr': '${source_url}',
  'repo_name': '${source_repo}',
  'repo_owner': '${mirror_owner}',
  'description': 'GitHub ktcloud4-bean/platform SSOT source mirror (read-only, GitOps는 계속 GitHub만 읽음)',
  'private': True,
  'mirror': True,
  'mirror_interval': '30m',
  'service': 'github',
  'auth_username': 'x-access-token',
  'auth_password': '${github_token}',
  'auth_token': '${github_token}',
}, open('${mirror_payload}', 'w'))
"
  unset github_token
  status=$(request_status POST "${gitea_api}/repos/migrate" "${temp_dir}/mirror-create.json" "${mirror_payload}")
  [[ ${status} == 201 ]] || { echo "Gitea pull-mirror 생성 HTTP ${status}" >&2; exit 1; }
fi

branch_response=${temp_dir}/branch.json
mirror_sha=
for _ in $(seq 1 45); do
  request_status POST "${gitea_api}/repos/${mirror_owner}/${source_repo}/mirror-sync" "${temp_dir}/mirror-sync.json" >/dev/null || true
  status=$(request_status GET "${gitea_api}/repos/${mirror_owner}/${source_repo}/branches/main" "${branch_response}")
  if [[ ${status} == 200 ]]; then
    mirror_sha=$(python3 -c "
import json,re
d = json.load(open('${branch_response}'))
sha = d.get('commit', {}).get('id', '')
print(sha if re.fullmatch(r'[0-9a-f]{40}', sha) else '')
")
    [[ ${mirror_sha} == "${github_sha}" ]] && break
  fi
  sleep 1
done
[[ ${mirror_sha} == "${github_sha}" ]] || { echo "Gitea mirror SHA가 GitHub main과 일치하지 않는다." >&2; exit 1; }

echo "SCM-02 mirror 검증 통과: owner=${mirror_owner} repo=${source_repo} private=true mirror=true main-sha=${mirror_sha}"
echo "임시 token ${token_name}을 postgres-01의 Gitea DB access_token 테이블에서 직접 지운다." >&2
