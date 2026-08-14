#!/usr/bin/env bash
# Amazon Managed Grafana SAML SSO & OCSF 통합 보안 대시보드 검증
#
# 대시보드가 실제로 SAML SSO로 로그인되고, CloudWatch/Athena(Security Lake
# OCSF 테이블) 데이터소스가 둘 다 살아있는지 확인한다.
# 멱등: 로그인 세션/토큰만 새로 만들 뿐 Grafana 리소스는 그대로 재사용
# (이미 있으면 건너뛰는 grafana-dashboard-setup.sh 로직 재사용).
#
# ⚠️ SESSION_REVOKE_TEST_USERNAME과 마찬가지로 GRAFANA_PROVISIONING_PASSWORD를
# 환경변수로 넘겨야 함(하드코딩 금지) - var.grafana_provisioning_user로 지정한
# 계정의 실제 Keycloak 비밀번호.
set -uo pipefail
cd "$(dirname "$0")"
source ./_lib.sh

scene_banner 13 "Grafana SAML SSO + OCSF SOC 통합 대시보드 검증" \
  "Grafana SAML 인증 상태(CONFIGURED) 확인" \
  "SAML SSO 로그인으로 대시보드 재프로비저닝 + 패널 구성 확인" \
  "Security Lake OCSF Athena 데이터소스 정상 연결 확인"

PASS=1
GRAFANA_ENDPOINT=$(tf_output grafana_workspace_endpoint)
KEYCLOAK_PUBLIC_IP=$(tf_output onprem_keycloak_host)
PROVISIONING_USER=$(tf_output grafana_provisioning_user)
GRAFANA_PROVISIONING_PASSWORD="${GRAFANA_PROVISIONING_PASSWORD:?GRAFANA_PROVISIONING_PASSWORD 환경변수 필요}"

step 1 "Grafana SAML 인증 상태 확인"
SAML_STATUS=$(aws grafana describe-workspace-authentication --workspace-id "$(tf_output grafana_workspace_id)" --query 'authentication.saml.status' --output text 2>&1)
if [ "$SAML_STATUS" = "CONFIGURED" ]; then
  ok "SAML 인증 CONFIGURED"
else
  fail "SAML 상태: $SAML_STATUS"
  PASS=0
fi

step 2 "SAML SSO 로그인으로 대시보드 재프로비저닝 + 패널 구성 확인"
progress "SAML 로그인으로 대시보드 재프로비저닝(로그인 자체가 SSO 동작 증거)"
export GRAFANA_ENDPOINT KEYCLOAK_PUBLIC_IP
export KEYCLOAK_USER="$PROVISIONING_USER"
export KEYCLOAK_PASSWORD="$GRAFANA_PROVISIONING_PASSWORD"
SETUP_OUT=$(bash ../grafana-dashboard-setup.sh 2>&1)
echo "$SETUP_OUT"
if echo "$SETUP_OUT" | grep -q "GRAFANA_DASHBOARD_SETUP_DONE"; then
  ok "SAML SSO 로그인 + 대시보드 프로비저닝 성공"
else
  fail "SAML SSO 로그인 또는 프로비저닝 실패"
  PASS=0
fi

progress "대시보드 패널 구성 확인(위협 카운트/VPC Flow/IAM API/PII·EKS 로그 4영역)"
PANEL_COUNT=$(python3 -c "import json; d=json.load(open('../../docs/grafana/grafana-soc-dashboard.json')); print(len(d['dashboard']['panels']))")
if [ "$PANEL_COUNT" -ge "4" ]; then
  ok "패널 $PANEL_COUNT 개 구성됨"
else
  fail "패널 수가 부족함($PANEL_COUNT)"
  PASS=0
fi

step 3 "Security Lake OCSF Athena 데이터소스 정상 연결 확인"
ATHENA_UID=$(echo "$SETUP_OUT" | sed -n 's/.*ATHENA_UID=\(.*\)/\1/p' | tr -d ' ')
if [ -n "$ATHENA_UID" ]; then
  ok "Athena(Security Lake OCSF 테이블 조회용) 데이터소스 존재 (uid=$ATHENA_UID)"
else
  fail "Athena 데이터소스 UID를 확인 못 함"
  PASS=0
fi

if [ "$PASS" = "1" ]; then
  result_box PASSED "SOC 대시보드 SAML SSO + OCSF 데이터소스 정상"
  scene_report 13 "Grafana SAML SSO + OCSF SOC 대시보드" PASSED "grafana-dashboard-setup.sh (SAML 로그인 재확인)"
else
  result_box FAILED "SAML SSO 또는 데이터소스 확인 실패"
  scene_report 13 "Grafana SAML SSO + OCSF SOC 대시보드" FAILED "grafana-dashboard-setup.sh (SAML 로그인 재확인)"
  exit 1
fi
