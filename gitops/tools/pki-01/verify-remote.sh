#!/usr/bin/env bash
# PKI-01 완료 증거 1~7을 k3s 호스트의 한 배치에서 판정한다.
set -euo pipefail

: "${PKI01_VAULT_TOKEN:?Vault root token is required on stdin wrapper}"
: "${PKI01_EXPECTED_CONFIG_REVISION:?config revision is required}"
: "${PKI01_EXPECTED_ROOT_REVISION:?root pointer revision is required}"

readonly k=(sudo -n /usr/local/bin/k3s kubectl)
readonly namespace=crowdsec-01
readonly agent_dns=crowdsec-agent.crowdsec-01.svc.cluster.local
readonly lapi_dns=crowdsec-service.crowdsec-01.svc.cluster.local
readonly probe_role=pki-01-bouncer-probe
readonly sealed_certificate=pki-01-sealed-probe
readonly sealed_secret=pki-01-sealed-probe-tls
verify_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
readonly verify_started_at
verify_dir=$(mktemp -d /tmp/pki-01-live.XXXXXX)
readonly verify_dir
port_forward_pid=''
vault_sealed_by_test=false

fail() {
  local stage=$1
  shift
  echo "검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

vault_root() {
  printf '%s\n' "${PKI01_VAULT_TOKEN}" | "${k[@]}" -n vault exec -i vault-0 -- \
    sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' sh "$@"
}

vault_sign_as() {
  local vault_token=$1 sign_path=$2 csr_file=$3
  # shellcheck disable=SC2016
  { printf '%s\n' "${vault_token}"; cat "${csr_file}"; } | \
    "${k[@]}" -n vault exec -i vault-0 -- sh -c '
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      sign_path=$1
      csr=$(cat)
      vault write -format=json "${sign_path}" csr="${csr}" format=pem
    ' sh "${sign_path}"
}

vault_sign_root() {
  vault_sign_as "${PKI01_VAULT_TOKEN}" "$1" "$2"
}

vault_status() {
  "${k[@]}" -n vault exec vault-0 -- vault status -format=json 2>/dev/null || true
}

wait_vault_unsealed() {
  local status_json pod_json
  for _ in $(seq 1 80); do
    status_json=$(vault_status)
    pod_json=$("${k[@]}" -n vault get pod vault-0 -o json 2>/dev/null || true)
    if jq -e '.sealed==false and .type=="awskms"' <<<"${status_json}" >/dev/null 2>&1 &&
       jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' \
         <<<"${pod_json}" >/dev/null 2>&1; then
      vault_sealed_by_test=false
      return 0
    fi
    sleep 3
  done
  return 1
}

cleanup() {
  local exit_status=$?
  trap - EXIT HUP INT TERM
  if [[ -n ${port_forward_pid} ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  if [[ ${vault_sealed_by_test} == true ]]; then
    "${k[@]}" -n vault delete pod vault-0 --wait=true --timeout=120s >/dev/null 2>&1 || true
    wait_vault_unsealed >/dev/null 2>&1 || {
      echo '긴급 복구 실패: vault-0가 AWS KMS auto-unseal되지 않았다.' >&2
      exit_status=1
    }
  fi
  "${k[@]}" -n "${namespace}" delete certificate "${sealed_certificate}" \
    --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  "${k[@]}" -n "${namespace}" delete certificaterequest \
    -l "cert-manager.io/certificate-name=${sealed_certificate}" \
    --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  "${k[@]}" -n "${namespace}" delete secret "${sealed_secret}" \
    --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  if jq -e '.sealed==false' <<<"$(vault_status)" >/dev/null 2>&1; then
    vault_root delete "pki/roles/${probe_role}" >/dev/null 2>&1 || true
  fi
  case ${verify_dir} in
    /tmp/pki-01-live.*) rm -rf -- "${verify_dir}" ;;
    *) echo "임시 디렉터리 정리 거부: ${verify_dir}" >&2; exit_status=1 ;;
  esac
  exit "${exit_status}"
}
trap cleanup EXIT HUP INT TERM

wait_certificate_revision() {
  local name=$1 expected=$2 attempts=$3 cert_json revision
  for _ in $(seq 1 "${attempts}"); do
    cert_json=$("${k[@]}" -n "${namespace}" get certificate "${name}" -o json 2>/dev/null || true)
    revision=$(jq -r '.status.revision // 0' <<<"${cert_json}" 2>/dev/null || printf 0)
    ((revision <= expected)) || fail renewal "${name} revision이 ${revision}까지 진행했다."
    if [[ ${revision} == "${expected}" ]] &&
       jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' \
         <<<"${cert_json}" >/dev/null 2>&1; then
      printf '%s' "${cert_json}"
      return 0
    fi
    sleep 5
  done
  return 1
}

ready_certificate_revision() {
  local name=$1 attempts=$2 cert_json revision
  for _ in $(seq 1 "${attempts}"); do
    cert_json=$("${k[@]}" -n "${namespace}" get certificate "${name}" -o json 2>/dev/null || true)
    revision=$(jq -r '.status.revision // 0' <<<"${cert_json}" 2>/dev/null || printf 0)
    if ((revision >= 1)) &&
       jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' \
         <<<"${cert_json}" >/dev/null 2>&1; then
      printf '%s' "${revision}"
      return 0
    fi
    sleep 5
  done
  return 1
}

secret_material() {
  local secret_name=$1 prefix=$2 secret_json
  secret_json=$("${k[@]}" -n "${namespace}" get secret "${secret_name}" -o json)
  jq -r '.data["tls.crt"]' <<<"${secret_json}" | base64 -d >"${verify_dir}/${prefix}.crt"
  jq -r '.data["tls.key"]' <<<"${secret_json}" | base64 -d >"${verify_dir}/${prefix}.key"
  jq -r '.data["ca.crt"]' <<<"${secret_json}" | base64 -d >"${verify_dir}/${prefix}-ca.crt"
  chmod 0600 "${verify_dir}/${prefix}.key"
}

fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//I;s/://g'
}

