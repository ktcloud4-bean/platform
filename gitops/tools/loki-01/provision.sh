#!/usr/bin/env bash
set -euo pipefail

readonly mode=${1:-check}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/loki
readonly secret_file=${secret_dir}/env
readonly vault_token_file=${secret_root}/vault-root.token
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
readonly repo_root
readonly vault_ca=${repo_root}/gitops/apps/loki/files/vault.crt
readonly s3_ca=${repo_root}/gitops/apps/loki/files/s3.crt
readonly object_host=${OBJECT_HOST:-rocky@object-01.imcherry5778.xyz}
readonly object_known_hosts=${OBJECT_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts_s3_01}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly k3s_known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly bucket=loki-chunks
readonly runtime_identity=loki-01
readonly remote_config=/etc/seaweedfs/s3.json
readonly remote_backup=/etc/seaweedfs/s3.json.loki-01-pre
readonly s3_forward_port=18334
readonly ssh_object=(
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${object_known_hosts}" "${object_host}"
)
readonly ssh_k3s_options=(
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${k3s_known_hosts}"
)

[[ ${mode} == check || ${mode} == apply ]] || {
  echo 'usage: provision.sh [check|apply]' >&2
  exit 2
}
[[ -f ${object_known_hosts} && ! -L ${object_known_hosts} ]] || {
  echo 'provision 실패: object-01 인증 known_hosts가 없다.' >&2
  exit 1
}
[[ -f ${k3s_known_hosts} && ! -L ${k3s_known_hosts} ]] || {
  echo 'provision 실패: k3s-01 인증 known_hosts가 없다.' >&2
  exit 1
}
[[ -f ${vault_ca} && -f ${s3_ca} ]] || {
  echo 'provision 실패: 고정 Vault/S3 trust file이 없다.' >&2
  exit 1
}

exec 9>/tmp/loki-01-provision.lock
flock -n 9 || {
  echo 'provision 실패: 다른 LOKI-01 provisioning이 실행 중이다.' >&2
  exit 1
}

