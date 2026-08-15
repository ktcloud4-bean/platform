#!/usr/bin/env bash
# =============================================================================
# AWS-DB-SEC-01: HR Aurora IAM DB 인증 및 PII 마스킹 뷰 종합 실측 검증 스크립트
# =============================================================================
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(cd -- "${script_dir}/../../../.." && pwd)
readonly repo_root
tofu_dir="${repo_root}/infra/aws/tofu-app-db"
readonly tofu_dir

export AWS_PAGER=""
REGION="${AWS_REGION:-ap-northeast-2}"
FUNCTION_NAME="hr-system-prod-db-sec-verifier"
ROLE_NAME="hr-system-prod-db-sec-verifier-role"

echo "============================================================"
echo " AWS-DB-SEC-01 Aurora IAM DB 인증 및 PII 마스킹 검증"
echo "============================================================"

# Step 1: OpenTofu 정적 검증
echo -n "[1/5] OpenTofu fmt & validate ... "
tofu -chdir="${tofu_dir}" fmt -check >/dev/null
tofu -chdir="${tofu_dir}" validate >/dev/null
echo "PASS"

# Step 2: OpenTofu output 및 IAM Auth 라이브 상태 확인
echo "[2/5] Aurora 클러스터 및 IAM Database Authentication 상태 확인 ..."
CLUSTER_RESOURCE_ID=$(tofu -chdir="${tofu_dir}" output -raw aurora_cluster_resource_id 2>/dev/null || aws rds describe-db-clusters --db-cluster-identifier hr-system-prod-aurora --region "${REGION}" --query 'DBClusters[0].DbClusterResourceId' --output text)
DB_HOST=$(tofu -chdir="${tofu_dir}" output -raw aurora_writer_endpoint 2>/dev/null || aws rds describe-db-clusters --db-cluster-identifier hr-system-prod-aurora --region "${REGION}" --query 'DBClusters[0].Endpoint' --output text)
MASTER_SECRET_ARN=$(tofu -chdir="${tofu_dir}" output -raw aurora_master_user_secret_arn 2>/dev/null || true)

echo "  - DB Host: ${DB_HOST}"
echo "  - Cluster Resource ID: ${CLUSTER_RESOURCE_ID}"
echo "  - Master Secret ARN: ${MASTER_SECRET_ARN}"

IAM_AUTH=$(aws rds describe-db-clusters --db-cluster-identifier hr-system-prod-aurora --region "${REGION}" --query 'DBClusters[0].IAMDatabaseAuthenticationEnabled' --output text)
if [[ "${IAM_AUTH}" != "True" && "${IAM_AUTH}" != "true" ]]; then
  echo "  [FAIL] IAMDatabaseAuthenticationEnabled is '${IAM_AUTH}' (expected True)" >&2
  exit 1
fi
echo "  [PASS] IAMDatabaseAuthenticationEnabled=True (무중단 Dynamic 적용 확인)"

# Step 3: VPC Lambda 패키징 및 실행 환경 준비
echo "[3/5] VPC 내부 실측용 검증 Lambda 패키징 및 배포 ..."
PKG_DIR=$(mktemp -d)
ZIP_FILE="/tmp/db_sec_verifier.zip"

cleanup() {
  echo "Cleaning up temporary verification resources..."
  aws lambda delete-function --function-name "${FUNCTION_NAME}" --region "${REGION}" >/dev/null 2>&1 || true
  rm -rf "${PKG_DIR}" "${ZIP_FILE}" /tmp/lambda_res.json
}
trap cleanup EXIT INT TERM

# 의존성 복사
pip install --target "${PKG_DIR}" pg8000 -q
cp "${script_dir}/apply_and_verify_masking.py" "${PKG_DIR}/lambda_function.py"
(cd "${PKG_DIR}" && zip -rq "${ZIP_FILE}" .)

# Lambda IAM Role 준비
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text 2>/dev/null || true)

if [[ -z "${ROLE_ARN}" || "${ROLE_ARN}" == "None" ]]; then
  ROLE_ARN=$(aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --query 'Role.Arn' --output text)
  
  aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  aws iam put-role-policy --role-name "${ROLE_NAME}" --policy-name "db-sec-verifier-permissions" \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\"],\"Resource\":\"*\"},{\"Effect\":\"Allow\",\"Action\":[\"rds-db:connect\"],\"Resource\":\"arn:aws:rds-db:${REGION}:${ACCOUNT_ID}:dbuser:${CLUSTER_RESOURCE_ID}/*\"}]}"
  sleep 10
fi

