#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

usage() {
  cat <<'USAGE'
사용법:
  K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz \
  K3S_SSH_KNOWN_HOSTS=<저장소-밖-trusted-known_hosts> \
  ./gitops/tools/crowdsec-01/inject-secrets.sh [mode-0600-env-file]

ADR-0012의 별도 승인 뒤에만 실행한다. 값이나 Secret YAML은 출력하지 않는다.
입력 생략 시 Git 제외 경로 gitops/apps/crowdsec/.env를 사용한다.
USAGE
}

if (($# > 1)); then
  usage >&2
  exit 2
fi

: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

env_input=${1:-"$repo_root/gitops/apps/crowdsec/.env"}
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

if grep -Ev '^[[:space:]]*(#.*)?$|^(CS_LAPI_SECRET|REGISTRATION_TOKEN|BOUNCER_KEY_CROWDSEC_01)=[A-Za-z0-9_-]+$' "$env_file" | grep -q .; then
  printf '%s\n' '오류: 주석과 허용된 세 key만 입력할 수 있습니다.' >&2
  exit 2
fi

read_value() {
  local key=$1
  local -a entries
  mapfile -t entries < <(sed -n "s/^${key}=//p" "$env_file" | tr -d '\r')
  if ((${#entries[@]} != 1)); then
    printf '오류: %s는 정확히 한 번 선언해야 합니다.\n' "$key" >&2
    return 2
  fi
  if [[ ${entries[0]} == your_* || ! ${entries[0]} =~ ^[A-Za-z0-9_-]{49,}$ ]]; then
    printf '오류: %s에는 49자 이상의 placeholder 아닌 값을 사용해야 합니다.\n' "$key" >&2
    return 2
  fi
  printf '%s' "${entries[0]}"
}

cs_lapi_secret=$(read_value CS_LAPI_SECRET)
registration_token=$(read_value REGISTRATION_TOKEN)
bouncer_key=$(read_value BOUNCER_KEY_CROWDSEC_01)

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

{
  printf 'CS_LAPI_SECRET=%s\n' "$cs_lapi_secret"
  printf 'REGISTRATION_TOKEN=%s\n' "$registration_token"
  printf 'BOUNCER_KEY_CROWDSEC_01=%s\n' "$bouncer_key"
} | "${ssh_base[@]}" '
  set -eu
  sudo -n /usr/local/bin/k3s kubectl create namespace crowdsec-01 \
    --dry-run=client -o yaml | \
  sudo -n /usr/local/bin/k3s kubectl apply --server-side -f - >/dev/null
  sudo -n /usr/local/bin/k3s kubectl label namespace crowdsec-01 \
    app.kubernetes.io/part-of=crowdsec-01 --overwrite >/dev/null
  sudo -n /usr/local/bin/k3s kubectl -n crowdsec-01 create secret generic crowdsec-01-bootstrap \
    --from-env-file=/dev/stdin --dry-run=client -o yaml | \
  sudo -n /usr/local/bin/k3s kubectl apply --server-side -f - >/dev/null
  sudo -n /usr/local/bin/k3s kubectl -n crowdsec-01 label secret crowdsec-01-bootstrap \
    app.kubernetes.io/part-of=crowdsec-01 --overwrite >/dev/null
  sudo -n /usr/local/bin/k3s kubectl -n crowdsec-01 get secret crowdsec-01-bootstrap \
    -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers
'

printf '%s' "$bouncer_key" | "${ssh_base[@]}" '
  set -eu
  sudo -n /usr/local/bin/k3s kubectl -n kube-system create secret generic crowdsec-01-bouncer \
    --from-file=bouncer-key=/dev/stdin --dry-run=client -o yaml | \
  sudo -n /usr/local/bin/k3s kubectl apply --server-side -f - >/dev/null
  sudo -n /usr/local/bin/k3s kubectl -n kube-system label secret crowdsec-01-bouncer \
    app.kubernetes.io/part-of=crowdsec-01 --overwrite >/dev/null
  sudo -n /usr/local/bin/k3s kubectl -n kube-system get secret crowdsec-01-bouncer \
    -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers
'

unset cs_lapi_secret registration_token bouncer_key
