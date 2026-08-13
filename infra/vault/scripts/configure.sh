#!/usr/bin/env bash
# VAULT-02: Vault 내부 구성(mount·auth·policy·role)을 만든다.
#
# 이 스크립트는 init·unseal·seal migration·Raft 구성을 건드리지 않는다.
# 그 경계는 docs/adr/0006-vault-seal-and-bootstrap-boundary.md 가 소유한다.
#
# 비밀은 stdin과 Pod 안 임시 파일로만 전달한다. 명령 인자나 환경변수 선언에 넣지 않아
# 프로세스 목록과 셸 기록에 남지 않는다.
set -euo pipefail

: "${VAULT_ROOT_TOKEN_FILE:?저장소 밖 root token 파일 경로가 필요하다}"
: "${PG_VAULT_PASSWORD_FILE:?저장소 밖 PostgreSQL vault_admin 비밀번호 파일 경로가 필요하다}"
K3S_HOST="${K3S_HOST:-rocky@10.10.20.10}"
KUBECTL="${KUBECTL:-sudo /usr/local/bin/k3s kubectl}"
POLICY_DIR="$(cd "$(dirname "$0")/policies" && pwd)"

[ -r "$VAULT_ROOT_TOKEN_FILE" ] || { echo "root token 파일을 읽을 수 없다" >&2; exit 1; }
[ -r "$PG_VAULT_PASSWORD_FILE" ] || { echo "비밀번호 파일을 읽을 수 없다" >&2; exit 1; }

# Pod 안에서 스크립트를 실행한다. 첫 줄이 root token 이고 나머지가 스크립트다.
vault_exec() {
  { cat "$VAULT_ROOT_TOKEN_FILE"; cat; } | ssh -o BatchMode=yes "$K3S_HOST" \
    "$KUBECTL -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'"
}

echo "== 1. audit device를 먼저 켠다. 이후의 모든 변경이 감사에 남는다 =="
vault_exec <<'EOF'
vault audit list 2>/dev/null | grep -q '^stdout/' \
  || vault audit enable -path=stdout file file_path=stdout
EOF

echo "== 2. KV v2 =="
vault_exec <<'EOF'
vault secrets list 2>/dev/null | grep -q '^kv/' \
  || vault secrets enable -path=kv -version=2 -description="앱별 정적 시크릿 (VAULT-02)" kv
EOF

