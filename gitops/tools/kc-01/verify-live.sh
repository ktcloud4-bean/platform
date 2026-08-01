#!/usr/bin/env bash
# KC-01의 issuer, MFA, claim, 최소 권한, 로컬 복구 관리자와 비밀 비노출을 검증한다.
set -Eeuo pipefail

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly k3s_host=${K3S_HOST:-rocky@10.10.20.10}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly connect_ip=${KC01_CONNECT_IP:-}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
temp_dir=$(mktemp -d)
readonly temp_dir
umask 077
curl_route=()
browser_route=()

if [[ -n "${connect_ip}" ]]; then
  python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
address = ipaddress.ip_address(sys.argv[1])
assert address.version == 4
PY
  curl_route=(
    --resolve "${issuer_host}:443:${connect_ip}"
    --resolve "${issuer_host}:80:${connect_ip}"
  )
  browser_route=(--connect-ip "${connect_ip}")
fi

cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT

for required in \
  verify-client-secret daily-password daily-totp privileged-password \
  privileged-totp local-admin-password local-admin-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "필수 외부 비밀 파일이 없다: ${required}" >&2
    exit 1
  }
done

make_password_form() {
  local output=$1
  local realm=$2
  local username=$3
  local password_file=$4
  local totp_file=$5
  local include_totp=$6
  local client_id=$7
  local client_secret_file=${8:-}
  python3 - "${output}" "${realm}" "${username}" "${password_file}" \
    "${totp_file}" "${include_totp}" "${client_id}" "${client_secret_file}" <<'PY'
import base64
import hashlib
import hmac
import struct
import sys
import time
import urllib.parse

output, realm, username, password_file, totp_file, include_totp, client_id, client_secret_file = sys.argv[1:]
with open(password_file, encoding="utf-8") as stream:
    password = stream.read().strip()
form = {
    "grant_type": "password",
    "client_id": client_id,
    "username": username,
    "password": password,
}
if client_secret_file:
    with open(client_secret_file, encoding="utf-8") as stream:
        form["client_secret"] = stream.read().strip()
if include_totp == "true":
    with open(totp_file, encoding="utf-8") as stream:
        seed = base64.b32decode(stream.read().strip(), casefold=True)
    remaining = 30 - (int(time.time()) % 30)
    if remaining < 4:
        time.sleep(remaining + 1)
    counter = int(time.time()) // 30
    digest = hmac.new(seed, struct.pack(">Q", counter), hashlib.sha256).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    form["totp"] = f"{value % 1_000_000:06d}"
with open(output, "w", encoding="utf-8") as stream:
    stream.write(urllib.parse.urlencode(form))
PY
}

request_token() {
  local realm=$1
  local username=$2
  local password_file=$3
  local totp_file=$4
  local include_totp=$5
  local client_id=$6
  local client_secret_file=$7
  local response_file=$8
  local form_file=${temp_dir}/form-$RANDOM
  make_password_form "${form_file}" "${realm}" "${username}" "${password_file}" \
    "${totp_file}" "${include_totp}" "${client_id}" "${client_secret_file}"
  curl --silent --show-error \
    "${curl_route[@]}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary "@${form_file}" \
    "${issuer}/realms/${realm}/protocol/openid-connect/token"
  rm -f "${form_file}"
}

make_bearer_header_and_check_claims() {
  local response_file=$1
  local account_kind=$2
  local header_file=$3
  python3 - "${response_file}" "${account_kind}" "${header_file}" "${issuer}" <<'PY'
import base64
import json
import sys

response_file, account_kind, header_file, issuer = sys.argv[1:]
with open(response_file, encoding="utf-8") as stream:
    token = json.load(stream)["access_token"]
payload = token.split(".")[1]
payload += "=" * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
expected_issuer = f"{issuer}/realms/{'master' if account_kind == 'local' else 'platform'}"
assert claims["iss"] == expected_issuer, claims.get("iss")
groups = set(claims.get("groups", []))
roles = set(claims.get("resource_access", {}).get("realm-management", {}).get("roles", []))
if account_kind == "daily":
    assert groups == {"/platform-users"}, groups
    assert not roles, roles
elif account_kind == "privileged":
    assert groups == {"/platform-privileged", "/keycloak-readers"}, groups
    assert "view-users" in roles, roles
    assert roles <= {"view-users", "query-users", "query-groups"}, roles
    assert not ({"manage-users", "view-clients", "realm-admin"} & roles), roles
elif account_kind != "local":
    raise AssertionError(account_kind)
with open(header_file, "w", encoding="utf-8") as stream:
    stream.write(f"Authorization: Bearer {token}\n")
print(f"{account_kind}: issuer={claims['iss']}, groups={sorted(groups)}, realm-management={sorted(roles)}")
PY
}

echo "KC-01: HTTPS 인증서, 고정 issuer, HTTP 영구 redirect를 확인합니다."
discovery=${temp_dir}/discovery.json
curl --silent --show-error --fail \
  "${curl_route[@]}" \
  "${issuer}/realms/platform/.well-known/openid-configuration" >"${discovery}"
