#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

usage() {
  cat <<'USAGE'
사용법:
  K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz \
  K3S_SSH_KNOWN_HOSTS=<저장소-밖-trusted-known_hosts> \
  ./gitops/tools/ingress-01/inject-cloudflare-secret.sh [mode-0600-env-file]

Cloudflare/public DNS staging 승인 뒤에만 실행한다. token은 화면이나 Secret YAML로
출력하지 않는다. env 파일을 생략하면 gitops/apps/ingress/.env를 사용한다.
USAGE
}

if (($# > 1)); then
  usage >&2
  exit 2
fi

: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

env_input=${1:-"$repo_root/gitops/apps/ingress/.env"}
if [[ ! -f $env_input || -L $env_input ]]; then
  printf '%s\n' '오류: env 입력은 존재하는 symlink 아닌 일반 파일이어야 합니다.' >&2
  exit 2
fi
env_file=$(realpath "$env_input")

if [[ $(stat -c '%a' "$env_file") != 600 ]]; then
  printf '%s\n' '오류: env 파일은 mode 0600이어야 합니다.' >&2
  exit 2
fi

case "$env_file" in
  "$repo_root"/*)
    relative_env=${env_file#"$repo_root"/}
    if git -C "$repo_root" ls-files --error-unmatch -- "$relative_env" >/dev/null 2>&1; then
      printf '%s\n' '오류: 실제 env 파일은 Git 추적 대상이면 안 됩니다.' >&2
      exit 2
    fi
    if ! git -C "$repo_root" check-ignore -q -- "$relative_env"; then
      printf '%s\n' '오류: 저장소 안 env 파일은 .gitignore로 제외되어야 합니다.' >&2
      exit 2
    fi
    ;;
esac

if grep -Ev '^[[:space:]]*(#.*)?$|^CLOUDFLARE_API_TOKEN=[A-Za-z0-9_-]+$' "$env_file" | grep -q .; then
  printf '%s\n' '오류: env 파일에는 주석과 CLOUDFLARE_API_TOKEN 한 항목만 허용합니다.' >&2
  exit 2
fi

mapfile -t token_entries < <(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$env_file" | tr -d '\r')
if ((${#token_entries[@]} != 1)); then
  printf '%s\n' '오류: CLOUDFLARE_API_TOKEN은 정확히 한 번 선언해야 합니다.' >&2
  exit 2
fi
token=${token_entries[0]}
if [[ $token == your_* || ! $token =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
  printf '%s\n' '오류: placeholder가 아닌 Cloudflare API token이 필요합니다.' >&2
  exit 2
fi
if [[ ! -f $K3S_SSH_KNOWN_HOSTS ]]; then
  printf '%s\n' '오류: trusted known_hosts 파일이 없습니다.' >&2
  exit 2
fi

ssh_base=(
  ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$K3S_SSH_KNOWN_HOSTS"
  -o PasswordAuthentication=no
  -o ConnectTimeout=10
  "$K3S_SSH_TARGET"
)

printf '%s' "$token" | "${ssh_base[@]}" '
  set -eu
  sudo -n /usr/local/bin/k3s kubectl -n kube-system create secret generic ingress-01-cloudflare-dns \
    --from-file=CF_DNS_API_TOKEN=/dev/stdin \
    --dry-run=client -o yaml | \
  sudo -n /usr/local/bin/k3s kubectl apply --server-side -f - >/dev/null
  sudo -n /usr/local/bin/k3s kubectl -n kube-system label secret ingress-01-cloudflare-dns \
    app.kubernetes.io/part-of=platform-ingress --overwrite >/dev/null
  sudo -n /usr/local/bin/k3s kubectl -n kube-system get secret ingress-01-cloudflare-dns \
    -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers
'

unset token token_entries