# Lambda 함수 생성 또는 업데이트
aws lambda delete-function --function-name "${FUNCTION_NAME}" --region "${REGION}" >/dev/null 2>&1 || true
sleep 3

SUBNET_IDS="subnet-0fa9786237198b292,subnet-08253642ad812c438"
SG_ID="sg-07e987531293b5cd4" # hr-system-prod-eks-nodes-sg

aws lambda create-function \
  --function-name "${FUNCTION_NAME}" \
  --runtime "python3.12" \
  --role "${ROLE_ARN}" \
  --handler "lambda_function.handler" \
  --zip-file "fileb://${ZIP_FILE}" \
  --timeout 60 \
  --vpc-config "SubnetIds=${SUBNET_IDS},SecurityGroupIds=${SG_ID}" \
  --environment "Variables={DB_HOST=${DB_HOST},DB_PORT=5432,DB_NAME=hr_system,MASTER_SECRET_ARN=${MASTER_SECRET_ARN},NAME_PREFIX=hr-system-prod}" \
  --region "${REGION}" >/dev/null

echo "  Waiting for Lambda function to become Active..."
aws lambda wait function-active-v2 --function-name "${FUNCTION_NAME}" --region "${REGION}"

# Step 4: 실측 실행 및 결과 파싱
echo "[4/5] SQL 마스킹 뷰 적용 및 IAM DB 토큰 접속 실측 실행 ..."
aws lambda invoke \
  --function-name "${FUNCTION_NAME}" \
  --payload '{}' \
  --region "${REGION}" \
  /tmp/lambda_res.json >/dev/null

if ! grep -q '"statusCode": 200' /tmp/lambda_res.json; then
  echo "  [FAIL] Lambda execution failed:" >&2
  cat /tmp/lambda_res.json >&2
  exit 1
fi

echo "  Lambda execution output:"
cat /tmp/lambda_res.json | jq '.results'

# Step 5: 상세 검증 항목 판정
echo "[5/5] 4대 검증 항목 상세 판정 ..."
RESULTS=$(cat /tmp/lambda_res.json | jq -r '.results')

# 1. 마스터 SQL 적용
SQL_APPLIED=$(echo "${RESULTS}" | jq -r '.master_applied_sql')
if [[ "${SQL_APPLIED}" != "true" ]]; then
  echo "  [FAIL] Master SQL apply failed" >&2
  exit 1
fi
echo "  - 마스킹 뷰 및 IAM 역할 SQL 적용: OK"

# 2. 기존 애플리케이션 무중단
APP_UNBROKEN=$(echo "${RESULTS}" | jq -r '.existing_apps_unbroken')
EMP_COUNT=$(echo "${RESULTS}" | jq -r '.employee_count')
if [[ "${APP_UNBROKEN}" != "true" ]]; then
  echo "  [FAIL] Existing application connection broken" >&2
  exit 1
fi
echo "  - 기존 앱(employee_service) 접속 무중단: OK (직원 수: ${EMP_COUNT}명 정상 조회)"

# 3. general_user_readonly 검증
GEN_DENIED=$(echo "${RESULTS}" | jq -r '.general_user_direct_table_denied')
GEN_MASKED=$(echo "${RESULTS}" | jq -r '.general_user_salary_null_masked')
GEN_HIST=$(echo "${RESULTS}" | jq -r '.general_user_history_masked')

if [[ "${GEN_DENIED}" != "true" || "${GEN_MASKED}" != "true" || "${GEN_HIST}" != "true" ]]; then
  echo "  [FAIL] general_user_readonly verification failed (Denied=${GEN_DENIED}, SalaryNull=${GEN_MASKED}, HistMasked=${GEN_HIST})" >&2
  exit 1
fi
echo "  - general_user_readonly: 원본 테이블 거부=OK, salary NULL 마스킹=OK, 변경이력 '****' 마스킹=OK"

# 4. security_auditor_readonly 검증
AUD_DENIED=$(echo "${RESULTS}" | jq -r '.auditor_user_direct_table_denied')
AUD_VISIBLE=$(echo "${RESULTS}" | jq -r '.auditor_user_salary_visible')

if [[ "${AUD_DENIED}" != "true" || "${AUD_VISIBLE}" != "true" ]]; then
  echo "  [FAIL] security_auditor_readonly verification failed (Denied=${AUD_DENIED}, SalaryVisible=${AUD_VISIBLE})" >&2
  exit 1
fi
echo "  - security_auditor_readonly: 원본 테이블 거부=OK, salary 원본 조회=OK"

echo "============================================================"
echo " AWS-DB-SEC-01 ALL EVIDENCE VERIFICATIONS PASSED"
echo "============================================================"
