#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
metadata_file="$repo_root/gitops/bootstrap/argocd/release-metadata.env"
manifest_file="$repo_root/gitops/bootstrap/argocd/install.yaml"
namespace_file="$repo_root/gitops/bootstrap/argocd/namespace.yaml"
project_file="$repo_root/gitops/root/app-project.yaml"
application_template="$repo_root/gitops/bootstrap/argocd/root-application.yaml.tmpl"
argocd_cm_patch="$repo_root/gitops/bootstrap/argocd/argocd-cm.patch.yaml"
argocd_rbac_cm_patch="$repo_root/gitops/bootstrap/argocd/argocd-rbac-cm.patch.yaml"
aws_hr_vault_agent_file="$repo_root/gitops/bootstrap/argocd/aws-hr-01-vault-agent.yaml"
aws_hr_runtime_patch="$repo_root/gitops/bootstrap/argocd/aws-hr-01-runtime.patch.yaml"
vault_trust_source_file="$repo_root/gitops/apps/jenkins/trust-bundle.yaml"

usage() {
  cat <<'USAGE'
사용법:
  K3S_SSH_TARGET=<rocky@k3s-01 FQDN> \
  K3S_SSH_KNOWN_HOSTS=<저장소 밖 trusted known_hosts> \
  ./gitops/bootstrap/argocd/bootstrap.sh \
    --target-revision <40자리 Git commit SHA 또는 main> \
    --private-key <저장소 밖 deploy key 경로>

이 스크립트는 k3s 호스트의 sudo -n k3s kubectl만 사용한다. kubeconfig와 private
key는 출력하지 않으며 Secret 원문 manifest를 저장소에 만들지 않는다.
USAGE
}

target_revision=
private_key=
while (($# > 0)); do
  case "$1" in
    --target-revision)
      target_revision=${2:-}
      shift 2
      ;;
    --private-key)
      private_key=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"
if [[ ! $target_revision =~ ^([0-9a-f]{40}|main)$ ]]; then
  printf '%s\n' '오류: target revision은 40자리 소문자 Git SHA 또는 main이어야 합니다.' >&2
  exit 2
fi
if [[ ! -f $private_key || $(stat -c '%a' "$private_key") != 600 ]]; then
  printf '%s\n' '오류: private key는 저장소 밖의 일반 파일이며 mode 0600이어야 합니다.' >&2
  exit 2
fi
if [[ ! -f $K3S_SSH_KNOWN_HOSTS ]]; then
  printf '%s\n' '오류: trusted known_hosts 파일이 없습니다.' >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$metadata_file"
actual_manifest_sha=$(sha256sum "$manifest_file" | awk '{print $1}')
if [[ $actual_manifest_sha != "$ARGOCD_MANIFEST_SHA256" ]]; then
  printf '%s\n' '오류: vendored Argo CD manifest SHA-256이 release metadata와 다릅니다.' >&2
  exit 1
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

remote_kubectl_file() {
  local file=$1
  "${ssh_base[@]}" 'sudo -n /usr/local/bin/k3s kubectl apply --server-side --force-conflicts -f -' < "$file"
}

remote_kubectl_namespaced_file() {
  local file=$1
  "${ssh_base[@]}" 'sudo -n /usr/local/bin/k3s kubectl -n argocd apply --server-side --force-conflicts -f -' < "$file"
}

remote_kubectl() {
  "${ssh_base[@]}" "sudo -n /usr/local/bin/k3s kubectl $*"
}

remote_kubectl_patch_file() {
  local target=$1 file=$2
  "${ssh_base[@]}" "sudo -n /usr/local/bin/k3s kubectl -n argocd patch configmap $target --type merge --patch-file=/dev/stdin" < "$file"
}

remote_argocd_statefulset_patch_file() {
  local file=$1
  "${ssh_base[@]}" 'sudo -n /usr/local/bin/k3s kubectl -n argocd patch statefulset argocd-application-controller --type strategic --patch-file=/dev/stdin' < "$file"
}

