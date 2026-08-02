#!/usr/bin/env bash
# 완료 증거 1(분석)과 2(같은 gate의 통과/실패)만 검증한다.
# shellcheck disable=SC2029
set -Eeuo pipefail

readonly sonar_url=${SONAR_URL:-http://127.0.0.1:19000}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly env_file=${secret_root}/sonarqube/env
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

SONARQUBE_ADMIN_PASSWORD=
while IFS='=' read -r key value; do
  [[ "${key}" == SONARQUBE_ADMIN_PASSWORD ]] && SONARQUBE_ADMIN_PASSWORD=${value}
done <"${env_file}"
readonly SONARQUBE_ADMIN_PASSWORD
[[ -n "${SONARQUBE_ADMIN_PASSWORD}" ]]

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
readonly netrc_file=${temp_dir}/netrc
printf 'machine 127.0.0.1 login admin password %s\n' "${SONARQUBE_ADMIN_PASSWORD}" >"${netrc_file}"
chmod 0600 "${netrc_file}"

kubectl_ssh() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}
cleanup() {
  kubectl_ssh -n sonarqube delete job quality01-scanner --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  kubectl_ssh -n sonarqube delete configmap quality01-pass-sample quality01-fail-sample --ignore-not-found=true >/dev/null 2>&1 || true
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kubectl_ssh -n sonarqube delete job quality01-scanner --ignore-not-found=true --wait=true >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" \
  <"${repo_root}/gitops/tools/quality-01/sample-configmaps.yaml" >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" \
  <"${repo_root}/gitops/tools/quality-01/scanner-job.yaml" >/dev/null

if ! kubectl_ssh -n sonarqube wait --for=condition=complete job/quality01-scanner --timeout=600s >/dev/null; then
  kubectl_ssh -n sonarqube logs job/quality01-scanner --all-containers=true --prefix=true >&2 || true
  exit 1
fi
kubectl_ssh -n sonarqube logs job/quality01-scanner -c scanner | \
  sed -n '/EXECUTION SUCCESS/p;/ANALYSIS SUCCESSFUL/p'

sonar_get() {
  curl --silent --show-error --fail --netrc-file "${netrc_file}" --get "$@"
}

for project in quality01-pass quality01-fail; do
  completed=false
  for _ in $(seq 1 60); do
    ce_json=$(sonar_get --data-urlencode "component=${project}" "${sonar_url}/api/ce/component")
    status=$(jq -r '.current.status // .queue[0].status // "NONE"' <<<"${ce_json}")
    case "${status}" in
      SUCCESS) completed=true; break ;;
      FAILED|CANCELED)
        jq '{project:"'"${project}"'",current,queue}' <<<"${ce_json}" >&2
        exit 1
        ;;
    esac
    sleep 2
  done
  [[ "${completed}" == true ]] || {
    echo "${project} Compute Engine 완료를 제한 시간 안에 확인하지 못했다." >&2
    exit 1
  }
done

pass_gate=$(sonar_get --data-urlencode projectKey=quality01-pass \
  "${sonar_url}/api/qualitygates/project_status")
fail_gate=$(sonar_get --data-urlencode projectKey=quality01-fail \
  "${sonar_url}/api/qualitygates/project_status")
jq -e '.projectStatus.status == "OK"' <<<"${pass_gate}" >/dev/null
jq -e '.projectStatus.status == "ERROR" and ([.projectStatus.conditions[] | select(.metricKey == "coverage" and .status == "ERROR" and .errorThreshold == "80")] | length == 1)' \
  <<<"${fail_gate}" >/dev/null

pass_analyses=$(sonar_get --data-urlencode project=quality01-pass --data-urlencode ps=1 \
  "${sonar_url}/api/project_analyses/search")
fail_analyses=$(sonar_get --data-urlencode project=quality01-fail --data-urlencode ps=1 \
  "${sonar_url}/api/project_analyses/search")
jq -e '.analyses | length == 1' <<<"${pass_analyses}" >/dev/null
jq -e '.analyses | length == 1' <<<"${fail_analyses}" >/dev/null

pass_date=$(jq -r '.analyses[0].date' <<<"${pass_analyses}")
fail_date=$(jq -r '.analyses[0].date' <<<"${fail_analyses}")
printf 'QUALITY-01 분석 기록: pass=%s fail=%s\n' "${pass_date}" "${fail_date}"
printf 'QUALITY-01 quality gate 대조: pass=%s fail=%s fail_metric=coverage threshold=80\n' \
  "$(jq -r '.projectStatus.status' <<<"${pass_gate}")" \
  "$(jq -r '.projectStatus.status' <<<"${fail_gate}")"
