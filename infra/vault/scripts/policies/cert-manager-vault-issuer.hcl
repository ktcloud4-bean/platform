# CERTMGR-01: ClusterIssuer/vault-internal이 사용하는 전용 signing endpoint 하나만 연다.
# private key를 반환하는 pki/issue/*와 기존 internal-workload role은 허용하지 않는다.
path "pki/sign/cert-manager-internal-workload" {
  capabilities = ["update"]
}
