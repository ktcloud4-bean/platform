#!/usr/bin/env bash
# Security Hub 1-Click → 긴급 세션 강제 종료 검증
#
# ⚠️ project-c는 keycloak-bootstrap.sh.tpl이 만드는 격리된 데모 전용 계정
# (test-session-revoke-demo)을 대상으로 썼다. platform-main엔 그런 데모 계정이
# 없으므로, 아래 USERNAME을 실제로 잠겨도 안전한 격리된 테스트 계정으로
# 반드시 채울 것 - 진짜 사람이 쓰는 계정을 넣으면 그 사람의 AWS 세션과
# Keycloak 로그인이 실제로 강제 종료된다.
set -uo pipefail
cd "$(dirname "$0")"
source ./_lib.sh

USERNAME="${SESSION_REVOKE_TEST_USERNAME:?격리된 테스트 계정명을 SESSION_REVOKE_TEST_USERNAME 환경변수로 넘겨주세요(실제 사용자 계정 금지)}"
NAME_PREFIX=$(tf_output name_prefix)
LAMBDA_NAME="${NAME_PREFIX}-session-revoke"
PASS=1

scene_banner 10 "Security Hub 1-Click → 긴급 세션 강제 종료 검증" \
  "위협 상황 가정: 긴급 세션 종료 Lambda 수동 테스트 이벤트로 직접 호출" \
  "4개 SAML Role에 세션 차단(Deny) 인라인 정책 부착 확인" \
  "Keycloak SSO 세션 강제 로그아웃/계정 비활성화 확인 및 정리"

step 1 "긴급 세션 종료 Lambda 직접 호출"
threat "위협 계정($USERNAME)의 모든 세션을 즉시 강제 종료합니다"
INVOKE_OUT=$(aws lambda invoke --function-name "$LAMBDA_NAME" \
  --payload "$(printf '{"username":"%s"}' "$USERNAME")" \
  --cli-binary-format raw-in-base64-out /tmp/scenario10-out.json 2>&1)
echo "$INVOKE_OUT"
cat /tmp/scenario10-out.json 2>/dev/null; echo

REVOKED_ROLES=$(python3 -c "import json; d=json.load(open('/tmp/scenario10-out.json')); print(len(d.get('revoked_roles',[])))" 2>/dev/null || echo 0)
KC_LOGGED_OUT=$(python3 -c "import json; print(json.load(open('/tmp/scenario10-out.json')).get('keycloak_logged_out'))" 2>/dev/null || echo "unknown")
KC_DISABLED=$(python3 -c "import json; print(json.load(open('/tmp/scenario10-out.json')).get('keycloak_disabled'))" 2>/dev/null || echo "unknown")

step 2 "AWS 세션 차단(Deny 인라인 정책) 확인"
if [ "$REVOKED_ROLES" -ge "1" ] 2>/dev/null; then
  ok "$REVOKED_ROLES 개 Role에 차단 정책이 붙음"
  SAMPLE_ROLE="platform-saml-observer"
  POLICY=$(aws iam get-role-policy --role-name "$SAMPLE_ROLE" --policy-name "revoke-session-$USERNAME" --query 'PolicyDocument' --output json 2>&1)
  if echo "$POLICY" | grep -q "$USERNAME"; then
    ok "정책이 정확히 $USERNAME 세션만 겨냥함(aws:userid 조건 확인)"
  else
    fail "정책 내용에서 대상 사용자를 확인 못 함"
    PASS=0
  fi
else
  fail "차단 정책이 붙은 Role이 0개"
  PASS=0
fi

step 3 "Keycloak SSO 세션 강제 로그아웃 + 계정 비활성화 확인 및 정리"
if [ "$KC_LOGGED_OUT" = "True" ] && [ "$KC_DISABLED" = "True" ]; then
  ok "Keycloak 세션 로그아웃 + 계정 비활성화 성공"
else
  fail "Keycloak 로그아웃/비활성화 실패 또는 확인 불가 (logged_out=$KC_LOGGED_OUT, disabled=$KC_DISABLED)"
  PASS=0
fi

progress "정리: 데모용 차단 정책 제거(반복 검증을 위해) - 4개 SAML Role"
for role in platform-saml-observer platform-saml-observability-reader \
  platform-saml-security-reader platform-saml-identity-reader; do
  aws iam delete-role-policy --role-name "$role" --policy-name "revoke-session-$USERNAME" >/dev/null 2>&1 || true
done
progress "정리: 테스트 계정 Keycloak 재활성화는 이 스크립트가 안 함 - 온프레미스 Keycloak에서 수동으로 enabled=true 되돌릴 것"

rm -f /tmp/scenario10-out.json

if [ "$PASS" = "1" ]; then
  result_box PASSED "위협 계정 세션 즉시 강제 종료 확인"
  scene_report 10 "Security Hub 1-Click 긴급 세션 강제 종료" PASSED "aws lambda invoke ${LAMBDA_NAME}"
else
  result_box FAILED "세션 차단 또는 로그아웃 확인 실패"
  scene_report 10 "Security Hub 1-Click 긴급 세션 강제 종료" FAILED "aws lambda invoke ${LAMBDA_NAME}"
  exit 1
fi
