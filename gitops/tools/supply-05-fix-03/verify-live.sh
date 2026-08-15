#!/usr/bin/env bash
# SUPPLY-05-FIX-03: Kyverno ImageValidatingPolicy admission latency verification.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/home/imcherry/.kube/k3s-01-admin.yaml}"
KUBECTL=(kubectl)
job_name="supply05fix03-canary-$(date +%s)"
job_created=0

cleanup() {
  if [[ "${job_created}" -eq 1 ]]; then
    "${KUBECTL[@]}" -n renovate delete job "${job_name}" --ignore-not-found --wait=false >/dev/null
  fi
}
trap cleanup EXIT

fail() {
  printf 'SUPPLY05FIX03_FAIL: %s\n' "$*" >&2
  exit 1
}

policy_json="$("${KUBECTL[@]}" get imagevalidatingpolicy k3s-image-supply-chain-policy -o json)"
printf '%s' "${policy_json}" | jq -e '
  .spec.failurePolicy == "Fail" and
  (.spec.validationActions | index("Deny")) and
  ([.spec.attestors[].name] | sort == ["current", "previous"])
' >/dev/null || fail 'ImageValidatingPolicy Enforce/Fail 또는 current/previous key 경계가 달라졌다'

signature_expression="$(printf '%s' "${policy_json}" | jq -r '
  .spec.validations[] | select(.message | contains("Cosign image signature")) | .expression
')"
[[ "${signature_expression}" == *'verifyImageSignatures(image, [attestors.current]) > 0 || verifyImageSignatures(image, [attestors.previous]) > 0'* ]] ||
  fail 'current→previous short-circuit signature expression이 없다'

"${KUBECTL[@]}" -n kyverno get configmap kyverno -o json | jq -e '
  (.data.resourceFilters | contains("kube-system") | not) and
  (.data.resourceFilters | contains("kyverno") | not)
' >/dev/null || fail 'Kyverno resourceFilters에 namespace 전체 제외가 있다'

"${KUBECTL[@]}" -n renovate get cronjob renovate -o json |
  jq --arg job_name "${job_name}" '
    {
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: {
        name: $job_name,
        namespace: "renovate",
        labels: {
          "app.kubernetes.io/name": "renovate",
          "app.kubernetes.io/component": "supply-05-fix-03-canary",
          "app.kubernetes.io/part-of": "platform-gitops"
        }
      },
      spec: .spec.jobTemplate.spec
    }
    | .spec.ttlSecondsAfterFinished = 300
    | .spec.template.spec.containers |= map(
        if .name == "renovate" then
          .command = ["node", "-e", "process.exit(0)"] |
          .args = []
        else .
        end
      )
  ' |
  "${KUBECTL[@]}" -n renovate create -f - >/dev/null
job_created=1

"${KUBECTL[@]}" -n renovate wait --for=condition=complete "job/${job_name}" --timeout=60s >/dev/null ||
  fail 'curated Renovate/Vault canary Job이 60초 안에 완료되지 않았다'

"${KUBECTL[@]}" -n renovate get "job/${job_name}" -o json | jq -e '.status.succeeded == 1' >/dev/null ||
  fail 'curated Renovate/Vault canary Job 성공 상태가 아니다'

for app in kyverno policy-baseline renovate platform-root; do
  app_json="$("${KUBECTL[@]}" -n argocd get application "${app}" -o json)"
  printf '%s' "${app_json}" | jq -e '
    .status.sync.status == "Synced" and .status.health.status == "Healthy"
  ' >/dev/null || fail "Application/${app}가 Synced/Healthy가 아니다"
done

printf 'SUPPLY05FIX03_LIVE=PASS job=%s\n' "${job_name}"