remote_aws_hr_vault_trust() {
  # Vault public leaf의 single source는 Jenkins trust bundle이다. 별도 copy를 두면 CA
  # rotation 때 Argo만 stale해지므로, bootstrap 시 이 공개 PEM만 exact ConfigMap으로 만든다.
  awk '
    /^  vault\.crt: \|$/ { collecting=1; next }
    collecting {
      is_end = ($0 ~ /^    -----END CERTIFICATE-----$/)
      sub(/^    /, "")
      print
      if (is_end) exit
    }
  ' "$vault_trust_source_file" | "${ssh_base[@]}" \
    'set -o pipefail; sudo -n /usr/local/bin/k3s kubectl -n argocd create configmap argocd-aws-hr-01-vault-trust --from-file=vault.crt=/dev/stdin --dry-run=client -o yaml | sudo -n /usr/local/bin/k3s kubectl -n argocd apply --server-side --force-conflicts -f -'
}

remote_kubectl_file "$namespace_file"
remote_kubectl_namespaced_file "$manifest_file"
remote_kubectl '-n argocd rollout status deployment/argocd-server --timeout=300s'
remote_kubectl '-n argocd rollout status deployment/argocd-repo-server --timeout=300s'
remote_kubectl '-n argocd rollout status deployment/argocd-dex-server --timeout=300s'
remote_kubectl '-n argocd rollout status deployment/argocd-redis --timeout=300s'
remote_kubectl '-n argocd rollout status statefulset/argocd-application-controller --timeout=300s'

# AWS-HR-01은 기존 Argo CD control plane을 유지하고 controller에만 Vault-backed AWS
# credential file을 붙인다. upstream vendored manifest에는 patch하지 않아 release checksum을
# 보존하며, bootstrap을 재실행해도 같은 strategic patch가 idempotent하게 적용된다.
remote_kubectl_namespaced_file "$aws_hr_vault_agent_file"
remote_aws_hr_vault_trust
remote_argocd_statefulset_patch_file "$aws_hr_runtime_patch"
remote_kubectl '-n argocd rollout status statefulset/argocd-application-controller --timeout=300s'

# GITOPS-02: Argo CD 자체 OIDC·RBAC. 다른 작업이 argocd-cm에 이미 만든 UI clutter
# 축소 키(resource.customizations.*, resource.exclusions)는 vendored manifest에
# 없고 이 스크립트도 그 키를 선언하지 않는다. merge patch만 써서 두 키를 건드리지
# 않고 url·oidc.config, policy.default·policy.csv·scopes만 추가한다.
remote_kubectl_patch_file argocd-cm "$argocd_cm_patch"
remote_kubectl_patch_file argocd-rbac-cm "$argocd_rbac_cm_patch"

"${ssh_base[@]}" 'set -o pipefail; sudo -n /usr/local/bin/k3s kubectl -n argocd create secret generic argocd-repo-platform --from-file=sshPrivateKey=/dev/stdin --from-literal=type=git --from-literal=url=ssh://git@ssh.github.com:443/ktcloud4-bean/platform.git --dry-run=client -o yaml | sudo -n /usr/local/bin/k3s kubectl apply --server-side -f -' < "$private_key"
remote_kubectl '-n argocd label secret argocd-repo-platform argocd.argoproj.io/secret-type=repository --overwrite'

remote_kubectl_namespaced_file "$project_file"
sed "s/__TARGET_REVISION__/$target_revision/g" "$application_template" | "${ssh_base[@]}" 'sudo -n /usr/local/bin/k3s kubectl -n argocd apply --server-side --force-conflicts -f -'
remote_kubectl '-n argocd get application platform-root'
printf 'bootstrap=완료 version=%s revision=%s\n' "$ARGOCD_VERSION" "$target_revision"
