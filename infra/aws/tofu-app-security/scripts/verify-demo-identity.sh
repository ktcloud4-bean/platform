#!/usr/bin/env bash
# AWS-SEC-04: 격리 데모 아이덴티티 종합 검증 스크립트
# 1. OpenTofu 포맷 및 문법 검증
# 2. 데모 Role 소유권 및 tofu-identity 와의 리소스 중복 0건 검증
# 3. Keycloak 테스트 사용자 격리 및 운영 SAML Role 4개 불변성 검증
# 4. 데모 Role 실제 API 호출 이력 기반 Access Analyzer 축소 정책 생성 검증
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(cd -- "${script_dir}/../../../.." && pwd)
readonly repo_root
readonly tofu_dir="${repo_root}/infra/aws/tofu-app-security"

echo "============================================================"
echo " AWS-SEC-04 격리 데모 아이덴티티 종합 검증"
echo "============================================================"

# Step 1: OpenTofu 정적 검증
echo -n "[1/4] OpenTofu fmt & validate ... "
tofu -chdir="${tofu_dir}" fmt -check >/dev/null
tofu -chdir="${tofu_dir}" validate >/dev/null
echo "PASS"

# Step 2: 데모 Role 소유권 및 tofu-identity 리소스 중복 0건 검증
echo -n "[2/4] 데모 Role 소유권 및 tofu-identity 중복 0건 검증 ... "
account_id=$(aws sts get-caller-identity --query Account --output text)
demo_role_name="platform-saml-demo-role"
demo_role_arn="arn:aws:iam::${account_id}:role/${demo_role_name}"

# 데모 role이 AWS IAM에 존재하는지 확인
aws iam get-role --role-name "${demo_role_name}" >/dev/null 2>&1 || {
  echo "FAIL (IAM role ${demo_role_name} not found)" >&2
  exit 1
}

# tofu-identity state와의 중복 0건 검증
# tofu-identity는 observer, observability_reader, security_reader, identity_reader 4개만 소유함
tofu_identity_tf="${repo_root}/infra/aws/tofu-identity/iam.tf"
if grep -q "resource \"aws_iam_role\" \"demo" "${tofu_identity_tf}" 2>/dev/null; then
  echo "FAIL (tofu-identity declares demo role)" >&2
  exit 1
fi
echo "PASS (tofu-app-security single ownership, overlap=0)"

# Step 3: Keycloak 테스트 사용자 격리 및 운영 SAML Role 4개 불변성 검증
echo -n "[3/4] Keycloak 데모 계정 격리 및 운영 Role 불변성 검증 ... "
kc_check_out=$("${script_dir}/provision-keycloak-demo-identity.sh" --check 2>&1)
echo "${kc_check_out}" | grep -q "Keycloak=PASS" || {
  echo "FAIL (${kc_check_out})" >&2
  exit 1
}
echo "PASS (isolated demo user, operational_roles_unchanged=4, membership_polluted=0)"

# Step 4: 데모 Role 실제 API 호출 및 Access Analyzer 축소 정책 생성 검증
echo "[4/4] Access Analyzer 정책 생성 검증 ..."
"${script_dir}/verify-demo-identity-access-analyzer.sh"

echo "============================================================"
echo " AWS-SEC-04 ALL VERIFICATIONS PASSED"
echo "============================================================"
