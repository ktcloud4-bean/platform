#!/usr/bin/env bash
# IAM Access Analyzer Policy Generation 수동 실행 스크립트.
# 지정한 SAML Role이 최근 N시간 동안 실제로 어떤 AWS API를 호출했는지
# CloudTrail 기록을 바탕으로 분석해서, "실제로 쓴 권한만" 담은 정책을
# 만들어준다. terraform apply 때 쓴 것과 동일한(관리자 권한이 있는) AWS
# 자격증명으로 실행할 것 - Role 자체는 이 분석을 실행할 권한이 없다.
#
# 사용법:
#   ./scripts/check-unused-permissions.sh <role-key> [시간(기본 3)]
#
# 예시:
#   ./scripts/check-unused-permissions.sh observer
#   ./scripts/check-unused-permissions.sh security-reader 6
#
# role-key: observer / observability-reader / security-reader / identity-reader
#
# 사전 조건: 이 Role로 Keycloak SSO를 통해 실제 작업을 최소 한 번은
# 해본 뒤에 실행해야 의미 있는 결과가 나온다(안 써봤으면 텅 빈 결과가 나옴).
set -euo pipefail

ROLE_KEY="${1:?사용법: $0 <role-key> [시간(기본 3)]}"
HOURS="${2:-3}"
REGION="${AWS_REGION:-ap-northeast-2}"
ROLE_NAME="platform-saml-${ROLE_KEY}"

echo "==> 계정/리소스 정보 조회 중..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLOUDTRAIL_NAME=$(aws cloudtrail describe-trails --region "$REGION" --query 'trailList[0].Name' --output text)

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
CLOUDTRAIL_ARN="arn:aws:cloudtrail:${REGION}:${ACCOUNT_ID}:trail/${CLOUDTRAIL_NAME}"

if date -u -d "${HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
  START_TIME=$(date -u -d "${HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ")
else
  START_TIME=$(date -u -v-"${HOURS}"H +"%Y-%m-%dT%H:%M:%SZ")
fi
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "==> 분석 대상 Role : ${ROLE_ARN}"
echo "==> 분석 구간      : ${START_TIME} ~ ${END_TIME} (최근 ${HOURS}시간)"
echo ""

echo "==> Policy Generation 작업 시작..."
JOB_ID=$(aws accessanalyzer start-policy-generation \
  --policy-generation-details principalArn="${ROLE_ARN}" \
  --cloud-trail-details "{
    \"trails\": [{\"cloudTrailArn\": \"${CLOUDTRAIL_ARN}\", \"allRegions\": true}],
    \"startTime\": \"${START_TIME}\",
    \"endTime\": \"${END_TIME}\"
  }" \
  --query 'jobId' --output text)

echo "==> Job ID: ${JOB_ID}"
echo "==> 완료 대기 중 (보통 1~3분 걸림)..."

STATUS="IN_PROGRESS"
for i in $(seq 1 30); do
  STATUS=$(aws accessanalyzer get-generated-policy --job-id "${JOB_ID}" --query 'jobDetails.status' --output text)
  if [ "$STATUS" != "IN_PROGRESS" ]; then
    break
  fi
  echo "   아직 진행 중... (${i}/30, 10초 후 재확인)"
  sleep 10
done

if [ "$STATUS" != "SUCCEEDED" ]; then
  echo "❌ 작업이 실패하거나 시간 내에 끝나지 않았습니다 (상태: ${STATUS})"
  echo "   상세 원인 확인:"
  aws accessanalyzer get-generated-policy --job-id "${JOB_ID}"
  exit 1
fi

echo "✅ 완료! 생성된 정책:"
echo ""

OUTPUT_FILE=".build/generated-policy-${ROLE_KEY}.json"
mkdir -p .build
aws accessanalyzer get-generated-policy --job-id "${JOB_ID}" \
  --query 'generatedPolicyResult.generatedPolicies[0].policy' --output text | tee "${OUTPUT_FILE}"

echo ""
echo "==> 결과가 ${OUTPUT_FILE} 에도 저장되었습니다."
echo "==> tofu-identity/iam.tf의 해당 Role 권한 정의와 비교해서, 여기 없는 권한(=실제로 안 쓴 권한)을 검토하세요."
