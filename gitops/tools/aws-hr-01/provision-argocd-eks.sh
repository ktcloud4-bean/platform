#!/usr/bin/env bash
# AWS-HR-01: 기존 k3s Argo CD를 private EKS destination에 안전하게 등록한다.
#
# access key secret은 OpenTofu state나 Kubernetes Secret에 쓰지 않는다. 최초 한 번만
# dedicated IAM user key를 만들고, Vault KV -> controller memory volume으로 전달한다.
set -euo pipefail

readonly mode=${1:-check}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
readonly repo_root
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly vault_token_file=${secret_root}/vault-root.token
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly tofu_dir=${repo_root}/infra/aws/tofu-app-argocd
readonly policy_file=${repo_root}/infra/vault/scripts/policies/aws-hr-01-argocd.hcl
readonly vault_agent_file=${repo_root}/gitops/bootstrap/argocd/aws-hr-01-vault-agent.yaml
readonly runtime_patch_file=${repo_root}/gitops/bootstrap/argocd/aws-hr-01-runtime.patch.yaml
readonly vault_trust_source_file=${repo_root}/gitops/apps/jenkins/trust-bundle.yaml
readonly aws_region=ap-northeast-2
readonly cluster_name=hr-system-prod-cluster
readonly cluster_secret_name=hr-system-prod-cluster

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
  -o ConnectTimeout=10
)

usage() {
  cat <<'USAGE'
사용법: gitops/tools/aws-hr-01/provision-argocd-eks.sh [check|apply]

apply는 Terraform이 만든 전용 IAM user의 access key가 없을 때만 한 개를 생성해 Vault
kv/aws-hr-01/argocd에 기록한다. key 원문, Vault token, EKS bearer token을 출력하지 않는다.
USAGE
}

[[ ${mode} == check || ${mode} == apply ]] || { usage >&2; exit 2; }
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || { echo '인증된 k3s known_hosts 파일이 없다.' >&2; exit 1; }
[[ -f ${vault_token_file} && ! -L ${vault_token_file} && $(stat -c %a "${vault_token_file}") == 600 ]] || {
  echo 'Vault root token file이 없거나 mode 0600이 아니다.' >&2
  exit 1
}
[[ -f ${policy_file} && -f ${vault_agent_file} && -f ${runtime_patch_file} && -f ${vault_trust_source_file} ]] || {
  echo 'AWS-HR-01 선언 파일이 완전하지 않다.' >&2
  exit 1
}

ssh_k3s() {
  ssh "${ssh_options[@]}" "${k3s_host}" "$@"
}

vault_exec() {
  local command=$1
  ssh_k3s "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; ${command}'"
}

vault_runtime_exists() {
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    'vault policy read aws-hr-01-argocd >/dev/null &&
     vault read auth/kubernetes/role/aws-hr-01-argocd >/dev/null &&
     vault kv metadata get kv/aws-hr-01/argocd >/dev/null'
}

tofu_output() {
  (cd "${tofu_dir}" && tofu output -raw "$1")
}

credential_user=$(tofu_output argocd_credential_issuer_user_name)
target_role_arn=$(tofu_output argocd_eks_role_arn)

key_count() {
  aws iam list-access-keys --user-name "${credential_user}" \
    --query 'length(AccessKeyMetadata)' --output text
}

runtime_patch() {
  ssh_k3s "${kubectl_command} -n argocd apply --server-side --force-conflicts -f -" < "${vault_agent_file}"
  awk '
    /^  vault\.crt: \|$/ { collecting=1; next }
    collecting {
      is_end = ($0 ~ /^    -----END CERTIFICATE-----$/)
      sub(/^    /, "")
      print
      if (is_end) exit
    }
  ' "${vault_trust_source_file}" | ssh_k3s \
    "set -o pipefail; ${kubectl_command} -n argocd create configmap argocd-aws-hr-01-vault-trust --from-file=vault.crt=/dev/stdin --dry-run=client -o yaml | ${kubectl_command} -n argocd apply --server-side --force-conflicts -f -"
  ssh_k3s "${kubectl_command} -n argocd patch statefulset argocd-application-controller --type strategic --patch-file=/dev/stdin" < "${runtime_patch_file}"
  if ! ssh_k3s "${kubectl_command} -n argocd rollout status statefulset/argocd-application-controller --timeout=300s"; then
    # 기존 controller revision으로만 되돌린다. credential과 Vault entry는 재시도에 필요하므로 제거하지 않는다.
    ssh_k3s "${kubectl_command} -n argocd rollout undo statefulset/argocd-application-controller"
    ssh_k3s "${kubectl_command} -n argocd rollout status statefulset/argocd-application-controller --timeout=300s"
    echo 'Argo controller Vault patch rollout이 실패해 직전 revision으로 복구했다.' >&2
    exit 1
  fi
}

