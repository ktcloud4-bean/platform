#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
metadata_file="$repo_root/gitops/bootstrap/argocd/release-metadata.env"
manifest_file="$repo_root/gitops/bootstrap/argocd/install.yaml"
namespace_file="$repo_root/gitops/bootstrap/argocd/namespace.yaml"
project_file="$repo_root/gitops/root/app-project.yaml"
application_template="$repo_root/gitops/bootstrap/argocd/root-application.yaml.tmpl"

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

remote_kubectl_file "$namespace_file"
remote_kubectl_namespaced_file "$manifest_file"
remote_kubectl '-n argocd rollout status deployment/argocd-server --timeout=300s'
remote_kubectl '-n argocd rollout status deployment/argocd-repo-server --timeout=300s'
remote_kubectl '-n argocd rollout status deployment/argocd-dex-server --timeout=300s'
remote_kubectl '-n argocd rollout status deployment/argocd-redis --timeout=300s'
remote_kubectl '-n argocd rollout status statefulset/argocd-application-controller --timeout=300s'

"${ssh_base[@]}" 'set -o pipefail; sudo -n /usr/local/bin/k3s kubectl -n argocd create secret generic argocd-repo-platform --from-file=sshPrivateKey=/dev/stdin --from-literal=type=git --from-literal=url=ssh://git@ssh.github.com:443/ktcloud4-bean/platform.git --dry-run=client -o yaml | sudo -n /usr/local/bin/k3s kubectl apply --server-side -f -' < "$private_key"
remote_kubectl '-n argocd label secret argocd-repo-platform argocd.argoproj.io/secret-type=repository --overwrite'

remote_kubectl_namespaced_file "$project_file"
sed "s/__TARGET_REVISION__/$target_revision/g" "$application_template" | "${ssh_base[@]}" 'sudo -n /usr/local/bin/k3s kubectl -n argocd apply --server-side --force-conflicts -f -'
remote_kubectl '-n argocd get application platform-root'
printf 'bootstrap=완료 version=%s revision=%s\n' "$ARGOCD_VERSION" "$target_revision"
