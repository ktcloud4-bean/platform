#!/usr/bin/env bash
# AWS-CI-FIX-02: Jenkins는 허용된 AWS root를 fmt·plan만 수행한다.
set -Eeuo pipefail

readonly target_root=${1:-}
readonly account_id_file=${2:-}
readonly expected_account_sha256='c7f2ce35b49904614900c67678e1bf706ede6f8f7dcbce3108bd3edd55f9f588'
readonly region='ap-northeast-2'
readonly lock_table='ktcloud4-bean-opentofu-locks'

fail() {
  echo "AWS-CI-FIX-01 OpenTofu 실패: $*" >&2
  exit 1
}

for command in tofu sha256sum mktemp; do
  command -v "${command}" >/dev/null || fail "${command} command가 없다."
done

case ${target_root} in
  tofu-app-network)
    readonly state_key='platform/infra/aws/tofu-app-network/v1/terraform.tfstate'
    ;;
  tofu-app-ecr)
    readonly state_key='platform/infra/aws/tofu-app-ecr/v1/terraform.tfstate'
    ;;
  tofu-account-baseline)
    readonly state_key='platform/infra/aws/tofu-account-baseline/v1/terraform.tfstate'
    ;;
  tofu-app-security)
    readonly state_key='platform/infra/aws/tofu-app-security/v1/terraform.tfstate'
    ;;
  *)
    fail '허용되지 않은 TARGET_ROOT다.'
    ;;
esac

readonly root_dir="infra/aws/${target_root}"
[[ -d ${root_dir} && -f ${root_dir}/versions.tf ]] || fail '선언한 root 디렉터리가 없다.'
[[ -f ${account_id_file} && ! -L ${account_id_file} && $(stat -c %a "${account_id_file}") == 600 ]] \
  || fail 'awscli가 만든 account ID 파일이 mode 0600 일반 파일이 아니다.'
[[ -n ${AWS_ACCESS_KEY_ID:-} && -n ${AWS_SECRET_ACCESS_KEY:-} ]] || fail 'AWS credential 환경변수가 없다.'

umask 077
temp_dir=$(mktemp -d /tmp/aws-ci-fix-01-tofu.XXXXXX)
cleanup() {
  local status=$?
  rm -f -- "${account_id_file}"
  rm -rf -- "${temp_dir}"
  exit "${status}"
}
trap cleanup EXIT INT TERM

export AWS_DEFAULT_REGION=${region} AWS_PAGER='' TF_IN_AUTOMATION=1
account_id=$(tr -d '\n' <"${account_id_file}")
case ${account_id} in
  '' | *[!0-9]*) fail 'AWS account 형식을 판정하지 못했다.' ;;
esac
[[ ${#account_id} == 12 ]] || fail 'AWS account 길이가 잘못됐다.'
[[ $(printf '%s' "${account_id}" | sha256sum | awk '{print $1}') == "${expected_account_sha256}" ]] \
  || fail '선언한 AWS account와 다르다.'

bucket="ktcloud4-bean-opentofu-state-${account_id}"
backend_file=${temp_dir}/backend.hcl
plan_file=${temp_dir}/plan.tfplan
cat >"${backend_file}" <<EOF
bucket         = "${bucket}"
key            = "${state_key}"
region         = "${region}"
dynamodb_table = "${lock_table}"
encrypt        = true
EOF

pushd "${root_dir}" >/dev/null
tofu init -input=false -reconfigure -backend-config="${backend_file}" >/dev/null
tofu validate -no-color >/dev/null
tofu plan \
  -input=false \
  -lock-timeout=60s \
  -no-color \
  -var "aws_account_id=${account_id}" \
  -out="${plan_file}" \
  >/dev/null

popd >/dev/null

printf 'AWS-CI-FIX-02 Plan=PASS root=%s state-key-version=v1 actions=summary-redacted sensitive-output=0\n' \
  "${target_root}"