container_restart_count() {
  local deployment=$1 container=$2
  "${k[@]}" -n "${namespace}" get pod -l "k8s-app=crowdsec,type=${deployment}" -o json | \
    jq -r --arg container "${container}" '.items[0].status.containerStatuses[] | select(.name==$container) | .restartCount'
}

pod_uid() {
  "${k[@]}" -n "${namespace}" get pod -l "k8s-app=crowdsec,type=$1" -o json | jq -r '.items[0].metadata.uid'
}

agent_lapi_status() {
  "${k[@]}" -n "${namespace}" exec deploy/crowdsec-agent -c crowdsec-agent -- \
    cscli lapi status >/dev/null 2>&1
}

# immutable root/children과 workload 준비
argo_json=''
for _ in $(seq 1 90); do
  argo_json=$("${k[@]}" -n argocd get application platform-root cert-manager crowdsec -o json 2>/dev/null || true)
  if jq -e --arg root "${PKI01_EXPECTED_ROOT_REVISION}" --arg child "${PKI01_EXPECTED_CONFIG_REVISION}" '
    all(.items[];
      if .metadata.name=="platform-root" then
        .spec.source.targetRevision==$root and .status.sync.revision==$root
      else
        .spec.source.targetRevision==$child and .status.sync.revision==$child
      end and .status.sync.status=="Synced" and .status.health.status=="Healthy")
  ' <<<"${argo_json}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${PKI01_EXPECTED_ROOT_REVISION}" --arg child "${PKI01_EXPECTED_CONFIG_REVISION}" '
  all(.items[];
    if .metadata.name=="platform-root" then
      .spec.source.targetRevision==$root and .status.sync.revision==$root
    else
      .spec.source.targetRevision==$child and .status.sync.revision==$child
    end and .status.sync.status=="Synced" and .status.health.status=="Healthy")
