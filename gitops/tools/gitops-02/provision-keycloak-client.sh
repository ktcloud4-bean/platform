#!/usr/bin/env bash
# GITOPS-02 public PKCE Keycloak client를 check-first 방식으로만 추가한다.
# 기존 realm, user, group, client, Vault object는 수정하거나 보정하지 않는다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법:
  KC01_SECRET_DIR=<저장소 밖 KC-01 비밀 디렉터리> \
  ./gitops/tools/gitops-02/provision-keycloak-client.sh --check|--apply

--check는 platform realm의 clientId=argocd 객체를 안전한 비밀 제외 필드로만 비교한다.
--apply는 client가 없을 때 public Authorization Code + PKCE(S256) client 한 건만 추가한다.
기존 client가 선언과 다르면 어떤 보정도 하지 않고 실패한다.
EOF
}

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply ]]; then
  usage >&2
  exit 2
fi

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly client_declaration=${repo_root}/gitops/tools/gitops-02/keycloak-client.json

case "${KC01_SECRET_DIR}" in
  /|/home|/home/*/projects|/home/*/projects/*|"${repo_root}"|"${repo_root}"/*)
    echo "KC01_SECRET_DIR가 너무 넓거나 저장소 경로다: ${KC01_SECRET_DIR}" >&2
    exit 1
    ;;
esac
[[ "${KC01_SECRET_DIR}" = /* ]] || {
  echo "KC01_SECRET_DIR는 절대 경로여야 한다." >&2
  exit 1
}
for required in local-admin-password local-admin-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "KC-01 복구 입력이 없다: ${required}" >&2
    exit 1
  }
done
python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]).version == 4
PY
jq -e . "${client_declaration}" >/dev/null

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

admin_header=${temp_dir}/admin.header
clients_json=${temp_dir}/clients.json
response_json=${temp_dir}/response.json

# 직전 Keycloak 검증과 같은 TOTP 값을 재사용하지 않는다.
wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" \
  --realm master \
  --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${KC01_SECRET_DIR}/local-admin-password" \
  --totp-file "${KC01_SECRET_DIR}/local-admin-totp" \
  --header-file "${admin_header}" \
  --connect-ip "${connect_ip}" \
  --capture-callback \
  --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" \
    "$@"
}

client_matches() {
  jq -e '
    length == 1 and
    .[0].clientId == "argocd" and
    .[0].enabled == true and
    .[0].protocol == "openid-connect" and
    .[0].publicClient == true and
    .[0].clientAuthenticatorType == "client-secret" and
    .[0].standardFlowEnabled == true and
    .[0].implicitFlowEnabled == false and
    .[0].directAccessGrantsEnabled == false and
    .[0].serviceAccountsEnabled == false and
    (.[0].authorizationServicesEnabled != true) and
    .[0].fullScopeAllowed == false and
    .[0].redirectUris == ["https://argo.imcherry5778.xyz/auth/callback"] and
    .[0].webOrigins == ["https://argo.imcherry5778.xyz"] and
    .[0].attributes["pkce.code.challenge.method"] == "S256" and
    ((.[0].attributes["post.logout.redirect.uris"] // "") == "") and
    (.[0].protocolMappers | map(select(
      .name == "groups" and
      .protocol == "openid-connect" and
      .protocolMapper == "oidc-group-membership-mapper" and
      .config["claim.name"] == "groups" and
      .config["full.path"] == "true" and
      .config["id.token.claim"] == "true" and
      .config["access.token.claim"] == "true" and
      .config["userinfo.token.claim"] == "true"
    )) | length == 1)
  ' "${clients_json}" >/dev/null
}

safe_client_summary() {
  jq '[.[] | {
    clientId, enabled, protocol, publicClient, clientAuthenticatorType,
    standardFlowEnabled, implicitFlowEnabled, directAccessGrantsEnabled,
    serviceAccountsEnabled, authorizationServicesEnabled, fullScopeAllowed,
    redirectUris, webOrigins,
    attributes:{pkce_code_challenge_method:.attributes["pkce.code.challenge.method"],
      post_logout_redirect_uris:.attributes["post.logout.redirect.uris"]},
    protocolMappers:[.protocolMappers[]? | select(.name == "groups") |
      {name, protocol, protocolMapper, config}]
  }]' "${clients_json}"
}

curl_admin "${issuer}/admin/realms/platform/clients?clientId=argocd" >"${clients_json}"
client_count=$(jq 'length' "${clients_json}")
case "${client_count}" in
  0)
    echo "GITOPS-02 Keycloak 차이: argocd client 0건 -> 신규 public PKCE client 추가 대상"
    ;;
  1)
    if client_matches; then
      echo "GITOPS-02 Keycloak 차이: argocd client 1건 -> 선언 일치"
    else
      safe_client_summary
      echo "live argocd client가 GITOPS-02 선언과 다르다. 자동 보정하지 않는다." >&2
      exit 1
    fi
    ;;
  *)
    echo "clientId=argocd live 객체가 ${client_count}건이다. 변경하지 않는다." >&2
    exit 1
    ;;
esac

if [[ "${mode}" == --check ]]; then
  exit 0
fi

if [[ "${client_count}" -eq 0 ]]; then
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' \
    --request POST \
    --header "@${admin_header}" \
    --header 'Content-Type: application/json' \
    --data-binary "@${client_declaration}" \
    "${issuer}/admin/realms/platform/clients")
  if [[ "${http_status}" != 201 ]]; then
    echo "GITOPS-02 Keycloak client 생성 실패: HTTP ${http_status}" >&2
    exit 1
  fi
  echo "GITOPS-02: 기존 realm 객체를 수정하지 않고 argocd public PKCE client 한 건을 추가했다."
fi

curl_admin "${issuer}/admin/realms/platform/clients?clientId=argocd" >"${clients_json}"
client_matches || {
  echo "생성 후 argocd client 선언 일치 검증에 실패했다." >&2
  exit 1
}
echo "GITOPS-02: Keycloak public PKCE client 선언 검증 통과"
