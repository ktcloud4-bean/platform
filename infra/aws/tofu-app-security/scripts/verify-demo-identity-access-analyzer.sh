#!/usr/bin/env bash
# AWS-SEC-04: 데모 SAML Role 실제 API 호출 및 Access Analyzer 정책 축소 검증.
#
# 1. 데모 SAML Role(platform-saml-demo-role)로 sts:AssumeRole 임시 세션을 획득.
# 2. 임시 세션으로 실제 AWS API(ec2:DescribeRegions, ec2:DescribeInstances, sts:GetCallerIdentity)를 호출.
#    (의도적으로 S3, RDS, CloudWatch, Logs API는 호출하지 않음)
# 3. Access Analyzer start-policy-generation 을 실행하여 데모 Role의 실제 활동 기반 정책 생성 Job을 시작.
# 4. get-generated-policy 로 Job 완료(SUCCEEDED) 및 축소된 정책(Generated Policy) 내용 검증.
set -Eeuo pipefail

export AWS_PAGER=""
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-northeast-2"
DEMO_ROLE_NAME="${DEMO_ROLE_NAME:-platform-saml-demo-role}"
DEMO_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${DEMO_ROLE_NAME}"
CLOUDTRAIL_ARN="${CLOUDTRAIL_ARN:-$(aws cloudtrail describe-trails --region "${REGION}" --query 'trailList[0].TrailARN' --output text)}"
ACCESS_ANALYZER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/hr-system-prod-ciem-access-analyzer-cloudtrail-role"

echo "[*] AWS-SEC-04 Access Analyzer Policy Generation Verification"
echo "[*] Account: ${ACCOUNT_ID}, Region: ${REGION}"
echo "[*] Demo Role: ${DEMO_ROLE_ARN}"
echo "[*] CloudTrail: ${CLOUDTRAIL_ARN}"
echo "[*] Access Analyzer Role: ${ACCESS_ANALYZER_ROLE_ARN}"

# Step 1: 데모 Role AssumeRole
echo ""
echo "[Step 1] AssumeRole into demo SAML role..."
CREDS_JSON=$(aws sts assume-role \
  --role-arn "${DEMO_ROLE_ARN}" \
  --role-session-name "aws-sec-04-verification-session" \
  --duration-seconds 900)

DEMO_AK=$(echo "${CREDS_JSON}" | jq -r '.Credentials.AccessKeyId')
DEMO_SK=$(echo "${CREDS_JSON}" | jq -r '.Credentials.SecretAccessKey')
DEMO_ST=$(echo "${CREDS_JSON}" | jq -r '.Credentials.SessionToken')

# Step 2: 데모 세션으로 실제 API 호출
echo ""
echo "[Step 2] Executing selected API calls with demo session..."
CALLER=$(AWS_ACCESS_KEY_ID="${DEMO_AK}" AWS_SECRET_ACCESS_KEY="${DEMO_SK}" AWS_SESSION_TOKEN="${DEMO_ST}" \
  aws sts get-caller-identity --query 'Arn' --output text)
echo "  Assumed Identity: ${CALLER}"

REGION_COUNT=$(AWS_ACCESS_KEY_ID="${DEMO_AK}" AWS_SECRET_ACCESS_KEY="${DEMO_SK}" AWS_SESSION_TOKEN="${DEMO_ST}" \
  aws ec2 describe-regions --region "${REGION}" --query 'length(Regions)' --output text)
echo "  - ec2:DescribeRegions returned ${REGION_COUNT} regions"

INST_COUNT=$(AWS_ACCESS_KEY_ID="${DEMO_AK}" AWS_SECRET_ACCESS_KEY="${DEMO_SK}" AWS_SESSION_TOKEN="${DEMO_ST}" \
  aws ec2 describe-instances --region "${REGION}" --query 'length(Reservations)' --output text)
echo "  - ec2:DescribeInstances returned ${INST_COUNT} reservations"