' <<<"${argo_json}" >/dev/null || fail argo 'root/cert-manager/crowdsec가 immutable SHA에서 Synced/Healthy가 아니다.'
for deployment in crowdsec-lapi crowdsec-agent crowdsec-appsec; do
  "${k[@]}" -n "${namespace}" rollout status "deployment/${deployment}" --timeout=240s >/dev/null \
    || fail workload "${deployment}가 Ready가 아니다."
done
for issuer in vault-crowdsec-agent vault-crowdsec-lapi; do
  issuer_json=$("${k[@]}" get clusterissuer "${issuer}" -o json)
  jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' <<<"${issuer_json}" >/dev/null \
    || fail issuer "${issuer}가 Ready가 아니다."
done
echo "Argo=PASS root=${PKI01_EXPECTED_ROOT_REVISION} children=${PKI01_EXPECTED_CONFIG_REVISION}"

# 1. role/policy의 정확한 이름·EKU·OU 경계
agent_role=$(vault_root read -format=json pki/roles/crowdsec-agent)
lapi_role=$(vault_root read -format=json pki/roles/crowdsec-lapi)
jq -e --arg dns "${agent_dns}" '
  .data.allowed_domains==[$dns] and .data.allow_bare_domains==true and
  .data.allow_subdomains==false and .data.allow_any_name==false and
  .data.client_flag==true and .data.server_flag==false and .data.ou==["agent-ou"]
' <<<"${agent_role}" >/dev/null || fail role 'agent PKI role 경계가 다르다.'
jq -e --arg dns "${lapi_dns}" '
  .data.allowed_domains==[$dns,"localhost"] and .data.allow_bare_domains==true and
  .data.allow_subdomains==false and .data.allow_any_name==false and
  .data.allow_localhost==true and .data.client_flag==false and
  .data.server_flag==true and (.data.ou|length)==0
' <<<"${lapi_role}" >/dev/null || fail role 'LAPI PKI role 경계가 다르다.'

openssl ecparam -name prime256v1 -genkey -noout -out "${verify_dir}/boundary.key"
chmod 0600 "${verify_dir}/boundary.key"
openssl req -new -key "${verify_dir}/boundary.key" -out "${verify_dir}/outside-name.csr" \
  -subj '/CN=outside.crowdsec-01.svc.cluster.local/OU=agent-ou' \
  -addext 'subjectAltName=DNS:outside.crowdsec-01.svc.cluster.local'
openssl req -new -key "${verify_dir}/boundary.key" -out "${verify_dir}/outside-ou.csr" \
  -subj "/CN=${agent_dns}/OU=bouncer-ou" -addext "subjectAltName=DNS:${agent_dns}"