echo "== 3. 앱별 policy =="
for f in "$POLICY_DIR"/*.hcl; do
  name="$(basename "$f" .hcl)"
  echo "   - $name"
  { echo "cat > /tmp/p.hcl <<'HCL'"; cat "$f"; echo "HCL"; \
    echo "vault policy write $name /tmp/p.hcl; rm -f /tmp/p.hcl"; } | vault_exec
done

echo "== 4. Kubernetes auth =="
# token_reviewer_jwt 를 지정하지 않는다. Pod에 마운트된 만료 1시간 SA token 을 쓰고
# kubelet이 갱신하므로 만료 없는 자격증명이 생기지 않는다.
vault_exec <<'EOF'
vault auth list 2>/dev/null | grep -q '^kubernetes/' \
  || vault auth enable -description="k3s ServiceAccount 기반 워크로드 인증 (VAULT-02)" kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
vault write auth/kubernetes/role/keycloak \
  bound_service_account_names="keycloak" \
  bound_service_account_namespaces="keycloak" \
  token_policies="keycloak" \
  token_ttl=1h token_max_ttl=4h
vault write auth/kubernetes/role/pomerium \
  bound_service_account_names="pomerium" \
  bound_service_account_namespaces="pomerium" \
  audience="vault" \
  token_policies="pomerium" \
  token_no_default_policy=true \
  token_ttl=15m token_max_ttl=1h
vault write auth/kubernetes/role/awx \
  bound_service_account_names="awx-vault-bootstrap,awx-verifier" \
  bound_service_account_namespaces="awx" \
  audience="vault" \
  token_policies="awx" \
  token_no_default_policy=true \
  token_ttl=15m token_max_ttl=1h
vault write auth/kubernetes/role/awx-provisioner \
  bound_service_account_names="awx-provisioner" \
  bound_service_account_namespaces="awx" \
  audience="vault" \
  token_policies="awx-provisioner" \
  token_no_default_policy=true \
  token_ttl=10m token_max_ttl=15m
vault write auth/kubernetes/role/renovate \
  bound_service_account_names="renovate" \
  bound_service_account_namespaces="renovate" \
  audience="vault" \
  token_policies="renovate" \
  token_no_default_policy=true \
  token_ttl=10m token_max_ttl=15m
vault write auth/kubernetes/role/harbor \
  bound_service_account_names="harbor" \
  bound_service_account_namespaces="harbor" \
  audience="vault" \
  token_policies="harbor" \
  token_no_default_policy=true \
  token_ttl=15m token_max_ttl=1h

# AWX에는 deploy key 원문을 저장하지 않는다. provision Hook은 이 AppRole bootstrap 값만
# 받고, AWX의 built-in Vault external lookup이 `kv/awx/scm`에서 private key를 읽는다.
vault auth list 2>/dev/null | grep -q '^approle/' \
  || vault auth enable -description="AWX SCM external credential lookup" approle
vault write auth/approle/role/awx-04-scm-lookup \
  token_policies="awx-scm-lookup" \
  token_no_default_policy=true \
  token_ttl=10m token_max_ttl=15m \
  secret_id_ttl=1h secret_id_num_uses=0
EOF

echo "== 5. 내부 PKI =="
vault_exec <<'EOF'
if ! vault secrets list 2>/dev/null | grep -q '^pki/'; then
  vault secrets enable -path=pki -max-lease-ttl=87600h \
    -description="내부 workload TLS/mTLS 전용 (VAULT-02)" pki
  vault write -field=issuer_name pki/root/generate/internal \
    common_name="ktcloud4-bean Internal CA" issuer_name="internal-root" \
    key_type=ec key_bits=256 ttl=87600h
fi
vault write pki/config/urls \
  issuing_certificates="https://vault.vault.svc.cluster.local:8200/v1/pki/ca" \
  crl_distribution_points="https://vault.vault.svc.cluster.local:8200/v1/pki/crl"
# 공인 zone(imcherry5778.xyz)은 넣지 않는다. Vault PKI로 공인 관리 인증서를 대체하지 않는다.
vault write pki/roles/internal-workload \
  allowed_domains="svc.cluster.local,cluster.local" \
  allow_subdomains=true allow_bare_domains=false allow_glob_domains=false \
  allow_any_name=false enforce_hostnames=true allow_ip_sans=false \
  key_type=ec key_bits=256 ttl=72h max_ttl=720h
EOF

echo "== 6. PostgreSQL database engine =="
# 비밀번호는 Pod 안 임시 파일로만 전달하고 즉시 지운다.
tr -d '\n' < "$PG_VAULT_PASSWORD_FILE" | ssh -o BatchMode=yes "$K3S_HOST" \
  "$KUBECTL -n vault exec -i vault-0 -- sh -c 'umask 077; cat > /tmp/pg.pw'"

vault_exec <<'EOF'
vault secrets list 2>/dev/null | grep -q '^database/' \
  || vault secrets enable -path=database -description="지원 서비스의 단기 DB 자격증명 (VAULT-02)" database

vault write database/config/postgres-01 \
  plugin_name=postgresql-database-plugin \
  allowed_roles="keycloak" \
  connection_url='postgresql://{{username}}:{{password}}@postgres-01.imcherry5778.xyz:5432/keycloak?sslmode=verify-full&sslrootcert=/vault/userconfig/postgres-ca/postgres-01.crt' \
  username="vault_admin" \
  password=@/tmp/pg.pw

# 사람이 아는 비밀번호를 즉시 폐기한다. 이후로는 Vault만 이 자격증명을 안다.
vault write -f database/rotate-root/postgres-01

vault write database/roles/keycloak \
  db_name=postgres-01 \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE keycloak_user;" \
  revocation_statements="REVOKE keycloak_user FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl=1h max_ttl=24h

rm -f /tmp/pg.pw
EOF

echo
echo "완료. root token 은 더 이상 필요하지 않다."
echo "vault token revoke -self 로 폐기하고 파일을 shred 한다."
echo "다시 필요하면 Shamir share 3개로 vault operator generate-root 를 쓴다."
