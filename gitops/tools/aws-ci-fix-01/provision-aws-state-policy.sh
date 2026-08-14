#!/usr/bin/env bash
# shellcheck disable=SC2029
# AWS-CI-FIX-01 Jenkins plan용 state read/lock policy만 생성·판정·회수한다.
set -Eeuo pipefail

readonly mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply || ${mode} == --rollback || ${mode} == --destroy ]] || {
  echo 'usage: provision-aws-state-policy.sh --check|--apply|--rollback|--destroy' >&2
  exit 2
}

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly policy_name=AWS-CI-FIX-01-OpenTofuPlanState
readonly expected_account_sha256='c7f2ce35b49904614900c67678e1bf706ede6f8f7dcbce3108bd3edd55f9f588'

fail() {
  echo "AWS-CI-FIX-01 state policy provisioning 실패: $*" >&2
  exit 1
}

for command in aws jq sha256sum ssh stat; do
  command -v "${command}" >/dev/null || fail "${command} command가 없다."
done
[[ -f ${vault_root_token_file} && ! -L ${vault_root_token_file} &&
   $(stat -c %u "${vault_root_token_file}") -eq $(id -u) &&
   $(stat -c %a "${vault_root_token_file}") == 600 ]] \
  || fail 'Vault root token은 호출자 소유 mode 0600 일반 파일이어야 한다.'
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || fail '인증된 k3s known_hosts가 없다.'

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)

umask 077
temp_dir=$(mktemp -d /dev/shm/aws-ci-fix-01-state-policy.XXXXXX)
cleanup() {
  local status=$?
  rm -rf -- "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

{
  tr -d '\n' <"${vault_root_token_file}"
  printf '\n'
  printf 'vault kv get -format=json kv/jenkins/runtime\n'
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
    set -eu
    read -r VAULT_TOKEN
    export VAULT_TOKEN
    exec sh -eu
  '" >"${temp_dir}/runtime.json"

jq -er '.data.data.aws_access_key_id | select(length > 0)' \
  "${temp_dir}/runtime.json" >"${temp_dir}/jenkins-access-key-id"
jq -er '.data.data.aws_secret_access_key | select(length > 0)' \
  "${temp_dir}/runtime.json" >"${temp_dir}/jenkins-secret-access-key"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
AWS_ACCESS_KEY_ID=$(tr -d '\n' <"${temp_dir}/jenkins-access-key-id")
AWS_SECRET_ACCESS_KEY=$(tr -d '\n' <"${temp_dir}/jenkins-secret-access-key")
export AWS_DEFAULT_REGION=ap-northeast-2 AWS_PAGER=''

account_id=$(aws sts get-caller-identity --query Account --output text)
target_arn=$(aws sts get-caller-identity --query Arn --output text)
case "${account_id}" in
  '' | *[!0-9]*) fail 'Jenkins AWS account 형식을 판정하지 못했다.' ;;
esac
[[ ${#account_id} == 12 ]] || fail 'Jenkins AWS account 길이가 잘못됐다.'
[[ $(printf '%s' "${account_id}" | sha256sum | awk '{print $1}') == "${expected_account_sha256}" ]] \
  || fail 'Jenkins AWS account가 선언한 대상과 다르다.'
case "${target_arn}" in
  *':user/'*) ;;
  *) fail 'Jenkins credential이 IAM user가 아니어서 user inline policy를 안전하게 소유할 수 없다.' ;;
esac
readonly target_user_name=${target_arn##*/}
readonly target_arn account_id

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
admin_arn=$(aws sts get-caller-identity --query Arn --output text)
[[ -n ${admin_arn} && ${admin_arn} != "${target_arn}" ]] \
  || fail 'Jenkins credential과 다른 관리 AWS principal이 필요하다.'
readonly admin_arn

readonly bucket_name="ktcloud4-bean-opentofu-state-${account_id}"
readonly bucket_arn="arn:aws:s3:::${bucket_name}"
readonly lock_table_arn="arn:aws:dynamodb:ap-northeast-2:${account_id}:table/ktcloud4-bean-opentofu-locks"

legacy_state_objects=(
  "${bucket_arn}/platform/infra/aws/tofu-app-network/v1/terraform.tfstate"
  "${bucket_arn}/platform/infra/aws/tofu-app-ecr/v1/terraform.tfstate"
)
expanded_state_objects=(
  "${legacy_state_objects[@]}"
  "${bucket_arn}/platform/infra/aws/tofu-account-baseline/v1/terraform.tfstate"
  "${bucket_arn}/platform/infra/aws/tofu-app-security/v1/terraform.tfstate"
)

if [[ ${mode} == --rollback ]]; then
  desired_state_objects=("${legacy_state_objects[@]}")
  previous_state_objects=("${expanded_state_objects[@]}")
else
  desired_state_objects=("${expanded_state_objects[@]}")
  previous_state_objects=("${legacy_state_objects[@]}")
fi

write_policy() {
  local output_file=$1
  shift
  jq -n \
    --arg bucket_arn "${bucket_arn}" \
    --arg lock_table_arn "${lock_table_arn}" \
    '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "ListDedicatedStateBucketMetadata",
        Effect: "Allow",
        Action: ["s3:ListBucket"],
        Resource: $bucket_arn
      },
      {
        Sid: "ManageSelectedPlanStateObjects",
        Effect: "Allow",
        Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        Resource: $ARGS.positional
      },
      {
        Sid: "ReadStateBucketLocation",
        Effect: "Allow",
        Action: ["s3:GetBucketLocation"],
        Resource: $bucket_arn
      },
      {
        Sid: "LeaseDedicatedStateLock",
        Effect: "Allow",
        Action: [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ],
        Resource: $lock_table_arn
      }
    ]
  }' --args "$@" >"${output_file}"
}

