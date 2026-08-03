#!/usr/bin/env bash
set -euo pipefail

readonly mode=${1:-run}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
readonly repo_root
readonly remote_script=${repo_root}/gitops/tools/pki-01/verify-remote.sh
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == run || ${mode} == rollback-regression ]] || {
  echo 'usage: verify-live.sh [run|rollback-regression]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo '검증 실패 단계=precondition 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

if [[ ${mode} == rollback-regression ]]; then
  readonly expected_main_sha=${PKI01_EXPECTED_MAIN_SHA:?시작 main SHA가 필요하다}
  readonly base_url=${CROWDSEC_01_BASE_URL:?CrowdSec base URL이 필요하다}
  apps=$(ssh "${ssh_options[@]}" "${k3s_host}" \
    'sudo -n /usr/local/bin/k3s kubectl -n argocd get application platform-root cert-manager crowdsec -o json')
  jq -e --arg revision "${expected_main_sha}" '
    all(.items[];
      .spec.source.targetRevision=="main" and .status.sync.revision==$revision and
      .status.sync.status=="Synced" and .status.health.status=="Healthy")
  ' <<<"${apps}" >/dev/null || {
    echo '검증 실패 단계=rollback 원인=root/cert-manager/crowdsec가 시작 main에서 Synced/Healthy가 아니다.' >&2
    exit 1
  }
  status() {
    curl -sS -o /dev/null --max-time 10 -w '%{http_code}' "$@" 2>/dev/null || true
  }
  normal=$(status "${base_url%/}/crowdsec-01/waf/normal")
  attack=$(status -A masscan "${base_url%/}/crowdsec-01/waf/attack")
  exception=$(status -A masscan "${base_url%/}/crowdsec-01/waf/exception")
  [[ ${normal} == 200 && ${attack} == 403 && ${exception} == 200 ]] || {
    echo "검증 실패 단계=rollback-regression 원인=status normal=${normal} attack=${attack} exception=${exception}" >&2
    exit 1
  }
  echo "Evidence8=PASS tls_enabled=false normal=${normal} attack=${attack} exact_exception=${exception}"
  exit 0
fi

readonly expected_config_revision=${PKI01_EXPECTED_CONFIG_REVISION:?설정 commit SHA가 필요하다}
readonly expected_root_revision=${PKI01_EXPECTED_ROOT_REVISION:?root pointer commit SHA가 필요하다}
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] || {
  echo '검증 실패 단계=precondition 원인=immutable commit SHA 형식이 아니다.' >&2
  exit 1
}
[[ -f ${vault_token_file} && ! -L ${vault_token_file} &&
   $(stat -c %a "${vault_token_file}") == 600 ]] || {
  echo '검증 실패 단계=precondition 원인=Vault root token file이 없거나 mode 0600이 아니다.' >&2
  exit 1
}
[[ -f ${remote_script} && ! -L ${remote_script} ]] || {
  echo '검증 실패 단계=precondition 원인=원격 검증 batch가 없다.' >&2
  exit 1
}

if git -C "${repo_root}" grep -E '^-----BEGIN (EC |RSA |OPENSSH )?PRIVATE KEY-----$' -- . >/dev/null; then
  echo '검증 실패 단계=privacy 원인=Git tracked 파일에 private key PEM이 있다.' >&2
  exit 1
fi

if [[ ${PKI01_ARGO_LOCK_HELD:-false} != true ]]; then
  exec 9>/tmp/ktcloud4-bean-argo-root.lock
  flock -n 9 || {
    echo '검증 실패 단계=lock 원인=다른 ARGO-ROOT 작업이 실행 중이다.' >&2
    exit 1
  }
fi

# 첫 줄만 root token이며 원격 wrapper가 읽고, 나머지 script는 bash stdin으로 넘긴다.
# shellcheck disable=SC2029
ssh "${ssh_options[@]}" "${k3s_host}" \
  "read -r PKI01_VAULT_TOKEN; export PKI01_VAULT_TOKEN; \
   PKI01_EXPECTED_CONFIG_REVISION=${expected_config_revision} \
   PKI01_EXPECTED_ROOT_REVISION=${expected_root_revision} bash -s" \
  < <({ tr -d '\n' <"${vault_token_file}"; printf '\n'; cat "${remote_script}"; })
