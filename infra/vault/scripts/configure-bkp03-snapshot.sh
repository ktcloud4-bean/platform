#!/usr/bin/env bash
# BKP-03: live Vault에는 snapshot read policy와 periodic service token만 만든다.
# init·unseal·restore·seal migration은 수행하지 않는다.
set -euo pipefail

: "${VAULT_ROOT_TOKEN_FILE:?저장소 밖 root token 파일 경로가 필요하다}"
K3S_HOST="${K3S_HOST:-rocky@10.10.20.10}"
KUBECTL="${KUBECTL:-sudo /usr/local/bin/k3s kubectl}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
TOKEN_PATH=/etc/vault-raft-backup/token
POLICY_NAME=bkp-03-snapshot
POLICY_FILE="$(cd "$(dirname "$0")/policies" && pwd)/${POLICY_NAME}.hcl"
SSH_ARGS=(-o BatchMode=yes -o StrictHostKeyChecking=yes
          -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
          -o PasswordAuthentication=no -o ControlMaster=no)

[ -r "${VAULT_ROOT_TOKEN_FILE}" ] || { echo "root token 파일을 읽을 수 없다" >&2; exit 1; }
[ "$(stat -c %a "${VAULT_ROOT_TOKEN_FILE}")" = 600 ] \
  || { echo "root token 파일 mode는 0600이어야 한다" >&2; exit 1; }
[ -r "${POLICY_FILE}" ] || { echo "snapshot policy 파일이 없다" >&2; exit 1; }

vault_exec() {
  { sed -n '1p' "${VAULT_ROOT_TOKEN_FILE}"; cat; } |
    ssh "${SSH_ARGS[@]}" "${K3S_HOST}" \
      "${KUBECTL} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'"
}

echo "snapshot read-only policy를 선언한다"
{
  echo "cat > /tmp/${POLICY_NAME}.hcl <<'HCL'"
  cat "${POLICY_FILE}"
  echo HCL
  echo "vault policy write ${POLICY_NAME} /tmp/${POLICY_NAME}.hcl >/dev/null"
  echo "rm -f /tmp/${POLICY_NAME}.hcl"
} | vault_exec

if ssh "${SSH_ARGS[@]}" "${K3S_HOST}" "sudo bash -s" <<'REMOTE'
set -euo pipefail
TOKEN_PATH=/etc/vault-raft-backup/token
[ -s "${TOKEN_PATH}" ]
[ "$(stat -c %a "${TOKEN_PATH}")" = 600 ]
TOKEN=$(tr -d '\r\n' <"${TOKEN_PATH}")
printf '%s\n' "${TOKEN}" |
  sudo /usr/local/bin/k3s kubectl -n vault exec -i vault-0 -- sh -c '
    read -r VAULT_TOKEN
    export VAULT_TOKEN
    LOOKUP=$(vault token lookup -format=json)
    printf "%s\n" "${LOOKUP}" | grep -q '"'"'"orphan": true'"'"'
    printf "%s\n" "${LOOKUP}" | grep -q '"'"'"period": 172800'"'"'
    printf "%s\n" "${LOOKUP}" | grep -q '"'"'"renewable": true'"'"'
    printf "%s\n" "${LOOKUP}" | grep -q '"'"'"bkp-03-snapshot"'"'"'
  ' >/dev/null
REMOTE
then
  echo "기존 periodic snapshot token이 유효해 재사용한다"
  exit 0
fi

echo "유효한 snapshot token이 없어 새 periodic token을 발급한다"
vault_exec <<'REMOTE' |
vault token create -display-name=bkp-03-snapshot -policy=bkp-03-snapshot \
  -period=48h -orphan -no-default-policy -field=token
REMOTE
  ssh "${SSH_ARGS[@]}" "${K3S_HOST}" "sudo bash -c '
    set -euo pipefail
    umask 077
    tmp=\$(mktemp /etc/vault-raft-backup/.token.XXXXXX)
    cat >\"\${tmp}\"
    test -s \"\${tmp}\"
    chown vault-backup:vault-backup \"\${tmp}\"
    chmod 0600 \"\${tmp}\"
    mv -f \"\${tmp}\" ${TOKEN_PATH}
  '"

echo "완료. root token은 정기 snapshot에 사용되지 않는다"