python3 - "${discovery}" "${issuer}/realms/platform" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)
assert document["issuer"] == sys.argv[2], document["issuer"]
PY
redirect_headers=${temp_dir}/redirect.headers
http_status=$(curl --silent --show-error --output /dev/null \
  "${curl_route[@]}" \
  --dump-header "${redirect_headers}" --write-out '%{http_code}' \
  http://sso.imcherry5778.xyz/realms/platform/)
[[ "${http_status}" == 301 ]]
grep -Eiq '^location: https://sso\.imcherry5778\.xyz/realms/platform/' "${redirect_headers}"

echo "KC-01: MFA 없는 로그인은 거부되고 MFA 로그인은 성공해야 합니다."
missing_response=${temp_dir}/missing-mfa.json
http_status=$(request_token platform imcherry \
  "${KC01_SECRET_DIR}/daily-password" "${KC01_SECRET_DIR}/daily-totp" false \
  kc-verify "${KC01_SECRET_DIR}/verify-client-secret" "${missing_response}")
[[ "${http_status}" == 400 ]]
python3 - "${missing_response}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    response = json.load(stream)
assert response.get("error") == "invalid_grant", response.get("error")
PY

daily_response=${temp_dir}/daily.json
http_status=$(request_token platform imcherry \
  "${KC01_SECRET_DIR}/daily-password" "${KC01_SECRET_DIR}/daily-totp" true \
  kc-verify "${KC01_SECRET_DIR}/verify-client-secret" "${daily_response}")
[[ "${http_status}" == 200 ]]
daily_header=${temp_dir}/daily.header
make_bearer_header_and_check_claims "${daily_response}" daily "${daily_header}"

privileged_response=${temp_dir}/privileged.json
http_status=$(request_token platform imcherry-admin \
  "${KC01_SECRET_DIR}/privileged-password" "${KC01_SECRET_DIR}/privileged-totp" true \
  kc-verify "${KC01_SECRET_DIR}/verify-client-secret" "${privileged_response}")
[[ "${http_status}" == 200 ]]
privileged_header=${temp_dir}/privileged.header
make_bearer_header_and_check_claims "${privileged_response}" privileged "${privileged_header}"

echo "KC-01: 최소 view-users 권한의 양성/음성 API를 확인합니다."
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  "${curl_route[@]}" \
  --header "@${daily_header}" "${issuer}/admin/realms/platform/users")
[[ "${http_status}" == 403 ]]
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  "${curl_route[@]}" \
  --header "@${privileged_header}" "${issuer}/admin/realms/platform/users")
[[ "${http_status}" == 200 ]]
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  "${curl_route[@]}" \
  --header "@${privileged_header}" "${issuer}/admin/realms/platform/clients")
[[ "${http_status}" == 403 ]]

echo "KC-01: master realm의 독립 로컬 관리자를 확인합니다."
local_header=${temp_dir}/local.header
# master realm은 otpPolicyCodeReusable=false다. 이 verifier 직전에 다른 check가
# 같은 recovery identity를 썼더라도 재사용되지 않도록 새 TOTP 구간에서 시작한다.
local_totp_wait_seconds=$((31 - $(date +%s) % 30))
sleep "${local_totp_wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" \
  --realm master \
  --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${KC01_SECRET_DIR}/local-admin-password" \
  --totp-file "${KC01_SECRET_DIR}/local-admin-totp" \
  --header-file "${local_header}" \
  "${browser_route[@]}" \
  --capture-callback \
  --expect-realm-role admin
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  "${curl_route[@]}" \
  --header "@${local_header}" "${issuer}/admin/realms/platform")
[[ "${http_status}" == 200 ]]

echo "KC-01: Argo 상태, SA token 경계, Kubernetes Secret 0건을 확인합니다."
argo_state=$(ssh -o BatchMode=yes "${k3s_host}" \
  "${kubectl_command} -n argocd get application keycloak -o jsonpath='{.status.sync.status}|{.status.health.status}|{.spec.source.targetRevision}'")
[[ "${argo_state}" == 'Synced|Healthy|main' ]]
secret_count=$(ssh -o BatchMode=yes "${k3s_host}" \
  "${kubectl_command} -n keycloak get secrets --no-headers 2>/dev/null | wc -l")
[[ "${secret_count}" -eq 0 ]]
ssh -o BatchMode=yes "${k3s_host}" \
  "${kubectl_command} -n keycloak exec deploy/keycloak -c keycloak -- test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token"

echo "KC-01: Git과 Keycloak 컨테이너 로그에 비밀 원문이 없는지 확인합니다."
pattern_file=${temp_dir}/secret-patterns
for secret_file in "${KC01_SECRET_DIR}"/*; do
  [[ -f "${secret_file}" && "${secret_file}" != "${KC01_SECRET_DIR}/.provisioned" ]] || continue
  tr -d '\n' <"${secret_file}"
  printf '\n'
done >"${pattern_file}"
if git -C "${repo_root}" grep -F -f "${pattern_file}" -- . >/dev/null 2>&1; then
  echo "Git 추적 파일에서 비밀 원문을 찾았다." >&2
  exit 1
fi
if ssh -o BatchMode=yes "${k3s_host}" \
  "${kubectl_command} -n keycloak logs -l app.kubernetes.io/name=keycloak --all-containers=true --prefix=true --tail=-1" 2>/dev/null \
  | grep -F -f "${pattern_file}" -q; then
  echo "Keycloak Pod 로그에서 비밀 원문을 찾았다." >&2
  exit 1
fi

echo "KC-01: issuer/MFA/claim/최소권한/로컬 관리자/비밀 비노출 검증 통과"
