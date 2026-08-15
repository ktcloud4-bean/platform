#!/usr/bin/env bash
set -euo pipefail

readonly task_sha=${SUPPLY05FIX04_TASK_SHA:?task SHA is required}
readonly main_sha=${SUPPLY05FIX04_MAIN_SHA:?main SHA is required}
readonly ssh_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly policy_name=k3s-image-supply-chain-policy
readonly manager_image=docker.io/wazuh/wazuh-manager:4.14.7@sha256:a65dcdb61e48b7064bd7250c5cbd6aceeb9b8043a1a413931a8868793146f06d
readonly vault_image=hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54
readonly negative_name=supply05fix04-manager-negative

fail() { printf 'SUPPLY05FIX04_LIVE=FAIL stage=%s reason=%s\n' "$1" "$2" >&2; exit 1; }

remote_kubectl() {
  local quoted command='sudo -n /usr/local/bin/k3s kubectl'
  printf -v quoted ' %q' "$@"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
    "${ssh_host}" "${command}${quoted}"
}

[[ ${task_sha} =~ ^[0-9a-f]{40}$ && ${main_sha} =~ ^[0-9a-f]{40}$ ]] \
  || fail precondition 'full lowercase SHAs are required'

policy=$(remote_kubectl get imagevalidatingpolicy "${policy_name}" -o json)
jq -e --arg manager "${manager_image}" --arg vault "${vault_image}" '
  .spec.failurePolicy == "Fail" and .spec.validationActions == ["Deny"] and
  (.spec.matchConditions[0].expression | contains("object.metadata.name == \"wazuh-manager-master-0\"")) and
  (.spec.matchConditions[0].expression | contains($manager)) and
  (.spec.matchConditions[0].expression | contains($vault))
' <<<"${policy}" >/dev/null || fail policy 'exact manager exception or Enforce/Fail is absent'
echo 'SUPPLY05FIX04_POLICY=PASS enforcement=Deny failurePolicy=Fail scope=exact-pod-sa-digests'

statefulset=$(remote_kubectl -n wazuh get statefulset wazuh-manager-master -o json)
jq -e --arg manager "${manager_image}" --arg vault "${vault_image}" '
  .spec.template.spec.serviceAccountName == "wazuh-manager" and
  (.spec.template.spec.containers | length) == 1 and .spec.template.spec.containers[0].image == $manager and
  (.spec.template.spec.initContainers | length) == 1 and .spec.template.spec.initContainers[0].image == $vault
' <<<"${statefulset}" >/dev/null || fail precondition 'running StatefulSet shape differs from the exact exception'

negative=$(jq --arg name "${negative_name}" '
  {
    apiVersion:"v1", kind:"Pod",
    metadata:{name:$name,namespace:"wazuh"},
    spec:.spec.template.spec
  }
  | del(.spec.affinity, .spec.nodeName)
  | .spec.volumes = ((.spec.volumes // []) + [{name:"wazuh-manager-master",emptyDir:{}}])
' <<<"${statefulset}")
set +e
negative_result=$(remote_kubectl apply --server-side --dry-run=server -f - <<<"${negative}" 2>&1)
negative_status=$?
set -e
(( negative_status != 0 )) || fail negative 'different-name Pod was admitted'
grep -q "${policy_name}" <<<"${negative_result}" \
  || fail negative 'different-name rejection did not come from the supply policy'
echo 'SUPPLY05FIX04_NEGATIVE=PASS same_images=true different_name=denied resource_created=0'

old_uid=$(remote_kubectl -n wazuh get pod wazuh-manager-master-0 -o jsonpath='{.metadata.uid}')
[[ -n ${old_uid} ]] || fail rollout 'existing manager Pod UID is absent'
remote_kubectl -n wazuh rollout restart statefulset/wazuh-manager-master >/dev/null
remote_kubectl -n wazuh rollout status statefulset/wazuh-manager-master --timeout=420s >/dev/null \
  || fail rollout 'manager StatefulSet did not complete rollout'
new_pod=$(remote_kubectl -n wazuh get pod wazuh-manager-master-0 -o json)
new_uid=$(jq -r '.metadata.uid' <<<"${new_pod}")
[[ -n ${new_uid} && ${new_uid} != "${old_uid}" ]] || fail rollout 'manager Pod UID did not change'
jq -e 'any(.status.conditions[]; .type=="Ready" and .status=="True")' <<<"${new_pod}" >/dev/null \
  || fail rollout 'new manager Pod is not Ready'
echo 'SUPPLY05FIX04_RECREATE=PASS pod=wazuh-manager-master-0 uid_changed=true ready=1/1'

apps=$(remote_kubectl -n argocd get applications.argoproj.io platform-root policy-baseline wazuh -o json)
jq -e --arg task "${task_sha}" --arg main "${main_sha}" '
  ([.items[]|select(.metadata.name=="platform-root")][0]) as $root |
  ([.items[]|select(.metadata.name=="policy-baseline")][0]) as $policy |
  ([.items[]|select(.metadata.name=="wazuh")][0]) as $wazuh |
  $root.spec.source.targetRevision==$task and $root.status.sync.revision==$task and
  $root.status.sync.status=="Synced" and $root.status.health.status=="Healthy" and
  $policy.spec.source.targetRevision==$task and $policy.status.sync.revision==$task and
  $policy.status.sync.status=="Synced" and $policy.status.health.status=="Healthy" and
  $wazuh.spec.source.targetRevision=="main" and $wazuh.status.sync.revision==$main and
  $wazuh.status.sync.status=="Synced" and $wazuh.status.health.status=="Healthy"
' <<<"${apps}" >/dev/null || fail argo 'root/policy task SHA or Wazuh main state is not Synced/Healthy'

remote_kubectl -n wazuh get pod "${negative_name}" >/dev/null 2>&1 \
  && fail cleanup 'negative control Pod exists'
echo 'SUPPLY05FIX04_LIVE=PASS manager_recreated=true negative_denied=true transient_resources=0'
