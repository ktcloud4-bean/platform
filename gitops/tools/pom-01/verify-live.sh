#!/usr/bin/env bash
# shellcheck disable=SC2029
# POM-01의 Route/Dashy Portal/TLS/MFA/Secret 0과 기본 복구 조회 경계를 검증한다.
set -Eeuo pipefail

: "${POM01_SECRET_DIR:?저장소 밖 POM-01 비밀 디렉터리가 필요하다}"
: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
readonly connect_ip=${POM01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly expected_root_revision=${POM01_EXPECTED_ROOT_REVISION:-main}
readonly expected_app_revision=${POM01_EXPECTED_APP_REVISION:-main}
readonly expected_pomerium_image_id=docker.io/pomerium/pomerium@sha256:aae6010af6ba4c864bbd3f748cf37843a140b1ddef74d7d2ac1aa87660f8da1f
readonly expected_dashy_image_id=docker.io/lissy93/dashy@sha256:54d5ba3eff1fe31856fda9eed06e64e3f4ab2a4473c2bbf81b13a9bff6cba7dd
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]).version == 4
PY
for required in client-secret shared-secret cookie-secret signing-key.pem; do
  [[ -s "${POM01_SECRET_DIR}/${required}" ]] || {
    echo "POM-01 외부 비밀 파일이 없다: ${required}" >&2
    exit 1
  }
done
for required in \
  verify-client-secret daily-password daily-totp privileged-password \
  privileged-totp local-admin-password local-admin-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "KC-01 외부 검증 파일이 없다: ${required}" >&2
    exit 1
  }
done

echo "POM-01: Keycloak 고정 issuer, MFA 누락 거부와 실제 groups claim을 재검증합니다."
KC01_SECRET_DIR="${KC01_SECRET_DIR}" \
KC01_CONNECT_IP="${connect_ip}" \
K3S_HOST="${k3s_host}" \
"${repo_root}/gitops/tools/kc-01/verify-live.sh"

# KC 검증과 다른 새 TOTP 구간에서 Pomerium 브라우저 flow를 시작한다.
wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"

echo "POM-01: 허용/비허용 ID의 Route와 Portal 결과를 같은 검증 실행에서 대조합니다."
python3 "${repo_root}/gitops/tools/pom-01/browser-session.py" \
  --connect-ip "${connect_ip}" \
  --username imcherry \
  --password-file "${KC01_SECRET_DIR}/daily-password" \
  --totp-file "${KC01_SECRET_DIR}/daily-totp" \
  --expect allow \
  --check-logout
python3 "${repo_root}/gitops/tools/pom-01/browser-session.py" \
  --connect-ip "${connect_ip}" \
  --username imcherry-admin \
  --password-file "${KC01_SECRET_DIR}/privileged-password" \
  --totp-file "${KC01_SECRET_DIR}/privileged-totp" \
  --expect deny

# urllib 검증과 다른 새 TOTP 구간에서 실제 Dashy JavaScript 렌더링을 확인한다.
wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
node "${repo_root}/gitops/tools/pom-01/dashy-browser.js" \
  --connect-ip "${connect_ip}" \
  --username imcherry \
  --password-file "${KC01_SECRET_DIR}/daily-password" \
  --totp-file "${KC01_SECRET_DIR}/daily-totp" \
  --expect allow
node "${repo_root}/gitops/tools/pom-01/dashy-browser.js" \
  --connect-ip "${connect_ip}" \
  --username imcherry-admin \
  --password-file "${KC01_SECRET_DIR}/privileged-password" \
  --totp-file "${KC01_SECRET_DIR}/privileged-totp" \
  --expect deny

echo "POM-01: 정확한 TLS hostname, 잘못된 hostname 거부와 HTTP 301을 확인합니다."
curl --silent --show-error --fail \
  --resolve "access.imcherry5778.xyz:443:${connect_ip}" \
  "https://access.imcherry5778.xyz/.well-known/pomerium" >/dev/null
printf '' | openssl s_client -connect "${connect_ip}:443" \
  -servername access.imcherry5778.xyz 2>/dev/null \
  | openssl x509 -noout -checkhost access.imcherry5778.xyz >/dev/null
set +e
curl --silent --show-error \
  --resolve "wrong-pom-01.imcherry5778.xyz:443:${connect_ip}" \
  "https://wrong-pom-01.imcherry5778.xyz/" >/dev/null 2>&1
