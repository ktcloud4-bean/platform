#!/usr/bin/env bash
# 완료 증거 4: 같은 시점 Keycloak allow/Pomerium deny와 독립 local admin login을 검증한다.
set -Eeuo pipefail

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly env_file=${secret_root}/sonarqube/env
readonly kc_dir=${secret_root}/keycloak
readonly sonar_url=${SONAR_URL:-http://127.0.0.1:19000}
readonly connect_ip=${K3S_CONNECT_IP:-10.10.20.10}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root

node "${repo_root}/gitops/tools/quality-01/sso-browser.js" \
  --connect-ip "${connect_ip}" \
  --username imcherry \
  --password-file "${kc_dir}/daily-password" \
  --totp-file "${kc_dir}/daily-totp" \
  --expect allow

node "${repo_root}/gitops/tools/quality-01/sso-browser.js" \
  --connect-ip "${connect_ip}" \
  --username imcherry-admin \
  --password-file "${kc_dir}/privileged-password" \
  --totp-file "${kc_dir}/privileged-totp" \
  --expect deny

SONARQUBE_ADMIN_PASSWORD=
while IFS='=' read -r key value; do
  [[ "${key}" == SONARQUBE_ADMIN_PASSWORD ]] && SONARQUBE_ADMIN_PASSWORD=${value}
done <"${env_file}"
readonly SONARQUBE_ADMIN_PASSWORD
[[ -n "${SONARQUBE_ADMIN_PASSWORD}" ]]

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
form_file=${temp_dir}/login.form
cookie_file=${temp_dir}/cookies
python3 - "${SONARQUBE_ADMIN_PASSWORD}" "${form_file}" <<'PY'
import sys
import urllib.parse
with open(sys.argv[2], "w", encoding="utf-8") as output:
    output.write(urllib.parse.urlencode({"login": "admin", "password": sys.argv[1]}))
PY
status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --cookie-jar "${cookie_file}" --request POST --data-binary "@${form_file}" \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  "${sonar_url}/api/authentication/login")
[[ "${status}" == 200 ]] || {
  echo "SonarQube local admin session login 실패: HTTP ${status}" >&2
  exit 1
}
curl --silent --show-error --fail --cookie "${cookie_file}" \
  "${sonar_url}/api/authentication/validate" | jq -e '.valid == true' >/dev/null
echo "QUALITY-01 local admin recovery login: valid=true (SSH port-forward 직접 경로)"
