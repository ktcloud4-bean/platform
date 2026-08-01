#!/usr/bin/env bash
# platform realm을 잠시 비활성화해 master realm 로컬 관리 경로의 독립성을 검증한다.
# 서비스 영향이 있으므로 실행 전 사용자 승인과 즉시 복구 준비가 필요하다.
set -Eeuo pipefail

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
readonly issuer=https://sso.imcherry5778.xyz
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
temp_dir=$(mktemp -d)
readonly temp_dir
umask 077
realm_disabled=false

cleanup() {
  local cleanup_status=$?
  set +e
  if [[ "${realm_disabled}" == true && -s "${temp_dir}/local.header" ]]; then
    printf '{"enabled":true}\n' >"${temp_dir}/enable.json"
    curl --silent --show-error --output /dev/null \
      --request PUT \
      --header "@${temp_dir}/local.header" \
      --header 'Content-Type: application/json' \
      --data-binary "@${temp_dir}/enable.json" \
      "${issuer}/admin/realms/platform"
  fi
  rm -rf "${temp_dir}"
  exit "${cleanup_status}"
}
trap cleanup EXIT INT TERM

for required in \
  verify-client-secret daily-password daily-totp \
  local-admin-password local-admin-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "필수 외부 비밀 파일이 없다: ${required}" >&2
    exit 1
  }
done

make_daily_form() {
  local output=$1
  python3 - "${output}" \
    "${KC01_SECRET_DIR}/verify-client-secret" \
    "${KC01_SECRET_DIR}/daily-password" \
    "${KC01_SECRET_DIR}/daily-totp" <<'PY'
import base64, hashlib, hmac, struct, sys, time, urllib.parse
output, client_secret_file, password_file, totp_file = sys.argv[1:]
with open(client_secret_file, encoding="utf-8") as stream:
    client_secret = stream.read().strip()
with open(password_file, encoding="utf-8") as stream:
    password = stream.read().strip()
with open(totp_file, encoding="utf-8") as stream:
    seed = base64.b32decode(stream.read().strip(), casefold=True)
remaining = 30 - (int(time.time()) % 30)
if remaining < 4:
    time.sleep(remaining + 1)
counter = int(time.time()) // 30
digest = hmac.new(seed, struct.pack(">Q", counter), hashlib.sha256).digest()
offset = digest[-1] & 0x0F
value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
form = {
    "grant_type": "password", "client_id": "kc-verify",
    "client_secret": client_secret, "username": "imcherry",
    "password": password, "totp": f"{value % 1_000_000:06d}",
}
with open(output, "w", encoding="utf-8") as stream:
    stream.write(urllib.parse.urlencode(form))
PY
}

# verify-live 직후 같은 TOTP code를 재사용하지 않도록 새 30초 구간에서 시작한다.
totp_wait_seconds=$((31 - $(date +%s) % 30))
echo "KC-01 복구 시험: 새 TOTP 구간을 ${totp_wait_seconds}초 기다립니다."
sleep "${totp_wait_seconds}"

python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" \
  --realm master \
  --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${KC01_SECRET_DIR}/local-admin-password" \
  --totp-file "${KC01_SECRET_DIR}/local-admin-totp" \
  --header-file "${temp_dir}/local.header" \
  --expect-realm-role admin

http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --header "@${temp_dir}/local.header" "${issuer}/admin/realms/platform")
[[ "${http_status}" == 200 ]]

echo "KC-01 복구 시험: platform realm을 일시 비활성화합니다."
printf '{"enabled":false}\n' >"${temp_dir}/disable.json"
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --request PUT \
  --header "@${temp_dir}/local.header" \
  --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/disable.json" \
  "${issuer}/admin/realms/platform")
[[ "${http_status}" == 204 ]]
realm_disabled=true

make_daily_form "${temp_dir}/daily-disabled.form"
http_status=$(curl --silent --show-error --output "${temp_dir}/daily-disabled.json" \
  --write-out '%{http_code}' \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary "@${temp_dir}/daily-disabled.form" \
  "${issuer}/realms/platform/protocol/openid-connect/token")
[[ "${http_status}" == 403 ]]
python3 - "${temp_dir}/daily-disabled.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    response = json.load(stream)
assert response.get("error") == "access_denied", response.get("error")
assert response.get("error_description") == "Realm not enabled"
PY
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --header "@${temp_dir}/local.header" "${issuer}/admin/realms/platform")
[[ "${http_status}" == 200 ]]

echo "KC-01 복구 시험: master 로컬 관리 경로로 platform realm을 복구합니다."
printf '{"enabled":true}\n' >"${temp_dir}/enable.json"
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --request PUT \
  --header "@${temp_dir}/local.header" \
  --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/enable.json" \
  "${issuer}/admin/realms/platform")
[[ "${http_status}" == 204 ]]
realm_disabled=false
make_daily_form "${temp_dir}/daily-restored.form"
http_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary "@${temp_dir}/daily-restored.form" \
  "${issuer}/realms/platform/protocol/openid-connect/token")
[[ "${http_status}" == 200 ]]
echo "KC-01: IdP realm 장애와 독립된 로컬 관리자 복구 시험 통과"
