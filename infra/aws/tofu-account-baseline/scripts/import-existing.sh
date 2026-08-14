#!/usr/bin/env bash
# AWS-SEC-01: preflight에서 존재가 확인된 account-global 자원만 state로 흡수한다.
set -Eeuo pipefail

readonly input_file=${1:?usage: import-existing.sh /absolute/path/account-baseline.tfvars}
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly root_dir

fail() {
  echo "AWS-SEC-01 import 실패: $*" >&2
  exit 1
}

for command in aws tofu awk stat; do
  command -v "${command}" >/dev/null || fail "${command} command가 없다."
done
[[ ${input_file} = /* && -f ${input_file} && ! -L ${input_file} && $(stat -c %a "${input_file}") == 600 ]] \
  || fail '입력은 mode 0600의 절대 경로 일반 파일이어야 한다.'

trail_name=$(awk -F= '$1 ~ /^cloudtrail_name[[:space:]]*$/ {gsub(/[[:space:]"]/, "", $2); print $2; exit}' "${input_file}")
[[ -n ${trail_name} ]] || trail_name=management-events

if [[ -z ${TF_VAR_aws_account_id:-} ]]; then
  TF_VAR_aws_account_id=$(aws sts get-caller-identity --query Account --output text)
  export TF_VAR_aws_account_id
fi

cd "${root_dir}"
tofu init -input=false >/dev/null

state_has() {
  tofu state list 2>/dev/null | grep -Fxq "$1"
}

tfvar_value() {
  awk -F= -v key="$1" '$1 ~ "^" key "[[:space:]]*$" {gsub(/[[:space:]"]/, "", $2); print $2; exit}' "${input_file}"
}

if ! state_has aws_cloudtrail.main; then
  trail_arn=$(aws cloudtrail get-trail --name "${trail_name}" --query 'Trail.TrailARN' --output text 2>/dev/null) \
    || fail '선언한 기존 CloudTrail을 찾지 못했다.'
  [[ ${trail_arn} == arn:aws:cloudtrail:* ]] || fail '기존 CloudTrail ARN 형식을 판정하지 못했다.'
  tofu import -input=false -var-file="${input_file}" aws_cloudtrail.main "${trail_arn}" >/dev/null
  unset trail_arn
  echo 'AWS-SEC-01 Import=PASS resource=cloudtrail'
else
  echo 'AWS-SEC-01 Import=EXISTS resource=cloudtrail'
fi

if ! state_has aws_iam_service_linked_role.config; then
  if aws iam get-role --role-name AWSServiceRoleForConfig >/dev/null 2>&1; then
    tofu import -input=false -var-file="${input_file}" aws_iam_service_linked_role.config config.amazonaws.com >/dev/null
    echo 'AWS-SEC-01 Import=PASS resource=config-service-linked-role'
  else
    echo 'AWS-SEC-01 Import=ABSENT resource=config-service-linked-role'
  fi
else
  echo 'AWS-SEC-01 Import=EXISTS resource=config-service-linked-role'
fi

alert_email=$(tfvar_value alert_email)
if [[ -n ${alert_email} ]] && ! state_has "aws_ce_anomaly_monitor.service[0]"; then
  monitor_name=$(tfvar_value cost_anomaly_monitor_name)
  [[ -n ${monitor_name} ]] || monitor_name=Default-Services-Monitor
  monitor_arn=$(aws ce get-anomaly-monitors --region us-east-1 \
    --query "AnomalyMonitors[?MonitorName==\`${monitor_name}\` && MonitorType==\`DIMENSIONAL\`].MonitorArn | [0]" --output text)
  [[ ${monitor_arn} == arn:aws:ce:* ]] || fail '선언한 기존 Cost Explorer dimensional monitor를 찾지 못했다.'
  tofu import -input=false -var-file="${input_file}" aws_ce_anomaly_monitor.service[0] "${monitor_arn}" >/dev/null
  unset monitor_name monitor_arn
  echo 'AWS-SEC-01 Import=PASS resource=cost-anomaly-monitor'
elif state_has "aws_ce_anomaly_monitor.service[0]"; then
  echo 'AWS-SEC-01 Import=EXISTS resource=cost-anomaly-monitor'
fi