readonly desired_policy="${temp_dir}/desired-policy.json"
readonly previous_policy="${temp_dir}/previous-policy.json"
write_policy "${desired_policy}" "${desired_state_objects[@]}"
write_policy "${previous_policy}" "${previous_state_objects[@]}"

policy_exists=false
if aws iam get-user-policy \
  --user-name "${target_user_name}" \
  --policy-name "${policy_name}" >"${temp_dir}/actual-policy.json" 2>"${temp_dir}/actual-policy.err"; then
  policy_exists=true
elif ! grep -q 'NoSuchEntity' "${temp_dir}/actual-policy.err"; then
  fail '기존 AWS-CI-FIX-01 policy 상태를 읽지 못했다.'
fi

policy_matches() {
  local policy_file=$1
  jq -e -S --slurpfile expected "${policy_file}" \
    '.PolicyDocument == $expected[0]' "${temp_dir}/actual-policy.json" >/dev/null
}

verify_desired_policy() {
  [[ ${policy_exists} == true ]] || fail 'AWS-CI-FIX-01 전용 state policy가 없다.'
  policy_matches "${desired_policy}" \
    || fail '동일 이름의 AWS-CI-FIX-01 policy가 예상 권한과 다르다.'
}

apply_desired_policy() {
  aws iam put-user-policy \
    --user-name "${target_user_name}" \
    --policy-name "${policy_name}" \
    --policy-document "file://${desired_policy}" >/dev/null
  policy_exists=true
  aws iam get-user-policy \
    --user-name "${target_user_name}" \
    --policy-name "${policy_name}" >"${temp_dir}/actual-policy.json"
  verify_desired_policy
}

case ${mode} in
  --check)
    verify_desired_policy
    echo "AWS-CI-FIX-02 StatePolicy=PASS target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}') state-objects=${#desired_state_objects[@]} key-version=v1 lock-table=exact"
    ;;
  --apply)
    if [[ ${policy_exists} == true ]]; then
      if policy_matches "${desired_policy}"; then
        echo "AWS-CI-FIX-02 StatePolicy=EXISTS target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}') state-objects=${#desired_state_objects[@]} key-version=v1 lock-table=exact"
        exit 0
      fi
      policy_matches "${previous_policy}" \
        || fail '동일 이름의 AWS-CI-FIX-01 policy가 허용된 이전 정책과 다르다.'
    fi
    apply_desired_policy
    echo "AWS-CI-FIX-02 StatePolicy=APPLIED target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}') state-objects=${#desired_state_objects[@]} key-version=v1 lock-table=exact"
    ;;
  --rollback)
    if [[ ${policy_exists} == false ]]; then
      echo 'AWS-CI-FIX-02 StatePolicy=ABSENT'
      exit 0
    fi
    if policy_matches "${desired_policy}"; then
      echo "AWS-CI-FIX-02 StatePolicy=ROLLBACK_EXISTS target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}') state-objects=${#desired_state_objects[@]} key-version=v1 lock-table=exact"
      exit 0
    fi
    policy_matches "${previous_policy}" \
      || fail '동일 이름의 AWS-CI-FIX-01 policy가 AWS-CI-FIX-02 확장 정책과 다르다.'
    apply_desired_policy
    echo "AWS-CI-FIX-02 StatePolicy=ROLLED_BACK target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}') state-objects=${#desired_state_objects[@]} key-version=v1 lock-table=exact"
    ;;
  --destroy)
    if [[ ${policy_exists} == false ]]; then
      echo 'AWS-CI-FIX-01 StatePolicy=ABSENT'
      exit 0
    fi
    verify_desired_policy
    aws iam delete-user-policy \
      --user-name "${target_user_name}" \
      --policy-name "${policy_name}" >/dev/null
    echo "AWS-CI-FIX-01 StatePolicy=DESTROYED target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}')"
    ;;
esac
