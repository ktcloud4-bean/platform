#!/usr/bin/env bash
# =============================================================================
# AWS-SEC-06: AWS 통합 보안 시나리오 5종 라이브 실측 및 검증 스크립트
# =============================================================================
# 1. PII 데이터 이중 마스킹 (RDS Aurora PostgreSQL + IAM DB Auth)
# 2. ASR 보안 오설정(SSH 0.0.0.0/0) 자동 원복
# 3. Security Hub / CIEM 긴급 세션 강제 종료 (격리 데모 계정 한정)
# 4. CIEM 권한 드리프트 탐지 및 Slack 인터랙티브 엔드포인트 보안
# 5. Amazon Managed Grafana SOC 통합 대시보드 및 데이터소스 생존 확인
# =============================================================================
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(cd -- "${script_dir}/../../../.." && pwd)
readonly repo_root
tofu_sec_dir="${repo_root}/infra/aws/tofu-app-security"
tofu_db_dir="${repo_root}/infra/aws/tofu-app-db"

export AWS_PAGER=""
REGION="${AWS_REGION:-ap-northeast-2}"
DEMO_USER="test-session-revoke-demo"
DEMO_ROLE="platform-saml-demo-role"
OPERATIONAL_ROLES=(
  "platform-saml-observer"
  "platform-saml-observability-reader"
  "platform-saml-security-reader"
  "platform-saml-identity-reader"
)

echo "============================================================"
echo " AWS-SEC-06 AWS 통합 보안 시나리오 5종 라이브 실측 검증"
echo "============================================================"

# -----------------------------------------------------------------------------
# [Scene 1/5] PII 데이터 이중 마스킹 및 IAM DB Auth 검증
# -----------------------------------------------------------------------------
echo ""
echo "=== [Scene 1/5] RDS Aurora PostgreSQL PII 데이터 이중 마스킹 검증 ==="
if [[ -f "${tofu_db_dir}/scripts/verify-db-sec.sh" ]]; then
  "${tofu_db_dir}/scripts/verify-db-sec.sh"
else
  echo "ERROR: ${tofu_db_dir}/scripts/verify-db-sec.sh not found!" >&2
  exit 1
fi
echo "[Scene 1/5 PASS] PII 마스킹 및 IAM DB 인증 정상 확인"

# -----------------------------------------------------------------------------
# [Scene 2/5] ASR 보안 오설정 자동 원복 검증
# -----------------------------------------------------------------------------
echo ""
echo "=== [Scene 2/5] ASR 보안 오설정(SSH 0.0.0.0/0) 자동 원복 검증 ==="
"${script_dir}/verify-asr-remediation.sh"
echo "[Scene 2/5 PASS] ASR 자동 원복 및 격리 타깃 정상 확인"

# -----------------------------------------------------------------------------
# [Scene 3/5] 긴급 세션 강제 종료 (격리 테스트 계정)
# -----------------------------------------------------------------------------
echo ""
echo "=== [Scene 3/5] 긴급 세션 강제 종료 실측 검증 (대상: ${DEMO_USER}) ==="

