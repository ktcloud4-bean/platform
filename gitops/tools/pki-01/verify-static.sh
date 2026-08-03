#!/usr/bin/env bash
set -euo pipefail

readonly mode=${1:-short}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
readonly repo_root
readonly crowdsec_dir=${repo_root}/gitops/apps/crowdsec
readonly cert_manager_dir=${repo_root}/gitops/apps/cert-manager

[[ ${mode} == short || ${mode} == final ]] || {
  echo 'usage: verify-static.sh [short|final]' >&2
  exit 2
}

fail() {
  echo "정적 검증 실패: $*" >&2
  exit 1
}

crowdsec_render=$(mktemp /tmp/pki-01-crowdsec.XXXXXX)
cert_manager_render=$(mktemp /tmp/pki-01-cert-manager.XXXXXX)
trap 'rm -f -- "${crowdsec_render}" "${cert_manager_render}"' EXIT

helm template crowdsec "${crowdsec_dir}" --namespace crowdsec-01 \
  -f "${crowdsec_dir}/values-crowdsec-01.yaml" >"${crowdsec_render}"
kubectl kustomize "${cert_manager_dir}" >"${cert_manager_render}"

[[ $(grep -c '^kind: Certificate$' "${crowdsec_render}") == 2 ]] \
  || fail 'CrowdSec Certificate가 agent와 LAPI 두 장이 아니다.'
grep -Fq 'commonName: crowdsec-agent.crowdsec-01.svc.cluster.local' "${crowdsec_render}" \
  || fail 'agent 실제 FQDN이 Certificate에 없다.'
grep -Fq 'commonName: crowdsec-service.crowdsec-01.svc.cluster.local' "${crowdsec_render}" \
  || fail 'LAPI 실제 FQDN이 Certificate에 없다.'
grep -A 12 -F 'commonName: crowdsec-service.crowdsec-01.svc.cluster.local' "${crowdsec_render}" | \
  grep -Fq -- '- localhost' || fail 'LAPI 자기 bootstrap용 localhost SAN이 없다.'
grep -Fq 'name: vault-crowdsec-agent' "${crowdsec_render}" \
  || fail 'agent 전용 ClusterIssuer 연결이 없다.'
grep -Fq 'name: vault-crowdsec-lapi' "${crowdsec_render}" \
  || fail 'LAPI 전용 ClusterIssuer 연결이 없다.'
if grep -Eq 'commonName: CrowdSec|commonName: crowdsec-ca|isCA: true|name: crowdsec-ca-issuer' \
  "${crowdsec_render}"; then
  fail 'chart self-signed CA 또는 사람이 읽는 CN Certificate가 렌더됐다.'
fi

for path in pki/sign/crowdsec-agent pki/sign/crowdsec-lapi; do
  grep -Fq "path: ${path}" "${cert_manager_render}" || fail "ClusterIssuer path가 없다: ${path}"
done
grep -Fq 'namespace: crowdsec-01' "${cert_manager_render}" \
  || fail 'CrowdSec가 소비할 Vault server CA ConfigMap이 없다.'
grep -Fq 'CRL_FILE' "${crowdsec_render}" || fail 'LAPI CRL 경로가 없다.'
grep -Fq 'pki-01-crl-sync' "${crowdsec_render}" || fail 'CRL 갱신 sidecar가 없다.'
grep -Fq 'pki-01-tls.sha256' "${crowdsec_render}" || fail '인증서 변경 reload probe가 없다.'

grep -Fq 'allowed_domains="crowdsec-agent.crowdsec-01.svc.cluster.local"' \
  "${repo_root}/gitops/tools/pki-01/provision.sh" || fail 'agent role 이름 경계가 다르다.'
grep -Fq 'allowed_domains="crowdsec-service.crowdsec-01.svc.cluster.local,localhost"' \
  "${repo_root}/gitops/tools/pki-01/provision.sh" || fail 'LAPI role 이름 경계가 다르다.'
grep -Fq 'ou="agent-ou"' "${repo_root}/gitops/tools/pki-01/provision.sh" \
  || fail 'agent role이 OU를 고정하지 않는다.'
if grep -R -E 'pki/(issue|sign-verbatim)' \
  "${repo_root}/infra/vault/scripts/policies/cert-manager-vault-crowdsec-"*.hcl >/dev/null; then
  fail 'CrowdSec Vault policy가 sign endpoint 밖을 연다.'
fi

if git -C "${repo_root}" grep -E '^-----BEGIN (EC |RSA |OPENSSH )?PRIVATE KEY-----$' -- . >/dev/null; then
  fail 'Git tracked 파일에 private key PEM이 있다.'
fi
snapshot_expected=$(sed -n 's/^CROWDSEC_AGENT_CONFIG_SNAPSHOT_SHA256=//p' \
  "${crowdsec_dir}/release-metadata.env")
snapshot_actual=$(base64 -d "${crowdsec_dir}/files/agent-config-snapshot.tar.gz.b64" | sha256sum | awk '{print $1}')
[[ ${snapshot_actual} == "${snapshot_expected}" ]] || fail 'agent config snapshot hash가 다르다.'
if base64 -d "${crowdsec_dir}/files/agent-config-snapshot.tar.gz.b64" | tar -tzf - | \
   grep -Eq '(^|/)(local_api_credentials|online_api_credentials)\.yaml$'; then
  fail 'agent config snapshot에 credential 파일이 있다.'
fi
grep -R -Fq 'targetRevision: main' "${repo_root}/gitops/root/crowdsec-application.yaml" \
  || fail 'CrowdSec child targetRevision이 literal main이 아니다.'
grep -R -Fq 'targetRevision: main' "${repo_root}/gitops/root/cert-manager-application.yaml" \
  || fail 'cert-manager child targetRevision이 literal main이 아니다.'

if [[ ${mode} == final ]]; then
  grep -A 16 '^  pki01:' "${crowdsec_dir}/values-crowdsec-01.yaml" | grep -Fq 'duration: 720h' \
    || fail '최종 duration이 720h가 아니다.'
  grep -A 16 '^  pki01:' "${crowdsec_dir}/values-crowdsec-01.yaml" | grep -Fq 'renewBefore: 240h' \
    || fail '최종 renewBefore가 240h가 아니다.'
else
  grep -A 16 '^  pki01:' "${crowdsec_dir}/values-crowdsec-01.yaml" | grep -Fq 'duration: 1h' \
    || fail '검증 duration이 1h가 아니다.'
  grep -A 16 '^  pki01:' "${crowdsec_dir}/values-crowdsec-01.yaml" | grep -Fq 'renewBefore: 55m' \
    || fail '검증 renewBefore가 55m가 아니다.'
fi

echo "Static=PASS mode=${mode} certificates=2 roles=2 policies=2 private_key_pem=0"
