#!/usr/bin/env bash
# CERTMGR-01 완료 증거 전용 검증기. 시험 Certificate는 정확히 한 개만 만든다.
set -euo pipefail

readonly mode=${1:-issue-renew}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly test_certificate=certmgr-01-test
readonly test_secret=certmgr-01-test-tls
readonly test_dns=certmgr-01-test.cert-manager.svc.cluster.local
readonly available_warn_bytes=$((12 * 1024 * 1024 * 1024))
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
readonly pvc_warn_bytes=$((96 * 1024 * 1024 * 1024))
readonly pvc_stop_bytes=$((120 * 1024 * 1024 * 1024))
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == capacity-pre || ${mode} == issue-renew ||
   ${mode} == issue-renew-retry || ${mode} == sealed-cleanup ]] || {
  echo 'usage: verify-live.sh [capacity-pre|issue-renew|issue-renew-retry|sealed-cleanup]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo '검증 실패 단계=precondition 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  # 인자는 이 스크립트의 비밀 없는 고정값만 전달한다.
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

measure_capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'REMOTE'
set -euo pipefail
k='sudo -n /usr/local/bin/k3s kubectl'
available_bytes=$(free -b | awk '/Mem:/{print $7}')
pvc_request_bytes=$(
  ${k} get pvc -A -o json \
    | jq -r '.items[].spec.resources.requests.storage' \
    | while IFS= read -r quantity; do numfmt --from=iec-i "${quantity}"; done \
    | awk '{sum+=$1} END{printf "%.0f\n",sum+0}'
)
printf 'AVAILABLE_BYTES=%s\nPVC_REQUEST_BYTES=%s\n' "${available_bytes}" "${pvc_request_bytes}"
REMOTE
}

capacity_field() {
  awk -F= -v key="$2" '$1==key{print $2}' <<<"$1"
}

capacity_stop_gate() {
  local prefix=$1 capacity=$2
  local available_bytes pvc_request_bytes
  available_bytes=$(capacity_field "${capacity}" AVAILABLE_BYTES)
  pvc_request_bytes=$(capacity_field "${capacity}" PVC_REQUEST_BYTES)
  [[ ${available_bytes} =~ ^[0-9]+$ && ${pvc_request_bytes} =~ ^[0-9]+$ ]] \
    || fail capacity "${prefix} RAM/PVC 측정값을 읽지 못했다."
  ((available_bytes >= available_stop_bytes)) \
    || fail capacity "${prefix} available RAM이 8 GiB 정지선 아래다: ${available_bytes}"
  ((pvc_request_bytes < pvc_stop_bytes)) \
    || fail capacity "${prefix} PVC 선언 합계가 120 GiB 정지선에 도달했다: ${pvc_request_bytes}"
}

if [[ ${mode} == capacity-pre ]]; then
  capacity=$(measure_capacity)
  capacity_stop_gate PRE "${capacity}"
  available_bytes=$(capacity_field "${capacity}" AVAILABLE_BYTES)
  pvc_request_bytes=$(capacity_field "${capacity}" PVC_REQUEST_BYTES)
  ram_band=NORMAL
  pvc_band=NORMAL
  ((available_bytes < available_warn_bytes)) && ram_band=WARNING
  ((pvc_request_bytes >= pvc_warn_bytes)) && pvc_band=WARNING
  echo "CAPACITY_PRE=PASS AVAILABLE_BYTES=${available_bytes} AVAILABLE_BAND=${ram_band} PVC_REQUEST_BYTES=${pvc_request_bytes} PVC_BAND=${pvc_band}"
  exit 0
fi

cleanup_test() {
  remote_kubectl -n cert-manager delete certificate "${test_certificate}" \
    --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  remote_kubectl -n cert-manager delete certificaterequest \
    -l "cert-manager.io/certificate-name=${test_certificate}" \
    --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  remote_kubectl -n cert-manager delete secret "${test_secret}" \
    --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
}