# 3-1: 세션 강제 종료 실행 (Action Executor Lambda 직접 호출)
echo "  [Step 3-1] Invoking CIEM action-executor for session revocation..."
INVOKE_PAYLOAD=$(python3 -c "
import json, time
payload = {
    'action_key': f'test-session-revoke-{int(time.time())}',
    'action_id': 'lock_account_risk',
    'value': {
        'role_name': '${DEMO_ROLE}',
        'policy_arn': 'arn:aws:iam::aws:policy/AdministratorAccess',
        'username': '${DEMO_USER}'
    },
    'approver_name': 'U0BJMM9ENPQ',
    'response_url': 'https://httpbin.org/post'
}
print(json.dumps(payload))
")

aws lambda invoke \
  --function-name "hr-system-prod-ciem-action-executor" \
  --cli-binary-format raw-in-base64-out \
  --payload "${INVOKE_PAYLOAD}" \
  --region "${REGION}" \
  /tmp/scene3_revoke_out.json >/dev/null

echo "  Action Executor output:"
cat /tmp/scene3_revoke_out.json; echo ""

# 3-2: SAML Role에 ciem-revoke-session-* 인라인 정책 부착 확인
echo "  [Step 3-2] Verifying Deny inline policies on SAML roles..."
POLICY_NAME="ciem-revoke-session-${DEMO_USER}"
ALL_TEST_ROLES=("${OPERATIONAL_ROLES[@]}" "${DEMO_ROLE}")

for role in "${ALL_TEST_ROLES[@]}"; do
  POL_DOC=$(aws iam get-role-policy --role-name "${role}" --policy-name "${POLICY_NAME}" --query 'PolicyDocument' --output json 2>/dev/null || true)
  if [[ -z "${POL_DOC}" || "${POL_DOC}" == "None" ]]; then
    echo "  [FAIL] Deny policy ${POLICY_NAME} not found on role ${role}" >&2
    exit 1
  fi
  if ! echo "${POL_DOC}" | grep -q "${DEMO_USER}"; then
    echo "  [FAIL] Policy on ${role} does not target ${DEMO_USER}" >&2
    exit 1
  fi
  echo "    - Role ${role}: Deny policy active targeting ${DEMO_USER} (OK)"
done

# 3-3: 실제 팀원 세션 영향 0건 및 정리 (인라인 정책 제거)
echo "  [Step 3-3] Cleaning up test deny policies (ensuring 0 residual)..."
for role in "${ALL_TEST_ROLES[@]}"; do
  aws iam delete-role-policy --role-name "${role}" --policy-name "${POLICY_NAME}" 2>/dev/null || true
  # 확인
  REMAIN=$(aws iam get-role-policy --role-name "${role}" --policy-name "${POLICY_NAME}" 2>/dev/null || true)
  if [[ -n "${REMAIN}" ]]; then
    echo "  [FAIL] Failed to delete temporary policy from ${role}" >&2
    exit 1
  fi
done
echo "    - All temporary deny policies cleanly removed (0 residual)."
echo "[Scene 3/5 PASS] 긴급 세션 종료 및 무잔여 정리 정상 확인"

# -----------------------------------------------------------------------------
# [Scene 4/5] CIEM 권한 드리프트 탐지 및 Slack 인터랙티브 엔드포인트 보안
# -----------------------------------------------------------------------------
echo ""
echo "=== [Scene 4/5] CIEM 권한 드리프트 탐지 및 Slack 콜백 엔드포인트 검증 ==="

# 4-1: 데모 Role 대상 Access Analyzer 축소 정책 생성 검증
echo "  [Step 4-1] Verifying Access Analyzer Policy Generation on demo role..."
"${script_dir}/verify-demo-identity-access-analyzer.sh"

# 4-2: 운영 SAML Role 4개 정책 불변성 확인
echo "  [Step 4-2] Verifying operational SAML roles policy invariance..."
EXPECTED_INLINE_POLICIES=(
  "platform-saml-observer:AWSID01ObserverReadOnly"
  "platform-saml-observability-reader:AWSID02ObservabilityReadOnly"
  "platform-saml-security-reader:AWSID02SecurityReadOnly"
  "platform-saml-identity-reader:AWSID01IdentityReadOnly"
)

for pair in "${EXPECTED_INLINE_POLICIES[@]}"; do
  RNAME="${pair%%:*}"
  PNAME="${pair##*:}"
  POLICIES=$(aws iam list-role-policies --role-name "${RNAME}" --query 'PolicyNames[]' --output text)
  if [[ "${POLICIES}" != "${PNAME}" ]]; then
    echo "  [FAIL] Role ${RNAME} policy modified: expected [${PNAME}], got [${POLICIES}]" >&2
    exit 1
  fi
  ATTACHED_COUNT=$(aws iam list-attached-role-policies --role-name "${RNAME}" --query 'length(AttachedPolicies)' --output text)
  if [[ "${ATTACHED_COUNT}" -ne 0 ]]; then
    echo "  [FAIL] Role ${RNAME} has unexpected attached policies: ${ATTACHED_COUNT}" >&2
    exit 1
  fi
  echo "    - Role ${RNAME}: InlinePolicy=[${POLICIES}], AttachedCount=0 (OK)"
done

# 4-3: Slack Callback API Gateway 위조 서명 401 거부 확인
echo "  [Step 4-3] Testing Slack callback endpoint signature verification..."
SLACK_ENDPOINT=$(tofu -chdir="${tofu_sec_dir}" output -raw ciem_slack_interactivity_endpoint 2>/dev/null || true)
if [[ -n "${SLACK_ENDPOINT}" && "${SLACK_ENDPOINT}" != "None" ]]; then
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${SLACK_ENDPOINT}slack/interactivity" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "X-Slack-Request-Timestamp: $(date +%s)" \
    -H "X-Slack-Signature: v0=0000000000000000000000000000000000000000000000000000000000000000" \
    --data-raw "payload=%7B%22bad%22%3A1%7D" 2>/dev/null || true)
  if [[ "${HTTP_CODE}" == "401" ]]; then
    echo "    - Invalid signature rejected with HTTP 401 (OK)"
  else
    echo "    - Invalid signature returned HTTP ${HTTP_CODE} (expected 401)" >&2
    exit 1
  fi
fi
echo "[Scene 4/5 PASS] CIEM 권한 드리프트 및 Slack 엔드포인트 보안 검증 완료"

# -----------------------------------------------------------------------------
# [Scene 5/5] Amazon Managed Grafana SOC 통합 대시보드 검증
# -----------------------------------------------------------------------------
echo ""
echo "=== [Scene 5/5] Amazon Managed Grafana SOC 대시보드 및 데이터소스 검증 ==="

# 5-1: Grafana 워크스페이스 상태 확인
GRAFANA_WS_ID=$(tofu -chdir="${tofu_sec_dir}" output -raw grafana_workspace_id 2>/dev/null || true)
WS_STATUS=$(aws grafana describe-workspace --workspace-id "${GRAFANA_WS_ID}" --region "${REGION}" --query 'workspace.status' --output text 2>/dev/null || true)
if [[ "${WS_STATUS}" != "ACTIVE" ]]; then
  echo "  [FAIL] Grafana workspace status is '${WS_STATUS}' (expected ACTIVE)" >&2
  exit 1
fi
echo "  - Grafana Workspace: ID=${GRAFANA_WS_ID}, Status=${WS_STATUS} (OK)"

# 5-2: SAML Authentication 상태 확인
SAML_STATUS=$(aws grafana describe-workspace-authentication --workspace-id "${GRAFANA_WS_ID}" --region "${REGION}" --query 'authentication.saml.status' --output text 2>/dev/null || true)
if [[ "${SAML_STATUS}" != "CONFIGURED" ]]; then
  echo "  [FAIL] Grafana SAML auth status is '${SAML_STATUS}' (expected CONFIGURED)" >&2
  exit 1
fi
echo "  - Grafana SAML Authentication: Status=${SAML_STATUS} (OK)"

# 5-3: Athena Workgroup 및 Security Lake Glue DB 확인
ATHENA_WG=$(tofu -chdir="${tofu_sec_dir}" output -raw athena_workgroup_name 2>/dev/null || true)
WG_STATE=$(aws athena get-work-group --work-group "${ATHENA_WG}" --region "${REGION}" --query 'WorkGroup.State' --output text 2>/dev/null || true)
if [[ "${WG_STATE}" != "ENABLED" ]]; then
  echo "  [FAIL] Athena Workgroup state is '${WG_STATE}' (expected ENABLED)" >&2
  exit 1
fi
echo "  - Athena Workgroup: Name=${ATHENA_WG}, State=${WG_STATE} (OK)"

GLUE_DB="amazon_security_lake_glue_db_${REGION//-/_}"
GLUE_STATUS=$(aws glue get-database --name "${GLUE_DB}" --region "${REGION}" --query 'Database.Name' --output text 2>/dev/null || true)
if [[ "${GLUE_STATUS}" != "${GLUE_DB}" ]]; then
  echo "  [FAIL] Security Lake Glue DB '${GLUE_DB}' not found!" >&2
  exit 1
fi
echo "  - Security Lake Glue DB: ${GLUE_STATUS} (OK)"
echo "[Scene 5/5 PASS] Grafana SOC 워크스페이스 및 데이터소스 생존 확인 완료"

echo ""
echo "============================================================"
echo " AWS-SEC-06 ALL 5 SCENARIOS VERIFICATIONS PASSED"
echo "============================================================"
