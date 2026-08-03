#!/usr/bin/env bash
set -euo pipefail

readonly kubeconfig=${KUBECONFIG:?KUBECONFIG에 k3s-01 admin kubeconfig를 지정해야 한다.}
readonly selector='app.kubernetes.io/name=falco,app.kubernetes.io/instance=falco'
readonly policy_name='pol-02-falco-root-sensor-baseline'
readonly pod_exception='pol-02-falco-pod-run-as-non-root'
readonly daemonset_exception='pol-02-falco-daemonset-run-as-non-root'

kube() {
  kubectl --kubeconfig "${kubeconfig}" "$@"
}

fail() {
  echo "FalcoRecreate=FAIL reason=$1" >&2
  exit 1
}

policy=$(kube get clusterpolicy.kyverno.io "${policy_name}" -o json)
jq -e '
  .spec.validationFailureAction == "Enforce" and
  ([.spec.rules[].name] | sort) == ([
    "require-falco-root-sensor-baseline",
    "restrict-falco-added-capabilities",
    "restrict-falco-host-paths"
  ] | sort)
' <<<"${policy}" >/dev/null || fail 'compensating_policy_not_enforced'

exceptions=$(kube -n kyverno get policyexceptions.kyverno.io \
  "${pod_exception}" "${daemonset_exception}" -o json)
jq -e \
  --arg pod "${pod_exception}" \
  --arg daemonset "${daemonset_exception}" '
  ([.items[] |
    select(.metadata.name == $pod) |
    select(.metadata.annotations["pol-02.imcherry5778.xyz/expires-at"] == null) |
    select(.spec.conditions == null) |
    select(.spec.exceptions == [{
      policyName: "pol-01-require-pod-run-as-non-root",
      ruleNames: ["require-pod-run-as-non-root"]
    }]) |
    select(.spec.match.any == [{resources: {
      kinds: ["Pod"], namespaces: ["falco"], names: ["falco-*"]
    }}])
  ] | length == 1) and
  ([.items[] |
    select(.metadata.name == $daemonset) |
    select(.metadata.annotations["pol-02.imcherry5778.xyz/expires-at"] == null) |
    select(.spec.conditions == null) |
    select(.spec.exceptions == [{
      policyName: "pol-01-require-pod-run-as-non-root",
      ruleNames: ["autogen-require-pod-run-as-non-root"]
    }]) |
    select(.spec.match.any == [{resources: {
      kinds: ["DaemonSet"], namespaces: ["falco"], names: ["falco"]
    }}])
  ] | length == 1)
' <<<"${exceptions}" >/dev/null || fail 'policy_exception_scope_mismatch'

old_state=$(kube -n falco get pods -l "${selector}" -o json)
jq -e '
  .items | length == 1 and
  .[0].metadata.ownerReferences[0].kind == "DaemonSet" and
  .[0].metadata.ownerReferences[0].name == "falco" and
  ([.[0].status.containerStatuses[]? |
    select(.name == "falco" and .ready == true)] | length) == 1
' <<<"${old_state}" >/dev/null || fail 'precondition_falco_not_ready'

old_name=$(jq -r '.items[0].metadata.name' <<<"${old_state}")
old_uid=$(jq -r '.items[0].metadata.uid' <<<"${old_state}")

negative_pod=$(jq '
  .items[0] |
  del(
    .metadata.annotations,
    .metadata.creationTimestamp,
    .metadata.generateName,
    .metadata.generation,
    .metadata.managedFields,
    .metadata.ownerReferences,
    .metadata.resourceVersion,
    .metadata.uid,
    .status
  ) |
  .metadata.name = "falco-cap-03-negative" |
  (.spec.containers[] |
    select(.name == "falco").securityContext.allowPrivilegeEscalation) = true
' <<<"${old_state}")

negative_output=''
if negative_output=$(printf '%s\n' "${negative_pod}" | \
  kube create --dry-run=server -f - 2>&1); then
  fail 'compensating_policy_allowed_privileged_falco'
fi
grep -Fq "${policy_name}" <<<"${negative_output}" \
  || fail 'negative_test_failed_outside_compensating_policy'
grep -Fq 'require-falco-root-sensor-baseline' <<<"${negative_output}" \
  || fail 'negative_test_did_not_hit_baseline_rule'

failed_create_before=$(kube -n falco get events -o json | jq '
  [.items[] |
    select(.reason == "FailedCreate") |
    select((.message // "") | contains("pol-01-require-pod-run-as-non-root")) |
    (.count // 1)
  ] | add // 0
')

kube -n falco delete pod "${old_name}" --wait=false >/dev/null

new_state=''
for _ in {1..24}; do
  new_state=$(kube -n falco get pods -l "${selector}" -o json 2>/dev/null || true)
  if jq -e --arg old_uid "${old_uid}" '
    .items | length == 1 and
    .[0].metadata.uid != $old_uid and
    .[0].metadata.ownerReferences[0].kind == "DaemonSet" and
    .[0].metadata.ownerReferences[0].name == "falco" and
    ([.[0].status.containerStatuses[]? |
      select(.name == "falco" and .ready == true)] | length) == 1
  ' <<<"${new_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

jq -e --arg old_uid "${old_uid}" '
  .items | length == 1 and
  .[0].metadata.uid != $old_uid and
  ([.[0].status.containerStatuses[]? |
    select(.name == "falco" and .ready == true)] | length) == 1
' <<<"${new_state}" >/dev/null || fail 'new_falco_pod_not_ready_within_120s'

new_name=$(jq -r '.items[0].metadata.name' <<<"${new_state}")
new_uid=$(jq -r '.items[0].metadata.uid' <<<"${new_state}")

failed_create_after=$(kube -n falco get events -o json | jq '
  [.items[] |
    select(.reason == "FailedCreate") |
    select((.message // "") | contains("pol-01-require-pod-run-as-non-root")) |
    (.count // 1)
  ] | add // 0
')
[[ ${failed_create_after} -eq ${failed_create_before} ]] \
  || fail 'run_as_non_root_admission_rejection_increased'

falco_logs=$(kube -n falco logs "${new_name}" -c falco --tail=120)
if grep -Fq 'could not initialize inotify handler' <<<"${falco_logs}"; then
  fail 'inotify_handler_initialization_failed'
fi

daemonset_state=$(kube -n falco get daemonset falco -o json)
jq -e '
  .status.desiredNumberScheduled == 1 and
  .status.currentNumberScheduled == 1 and
  .status.numberReady == 1 and
  .status.numberAvailable == 1
' <<<"${daemonset_state}" >/dev/null || fail 'daemonset_not_fully_available'

echo "FalcoPolicy=PASS policy=${policy_name} exceptions=${pod_exception},${daemonset_exception}"
echo 'FalcoPolicyNegative=PASS allowPrivilegeEscalation=true denied_by=require-falco-root-sensor-baseline persisted=0'
echo "FalcoRecreate=PASS old_pod=${old_name} old_uid=${old_uid} new_pod=${new_name} new_uid=${new_uid} admission_rejections_added=0"
