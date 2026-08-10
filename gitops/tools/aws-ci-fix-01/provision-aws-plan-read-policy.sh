#!/usr/bin/env bash
# shellcheck disable=SC2029
# AWS-CI-FIX-01의 실제 plan 응답에서 확인된 AWS read action만 관리한다.
set -Eeuo pipefail

readonly mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply || ${mode} == --destroy ]] || {
  echo 'usage: provision-aws-plan-read-policy.sh --check|--apply|--destroy' >&2
  exit 2
}

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly policy_name=AWS-CI-FIX-01-OpenTofuPlanRead
readonly expected_account_sha256='c7f2ce35b49904614900c67678e1bf706ede6f8f7dcbce3108bd3edd55f9f588'

fail() {
  echo "AWS-CI-FIX-01 plan read policy provisioning 실패: $*" >&2
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
temp_dir=$(mktemp -d /dev/shm/aws-ci-fix-01-plan-read-policy.XXXXXX)
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

jq -n '{
  Version: "2012-10-17",
  Statement: [
    {
      Sid: "ReadAvailableZonesForNetworkPlan",
      Effect: "Allow",
      Action: ["ec2:DescribeAvailabilityZones"],
      Resource: "*"
    }
  ]
}' >"${temp_dir}/expected-policy.json"

policy_exists=false
if aws iam get-user-policy \
  --user-name "${target_user_name}" \
  --policy-name "${policy_name}" >"${temp_dir}/actual-policy.json" 2>"${temp_dir}/actual-policy.err"; then
  policy_exists=true
elif ! grep -q 'NoSuchEntity' "${temp_dir}/actual-policy.err"; then
  fail '기존 AWS-CI-FIX-01 plan read policy 상태를 읽지 못했다.'
fi

verify_policy() {
  [[ ${policy_exists} == true ]] || fail 'AWS-CI-FIX-01 전용 plan read policy가 없다.'
  jq -e -S --slurpfile expected "${temp_dir}/expected-policy.json" \
    '.PolicyDocument == $expected[0]' "${temp_dir}/actual-policy.json" >/dev/null \
    || fail '동일 이름의 AWS-CI-FIX-01 plan read policy가 예상 권한과 다르다.'
}

case ${mode} in
  --check)
    verify_policy
    echo "AWS-CI-FIX-01 PlanReadPolicy=PASS target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}') actions=ec2:DescribeAvailabilityZones"
    ;;
  --apply)
    if [[ ${policy_exists} == true ]]; then
      verify_policy
      echo "AWS-CI-FIX-01 PlanReadPolicy=EXISTS target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}') actions=ec2:DescribeAvailabilityZones"
      exit 0
    fi
    aws iam put-user-policy \
      --user-name "${target_user_name}" \
      --policy-name "${policy_name}" \
      --policy-document "file://${temp_dir}/expected-policy.json" >/dev/null
    policy_exists=true
    aws iam get-user-policy \
      --user-name "${target_user_name}" \
      --policy-name "${policy_name}" >"${temp_dir}/actual-policy.json"
    verify_policy
    echo "AWS-CI-FIX-01 PlanReadPolicy=APPLIED target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}') actions=ec2:DescribeAvailabilityZones"
    ;;
  --destroy)
    if [[ ${policy_exists} == false ]]; then
      echo 'AWS-CI-FIX-01 PlanReadPolicy=ABSENT'
      exit 0
    fi
    verify_policy
    aws iam delete-user-policy \
      --user-name "${target_user_name}" \
      --policy-name "${policy_name}" >/dev/null
    echo "AWS-CI-FIX-01 PlanReadPolicy=DESTROYED target-user-sha256=$(printf '%s' "${target_arn}" | sha256sum | awk '{print $1}')"
    ;;
esac
