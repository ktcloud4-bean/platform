#!/usr/bin/env bash
# BKP-03 Vault Raft snapshot의 S3 round-trip과 격리 restore를 검증한다.
# live vault-0에는 snapshot save와 폐기형 marker write/delete만 수행한다.
# snapshot restore endpoint는 고정 namespace의 별도 Pod에만 호출한다.
set -euo pipefail
umask 077

: "${VAULT_ROOT_TOKEN_FILE:?저장소 밖 root token 파일 경로가 필요하다}"
: "${VAULT_UNSEAL_KEYS_FILE:?원본 Shamir key 3개 이상을 한 줄씩 둔 mode 0600 파일이 필요하다}"
K3S_HOST="${K3S_HOST:-rocky@10.10.20.10}"
KUBECTL="${KUBECTL:-sudo /usr/local/bin/k3s kubectl}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${BKP03_RESTORE_MANIFEST:-${SCRIPT_DIR}/../restore/bkp03-isolated-restore.yaml}"
RESTORE_NS=bkp-03-vault-restore
RESTORE_POD=vault-restore
RESTORE_PORT=18200
LIVE_MARKER_PATH=kv/bkp-03/restore-marker
REMOTE_RESTORE_INPUT=/var/lib/vault-raft-backup/restore-input.snap
REMOTE_PF_LOG=/run/bkp03-vault-restore-port-forward.log
SSH_ARGS=(-o BatchMode=yes -o StrictHostKeyChecking=yes
          -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
          -o PasswordAuthentication=no -o ControlMaster=no)
PF_PID=
MARKER_CREATED=0
NAMESPACE_CREATED=0

cleanup_live_marker() {
  if [ "${MARKER_CREATED}" -eq 1 ]; then
    {
      sed -n '1p' "${VAULT_ROOT_TOKEN_FILE}"
      cat <<'REMOTE'
vault kv metadata delete kv/bkp-03/restore-marker >/dev/null 2>&1 || true
REMOTE
    } | ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
      "${KUBECTL} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'" \
      >/dev/null 2>&1 || true
    MARKER_CREATED=0
  fi
}

stop_port_forward() {
  if [[ "${PF_PID}" =~ ^[0-9]+$ ]]; then
    ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
      "sudo env PF_PID=${PF_PID} REMOTE_PF_LOG=${REMOTE_PF_LOG} bash -s" <<'REMOTE'
set -euo pipefail
if [ -r "/proc/${PF_PID}/cmdline" ]; then
  [ "$(cat "/proc/${PF_PID}/comm")" = kubectl ] \
    || { echo "격리 port-forward PID의 프로세스 이름이 다르다" >&2; exit 1; }
  ss -H -lntp | grep -F '127.0.0.1:18200' | grep -F "pid=${PF_PID}," >/dev/null \
    || { echo "격리 port-forward PID가 loopback listener를 소유하지 않는다" >&2; exit 1; }
  kill -TERM "${PF_PID}"
  for _ in 1 2 3 4 5; do
    kill -0 "${PF_PID}" 2>/dev/null || break
    sleep 1
  done
  kill -KILL "${PF_PID}" 2>/dev/null || true
fi
rm -f -- "${REMOTE_PF_LOG}"
REMOTE
  fi
  PF_PID=
}