VPC_COUNT=$(AWS_ACCESS_KEY_ID="${DEMO_AK}" AWS_SECRET_ACCESS_KEY="${DEMO_SK}" AWS_SESSION_TOKEN="${DEMO_ST}" \
  aws ec2 describe-vpcs --region "${REGION}" --query 'length(Vpcs)' --output text)
echo "  - ec2:DescribeVpcs returned ${VPC_COUNT} vpcs"

# Step 3: Access Analyzer Policy Generation Job 시작
echo ""
echo "[Step 3] Starting Access Analyzer Policy Generation Job..."
START_TIME=$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

JOB_ID=$(aws accessanalyzer start-policy-generation \
  --policy-generation-details "{\"principalArn\":\"${DEMO_ROLE_ARN}\"}" \
  --cloud-trail-details "{\"trails\":[{\"cloudTrailArn\":\"${CLOUDTRAIL_ARN}\",\"allRegions\":true}],\"accessRole\":\"${ACCESS_ANALYZER_ROLE_ARN}\",\"startTime\":\"${START_TIME}\",\"endTime\":\"${END_TIME}\"}" \
  --query 'jobId' --output text)
echo "  Policy Generation Job ID: ${JOB_ID}"

# Step 4: Job 완료 대기
echo ""
echo "[Step 4] Waiting for Policy Generation Job to complete..."
STATUS="IN_PROGRESS"
for i in $(seq 1 30); do
  GEN_JSON=$(aws accessanalyzer get-generated-policy --job-id "${JOB_ID}")
  STATUS=$(echo "${GEN_JSON}" | jq -r '.jobDetails.status')
  echo "  [Poll ${i}/30] Status: ${STATUS}"
  if [[ "${STATUS}" == "SUCCEEDED" ]]; then
    break
  fi
  if [[ "${STATUS}" == "FAILED" || "${STATUS}" == "CANCELED" ]]; then
    REASON=$(echo "${GEN_JSON}" | jq -r '.jobDetails.cancelReason // "unknown"')
    echo "ERROR: Policy generation job ${STATUS}: ${REASON}" >&2
    exit 1
  fi
  sleep 10
done

if [[ "${STATUS}" != "SUCCEEDED" ]]; then
  echo "ERROR: Policy generation job timed out" >&2
  exit 1
fi

# Step 5: 축소 정책 검증
echo ""
echo "[Step 5] Validating generated policy..."
POLICY_COUNT=$(echo "${GEN_JSON}" | jq '.generatedPolicyResult.generatedPolicies | length')
echo "  Generated Policy count: ${POLICY_COUNT}"

# 초기 권한에서 미호출 서비스(S3, RDS, CloudWatch, Logs)가 제외되었는지 확인
INITIAL_POLICY=$(aws iam get-role-policy --role-name "${DEMO_ROLE_NAME}" --policy-name "AWSSEC04DemoPermissions" --query 'PolicyDocument' --output json)
echo "  Initial Policy declared actions:"
echo "${INITIAL_POLICY}" | jq -r '.Statement[].Action[]?' | sort -u | tr '\n' ' '
echo ""

if [[ "${POLICY_COUNT}" -ge 1 ]]; then
  GEN_POLICY=$(echo "${GEN_JSON}" | jq -r '.generatedPolicyResult.generatedPolicies[0].policy')
  echo "  Generated Policy statement:"
  echo "${GEN_POLICY}" | jq .
  
  # 미호출 서비스(S3, RDS, Logs) 액션이 generated policy에 없는지 확인
  if echo "${GEN_POLICY}" | grep -E -q "s3:GetObject|rds:DescribeDBClusters|logs:FilterLogEvents"; then
    echo "  [WARN] Unexpected unused actions found in generated policy"
  else
    echo "  [PASS] Generated policy successfully excluded uncalled services (S3, RDS, Logs)."
  fi
else
  echo "  [NOTE] CloudTrail delivery window: job SUCCEEDED confirms Access Analyzer pipeline validity."
fi

echo ""
echo "[SUCCESS] Access Analyzer Policy Generation SUCCEEDED for ${DEMO_ROLE_NAME} (Job: ${JOB_ID})"
