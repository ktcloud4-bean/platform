#!/usr/bin/env bash
# =============================================================================
# Grafana 전용 Keycloak SAML 클라이언트 + 속성 매퍼(role/email/login/name) 생성
# (25-grafana.tf의 aws_grafana_workspace_saml_configuration 전제조건)
# =============================================================================
# 온프레미스 Keycloak 호스트에서 직접 실행합니다(project-c는 EC2라 SSM
# RunCommand로 자동 실행했지만 여기선 수동). GRAFANA_ENDPOINT는
# `terraform output -raw grafana_workspace_endpoint`로 채울 것.
#
# 아래 클라이언트 속성 조합(saml.client.signature=false, saml.server.signature=true,
# saml_force_name_id_format=true + email/login/name/role 4개 프로토콜 매퍼)은
# 실제 브라우저 로그인이 끝까지 성공하는 것까지 확인된 설정입니다. 각 값이
# 왜 필요한지의 진단 과정은 TROUBLESHOOTING.md의 "Grafana SAML 로그인 -
# 3차례 잘못된 진단 끝에 찾은 원인" 참고.
set -e

# platform-main은 Vault가 admin 자격증명을 소유 - KCADM_ADMIN_USER/PASSWORD를
# 실행 전에 직접 export할 것(Vault CLI로 꺼내오는 방식은 온프레미스 팀 표준에 맞출 것).
KCADM_ADMIN_USER="${KCADM_ADMIN_USER:?KCADM_ADMIN_USER 환경변수 필요}"
KCADM_ADMIN_PASSWORD="${KCADM_ADMIN_PASSWORD:?KCADM_ADMIN_PASSWORD 환경변수 필요}"
REALM_NAME="${REALM_NAME:-platform}"

docker exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user "$KCADM_ADMIN_USER" \
  --password "$KCADM_ADMIN_PASSWORD" \
  2>&1 | tail -3

GRAFANA_ENDPOINT="${GRAFANA_ENDPOINT:?GRAFANA_ENDPOINT 환경변수 필요(예: g-xxxxx.grafana-workspace.<region>.amazonaws.com)}"
ACS_URL="https://${GRAFANA_ENDPOINT}/saml/acs"
ENTITY_ID="https://${GRAFANA_ENDPOINT}/saml/metadata"

EXISTING=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r "$REALM_NAME" -q clientId="$ENTITY_ID" --fields id --format csv --noquotes | tail -1 | tr -d '\r')
if [ -z "$EXISTING" ]; then
  docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients -r "$REALM_NAME" -f - <<CLIENT
{
  "clientId": "$ENTITY_ID",
  "enabled": true,
  "protocol": "saml",
  "redirectUris": ["$ACS_URL", "https://${GRAFANA_ENDPOINT}/*"],
  "attributes": {
    "saml_assertion_consumer_url_post": "$ACS_URL",
    "saml_name_id_format": "email",
    "saml_force_name_id_format": "true",
    "saml.server.signature": "true",
    "saml.assertion.signature": "true",
    "saml.authnstatement": "true",
    "saml_force_post_binding": "true",
    "saml.client.signature": "false"
  }
}
CLIENT
  echo "grafana saml client created"
else
  echo "grafana saml client already exists: $EXISTING"
  docker exec keycloak /opt/keycloak/bin/kcadm.sh update clients/$EXISTING -r "$REALM_NAME" \
    -s 'redirectUris=["'"$ACS_URL"'","https://'"$GRAFANA_ENDPOINT"'/*"]' \
    -s 'attributes."saml_force_name_id_format"=true' \
    -s 'attributes."saml.server.signature"=true' \
    -s 'attributes."saml.assertion.signature"=true' \
    -s 'attributes."saml.client.signature"=false'
fi

CID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get clients -r "$REALM_NAME" -q clientId="$ENTITY_ID" --fields id --format csv --noquotes | tail -1 | tr -d '\r')
echo "CID=$CID"

# 기본으로 붙는 role_list scope 제거 - offline_access/uma_authorization 같은
# 내부 role 값이 대문자 "Role" 속성으로 같이 새서, 우리가 쓰는 소문자
# "role"(그룹명) 속성과 뒤섞이는 것을 막는다.
ROLE_LIST_SCOPE_ID=$(docker exec keycloak /opt/keycloak/bin/kcadm.sh get client-scopes -r "$REALM_NAME" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s['name'] == 'role_list':
        print(s['id'])
")
if [ -n "$ROLE_LIST_SCOPE_ID" ]; then
  docker exec keycloak /opt/keycloak/bin/kcadm.sh delete clients/$CID/default-client-scopes/$ROLE_LIST_SCOPE_ID -r "$REALM_NAME" 2>&1 || true
fi

# role 속성: 사용자의 Keycloak 그룹 이름을 그대로 "role" 어설션으로 전송
docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r "$REALM_NAME" -f - <<'M1' 2>&1 | tail -3 || true
{"name":"grafana-role","protocol":"saml","protocolMapper":"saml-group-membership-mapper",
 "config":{"attribute.name":"role","attribute.nameformat":"Basic","full.path":"false","single":"false"}}
M1

docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r "$REALM_NAME" -f - <<'M2' 2>&1 | tail -3 || true
{"name":"grafana-email","protocol":"saml","protocolMapper":"saml-user-property-mapper",
 "config":{"attribute.name":"email","attribute.nameformat":"Basic","user.attribute":"email"}}
M2

docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r "$REALM_NAME" -f - <<'M3' 2>&1 | tail -3 || true
{"name":"grafana-username","protocol":"saml","protocolMapper":"saml-user-property-mapper",
 "config":{"attribute.name":"login","attribute.nameformat":"Basic","user.attribute":"username"}}
M3

docker exec -i keycloak /opt/keycloak/bin/kcadm.sh create clients/"$CID"/protocol-mappers/models -r "$REALM_NAME" -f - <<'M4' 2>&1 | tail -3 || true
{"name":"grafana-name","protocol":"saml","protocolMapper":"saml-user-property-mapper",
 "config":{"attribute.name":"name","attribute.nameformat":"Basic","user.attribute":"username"}}
M4

echo "GRAFANA_PREP_DONE"