wrong_hostname_status=$?
set -e
if [[ "${wrong_hostname_status}" -ne 60 ]]; then
  echo "잘못된 TLS hostname의 curl 종료 코드가 60이 아니다: ${wrong_hostname_status}" >&2
  exit 1
fi
redirect_headers=$(mktemp)
trap 'rm -f "${redirect_headers}"' EXIT
http_status=$(curl --silent --show-error --output /dev/null \
  --resolve "access.imcherry5778.xyz:80:${connect_ip}" \
  --dump-header "${redirect_headers}" --write-out '%{http_code}' \
  http://access.imcherry5778.xyz/)
[[ "${http_status}" == 301 ]]
grep -Eiq '^location: https://access\.imcherry5778\.xyz/' "${redirect_headers}"

echo "POM-01: Argo main, image digest, health, SA token 비마운트와 Secret 0건을 확인합니다."
argo_state=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n argocd get application platform-root pomerium \
    -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.status.sync.status}{\"|\"}{.status.health.status}{\"|\"}{.spec.source.targetRevision}{\"\\n\"}{end}'")
grep -Fxq "platform-root|Synced|Healthy|${expected_root_revision}" <<<"${argo_state}"
grep -Fxq "pomerium|Synced|Healthy|${expected_app_revision}" <<<"${argo_state}"
secret_count=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium get secrets --no-headers 2>/dev/null | wc -l")
[[ "${secret_count}" -eq 0 ]]
image_id=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium get pod -l app.kubernetes.io/name=pomerium \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'")
[[ "${image_id}" == "${expected_pomerium_image_id}" ]]
dashy_image_id=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium get pod -l app.kubernetes.io/name=dashy \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'")
[[ "${dashy_image_id}" == "${expected_dashy_image_id}" ]]
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium get deployment pomerium -o json" \
  | jq -e '
      .spec.template.spec.automountServiceAccountToken == false and
      ([.spec.template.spec.containers[] | select(.name == "pomerium") |
        .volumeMounts[]?.name] | index("vault-token") | not) and
      ([.spec.template.spec.volumes[] | select(.name == "vault-token") |
        .projected.sources[].serviceAccountToken |
        {expirationSeconds,audience}] == [{"expirationSeconds":600,"audience":"vault"}])
    ' >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium get deployment dashy -o json" \
  | jq -e '
      .spec.template.spec.automountServiceAccountToken == false and
      .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true
    ' >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium exec deploy/pomerium -c pomerium -- \
    /bin/pomerium health --health-addr 127.0.0.1:28080" >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium exec deploy/dashy -c dashy -- \
    node -e \"fetch('http://127.0.0.1:8080/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))\"" >/dev/null

echo "POM-01: Git과 전체 Pomerium/Dashy Pod 로그의 client secret·token 원문 0건을 확인합니다."
pattern_file=$(mktemp)
log_file=$(mktemp)
cleanup() {
  rm -f "${redirect_headers}" "${pattern_file}" "${log_file}"
}
trap cleanup EXIT
for secret_file in "${POM01_SECRET_DIR}"/*; do
  [[ -f "${secret_file}" && "$(basename "${secret_file}")" != .provisioned ]] || continue
  awk 'length($0) >= 20 && $0 !~ /^-----BEGIN / && $0 !~ /^-----END /' "${secret_file}"
done >"${pattern_file}"
if git -C "${repo_root}" grep -F -f "${pattern_file}" -- . >/dev/null 2>&1; then
  echo "Git 추적 파일에서 POM-01 비밀 원문을 찾았다." >&2
  exit 1
fi
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n pomerium logs -l app.kubernetes.io/part-of=platform-gitops \
    --all-containers=true --prefix=true --tail=-1" >"${log_file}" 2>/dev/null
if grep -F -f "${pattern_file}" "${log_file}" >/dev/null 2>&1; then
  echo "Pomerium Pod 로그에서 client secret 원문을 찾았다." >&2
  exit 1
fi
if grep -Eq 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "${log_file}"; then
  echo "Pomerium Pod 로그에서 JWT 형식 원문을 찾았다." >&2
  exit 1
fi

echo "POM-01: claim/groups allow/deny, Dashy 타일, MFA, logout, TLS, Argo, Secret 0과 비밀 비노출 검증 통과"