load_or_create_secret_input() {
  if [[ ! -f ${secret_file} ]]; then
    [[ ${mode} == apply ]] || {
      echo 'SecretInput=ABSENT'
      return 1
    }
    install -d -m 0700 "${secret_dir}"
    umask 077
    local access_key secret_key
    access_key=$(openssl rand -hex 16)
    secret_key=$(openssl rand -base64 36 | tr -d '\n')
    install -m 0600 /dev/null "${secret_file}"
    printf 'LOKI_S3_ACCESS_KEY=%s\nLOKI_S3_SECRET_KEY=%s\n' \
      "${access_key}" "${secret_key}" >"${secret_file}"
  fi
  [[ $(stat -c %a "${secret_file}") == 600 ]] || {
    echo 'provision 실패: Loki secret input mode가 0600이 아니다.' >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source "${secret_file}"
  [[ ${LOKI_S3_ACCESS_KEY:-} =~ ^[0-9a-f]{32}$ && -n ${LOKI_S3_SECRET_KEY:-} ]] || {
    echo 'provision 실패: Loki S3 secret input 형식이 잘못됐다.' >&2
    exit 1
  }
  export LOKI_S3_ACCESS_KEY LOKI_S3_SECRET_KEY
}

identity_state() {
  "${ssh_object[@]}" \
    "sudo -n jq -r --arg name '${runtime_identity}' '
      [.identities[] | select(.name == \$name)] as \$ids |
      if (\$ids|length)==0 then \"absent\"
      elif (\$ids|length)!=1 then \"duplicate\"
      elif (\$ids[0].credentials|length)!=1 then \"drift\"
      elif ((\$ids[0].actions|sort) != ([\"Delete:loki-chunks\",\"List:loki-chunks\",\"Read:loki-chunks\",\"Write:loki-chunks\"]|sort)) then \"drift\"
      else \"match\" end
    ' '${remote_config}'"
}

remote_apply_identity() {
  local phase=$1 access=$2 secret=$3 remote_script
  # credential은 SSH/remote process argv에 싣지 않고 stdin script로만 전달한다.
  read -r -d '' remote_script <<'REMOTE' || true
set -euo pipefail
config=/etc/seaweedfs/s3.json
tmp=$(mktemp /etc/seaweedfs/s3.json.loki-01.XXXXXX)
trap 'rm -f "${tmp}"' EXIT
if [[ ${phase} == bootstrap ]]; then
  jq --arg access "${access}" --arg secret "${secret}" '
    .identities |= map(select(.name != "loki-01-bootstrap")) |
    .identities += [{
      name:"loki-01-bootstrap",
      credentials:[{accessKey:$access,secretKey:$secret}],
      actions:["Admin"]
    }]
  ' "${config}" >"${tmp}"
elif [[ ${phase} == runtime ]]; then
  jq --arg access "${access}" --arg secret "${secret}" '
    .identities |= map(select(.name != "loki-01-bootstrap" and .name != "loki-01")) |
    .identities += [{
      name:"loki-01",
      credentials:[{accessKey:$access,secretKey:$secret}],
      actions:["Read:loki-chunks","List:loki-chunks","Write:loki-chunks","Delete:loki-chunks"]
    }]
  ' "${config}" >"${tmp}"
else
  exit 2
fi
jq -e '.identities | type == "array" and length > 0' "${tmp}" >/dev/null
install -o seaweedfs -g seaweedfs -m 0600 "${tmp}" "${config}"
systemctl restart seaweedfs-s3.service
systemctl is-active --quiet seaweedfs-s3.service
REMOTE
  {
    printf 'phase=%q\naccess=%q\nsecret=%q\n' "${phase}" "${access}" "${secret}"
    printf '%s\n' "${remote_script}"
  } | "${ssh_object[@]}" "sudo -n bash -s"
}

restore_remote_config() {
  "${ssh_object[@]}" "sudo -n bash -s" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
if [[ -f /etc/seaweedfs/s3.json.loki-01-pre ]]; then
  install -o seaweedfs -g seaweedfs -m 0600 /etc/seaweedfs/s3.json.loki-01-pre /etc/seaweedfs/s3.json
  rm -f /etc/seaweedfs/s3.json.loki-01-pre
  systemctl restart seaweedfs-s3.service
fi
REMOTE
}

remove_remote_backup() {
  "${ssh_object[@]}" "sudo -n rm -f '${remote_backup}'"
}

start_s3_forward() {
  s3_socket_dir=$(mktemp -d /tmp/loki-01-s3.XXXXXX)
  s3_socket=${s3_socket_dir}/control
  "${ssh_k3s_options[@]}" -o ExitOnForwardFailure=yes -M -S "${s3_socket}" -fNT \
    -L "127.0.0.1:${s3_forward_port}:10.10.50.20:8333" "${k3s_host}" 9>&-
  local ready=false
  for _ in $(seq 1 20); do
    if nc -z 127.0.0.1 "${s3_forward_port}"; then
      ready=true
      break
    fi
    sleep 1
  done
  [[ ${ready} == true ]] || {
    echo 'provision 실패: S3 SSH forward가 준비되지 않았다.' >&2
    exit 1
  }
}

stop_s3_forward() {
  if [[ -n ${s3_socket:-} && -S ${s3_socket} ]]; then
    "${ssh_k3s_options[@]}" -S "${s3_socket}" -O exit "${k3s_host}" >/dev/null 2>&1 || true
  fi
  if [[ -n ${s3_socket_dir:-} && -d ${s3_socket_dir} ]]; then
    rmdir "${s3_socket_dir}" 2>/dev/null || true
  fi
}

s3_request() {
  local operation=$1 target_bucket=$2 key=${3:-}
  python3 - "${operation}" "${target_bucket}" "${key}" "${s3_forward_port}" "${s3_ca}" <<'PY'
import datetime
import hashlib
import hmac
import http.client
import os
from pathlib import Path
import socket
import ssl
import sys
import urllib.parse

operation, bucket, key, connect_port, ca_file = sys.argv[1:]
method = {"create": "PUT", "put": "PUT", "head": "HEAD", "delete": "DELETE", "deny": "HEAD"}[operation]
host, port, region = "s3.imcherry5778.xyz", 8333, "us-east-1"
access, secret = os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"]
uri = "/" + urllib.parse.quote(bucket, safe="")
if key:
    uri += "/" + urllib.parse.quote(key, safe="/")
now = datetime.datetime.now(datetime.timezone.utc)
amz_date, date = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
payload_hash = hashlib.sha256(b"").hexdigest()
host_header = f"{host}:{port}"
headers_text = f"host:{host_header}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
signed = "host;x-amz-content-sha256;x-amz-date"
canonical = "\n".join([method, uri, "", headers_text, signed, payload_hash])
scope = f"{date}/{region}/s3/aws4_request"
to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])

def digest(signing_key: bytes, value: str) -> bytes:
    return hmac.new(signing_key, value.encode(), hashlib.sha256).digest()

signing_key = digest(digest(digest(digest(("AWS4" + secret).encode(), date), region), "s3"), "aws4_request")
signature = hmac.new(signing_key, to_sign.encode(), hashlib.sha256).hexdigest()
headers = {
    "Authorization": f"AWS4-HMAC-SHA256 Credential={access}/{scope},SignedHeaders={signed},Signature={signature}",
    "Host": host_header,
    "x-amz-content-sha256": payload_hash,
    "x-amz-date": amz_date,
}
context = ssl.create_default_context(cafile=str(Path(ca_file)))
connection = http.client.HTTPSConnection(host, port, context=context, timeout=15)

def connect() -> None:
    raw = socket.create_connection(("127.0.0.1", int(connect_port)), timeout=15)
    connection.sock = context.wrap_socket(raw, server_hostname=host)

connection.connect = connect
connection.request(method, uri, headers=headers)
response = connection.getresponse()
response.read()
expected = {
    "create": {200, 409},
    "put": {200},
    "head": {200},
    "delete": {200, 204},
    "deny": {403},
}[operation]
if response.status not in expected:
    raise SystemExit(f"LOKI-01 S3 {operation}: unexpected HTTP {response.status}")
print(f"S3Request=PASS operation={operation} HTTP={response.status}")
PY
}

configure_vault() {
  [[ -f ${vault_token_file} && ! -L ${vault_token_file} && $(stat -c %a "${vault_token_file}") == 600 ]] || {
    echo 'provision 실패: Vault root token file이 없거나 mode 0600이 아니다.' >&2
    exit 1
  }
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; cat <<'HCL'
path "kv/data/loki/runtime" {
  capabilities = ["read"]
}
HCL
  } | "${ssh_k3s_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault policy write loki - >/dev/null'"
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | \
    "${ssh_k3s_options[@]}" "${k3s_host}" \
      "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault write auth/kubernetes/role/loki bound_service_account_names=loki bound_service_account_namespaces=loki audience=vault token_policies=loki token_no_default_policy=true token_ttl=10m token_max_ttl=30m >/dev/null'"
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n{"s3_access_key":"%s","s3_secret_key":"%s"}\n' \
      "${LOKI_S3_ACCESS_KEY}" "${LOKI_S3_SECRET_KEY}"
  } | "${ssh_k3s_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; umask 077; cat >/tmp/loki-01-runtime.json; vault kv put kv/loki/runtime @/tmp/loki-01-runtime.json >/dev/null; rm -f /tmp/loki-01-runtime.json'"
  unset LOKI_S3_SECRET_KEY
}

