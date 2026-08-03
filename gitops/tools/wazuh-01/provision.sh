#!/usr/bin/env bash
# WAZUH-01 Vault provisioning.
#
# indexer transport/HTTP 인증서와 admin·filebeat client 인증서, indexer admin password와 그
# bcrypt hash, Wazuh API credential, authd 등록 password를 로컬 mode 0600 입력으로 만들고
# Vault policy·Kubernetes auth role·KV에 넣는다. Git과 Kubernetes Secret에는 아무 값도
# 남기지 않으며 이 스크립트는 어떤 credential도 출력하지 않는다.
set -euo pipefail

readonly mode=${1:-check}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/wazuh
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly cert_days=3650
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == check || ${mode} == apply ]] || {
  echo 'usage: provision.sh [check|apply]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'provision 실패: 인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
[[ -f ${vault_token_file} && ! -L ${vault_token_file} && $(stat -c %a "${vault_token_file}") == 600 ]] || {
  echo 'provision 실패: Vault root token file이 없거나 mode 0600이 아니다.' >&2
  exit 1
}

exec 9>/tmp/wazuh-01-provision.lock
flock -n 9 || {
  echo 'provision 실패: 다른 WAZUH-01 provisioning이 실행 중이다.' >&2
  exit 1
}

vault_exec() {
  # 첫 줄로 Vault token을 넘기고 나머지 stdin은 호출자가 정한다. token은 인자에 두지 않는다.
  local script=$1
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; ${script}'"
}

vault_check() {
  # ${r}은 원격 sh가 확장한다.
  # shellcheck disable=SC2016
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    'for r in indexer manager bootstrap; do
       vault policy read wazuh-${r} >/dev/null || exit 1
       vault read auth/kubernetes/role/wazuh-${r} >/dev/null || exit 1
       vault kv metadata get kv/wazuh/${r} >/dev/null || exit 1
     done'
}

if [[ ${mode} == check ]]; then
  if [[ -d ${secret_dir} && -f ${secret_dir}/indexer-admin-password ]]; then
    echo 'SecretInput=PRESENT'
  else
    echo 'SecretInput=ABSENT'
  fi
  if vault_check; then
    echo 'VaultRuntime=PASS policy=wazuh-indexer,wazuh-manager,wazuh-bootstrap kv=kv/wazuh/{indexer,manager,bootstrap}'
  else
    echo 'VaultRuntime=ABSENT'
  fi
  exit 0
fi

install -d -m 0700 "${secret_dir}"
umask 077

random_alnum() {
  openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-32
}

ensure_password() {
  local file=${secret_dir}/$1 suffix=${2:-}
  if [[ ! -f ${file} ]]; then
    { random_alnum | tr -d '\n'; printf '%s\n' "${suffix}"; } >"${file}"
  fi
  [[ ! -L ${file} && $(stat -c %a "${file}") == 600 ]] || {
    echo "provision 실패: ${1} 입력이 regular file mode 0600이 아니다." >&2
    exit 1
  }
}

# Wazuh API password는 대문자·소문자·숫자·특수문자를 모두 요구한다.
ensure_password indexer-admin-password
ensure_password authd-password
ensure_password api-password 'Aa1.'

ensure_ca() {
  [[ -f ${secret_dir}/root-ca.pem && -f ${secret_dir}/root-ca-key.pem ]] && return 0
  local ca_config
  ca_config=$(mktemp "${secret_dir}/openssl-ca.XXXXXX")
  # RFC 5280 CA 확장을 명시한다. keyUsage가 없으면 OpenSSL 3 client가
  # "CA cert does not include key usage extension"으로 검증을 거부한다.
  {
    printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ca_ext\n'
    printf '[dn]\nC=US\nL=California\nO=Company\nCN=wazuh-01-root-ca\n'
    printf '[ca_ext]\nbasicConstraints=critical,CA:TRUE,pathlen:0\n'
    printf 'keyUsage=critical,keyCertSign,cRLSign,digitalSignature\n'
    printf 'subjectKeyIdentifier=hash\n'
  } >"${ca_config}"
  openssl genrsa -out "${secret_dir}/root-ca-key.pem" 4096 2>/dev/null
  openssl req -new -x509 -sha256 -days "${cert_days}" \
    -key "${secret_dir}/root-ca-key.pem" \
    -out "${secret_dir}/root-ca.pem" \
    -config "${ca_config}" 2>/dev/null
  rm -f "${ca_config}"
}

# $1=이름 $2=CN $3=SAN 목록(비어 있으면 client 전용)
ensure_leaf() {
  local name=$1 common_name=$2 san=${3:-}
  local key=${secret_dir}/${name}-key.pem cert=${secret_dir}/${name}.pem
  [[ -f ${key} && -f ${cert} ]] && return 0
  local config csr
  config=$(mktemp "${secret_dir}/openssl.XXXXXX")
  csr=$(mktemp "${secret_dir}/csr.XXXXXX")
  {
    printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nC=US\nL=California\nO=Company\nCN=%s\n' "${common_name}"
    printf '[ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
    printf 'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
    if [[ -n ${san} ]]; then
      printf 'extendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=%s\n' "${san}"
    else
      printf 'extendedKeyUsage=clientAuth\n'
    fi
  } >"${config}"
  openssl genrsa -out "${key}" 2048 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -inform PEM -outform PEM -in "${key}" -out "${key}.pk8" 2>/dev/null
  mv "${key}.pk8" "${key}"
  openssl req -new -key "${key}" -out "${csr}" -config "${config}" 2>/dev/null
  openssl x509 -req -in "${csr}" -sha256 -days "${cert_days}" \
    -CA "${secret_dir}/root-ca.pem" -CAkey "${secret_dir}/root-ca-key.pem" -CAcreateserial \
    -extfile "${config}" -extensions ext -out "${cert}" 2>/dev/null
  rm -f "${config}" "${csr}"
}

ensure_ca
ensure_leaf node indexer \
  'DNS:indexer,DNS:indexer.wazuh,DNS:indexer.wazuh.svc,DNS:indexer.wazuh.svc.cluster.local,DNS:wazuh-indexer,DNS:wazuh-indexer.wazuh.svc.cluster.local,DNS:wazuh-indexer-0.wazuh-indexer,DNS:wazuh-indexer-0.wazuh-indexer.wazuh.svc.cluster.local,DNS:localhost,IP:127.0.0.1'
ensure_leaf admin admin
ensure_leaf filebeat filebeat

openssl x509 -in "${secret_dir}/root-ca.pem" -noout -text \
  | grep -q 'Certificate Sign' || {
  echo 'provision 실패: root CA에 keyCertSign keyUsage가 없다.' >&2
  exit 1
}

# 저장한 인증서가 실제로 이 CA에서 검증되는지 로컬에서 한 번 확인한다.
for leaf in node admin filebeat; do
  openssl verify -CAfile "${secret_dir}/root-ca.pem" "${secret_dir}/${leaf}.pem" >/dev/null || {
    echo "provision 실패: ${leaf} 인증서가 root CA로 검증되지 않는다." >&2
    exit 1
  }
done

hash_file=${secret_dir}/indexer-admin-password-bcrypt
if [[ ! -f ${hash_file} ]]; then
  htpasswd -bnBC 12 '' "$(tr -d '\n' <"${secret_dir}/indexer-admin-password")" \
    | tr -d ':\n' >"${hash_file}"
  printf '\n' >>"${hash_file}"
fi
# bcrypt hash의 `$`는 정규식 literal이다.
# shellcheck disable=SC2016
grep -q '^\$2[aby]\$12\$' "${hash_file}" || {
  echo 'provision 실패: indexer admin password bcrypt hash 형식이 아니다.' >&2
  exit 1
}

json_field() {
  # 파일 내용을 JSON 문자열로 안전하게 인코딩한다. 값은 출력하지 않는다.
  local path=$1
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(open(sys.argv[1]).read().rstrip("\n")))' "${path}"
}

