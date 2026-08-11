#!/usr/bin/env bash
# AWS-ID-02 완료 증거: immutable Argo 상태와 실행 중인 Dashy AWS Console 타일만 판정한다.
set -Eeuo pipefail

if [[ ${1:-} == --main ]]; then
  readonly expected_root_target=main
  readonly expected_pomerium_target=main
  readonly expected_root_revision=${2:-}
  readonly expected_pomerium_revision=${2:-}
else
  readonly expected_root_target=${1:-}
  readonly expected_pomerium_target=${2:-}
  readonly expected_root_revision=${1:-}
  readonly expected_pomerium_revision=${2:-}
fi
for revision in "${expected_root_revision}" "${expected_pomerium_revision}"; do
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || {
    echo '사용법: verify-live.sh <platform-root-pointer-sha> <pomerium-config-sha> | --main <main-sha>' >&2
    exit 2
  }
done

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s\ kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'AWS-ID-02 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

readonly ssh_options=(
  -n
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(kube -n argocd get applications.argoproj.io platform-root pomerium -o json 2>/dev/null || true)
  if jq -e --arg root_target "${expected_root_target}" --arg root_revision "${expected_root_revision}" --arg pomerium_target "${expected_pomerium_target}" --arg pomerium_revision "${expected_pomerium_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "pomerium")][0] // {}) as $pomerium_app |
    $root_app.spec.source.targetRevision == $root_target and
    $root_app.status.sync.revision == $root_revision and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $pomerium_app.spec.source.targetRevision == $pomerium_target and
    $pomerium_app.status.sync.revision == $pomerium_revision and
    $pomerium_app.status.sync.status == "Synced" and
    $pomerium_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root_target "${expected_root_target}" --arg root_revision "${expected_root_revision}" --arg pomerium_target "${expected_pomerium_target}" --arg pomerium_revision "${expected_pomerium_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "pomerium")][0] // {}) as $pomerium_app |
  $root_app.spec.source.targetRevision == $root_target and
  $root_app.status.sync.revision == $root_revision and
  $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $pomerium_app.spec.source.targetRevision == $pomerium_target and
  $pomerium_app.status.sync.revision == $pomerium_revision and
  $pomerium_app.status.sync.status == "Synced" and
  $pomerium_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || {
  echo 'AWS-ID-02 검증 실패 단계=argo 원인=platform-root/Pomerium이 immutable SHA에서 Synced/Healthy가 아니다.' >&2
  exit 1
}

dashy_deployment=$(kube -n pomerium get deployment dashy -o json)
dashy_config_map=$(jq -er '
  [.spec.template.spec.volumes[]? | select(.configMap != null) | .configMap.name]
  | unique
  | if length == 1 then .[0] else error("Dashy ConfigMap count") end
' <<<"${dashy_deployment}")
dashy=$(kube -n pomerium get configmap "${dashy_config_map}" -o json | jq -er '.data["conf.yml"]')
jq -Rrs -e '
  (split("      - title: AWS Console")[1] | split("      - title: ")[0]) as $tile |
  $tile | contains("url: https://sso.imcherry5778.xyz/realms/platform/protocol/saml/clients/aws-console") and
  contains("- /aws-console-inventory-readers") and
  contains("- /aws-console-observability-readers") and
  contains("- /aws-console-security-readers") and
  contains("- /aws-console-identity-readers") and
  (contains("- /platform-users") | not) and
  (contains("- /platform-privileged") | not)
' <<<"${dashy}" >/dev/null || {
  echo 'AWS-ID-02 검증 실패 단계=dashy 원인=실행 중 AWS Console 타일 또는 reader group 선언이 다르다.' >&2
  exit 1
}

echo 'AWS-ID-02 Argo=PASS Dashy=PASS'