certificate_fingerprint() {
  local secret_json leaf_b64 ca_b64 leaf_pem ca_pem
  secret_json=$(remote_kubectl -n cert-manager get secret "${test_secret}" -o json)
  leaf_b64=$(jq -r '.data["tls.crt"] // ""' <<<"${secret_json}")
  ca_b64=$(jq -r '.data["ca.crt"] // ""' <<<"${secret_json}")
  [[ -n ${leaf_b64} && -n ${ca_b64} ]] || fail certificate 'Secret의 tls.crt 또는 ca.crt가 비었다.'
  leaf_pem=$(base64 -d <<<"${leaf_b64}")
  ca_pem=$(base64 -d <<<"${ca_b64}")
  openssl verify -CAfile <(printf '%s\n' "${ca_pem}") <(printf '%s\n' "${leaf_pem}") >/dev/null \
    || fail certificate 'Vault PKI chain 검증에 실패했다.'
  printf '%s\n' "${leaf_pem}" | openssl x509 -noout -fingerprint -sha256 \
    | sed 's/^sha256 Fingerprint=//;s/://g'
}

wait_issuer_ready() {
  local issuer_json
  for _ in $(seq 1 40); do
    issuer_json=$(remote_kubectl get clusterissuer vault-internal -o json 2>/dev/null || true)
    if jq -e '.status.conditions[]? | select(.type=="Ready" and .status=="True")' \
      <<<"${issuer_json}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

if [[ ${mode} == issue-renew || ${mode} == issue-renew-retry ]]; then
  readonly expected_config_revision=${CERTMGR01_EXPECTED_CONFIG_REVISION:?cert-manager 설정 commit SHA가 필요하다}
  readonly expected_root_revision=${CERTMGR01_EXPECTED_ROOT_REVISION:?platform-root pointer commit SHA가 필요하다}
  [[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
    || fail argo 'immutable commit SHA 형식이 아니다.'
  if [[ ${mode} == issue-renew ]]; then
    readonly pre_available_bytes=${CERTMGR01_PRE_AVAILABLE_BYTES:?배포 전 available bytes가 필요하다}
    readonly pre_pvc_request_bytes=${CERTMGR01_PRE_PVC_REQUEST_BYTES:?배포 전 PVC 합계가 필요하다}
    [[ ${pre_available_bytes} =~ ^[0-9]+$ && ${pre_pvc_request_bytes} =~ ^[0-9]+$ ]] \
      || fail capacity '배포 전 capacity 입력이 정수가 아니다.'
  fi

  argo_json=''
  for _ in $(seq 1 72); do
    argo_json=$(remote_kubectl -n argocd get applications platform-root cert-manager -o json 2>/dev/null || true)
    if jq -e --arg root_revision "${expected_root_revision}" --arg child_revision "${expected_config_revision}" '
      ([.items[] | select(.metadata.name=="platform-root")][0] // {}) as $root_app |
      ([.items[] | select(.metadata.name=="cert-manager")][0] // {}) as $child_app |
      $root_app.spec.source.targetRevision==$root_revision and $root_app.status.sync.revision==$root_revision and
      $root_app.status.sync.status=="Synced" and $root_app.status.health.status=="Healthy" and
      $child_app.spec.source.targetRevision==$child_revision and $child_app.status.sync.revision==$child_revision and
      $child_app.status.sync.status=="Synced" and $child_app.status.health.status=="Healthy"
    ' <<<"${argo_json}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  jq -e --arg root_revision "${expected_root_revision}" --arg child_revision "${expected_config_revision}" '
    ([.items[] | select(.metadata.name=="platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name=="cert-manager")][0] // {}) as $child_app |
    $root_app.spec.source.targetRevision==$root_revision and $root_app.status.sync.revision==$root_revision and
    $root_app.status.sync.status=="Synced" and $root_app.status.health.status=="Healthy" and
    $child_app.spec.source.targetRevision==$child_revision and $child_app.status.sync.revision==$child_revision and
    $child_app.status.sync.status=="Synced" and $child_app.status.health.status=="Healthy"
  ' <<<"${argo_json}" >/dev/null || fail argo 'root/child가 immutable SHA에서 Synced/Healthy가 아니다.'
  if [[ ${mode} == issue-renew ]]; then
    echo "Argo=PASS root=${expected_root_revision} child=${expected_config_revision}"
  else
    echo "RetryPrerequisite=PASS root=${expected_root_revision} child=${expected_config_revision}"
  fi

  for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
    remote_kubectl -n cert-manager rollout status "deployment/${deployment}" --timeout=180s >/dev/null \
      || fail deployment "${deployment}가 Ready가 아니다."
  done
  wait_issuer_ready || fail issuer 'ClusterIssuer/vault-internal이 Ready가 아니다.'
  if [[ ${mode} == issue-renew ]]; then
    echo 'Controller=PASS deployments=3 clusterissuer=vault-internal'

    capacity=$(measure_capacity)
    capacity_stop_gate POST "${capacity}"
    available_bytes=$(capacity_field "${capacity}" AVAILABLE_BYTES)
    pvc_request_bytes=$(capacity_field "${capacity}" PVC_REQUEST_BYTES)
    ((pvc_request_bytes == pre_pvc_request_bytes)) \
      || fail capacity "cert-manager 배포 전후 PVC 합계가 달라졌다: ${pre_pvc_request_bytes}->${pvc_request_bytes}"
    ram_band=NORMAL
    pvc_band=NORMAL
    ((available_bytes < available_warn_bytes)) && ram_band=WARNING
    ((pvc_request_bytes >= pvc_warn_bytes)) && pvc_band=WARNING
    echo "CAPACITY_POST=PASS PRE_AVAILABLE_BYTES=${pre_available_bytes} POST_AVAILABLE_BYTES=${available_bytes} DELTA_BYTES=$((available_bytes - pre_available_bytes)) AVAILABLE_BAND=${ram_band} PRE_PVC_REQUEST_BYTES=${pre_pvc_request_bytes} POST_PVC_REQUEST_BYTES=${pvc_request_bytes} PVC_BAND=${pvc_band}"

    jwt=$(remote_kubectl -n cert-manager create token cert-manager-vault-issuer \
      --audience=vault://vault-internal --duration=10m)
    [[ -n ${jwt} ]] || fail vault-policy '전용 ServiceAccount TokenRequest가 비었다.'
    # shellcheck disable=SC2029
    ssh "${ssh_options[@]}" "${k3s_host}" \
      "${kubectl_command} -n vault exec -i vault-0 -- sh -c \
      'read -r jwt; export jwt; exec sh'" \
      < <(
        printf '%s\n' "${jwt}"
        cat <<'REMOTE'
set -eu
vault_token=$(printf '%s' "${jwt}" | vault write -field=token \
  auth/kubernetes/login role=cert-manager-vault-issuer jwt=-)
unset jwt
export VAULT_TOKEN=${vault_token}
unset vault_token
set +e
denied=$(vault write pki/sign/internal-workload csr=invalid 2>&1)
rc=$?
set -e
test ${rc} -ne 0
printf '%s' "${denied}" | grep -q 'Code: 403'
printf '%s' "${denied}" | grep -q 'permission denied'
REMOTE
      ) \
      || fail vault-policy '전용 auth role 로그인 또는 타 PKI role 403 판정에 실패했다.'
    unset jwt
    echo 'VaultPolicy=PASS auth_role=cert-manager-vault-issuer allowed=pki/sign/cert-manager-internal-workload denied=pki/sign/internal-workload code=403'
  fi

  test_created=false
  keep_for_sealed=false
  # shellcheck disable=SC2329
  cleanup_on_exit() {
    if [[ ${test_created} == true && ${keep_for_sealed} == false ]]; then
      cleanup_test
    fi
  }
  trap cleanup_on_exit EXIT HUP INT TERM
  cleanup_test
  remote_kubectl apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${test_certificate}
  namespace: cert-manager
  labels:
    app.kubernetes.io/part-of: certmgr-01-verification
spec:
  secretName: ${test_secret}
  commonName: ${test_dns}
  duration: 1h
  renewBefore: 55m
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - server auth
    - client auth
  dnsNames:
    - ${test_dns}
  issuerRef:
    name: vault-internal
    kind: ClusterIssuer
    group: cert-manager.io
YAML
  test_created=true

  cert_json=''
  for _ in $(seq 1 48); do
    cert_json=$(remote_kubectl -n cert-manager get certificate "${test_certificate}" -o json 2>/dev/null || true)
    if jq -e '.status.revision==1 and (.status.conditions[]? | select(.type=="Ready" and .status=="True"))' \
      <<<"${cert_json}" >/dev/null 2>&1; then
      break
    fi
    sleep 3
  done
  jq -e '.status.revision==1 and (.status.conditions[]? | select(.type=="Ready" and .status=="True"))' \
    <<<"${cert_json}" >/dev/null || fail certificate '시험 Certificate 최초 발급이 Ready revision 1에 도달하지 못했다.'
  remote_kubectl -n cert-manager get secret "${test_secret}" -o json \
    | jq -e '(.data | keys | sort)==["ca.crt","tls.crt","tls.key"]' >/dev/null \
    || fail certificate '시험 Secret의 key 집합이 ca.crt/tls.crt/tls.key가 아니다.'
  initial_fingerprint=$(certificate_fingerprint)
  renewal_time=$(jq -r '.status.renewalTime' <<<"${cert_json}")
  echo "CertificateIssue=PASS revision=1 secret_keys=3 chain=OK fingerprint=${initial_fingerprint} renewal_time=${renewal_time}"

  renewed_json=''
  renewed_fingerprint=''
  for _ in $(seq 1 96); do
    renewed_json=$(remote_kubectl -n cert-manager get certificate "${test_certificate}" -o json 2>/dev/null || true)
    revision=$(jq -r '.status.revision // 0' <<<"${renewed_json}" 2>/dev/null || printf 0)
    ((revision <= 2)) || fail renewal "한 사이클을 넘겨 revision ${revision}까지 갔다. renewal loop 가능성이 있다."
    if [[ ${revision} == 2 ]] && jq -e '.status.conditions[]? | select(.type=="Ready" and .status=="True")' \
      <<<"${renewed_json}" >/dev/null 2>&1; then
      renewed_fingerprint=$(certificate_fingerprint)
      [[ ${renewed_fingerprint} != "${initial_fingerprint}" ]] \
        || fail renewal 'revision은 2지만 인증서 fingerprint가 바뀌지 않았다.'
      break
    fi
    sleep 5
  done
  [[ -n ${renewed_fingerprint} ]] || fail renewal '단축 renewBefore의 자동 갱신 한 사이클을 관측하지 못했다.'
  echo "AutoRenew=PASS revision=1->2 chain=OK fingerprint_changed=true renewed_fingerprint=${renewed_fingerprint}"
  remote_kubectl -n cert-manager patch certificate "${test_certificate}" \
    --type=merge --patch-file=/dev/stdin >/dev/null <<'JSON'
{"spec":{"renewBefore":"5m"}}
JSON
  cert_json=$(remote_kubectl -n cert-manager get certificate "${test_certificate}" -o json)
  jq -e '.spec.renewBefore=="5m" and .status.revision==2 and
    (.status.conditions[]? | select(.type=="Ready" and .status=="True"))' \
    <<<"${cert_json}" >/dev/null || fail renewal '한 사이클 뒤 renewBefore quiesce가 revision 2를 유지하지 못했다.'
  echo 'RenewalQuiesce=PASS revision=2 renewBefore=5m'
  keep_for_sealed=true
  trap - EXIT HUP INT TERM
  echo 'ISSUE_RENEW=PASS test_certificate_retained_for=sealed-cleanup'
  exit 0
fi

# sealed-cleanup은 Vault를 일시 중단하므로 호출 직전에 별도 승인이 있어야 한다.
readonly expected_sealed_revision=${CERTMGR01_EXPECTED_SEALED_REVISION:-2}
readonly verify_sealed_existing=${CERTMGR01_VERIFY_SEALED_EXISTING:-true}
[[ ${expected_sealed_revision} =~ ^[1-9][0-9]*$ ]] \
  || fail sealed 'sealed 시험 전 예상 revision이 양의 정수가 아니다.'
[[ ${verify_sealed_existing} == true || ${verify_sealed_existing} == false ]] \
  || fail sealed '기존 인증서 확인 여부는 true 또는 false여야 한다.'
[[ -f ${vault_token_file} && ! -L ${vault_token_file} &&
   $(stat -c %a "${vault_token_file}") == 600 ]] \
  || fail sealed 'Vault root token file이 없거나 mode 0600이 아니다.'

exec 9>/tmp/certmgr-01-sealed.lock
flock -n 9 || fail sealed '다른 CERTMGR-01 sealed 시험이 실행 중이다.'

vault_status_json() {
  remote_kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null || true
}

sealed_by_test=false
vault_restart_attempted=false
vault_old_uid=''

auto_unseal_vault() {
  local current_uid pod_json pod_ready status_json
  status_json=$(vault_status_json)
  if jq -e '.sealed==false and .type=="awskms"' <<<"${status_json}" >/dev/null 2>&1; then
    sealed_by_test=false
    return 0
  fi
  if [[ ${vault_restart_attempted} == false ]]; then
    pod_json=$(remote_kubectl -n vault get pod vault-0 -o json)
    vault_old_uid=$(jq -r '.metadata.uid // ""' <<<"${pod_json}")
    [[ -n ${vault_old_uid} ]] || return 1
    vault_restart_attempted=true
    remote_kubectl -n vault delete pod vault-0 --wait=true --timeout=120s >/dev/null || return 1
  fi
  for _ in $(seq 1 60); do
    status_json=$(vault_status_json)
    pod_json=$(remote_kubectl -n vault get pod vault-0 -o json 2>/dev/null || true)
    current_uid=$(jq -r '.metadata.uid // ""' <<<"${pod_json}" 2>/dev/null || true)
    pod_ready=$(jq -r '([.status.conditions[]? | select(.type=="Ready")][0].status) // ""' \
      <<<"${pod_json}" 2>/dev/null || true)
    if jq -e '.sealed==false and .type=="awskms"' <<<"${status_json}" >/dev/null 2>&1 \
      && [[ -n ${current_uid} && ${current_uid} != "${vault_old_uid}" ]] \
      && [[ ${pod_ready} == True ]]; then
      sealed_by_test=false
      return 0
    fi
    sleep 3
  done
  return 1
}

recover_and_cleanup() {
  local exit_status=$?
  trap - EXIT HUP INT TERM
  if [[ ${sealed_by_test} == true ]]; then
    if ! auto_unseal_vault >/dev/null 2>&1; then
      echo '긴급 복구 실패: vault-0 재생성 뒤 AWS KMS auto-unseal되지 않았다.' >&2
      exit_status=1
    fi
  fi
  cleanup_test
  exit "${exit_status}"
}
trap recover_and_cleanup EXIT HUP INT TERM

cert_json=$(remote_kubectl -n cert-manager get certificate "${test_certificate}" -o json 2>/dev/null || true)
before_revision=$(jq -r '.status.revision // 0' <<<"${cert_json}" 2>/dev/null || printf 0)
[[ ${before_revision} == "${expected_sealed_revision}" ]] \
  || fail sealed "sealed 시험 전 Certificate revision이 ${expected_sealed_revision}이 아니다: ${before_revision}"
before_fingerprint=$(certificate_fingerprint)

# shellcheck disable=SC2029
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c \
   'read -r VAULT_TOKEN; export VAULT_TOKEN; vault operator seal >/dev/null'" \
  < <({ tr -d '\n' <"${vault_token_file}"; printf '\n'; })
sealed_by_test=true

for _ in $(seq 1 20); do
  status_json=$(vault_status_json)
  jq -e '.sealed==true' <<<"${status_json}" >/dev/null 2>&1 && break
  sleep 1
done
jq -e '.sealed==true' <<<"${status_json}" >/dev/null || fail sealed 'Vault가 sealed 상태에 도달하지 않았다.'

if [[ ${verify_sealed_existing} == true ]]; then
  sealed_fingerprint=$(certificate_fingerprint)
  [[ ${sealed_fingerprint} == "${before_fingerprint}" ]] \
    || fail sealed 'sealed 상태에서 기존 Secret 인증서가 바뀌었다.'
  echo "SealedExisting=PASS revision=${before_revision} chain=OK fingerprint_unchanged=true"
fi

remote_kubectl -n cert-manager patch certificate "${test_certificate}" \
  --type=merge --patch-file=/dev/stdin >/dev/null <<'JSON'
{"spec":{"duration":"61m","renewBefore":"55m"}}
JSON
target_revision=$((before_revision + 1))
request_failed=false
for _ in $(seq 1 40); do
  requests_json=$(remote_kubectl -n cert-manager get certificaterequests -o json 2>/dev/null || true)
  issuer_json=$(remote_kubectl get clusterissuer vault-internal -o json 2>/dev/null || true)
  request_ready_false=$(jq -r --arg cert "${test_certificate}" --arg revision "${target_revision}" '
    any(.items[];
      select(any(.metadata.ownerReferences[]?; .kind=="Certificate" and .name==$cert)) |
      select(.metadata.annotations["cert-manager.io/certificate-revision"]==$revision) |
      .status.conditions[]? |
      .type=="Ready" and .status=="False")
  ' <<<"${requests_json}" 2>/dev/null || printf false)
  request_vault_error=$(jq -r --arg cert "${test_certificate}" --arg revision "${target_revision}" '
    any(.items[];
      select(any(.metadata.ownerReferences[]?; .kind=="Certificate" and .name==$cert)) |
      select(.metadata.annotations["cert-manager.io/certificate-revision"]==$revision) |
      .status.conditions[]? |
      .type=="Ready" and .status=="False" and
      ((.message // "") | test("sealed|503|vault"; "i")))
  ' <<<"${requests_json}" 2>/dev/null || printf false)
  issuer_vault_error=$(jq -r '
    any(.status.conditions[]?;
      .type=="Ready" and .status=="False" and .reason=="VaultError" and
      ((.message // "") | test("sealed|503|initialized and unsealed"; "i")))
  ' <<<"${issuer_json}" 2>/dev/null || printf false)
  if [[ ${request_ready_false} == true &&
        ( ${request_vault_error} == true || ${issuer_vault_error} == true ) ]]; then
    request_failed=true
    break
  fi
  sleep 3
done
[[ ${request_failed} == true ]] || fail sealed 'sealed 중 신규 CertificateRequest의 Vault 실패를 한 번 관측하지 못했다.'
current_revision=$(remote_kubectl -n cert-manager get certificate "${test_certificate}" -o jsonpath='{.status.revision}')
current_fingerprint=$(certificate_fingerprint)
[[ ${current_revision} == "${before_revision}" && ${current_fingerprint} == "${before_fingerprint}" ]] \
  || fail sealed '신규 발급 실패 중 기존 인증서 revision 또는 fingerprint가 바뀌었다.'
echo "SealedNewIssue=PASS requested_revision=${target_revision} ready=False vault_error=true existing_revision=${current_revision}"

auto_unseal_vault || fail sealed 'vault-0 재생성 뒤 AWS KMS auto-unseal 복구에 실패했다.'
wait_issuer_ready || fail sealed 'auto-unseal 뒤 ClusterIssuer/vault-internal이 Ready로 복구되지 않았다.'
cleanup_test
for _ in $(seq 1 20); do
  remaining=$(remote_kubectl -n cert-manager get certificate,certificaterequest,secret -o name 2>/dev/null \
    | grep "${test_certificate}" || true)
  [[ -z ${remaining} ]] && break
  sleep 1
done
[[ -z ${remaining} ]] || fail cleanup '시험 Certificate/CertificateRequest/Secret이 남아 있다.'
trap - EXIT HUP INT TERM
echo 'SealedRecovery=PASS vault=awskms-auto-unsealed pod_recreations=1 clusterissuer=Ready test_resources=removed'
echo 'SEALED_CLEANUP=PASS'