write_policy() {
  local role=$1
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\npath "kv/data/wazuh/%s" {\n  capabilities = ["read"]\n}\n' "${role}"
  } | vault_exec "vault policy write wazuh-${role} - >/dev/null"
}

write_role() {
  local role=$1 service_account=$2
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    "vault write auth/kubernetes/role/wazuh-${role} \
       bound_service_account_names=${service_account} \
       bound_service_account_namespaces=wazuh \
       audience=vault token_policies=wazuh-${role} token_no_default_policy=true \
       token_ttl=10m token_max_ttl=30m >/dev/null"
}

write_kv() {
  local role=$1 payload=$2
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n%s\n' "${payload}"
  } | vault_exec \
    "umask 077; cat >/tmp/wazuh-01-${role}.json; \
     vault kv put kv/wazuh/${role} @/tmp/wazuh-01-${role}.json >/dev/null; \
     rm -f /tmp/wazuh-01-${role}.json"
}

indexer_payload=$(printf '{"root_ca_pem":%s,"node_pem":%s,"node_key_pem":%s,"admin_pem":%s,"admin_key_pem":%s,"admin_password_hash":%s}' \
  "$(json_field "${secret_dir}/root-ca.pem")" \
  "$(json_field "${secret_dir}/node.pem")" \
  "$(json_field "${secret_dir}/node-key.pem")" \
  "$(json_field "${secret_dir}/admin.pem")" \
  "$(json_field "${secret_dir}/admin-key.pem")" \
  "$(json_field "${hash_file}")")

manager_payload=$(printf '{"root_ca_pem":%s,"filebeat_pem":%s,"filebeat_key_pem":%s,"indexer_username":"admin","indexer_password":%s,"api_username":"wazuh-01-api","api_password":%s,"authd_password":%s}' \
  "$(json_field "${secret_dir}/root-ca.pem")" \
  "$(json_field "${secret_dir}/filebeat.pem")" \
  "$(json_field "${secret_dir}/filebeat-key.pem")" \
  "$(json_field "${secret_dir}/indexer-admin-password")" \
  "$(json_field "${secret_dir}/api-password")" \
  "$(json_field "${secret_dir}/authd-password")")

bootstrap_payload=$(printf '{"root_ca_pem":%s,"admin_pem":%s,"admin_key_pem":%s}' \
  "$(json_field "${secret_dir}/root-ca.pem")" \
  "$(json_field "${secret_dir}/admin.pem")" \
  "$(json_field "${secret_dir}/admin-key.pem")")

for role in indexer manager bootstrap; do
  write_policy "${role}"
done
write_role indexer wazuh-indexer
write_role manager wazuh-manager
write_role bootstrap wazuh-bootstrap
write_kv indexer "${indexer_payload}"
write_kv manager "${manager_payload}"
write_kv bootstrap "${bootstrap_payload}"

vault_check || {
  echo 'provision 실패: Vault policy·role·KV 최종 확인에 실패했다.' >&2
  exit 1
}
echo 'Provision=PASS secret_input=0600 policy=wazuh-indexer,wazuh-manager,wazuh-bootstrap role=wazuh-indexer,wazuh-manager,wazuh-bootstrap kv=kv/wazuh/{indexer,manager,bootstrap}'
