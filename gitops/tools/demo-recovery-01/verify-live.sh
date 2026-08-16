#!/usr/bin/env bash
set -euo pipefail

readonly task_sha=${DEMORECOVERY01_TASK_SHA:?task SHA is required}
readonly main_sha=${DEMORECOVERY01_MAIN_SHA:?main SHA is required}
tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly tool_dir
readonly ssh_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}

fail() { printf 'DEMO_RECOVERY_LIVE=FAIL stage=%s reason=%s\n' "$1" "$2" >&2; exit 1; }

remote_kubectl() {
  local command='sudo -n /usr/local/bin/k3s kubectl'
  local quoted
  printf -v quoted ' %q' "$@"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
    "${ssh_host}" "${command}${quoted}"
}

[[ ${task_sha} =~ ^[0-9a-f]{40}$ && ${main_sha} =~ ^[0-9a-f]{40}$ ]] \
  || fail precondition 'full lowercase SHAs are required'

pvc=$(remote_kubectl -n demo-onprem get pvc demo-recovery-data -o json)
jq -e '
  .status.phase == "Bound" and .spec.storageClassName == "local-path" and
  .spec.resources.requests.storage == "512Mi"
' <<<"${pvc}" >/dev/null || fail pvc 'demo recovery PVC is not the declared Bound 512Mi local-path claim'

pod=$(remote_kubectl -n demo-onprem get deployment demo-onprem-portal -o json)
jq -e '
  .spec.template.metadata.annotations["backup.velero.io/backup-volumes"] == "recovery-data" and
  any(.spec.template.spec.initContainers[]; .name == "recovery-seed") and
  any(.spec.template.spec.containers[]; .name == "portal" and
    any(.volumeMounts[]; .name == "recovery-data" and .mountPath == "/var/lib/demo-recovery"))
' <<<"${pod}" >/dev/null || fail declaration 'portal opt-in annotation, seed, or PVC mount is absent'
echo 'DEMO_RECOVERY_DECLARATION=PASS pvc=512Mi backup_opt_in=data seed=once'

"${tool_dir}/recovery.sh" backup
"${tool_dir}/recovery.sh" attack
"${tool_dir}/recovery.sh" restore
"${tool_dir}/recovery.sh" reset

apps=$(remote_kubectl -n argocd get applications.argoproj.io platform-root demo-onprem velero policy-baseline -o json)
jq -e --arg task "${task_sha}" --arg main "${main_sha}" '
  ([.items[] | select(.metadata.name == "platform-root")][0]) as $root |
  ([.items[] | select(.metadata.name == "demo-onprem")][0]) as $demo |
  ([.items[] | select(.metadata.name == "velero")][0]) as $velero |
  ([.items[] | select(.metadata.name == "policy-baseline")][0]) as $policy |
  $root.spec.source.targetRevision == $task and $root.status.sync.revision == $task and
  $root.status.sync.status == "Synced" and $root.status.health.status == "Healthy" and
  $demo.spec.source.targetRevision == $task and $demo.status.sync.revision == $task and
  $demo.status.sync.status == "Synced" and $demo.status.health.status == "Healthy" and
  $velero.spec.source.targetRevision == "main" and $velero.status.sync.revision == $main and
  $velero.status.sync.status == "Synced" and $velero.status.health.status == "Healthy" and
  $policy.spec.source.targetRevision == $task and $policy.status.sync.revision == $task and
  $policy.status.sync.status == "Synced" and $policy.status.health.status == "Healthy"
' <<<"${apps}" >/dev/null || fail argo 'candidate root/demo/policy or main Velero state is not Synced/Healthy'
echo 'DEMO_RECOVERY_LIVE=PASS backup=completed selfheal=data-corrupt restore=completed reset=clean'
