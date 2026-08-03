#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
readonly repo_root
readonly app_dir=${repo_root}/gitops/apps/cert-manager
readonly metadata=${app_dir}/release-metadata.env

fail() {
  echo "정적 검증 실패: $*" >&2
  exit 1
}

metadata_value() {
  local key=$1
  local -a values
  mapfile -t values < <(sed -n "s/^${key}=//p" "${metadata}")
  ((${#values[@]} == 1)) && [[ -n ${values[0]} ]] || fail "${key}가 정확히 하나가 아니다."
  printf '%s' "${values[0]}"
}

install_sha256=$(sha256sum "${app_dir}/install.yaml" | awk '{print $1}')
vault_ca_sha256=$(sha256sum "${app_dir}/files/vault.crt" | awk '{print $1}')
[[ ${install_sha256} == "$(metadata_value CERT_MANAGER_RENDERED_INSTALL_SHA256)" ]] \
  || fail 'install.yaml hash가 고정값과 다르다.'
[[ ${vault_ca_sha256} == "$(metadata_value VAULT_SERVER_CERT_PEM_SHA256)" ]] \
  || fail 'Vault server CA hash가 고정값과 다르다.'

crd_count=$(grep -c '^kind: CustomResourceDefinition$' "${app_dir}/install.yaml")
[[ ${crd_count} == "$(metadata_value CERT_MANAGER_CRD_COUNT)" ]] || fail "CRD 수가 다르다: ${crd_count}"

expected_images=(
  "$(metadata_value CERT_MANAGER_CONTROLLER_IMAGE)@$(metadata_value CERT_MANAGER_CONTROLLER_IMAGE_INDEX_DIGEST)"
  "$(metadata_value CERT_MANAGER_WEBHOOK_IMAGE)@$(metadata_value CERT_MANAGER_WEBHOOK_IMAGE_INDEX_DIGEST)"
  "$(metadata_value CERT_MANAGER_CAINJECTOR_IMAGE)@$(metadata_value CERT_MANAGER_CAINJECTOR_IMAGE_INDEX_DIGEST)"
  "$(metadata_value CERT_MANAGER_ACMESOLVER_IMAGE)@$(metadata_value CERT_MANAGER_ACMESOLVER_IMAGE_INDEX_DIGEST)"
)
for image in "${expected_images[@]}"; do
  grep -Fq "${image}" "${app_dir}/install.yaml" || fail "digest 고정 image가 없다: ${image%%@*}"
done
if grep -E 'quay\.io/jetstack/cert-manager-[^[:space:]"@]+:v[^[:space:]"@]+(["[:space:]]|$)' \
  "${app_dir}/install.yaml" >/dev/null; then
  fail 'digest 없는 cert-manager image 참조가 남아 있다.'
fi

grep -Fq -- '--leader-election-namespace=cert-manager' "${app_dir}/install.yaml" \
  || fail 'leader election namespace가 cert-manager로 고정되지 않았다.'
grep -Fq 'path: pki/sign/cert-manager-internal-workload' "${app_dir}/vault-clusterissuer.yaml" \
  || fail 'ClusterIssuer signing path가 전용 PKI role이 아니다.'
grep -Fq 'audience="vault://vault-internal"' "${repo_root}/gitops/tools/certmgr-01/provision.sh" \
  || fail 'Vault Kubernetes auth audience가 ClusterIssuer에 묶이지 않았다.'

rendered=$(kubectl kustomize "${app_dir}")
grep -q '^kind: ClusterIssuer$' <<<"${rendered}" || fail '렌더에 ClusterIssuer가 없다.'
grep -q '^kind: Secret$' <<<"${rendered}" || fail '렌더에 Vault public CA Secret이 없다.'
grep -q '^kind: Deployment$' <<<"${rendered}" || fail '렌더에 controller Deployment가 없다.'

echo "Static=PASS version=$(metadata_value CERT_MANAGER_VERSION) crds=${crd_count} images=4 install_sha256=$(metadata_value CERT_MANAGER_RENDERED_INSTALL_SHA256)"