load_or_create_secret_input || exit 0
state=$(identity_state)
if [[ ${mode} == check ]]; then
  printf 'SecretInput=PRESENT\nS3Identity=%s\n' "${state}"
  [[ ${state} == match || ${state} == absent ]] || exit 1
  exit 0
fi
[[ ${state} == match || ${state} == absent ]] || {
  echo "provision 실패: 기존 ${runtime_identity} identity가 secret input/권한 계약과 다르다." >&2
  exit 1
}

provision_complete=false
trap 'stop_s3_forward; if [[ ${provision_complete} != true ]]; then restore_remote_config; fi' EXIT HUP INT TERM
if [[ ${state} == absent ]]; then
  "${ssh_object[@]}" "sudo -n test ! -e '${remote_backup}'"
  "${ssh_object[@]}" "sudo -n install -o root -g root -m 0600 '${remote_config}' '${remote_backup}'"
  start_s3_forward

  bootstrap_access=$(openssl rand -hex 16)
  bootstrap_secret=$(openssl rand -base64 36 | tr -d '\n')
  remote_apply_identity bootstrap "${bootstrap_access}" "${bootstrap_secret}"

  export AWS_ACCESS_KEY_ID=${bootstrap_access}
  export AWS_SECRET_ACCESS_KEY=${bootstrap_secret}
  s3_request create "${bucket}"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY bootstrap_secret

  remote_apply_identity runtime "${LOKI_S3_ACCESS_KEY}" "${LOKI_S3_SECRET_KEY}"
else
  start_s3_forward
fi

export AWS_ACCESS_KEY_ID=${LOKI_S3_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${LOKI_S3_SECRET_KEY}
probe_key="loki-01-provision/probe-$$"
s3_request put "${bucket}" "${probe_key}"
s3_request head "${bucket}" "${probe_key}"
s3_request delete "${bucket}" "${probe_key}"
s3_request deny harbor-registry
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

configure_vault
if [[ ${state} == absent ]]; then
  remove_remote_backup
fi
provision_complete=true
stop_s3_forward
trap - EXIT HUP INT TERM
echo 'LOKI-01 provisioning: PASS bucket=loki-chunks identity=loki-01 vault_role=loki'