agent_jwt=$("${k[@]}" -n cert-manager create token cert-manager-vault-crowdsec-agent \
  --audience=vault://vault-crowdsec-agent --duration=10m)
# shellcheck disable=SC2016
agent_token=$(printf '%s\n' "${agent_jwt}" | "${k[@]}" -n vault exec -i vault-0 -- sh -c '
  read -r jwt
  vault write -field=token auth/kubernetes/login role=cert-manager-vault-crowdsec-agent jwt="${jwt}"
')
unset agent_jwt

set +e
outside_name_error=$(vault_sign_as "${agent_token}" pki/sign/crowdsec-agent \
  "${verify_dir}/outside-name.csr" 2>&1)
outside_name_rc=$?
set -e
if [[ ${outside_name_rc} -eq 0 ]] || ! grep -qi 'not allowed by this role' <<<"${outside_name_error}"; then
  fail role '허용 밖 agent 이름이 거부되지 않았다.'
fi
unset outside_name_error

outside_ou_json=$(vault_sign_as "${agent_token}" pki/sign/crowdsec-agent "${verify_dir}/outside-ou.csr")
jq -r '.data.certificate' <<<"${outside_ou_json}" >"${verify_dir}/outside-ou.crt"
outside_ou_subject=$(openssl x509 -in "${verify_dir}/outside-ou.crt" -noout -subject -nameopt RFC2253)
if ! grep -Fq 'OU=agent-ou' <<<"${outside_ou_subject}" ||
   grep -Fq 'OU=bouncer-ou' <<<"${outside_ou_subject}"; then
  fail role 'agent role이 허용 밖 OU를 leaf에 남겼다.'
fi

set +e
cross_policy_error=$(vault_sign_as "${agent_token}" pki/sign/crowdsec-lapi \
  "${verify_dir}/outside-ou.csr" 2>&1)
cross_policy_rc=$?
set -e
unset agent_token
if [[ ${cross_policy_rc} -eq 0 ]] || ! grep -q 'Code: 403' <<<"${cross_policy_error}"; then
  fail policy 'agent policy가 LAPI signing endpoint를 403으로 막지 않았다.'
fi
unset cross_policy_error
echo 'Evidence1=PASS roles=2 exact_names=true outside_name=denied outside_ou_issued=false cross_path=403'

# 운영 인증서의 현재 Ready revision과 실제 agent 연결
agent_initial_revision=$(ready_certificate_revision crowdsec-agent 60) \
  || fail certificate 'agent Certificate가 Ready가 아니다.'
lapi_initial_revision=$(ready_certificate_revision crowdsec-lapi 60) \
  || fail certificate 'LAPI Certificate가 Ready가 아니다.'
secret_material crowdsec-agent-tls agent-initial
secret_material crowdsec-lapi-tls lapi-initial
openssl verify -CAfile "${verify_dir}/agent-initial-ca.crt" "${verify_dir}/agent-initial.crt" >/dev/null \
  || fail certificate 'agent chain 검증 실패'
openssl verify -CAfile "${verify_dir}/lapi-initial-ca.crt" "${verify_dir}/lapi-initial.crt" >/dev/null \
  || fail certificate 'LAPI chain 검증 실패'
agent_initial_fp=$(fingerprint "${verify_dir}/agent-initial.crt")
lapi_initial_fp=$(fingerprint "${verify_dir}/lapi-initial.crt")
agent_lapi_status || fail mtls 'agent가 LAPI에 실제 연결하지 못했다.'

# OU 구분과 wrong-CA를 한 port-forward에서 판정할 probe certificate
vault_root write "pki/roles/${probe_role}" \
  allowed_domains="pki-01-bouncer.crowdsec-01.svc.cluster.local" \
  allow_bare_domains=true allow_subdomains=false allow_glob_domains=false \
  allow_any_name=false enforce_hostnames=true allow_localhost=false allow_ip_sans=false \
  use_csr_common_name=true use_csr_sans=true require_cn=true ou=bouncer-ou \
  key_type=ec key_bits=256 server_flag=false client_flag=true \
  code_signing_flag=false email_protection_flag=false key_usage=DigitalSignature \
  ext_key_usage=ClientAuth ttl=1h max_ttl=1h no_store=false >/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "${verify_dir}/bouncer.key"
chmod 0600 "${verify_dir}/bouncer.key"
openssl req -new -key "${verify_dir}/bouncer.key" -out "${verify_dir}/bouncer.csr" \
  -subj '/CN=pki-01-bouncer.crowdsec-01.svc.cluster.local/OU=bouncer-ou' \
  -addext 'subjectAltName=DNS:pki-01-bouncer.crowdsec-01.svc.cluster.local'
bouncer_json=$(vault_sign_root "pki/sign/${probe_role}" "${verify_dir}/bouncer.csr")
jq -r '.data.certificate' <<<"${bouncer_json}" >"${verify_dir}/bouncer.crt"
jq -r '.data.issuing_ca' <<<"${bouncer_json}" >"${verify_dir}/bouncer-ca.crt"
bouncer_serial=$(jq -r '.data.serial_number' <<<"${bouncer_json}")
bouncer_serial_hex=${bouncer_serial//:/}
unset bouncer_json

openssl req -x509 -new -key "${verify_dir}/boundary.key" -out "${verify_dir}/wrong-ca.crt" \
  -days 1 -subj '/CN=wrong-ca/OU=bouncer-ou'

"${k[@]}" -n "${namespace}" port-forward service/crowdsec-service 18443:8080 \
  --address=127.0.0.1 >"${verify_dir}/port-forward.log" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 30); do
  grep -q 'Forwarding from 127.0.0.1:18443' "${verify_dir}/port-forward.log" && break
  kill -0 "${port_forward_pid}" 2>/dev/null || fail mtls 'LAPI port-forward가 종료됐다.'
  sleep 1
done
grep -q 'Forwarding from 127.0.0.1:18443' "${verify_dir}/port-forward.log" \
  || fail mtls 'LAPI port-forward가 준비되지 않았다.'

curl_base=(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 10 \
  --resolve "${lapi_dns}:18443:127.0.0.1" --cacert "${verify_dir}/lapi-initial-ca.crt")
bouncer_status=$("${curl_base[@]}" --cert "${verify_dir}/bouncer.crt" --key "${verify_dir}/bouncer.key" \
  "https://${lapi_dns}:18443/v1/decisions/stream?startup=true")
[[ ${bouncer_status} == 200 ]] || fail mtls "bouncer-ou control이 200이 아니다: ${bouncer_status}"
agent_on_bouncer_status=$("${curl_base[@]}" --cert "${verify_dir}/agent-initial.crt" \
  --key "${verify_dir}/agent-initial.key" "https://${lapi_dns}:18443/v1/decisions/stream?startup=true")
[[ ${agent_on_bouncer_status} == 401 || ${agent_on_bouncer_status} == 403 ]] \
  || fail ou "agent-ou가 bouncer endpoint에서 거부되지 않았다: ${agent_on_bouncer_status}"
bouncer_on_agent_status=$("${curl_base[@]}" -X POST -H 'Content-Type: application/json' -d '{}' \
  --cert "${verify_dir}/bouncer.crt" --key "${verify_dir}/bouncer.key" \
  "https://${lapi_dns}:18443/v1/watchers/login")
[[ ${bouncer_on_agent_status} == 401 || ${bouncer_on_agent_status} == 403 ]] \
  || fail ou "bouncer-ou가 agent endpoint에서 거부되지 않았다: ${bouncer_on_agent_status}"
set +e
wrong_ca_status=$("${curl_base[@]}" --cert "${verify_dir}/wrong-ca.crt" \
  --key "${verify_dir}/boundary.key" "https://${lapi_dns}:18443/v1/decisions/stream?startup=true" 2>/dev/null)
wrong_ca_rc=$?
set -e
[[ ${wrong_ca_rc} -ne 0 && ${wrong_ca_status} == 000 ]] \
  || fail mtls "wrong CA client가 TLS에서 거부되지 않았다: rc=${wrong_ca_rc} status=${wrong_ca_status}"
echo "Evidence2=PASS actual_agent_mtls=true wrong_ca=denied wrong_ou=denied agent_on_bouncer=${agent_on_bouncer_status} bouncer_on_agent=${bouncer_on_agent_status}"
echo 'Evidence3=PASS agent_ou=watcher-only bouncer_ou=bouncer-only'

# 5. revoke -> sidecar CRL 등재 -> 같은 certificate 거부
vault_root write pki/revoke serial_number="${bouncer_serial}" >/dev/null
crl_contains_serial=false
for _ in $(seq 1 20); do
  if "${k[@]}" -n "${namespace}" exec deploy/crowdsec-lapi -c crowdsec-lapi -- \
      cat /etc/ssl/crowdsec-crl/crl.pem 2>/dev/null | \
      openssl crl -noout -text 2>/dev/null | tr -d ':' | grep -Fqi "${bouncer_serial_hex}"; then
    crl_contains_serial=true
    break
  fi
  sleep 3
done
[[ ${crl_contains_serial} == true ]] || fail revoke '폐기 serial이 LAPI CRL 파일에 등재되지 않았다.'
sleep 2
set +e
revoked_status=$("${curl_base[@]}" --cert "${verify_dir}/bouncer.crt" --key "${verify_dir}/bouncer.key" \
  "https://${lapi_dns}:18443/v1/decisions/stream?startup=true" 2>/dev/null)
revoked_rc=$?
set -e
if [[ ! (${revoked_status} == 403 || (${revoked_rc} -ne 0 && ${revoked_status} == 000)) ]]; then
  fail revoke "폐기 인증서가 거부되지 않았다: rc=${revoked_rc} status=${revoked_status}"
fi
echo "Evidence5=PASS vault_revoke=true crl_listed=true revoked_certificate=denied status=${revoked_status}"

# 4. 짧은 TTL로 한 자동 갱신 주기와 container reload
agent_uid_before=$(pod_uid agent)
lapi_uid_before=$(pod_uid lapi)
agent_restart_before=$(container_restart_count agent crowdsec-agent)
lapi_restart_before=$(container_restart_count lapi crowdsec-lapi)
agent_renewed_revision=$((agent_initial_revision + 1))
lapi_renewed_revision=$((lapi_initial_revision + 1))
wait_certificate_revision crowdsec-agent "${agent_renewed_revision}" 100 >/dev/null \
  || fail renewal "agent 자동 갱신 revision ${agent_renewed_revision}를 관측하지 못했다."
wait_certificate_revision crowdsec-lapi "${lapi_renewed_revision}" 100 >/dev/null \
  || fail renewal "LAPI 자동 갱신 revision ${lapi_renewed_revision}를 관측하지 못했다."
secret_material crowdsec-agent-tls agent-renewed
secret_material crowdsec-lapi-tls lapi-renewed
agent_renewed_fp=$(fingerprint "${verify_dir}/agent-renewed.crt")
lapi_renewed_fp=$(fingerprint "${verify_dir}/lapi-renewed.crt")
[[ ${agent_renewed_fp} != "${agent_initial_fp}" && ${lapi_renewed_fp} != "${lapi_initial_fp}" ]] \
  || fail renewal 'revision 2 뒤 fingerprint가 바뀌지 않았다.'
reload_seen=false
for _ in $(seq 1 60); do
  agent_restart_after=$(container_restart_count agent crowdsec-agent)
  lapi_restart_after=$(container_restart_count lapi crowdsec-lapi)
  if ((agent_restart_after > agent_restart_before && lapi_restart_after > lapi_restart_before)); then
    reload_seen=true
    break
  fi
  sleep 5
done
[[ ${reload_seen} == true ]] || fail renewal 'agent와 LAPI container reload를 관측하지 못했다.'
[[ $(pod_uid agent) == "${agent_uid_before}" && $(pod_uid lapi) == "${lapi_uid_before}" ]] \
  || fail renewal 'Secret 갱신 중 Pod가 교체됐다.'
agent_lapi_status || fail renewal '갱신/reload 뒤 agent mTLS가 실패했다.'
echo "Evidence4=PASS agent_revision=${agent_initial_revision}->${agent_renewed_revision} lapi_revision=${lapi_initial_revision}->${lapi_renewed_revision} fingerprint_changed=true reload=container-restart pod_uid_unchanged=true"

# 6. sealed 중 기존 consumer와 Secret 유지, 신규 발급만 실패
cat <<YAML | "${k[@]}" apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${sealed_certificate}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/part-of: pki-01-verification
spec:
  secretName: ${sealed_secret}
  commonName: ${agent_dns}
  dnsNames:
    - ${agent_dns}
  subject:
    organizationalUnits:
      - agent-ou
  duration: 2h
  renewBefore: 30m
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - client auth
  issuerRef:
    name: vault-crowdsec-agent
    kind: ClusterIssuer
    group: cert-manager.io
YAML
wait_certificate_revision "${sealed_certificate}" 1 60 >/dev/null \
  || fail sealed 'sealed probe revision 1 발급 실패'
secret_material "${sealed_secret}" sealed-before
sealed_before_fp=$(fingerprint "${verify_dir}/sealed-before.crt")
vault_root operator seal >/dev/null
vault_sealed_by_test=true
for _ in $(seq 1 20); do
  jq -e '.sealed==true' <<<"$(vault_status)" >/dev/null 2>&1 && break
  sleep 1
done
jq -e '.sealed==true' <<<"$(vault_status)" >/dev/null || fail sealed 'Vault가 sealed 상태가 아니다.'
agent_lapi_status || fail sealed 'Vault sealed 중 기존 agent mTLS가 실패했다.'
secret_material "${sealed_secret}" sealed-during
[[ $(fingerprint "${verify_dir}/sealed-during.crt") == "${sealed_before_fp}" ]] \
  || fail sealed 'Vault sealed 중 기존 인증서가 바뀌었다.'
"${k[@]}" -n "${namespace}" patch certificate "${sealed_certificate}" \
  --type=merge -p '{"spec":{"duration":"61m","renewBefore":"55m"}}' >/dev/null
sealed_failure=false
for _ in $(seq 1 40); do
  requests_json=$("${k[@]}" -n "${namespace}" get certificaterequest -o json 2>/dev/null || true)
  if jq -e --arg cert "${sealed_certificate}" '
    any(.items[];
      any(.metadata.ownerReferences[]?; .kind=="Certificate" and .name==$cert) and
      any(.status.conditions[]?;
        .type=="Ready" and .status=="False" and
        ((.message // "")|test("Vault|vault|sealed|503"))))
  ' <<<"${requests_json}" >/dev/null 2>&1; then
    sealed_failure=true
    break
  fi
  sleep 3
done
[[ ${sealed_failure} == true ]] || fail sealed 'sealed 상태의 신규 발급 실패를 관측하지 못했다.'
secret_material "${sealed_secret}" sealed-after-request
[[ $(fingerprint "${verify_dir}/sealed-after-request.crt") == "${sealed_before_fp}" ]] \
  || fail sealed '신규 발급 실패 뒤 기존 Secret이 바뀌었다.'
"${k[@]}" -n vault delete pod vault-0 --wait=true --timeout=120s >/dev/null
wait_vault_unsealed || fail sealed 'vault-0가 AWS KMS auto-unseal되지 않았다.'
for issuer in vault-crowdsec-agent vault-crowdsec-lapi; do
  for _ in $(seq 1 40); do
    issuer_json=$("${k[@]}" get clusterissuer "${issuer}" -o json 2>/dev/null || true)
    jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' \
      <<<"${issuer_json}" >/dev/null 2>&1 && break
    sleep 3
  done
  jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' \
    <<<"${issuer_json}" >/dev/null || fail sealed "${issuer}가 복구되지 않았다."
done
echo 'Evidence6=PASS sealed_existing_mtls=true sealed_existing_secret=true new_issue=failed auto_unseal=PASS'

# 7. Git 검사는 local wrapper가, 여기서는 관련 로그의 PEM private key 0건을 판정한다.
log_file=${verify_dir}/relevant.log
: >"${log_file}"
"${k[@]}" -n cert-manager logs deployment/cert-manager --since-time="${verify_started_at}" \
  >>"${log_file}" 2>&1 || true
for deployment in crowdsec-lapi crowdsec-agent crowdsec-appsec; do
  "${k[@]}" -n "${namespace}" logs "deployment/${deployment}" --all-containers=true \
    --since-time="${verify_started_at}" >>"${log_file}" 2>&1 || true
done
"${k[@]}" -n vault logs statefulset/vault --since-time="${verify_started_at}" \
  >>"${log_file}" 2>&1 || true
if grep -E '^-----BEGIN (EC |RSA |OPENSSH )?PRIVATE KEY-----$' "${log_file}" >/dev/null; then
  fail privacy '관련 로그에 private key PEM이 있다.'
fi
echo 'Evidence7=PASS git_private_key_pem=0 log_private_key_pem=0'

echo 'PKI01_REMOTE_BATCH=PASS evidence=1,2,3,4,5,6,7'