cleanup() {
  set +e
  cleanup_live_marker
  stop_port_forward
  if [ "${NAMESPACE_CREATED}" -eq 1 ]; then
    ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
      "${KUBECTL} delete namespace ${RESTORE_NS} --wait=true --timeout=120s" >/dev/null 2>&1 || true
  fi
  ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
    "sudo rm -f ${REMOTE_RESTORE_INPUT} ${REMOTE_PF_LOG} /run/bkp03-vault-restore-init.json /run/bkp03-vault-restore-curl.conf" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for f in "${VAULT_ROOT_TOKEN_FILE}" "${VAULT_UNSEAL_KEYS_FILE}"; do
  [ -r "${f}" ] || { echo "필수 파일을 읽을 수 없다: ${f}" >&2; exit 1; }
  [ "$(stat -c %a "${f}")" = 600 ] || { echo "필수 파일 mode는 0600이어야 한다: ${f}" >&2; exit 1; }
done
[ -r "${MANIFEST}" ] || { echo "격리 restore manifest가 없다" >&2; exit 1; }
[ "$(awk 'NF {n++} END {print n+0}' "${VAULT_UNSEAL_KEYS_FILE}")" -ge 3 ] \
  || { echo "Shamir key가 3개 미만이다" >&2; exit 1; }
awk 'NF && $0 !~ /^[A-Za-z0-9+\/=]+$/ {exit 1}' "${VAULT_UNSEAL_KEYS_FILE}" \
  || { echo "Shamir key 파일 형식이 잘못됐다" >&2; exit 1; }
grep -Fq 'name: bkp-03-vault-restore' "${MANIFEST}" \
  || { echo "restore namespace guard가 manifest와 다르다" >&2; exit 1; }

if ssh "${SSH_ARGS[@]}" "${K3S_HOST}" "${KUBECTL} get namespace ${RESTORE_NS}" >/dev/null 2>&1; then
  echo "기존 ${RESTORE_NS} namespace가 있어 소유권을 판정할 수 없다" >&2
  exit 1
fi
if ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "sudo ss -H -lnt | awk '\$4 ~ /:${RESTORE_PORT}\$/ {found=1} END {exit found ? 0 : 1}'"; then
  echo "격리 restore loopback port가 이미 사용 중이다" >&2
  exit 1
fi

LIVE_STATUS=$(ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n vault exec vault-0 -- vault status -format=json")
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["initialized"] and not d["sealed"] and d["storage_type"]=="raft" and d["is_self"]' \
  <<<"${LIVE_STATUS}"
unset LIVE_STATUS

MARKER="bkp03-$(openssl rand -hex 24)"
EXPECTED_MARKER_SHA=$(printf '%s' "${MARKER}" | sha256sum | awk '{print $1}')

{
  sed -n '1p' "${VAULT_ROOT_TOKEN_FILE}"
  printf 'vault kv put %q marker=%q >/dev/null\n' "${LIVE_MARKER_PATH}" "${MARKER}"
} | ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'"
MARKER_CREATED=1
unset MARKER

mapfile -t LIVE_HASHES < <(
  {
    sed -n '1p' "${VAULT_ROOT_TOKEN_FILE}"
    cat <<'REMOTE'
set -eu
MARKER_VALUE=$(vault kv get -field=marker kv/bkp-03/restore-marker)
printf '%s' "${MARKER_VALUE}" | sha256sum | awk '{print $1}'
AUTH_CANONICAL=$(
  for field in alias_metadata alias_name_source bound_service_account_names \
    bound_service_account_namespace_selector bound_service_account_namespaces \
    token_bound_cidrs token_explicit_max_ttl token_max_ttl token_no_default_policy \
    token_num_uses token_period token_policies token_ttl token_type; do
    VALUE=$(vault read -field="${field}" auth/kubernetes/role/keycloak)
    printf '%s=%s\n' "${field}" "${VALUE}"
  done
)
printf '%s' "${AUTH_CANONICAL}" | sha256sum | awk '{print $1}'
POLICY_VALUE=$(vault policy read keycloak)
printf '%s' "${POLICY_VALUE}" | sha256sum | awk '{print $1}'
REMOTE
  } | ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
    "${KUBECTL} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'"
)
[ "${#LIVE_HASHES[@]}" -eq 3 ] || { echo "live Vault 비교 hash를 얻지 못했다" >&2; exit 1; }
[ "${LIVE_HASHES[0]}" = "${EXPECTED_MARKER_SHA}" ] || { echo "live marker hash 불일치" >&2; exit 1; }

ssh "${SSH_ARGS[@]}" "${K3S_HOST}" "sudo systemctl reset-failed vault-raft-backup.service; sudo systemctl start vault-raft-backup.service"
cleanup_live_marker
ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "sudo systemctl reset-failed vault-raft-restore-download.service >/dev/null 2>&1 || true; sudo systemctl start vault-raft-restore-download.service"

mapfile -t SNAPSHOT_INFO < <(ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "sudo sed -n '1p' /var/lib/vault-raft-backup/last-object; sudo sed -n '1p' /var/lib/vault-raft-backup/last-sha256")
[ "${#SNAPSHOT_INFO[@]}" -eq 2 ] || { echo "snapshot report 입력을 읽지 못했다" >&2; exit 1; }
[[ "${SNAPSHOT_INFO[0]}" =~ ^vault/vault-raft-[0-9]{8}T[0-9]{6}Z\.snap$ ]] \
  || { echo "snapshot object 형식이 잘못됐다" >&2; exit 1; }
[[ "${SNAPSHOT_INFO[1]}" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "snapshot SHA-256 형식이 잘못됐다" >&2; exit 1; }

ssh "${SSH_ARGS[@]}" "${K3S_HOST}" "${KUBECTL} apply -f -" <"${MANIFEST}" >/dev/null
NAMESPACE_CREATED=1
ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n ${RESTORE_NS} wait --for=jsonpath='{.status.phase}'=Running pod/${RESTORE_POD} --timeout=120s" >/dev/null

SERVICE_COUNT=$(ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n ${RESTORE_NS} get service --no-headers 2>/dev/null | wc -l")
[ "${SERVICE_COUNT}" -eq 0 ] || { echo "격리 restore namespace에 Service가 생겼다" >&2; exit 1; }
TOKEN_MOUNT_COUNT=$(ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n ${RESTORE_NS} exec ${RESTORE_POD} -- sh -c 'test -e /var/run/secrets/kubernetes.io/serviceaccount/token; echo \$?'")
[ "${TOKEN_MOUNT_COUNT}" -ne 0 ] || { echo "격리 Pod에 ServiceAccount token이 마운트됐다" >&2; exit 1; }

LIVE_VAULT_IP=$(ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n vault get service vault -o jsonpath='{.spec.clusterIP}'")
for target in "${LIVE_VAULT_IP}:8200" "10.10.50.10:5432" "10.10.50.20:8333"; do
  host=${target%:*}
  port=${target##*:}
  if ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
    "${KUBECTL} -n ${RESTORE_NS} exec ${RESTORE_POD} -- nc -z -w 2 ${host} ${port}" >/dev/null 2>&1; then
    echo "격리 restore Pod의 egress가 열려 있다 target=${target}" >&2
    exit 1
  fi
done
ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n vault exec vault-0 -- nc -z -w 2 127.0.0.1 8200" >/dev/null

ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "sudo cat ${REMOTE_RESTORE_INPUT} | ${KUBECTL} -n ${RESTORE_NS} exec -i ${RESTORE_POD} -- sh -c 'umask 077; cat > /vault/restore/input.snap'"

PF_PID=$(ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "sudo env RESTORE_NS=${RESTORE_NS} RESTORE_POD=${RESTORE_POD} RESTORE_PORT=${RESTORE_PORT} REMOTE_PF_LOG=${REMOTE_PF_LOG} bash -s" <<'REMOTE'
set -euo pipefail
rm -f -- "${REMOTE_PF_LOG}"
/usr/local/bin/k3s kubectl -n "${RESTORE_NS}" port-forward --address=127.0.0.1 \
  "pod/${RESTORE_POD}" "${RESTORE_PORT}:${RESTORE_PORT}" >"${REMOTE_PF_LOG}" 2>&1 &
echo "$!"
REMOTE
)
[[ "${PF_PID}" =~ ^[0-9]+$ ]] || { echo "격리 port-forward PID 형식이 잘못됐다" >&2; exit 1; }
for _ in $(seq 1 30); do
  if ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
    "curl --silent --output /dev/null --connect-timeout 1 --max-time 2 http://127.0.0.1:${RESTORE_PORT}/v1/sys/health"; then
    break
  fi
  sleep 1
done
ssh "${SSH_ARGS[@]}" "${K3S_HOST}" "sudo kill -0 ${PF_PID}" 2>/dev/null || {
  ssh "${SSH_ARGS[@]}" "${K3S_HOST}" "sudo cat ${REMOTE_PF_LOG}" >&2 || true
  echo "격리 Vault port-forward가 종료됐다" >&2
  exit 1
}

ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "sudo env RESTORE_PORT=${RESTORE_PORT} REMOTE_RESTORE_INPUT=${REMOTE_RESTORE_INPUT} bash -s" <<'REMOTE'
set -euo pipefail
umask 077
INIT=/run/bkp03-vault-restore-init.json
CURLCFG=/run/bkp03-vault-restore-curl.conf
cleanup_remote() { rm -f "${INIT}" "${CURLCFG}"; }
trap cleanup_remote EXIT INT TERM
curl --silent --show-error --fail --request PUT \
  --data '{"secret_shares":1,"secret_threshold":1}' \
  "http://127.0.0.1:${RESTORE_PORT}/v1/sys/init" >"${INIT}"
KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keys_base64"][0])' "${INIT}")
printf '%s\n' "${KEY}" | python3 -c 'import json,sys; print(json.dumps({"key":sys.stdin.readline().strip()}))' |
  curl --silent --show-error --fail --request PUT --data-binary @- \
    "http://127.0.0.1:${RESTORE_PORT}/v1/sys/unseal" >/dev/null
unset KEY
ROOT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_token"])' "${INIT}")
printf 'header = "X-Vault-Token: %s"\n' "${ROOT}" >"${CURLCFG}"
unset ROOT
curl --silent --show-error --fail --config "${CURLCFG}" --request POST \
  --data-binary @"${REMOTE_RESTORE_INPUT}" \
  "http://127.0.0.1:${RESTORE_PORT}/v1/sys/storage/raft/snapshot-force" >/dev/null
REMOTE

for i in 1 2 3; do
  sed -n "${i}p" "${VAULT_UNSEAL_KEYS_FILE}" |
    ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
      "python3 -c 'import json,sys; print(json.dumps({\"key\":sys.stdin.readline().strip()}))' | sudo curl --silent --show-error --fail --request PUT --data-binary @- http://127.0.0.1:${RESTORE_PORT}/v1/sys/unseal >/dev/null"
done

{
  sed -n '1p' "${VAULT_ROOT_TOKEN_FILE}"
  printf '%s\n' "${EXPECTED_MARKER_SHA}" "${LIVE_HASHES[1]}" "${LIVE_HASHES[2]}"
} | ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n ${RESTORE_NS} exec -i ${RESTORE_POD} -- sh -c '
    set -eu
    read -r VAULT_TOKEN
    read -r EXPECTED_MARKER_SHA
    read -r EXPECTED_AUTH_SHA
    read -r EXPECTED_POLICY_SHA
    export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:${RESTORE_PORT}
    vault status -format=json | grep -q \"\\\"sealed\\\": false\"
    vault secrets list | grep -q \"^kv/\"
    vault auth list | grep -q \"^kubernetes/\"
    MARKER_VALUE=\$(vault kv get -field=marker kv/bkp-03/restore-marker)
    ACTUAL_MARKER_SHA=\$(printf \"%s\" \"\${MARKER_VALUE}\" | sha256sum | awk \"{print \\\$1}\")
    AUTH_CANONICAL=\$(
      for field in alias_metadata alias_name_source bound_service_account_names \
        bound_service_account_namespace_selector bound_service_account_namespaces \
        token_bound_cidrs token_explicit_max_ttl token_max_ttl token_no_default_policy \
        token_num_uses token_period token_policies token_ttl token_type; do
        VALUE=\$(vault read -field=\"\${field}\" auth/kubernetes/role/keycloak)
        printf \"%s=%s\\n\" \"\${field}\" \"\${VALUE}\"
      done
    )
    ACTUAL_AUTH_SHA=\$(printf \"%s\" \"\${AUTH_CANONICAL}\" | sha256sum | awk \"{print \\\$1}\")
    POLICY_VALUE=\$(vault policy read keycloak)
    ACTUAL_POLICY_SHA=\$(printf \"%s\" \"\${POLICY_VALUE}\" | sha256sum | awk \"{print \\\$1}\")
    test \"\${ACTUAL_MARKER_SHA}\" = \"\${EXPECTED_MARKER_SHA}\"
    test \"\${ACTUAL_AUTH_SHA}\" = \"\${EXPECTED_AUTH_SHA}\"
    test \"\${ACTUAL_POLICY_SHA}\" = \"\${EXPECTED_POLICY_SHA}\"
    printf \"Vault isolated restore PASS marker_sha256=%s auth_sha256=%s policy_sha256=%s\\n\" \\
      \"\${ACTUAL_MARKER_SHA}\" \"\${ACTUAL_AUTH_SHA}\" \"\${ACTUAL_POLICY_SHA}\"
  '"

stop_port_forward
ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} delete namespace ${RESTORE_NS} --wait=true --timeout=120s" >/dev/null
NAMESPACE_CREATED=0
ssh "${SSH_ARGS[@]}" "${K3S_HOST}" "sudo rm -f ${REMOTE_RESTORE_INPUT}"

MARKER_STATE=$({
  sed -n '1p' "${VAULT_ROOT_TOKEN_FILE}"
  cat <<'REMOTE'
if vault kv metadata get kv/bkp-03/restore-marker >/dev/null 2>&1; then
  echo present
else
  echo absent
fi
REMOTE
} | ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'")
if [ "${MARKER_STATE}" != absent ]; then
  echo "live Vault에 검증 marker metadata가 남았다" >&2
  exit 1
fi

{
  printf 'object=%s\n' "${SNAPSHOT_INFO[0]}"
  printf 'snapshot_sha256=%s\n' "${SNAPSHOT_INFO[1]}"
  printf 'marker_sha256=%s\n' "${EXPECTED_MARKER_SHA}"
  printf 'auth_sha256=%s\n' "${LIVE_HASHES[1]}"
  printf 'policy_sha256=%s\n' "${LIVE_HASHES[2]}"
  printf 'service_count=0\nservice_account_token_mount_count=0\n'
  printf 'denied_egress_targets=3\nnamespace_removed=1\n'
} | ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
  "sudo install -o vault-backup -g vault-backup -m 0600 /dev/stdin /var/lib/vault-raft-backup/last-restore-report"

trap - EXIT INT TERM
printf 'BKP-03 Vault restore 검증 완료 snapshot_marker_sha256=%s\n' "${EXPECTED_MARKER_SHA}"