register_cluster() {
  local cluster_json endpoint ca_data config manifest
  cluster_json=$(aws eks describe-cluster --region "${aws_region}" --name "${cluster_name}" \
    --query 'cluster.{endpoint:endpoint,ca:certificateAuthority.data,status:status}' --output json)
  endpoint=$(AWS_HR_CLUSTER_JSON="${cluster_json}" python3 -c 'import json,os; print(json.loads(os.environ["AWS_HR_CLUSTER_JSON"])["endpoint"])')
  ca_data=$(AWS_HR_CLUSTER_JSON="${cluster_json}" python3 -c 'import json,os; print(json.loads(os.environ["AWS_HR_CLUSTER_JSON"])["ca"])')
  config=$(AWS_HR_CLUSTER_NAME="${cluster_name}" AWS_HR_TARGET_ROLE_ARN="${target_role_arn}" AWS_HR_CA_DATA="${ca_data}" python3 - <<'PY'
import json
import os

print(json.dumps({
    "execProviderConfig": {
        "command": "argocd-k8s-auth",
        "args": ["aws", "--cluster-name", os.environ["AWS_HR_CLUSTER_NAME"], "--role-arn", os.environ["AWS_HR_TARGET_ROLE_ARN"]],
        "apiVersion": "client.authentication.k8s.io/v1beta1",
        "env": {
            "AWS_REGION": "ap-northeast-2",
            "AWS_SHARED_CREDENTIALS_FILE": "/argocd/aws/credentials",
        },
    },
    "tlsClientConfig": {"insecure": False, "caData": os.environ["AWS_HR_CA_DATA"]},
}, separators=(",", ":")))
PY
)
  manifest=$(AWS_HR_ENDPOINT="${endpoint}" AWS_HR_CONFIG="${config}" python3 - <<'PY'
import os

config = os.environ["AWS_HR_CONFIG"]
print("apiVersion: v1")
print("kind: Secret")
print("metadata:")
print("  name: hr-system-prod-cluster")
print("  namespace: argocd")
print("  labels:")
print("    argocd.argoproj.io/secret-type: cluster")
print("type: Opaque")
print("stringData:")
print("  name: hr-system-prod")
print(f"  server: {os.environ['AWS_HR_ENDPOINT']}")
print("  config: |")
print(f"    {config}")
PY
)
  printf '%s\n' "${manifest}" | ssh_k3s "${kubectl_command} -n argocd apply --server-side --force-conflicts -f -"
}

if [[ ${mode} == check ]]; then
  vault_runtime_exists
  [[ $(key_count) == 1 ]] || { echo 'Argo credential issuer access key 수가 정확히 1개가 아니다.' >&2; exit 1; }
  ssh_k3s "${kubectl_command} -n argocd get secret ${cluster_secret_name} -o jsonpath='{.metadata.labels.argocd\\.argoproj\\.io/secret-type}'" | grep -qx cluster
  echo 'ArgoEksRuntime=PASS vault=kv/aws-hr-01/argocd source-key=1 cluster-secret=registered'
  exit 0
fi

existing_key_count=$(key_count)
if [[ ${existing_key_count} == 0 ]]; then
  created_key_json=$(aws iam create-access-key --user-name "${credential_user}" --output json)
  created_access_key_id=$(AWS_HR_CREATED_KEY_JSON="${created_key_json}" python3 -c 'import json,os; print(json.loads(os.environ["AWS_HR_CREATED_KEY_JSON"])["AccessKey"]["AccessKeyId"])')
  created_secret_access_key=$(AWS_HR_CREATED_KEY_JSON="${created_key_json}" python3 -c 'import json,os; print(json.loads(os.environ["AWS_HR_CREATED_KEY_JSON"])["AccessKey"]["SecretAccessKey"])')
  cleanup_unstored_key() {
    aws iam delete-access-key --user-name "${credential_user}" --access-key-id "${created_access_key_id}" >/dev/null 2>&1 || true
  }
  trap cleanup_unstored_key EXIT HUP INT TERM

  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n'
    cat "${policy_file}"
  } | vault_exec 'vault policy write aws-hr-01-argocd - >/dev/null'
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    'vault write auth/kubernetes/role/aws-hr-01-argocd bound_service_account_names=argocd-application-controller bound_service_account_namespaces=argocd audience=vault token_policies=aws-hr-01-argocd token_no_default_policy=true token_ttl=10m token_max_ttl=30m >/dev/null'
  payload=$(AWS_HR_ACCESS_KEY_ID="${created_access_key_id}" AWS_HR_SECRET_ACCESS_KEY="${created_secret_access_key}" python3 - <<'PY'
import json
import os

print(json.dumps({
    "access_key_id": os.environ["AWS_HR_ACCESS_KEY_ID"],
    "secret_access_key": os.environ["AWS_HR_SECRET_ACCESS_KEY"],
}))
PY
)
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n%s\n' "${payload}"
  } | vault_exec 'umask 077; cat >/tmp/aws-hr-01-argocd.json; vault kv put kv/aws-hr-01/argocd @/tmp/aws-hr-01-argocd.json >/dev/null; : >/tmp/aws-hr-01-argocd.json; rm -f /tmp/aws-hr-01-argocd.json'
  unset created_key_json created_secret_access_key payload
  trap - EXIT HUP INT TERM
elif [[ ${existing_key_count} == 1 ]]; then
  vault_runtime_exists || {
    echo 'IAM key는 있으나 Vault runtime bundle이 없다. key를 새로 만들지 않고 현재 key의 소유자를 확인해야 한다.' >&2
    exit 1
  }
else
  echo 'Argo credential issuer IAM user에 access key가 둘 이상 있어 중단한다.' >&2
  exit 1
fi

vault_runtime_exists
runtime_patch
register_cluster

# token 원문은 discard하고 status만 확인한다. private DNS forwarding 전에는 EKS API HTTPS
# health 판정을 여기서 강제하지 않는다.
ssh_k3s "${kubectl_command} -n argocd exec statefulset/argocd-application-controller -c argocd-application-controller -- sh -c 'AWS_REGION=${aws_region} AWS_SHARED_CREDENTIALS_FILE=/argocd/aws/credentials argocd-k8s-auth aws --cluster-name ${cluster_name} --role-arn ${target_role_arn} >/dev/null'"
bash "${BASH_SOURCE[0]}" check
echo 'Provision=PASS controller=Vault-backed EKS-destination=registered'
