#!/usr/bin/env bash
set -euo pipefail

readonly task_sha=${POL03FIX01_TASK_SHA:?task SHA is required}
readonly main_sha=${POL03FIX01_MAIN_SHA:?main SHA is required}
readonly ssh_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly exception_name=pol-03-velero-pvb-hosting-run-as-non-root
readonly backup_name=pol03fix01-pvb-verify
readonly negative_name=pol03fix01-pvb-negative
readonly pvb_label=velero.io/pod-volume-backup
readonly velero_sa=velero-server

fail() { printf 'POL03FIX01_LIVE=FAIL stage=%s reason=%s\n' "$1" "$2" >&2; exit 1; }

remote_kubectl() {
  local command='sudo -n /usr/local/bin/k3s kubectl'
  local quoted
  printf -v quoted ' %q' "$@"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
    "${ssh_host}" "${command}${quoted}"
}

cleanup() {
  remote_kubectl -n velero delete backup "${backup_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  for _ in {1..36}; do
    if ! remote_kubectl -n velero get backup "${backup_name}" >/dev/null 2>&1; then
      local pvb_count
      pvb_count=$(remote_kubectl -n velero get podvolumebackups.velero.io -o json 2>/dev/null | jq --arg backup "${backup_name}" \
        '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Backup" and .name == $backup))] | length' 2>/dev/null || true)
      [[ ${pvb_count} == 0 ]] && return
    fi
    sleep 5
  done
  printf 'POL03FIX01_CLEANUP=INCOMPLETE backup=%s\n' "${backup_name}" >&2
}
trap cleanup EXIT

[[ ${task_sha} =~ ^[0-9a-f]{40}$ && ${main_sha} =~ ^[0-9a-f]{40}$ ]] \
  || fail precondition 'full lowercase SHAs are required'

remote_kubectl -n velero get backup "${backup_name}" >/dev/null 2>&1 \
  && fail precondition 'task-owned backup already exists'

exception=$(remote_kubectl -n kyverno get policyexception "${exception_name}" -o json)
jq -e --arg label "${pvb_label}" --arg sa "${velero_sa}" '
  .spec.background == false and
  .spec.exceptions == [{"policyName":"pol-01-require-pod-run-as-non-root","ruleNames":["require-pod-run-as-non-root"]}] and
  (.spec.match.any | length) == 1 and
  .spec.match.any[0].resources.kinds == ["Pod"] and
  .spec.match.any[0].resources.namespaces == ["velero"] and
  .spec.match.any[0].resources.selector.matchExpressions == [{"key":$label,"operator":"Exists"}] and
  .spec.match.any[0].subjects == [{"kind":"ServiceAccount","name":$sa,"namespace":"velero"}] and
  (.spec.conditions.all | length) == 4 and
  ([.spec.conditions.all[] | .operator] | all(. == "Equals"))
' <<<"${exception}" >/dev/null || fail policy 'live PVB exception is not the declared narrow boundary'
echo 'POL03FIX01_POLICY=PASS scope=label-ownerref-serviceaccount wildcard=0'

node_agent=$(remote_kubectl -n velero get daemonset node-agent -o json)
image=$(jq -r '.spec.template.spec.containers[0].image // empty' <<<"${node_agent}")
[[ ${image} == *@sha256:* ]] || fail precondition 'node-agent immutable image is absent'

set +e
negative_result=$(remote_kubectl --as="system:serviceaccount:velero:${velero_sa}" -n velero apply --server-side --dry-run=server -f - <<YAML 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${negative_name}
  namespace: velero
  labels:
    ${pvb_label}: ${negative_name}
spec:
  serviceAccountName: ${velero_sa}
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  containers:
    - name: negative
      image: ${image}
      command: ["sh", "-c", "sleep 1"]
YAML
)
negative_status=$?
set -e
(( negative_status != 0 )) || fail negative 'PodVolumeBackup ownerRef-free root Pod was admitted'
grep -Eq 'pol-01-require-pod-run-as-non-root|runAsNonRoot must be true' <<<"${negative_result}" \
  || fail negative 'ownerRef-free root Pod was not rejected by POL-01'
echo 'POL03FIX01_NEGATIVE=PASS same_sa_label=true ownerref=false denied_by=POL-01 resource_created=0'

gitea_pod=$(remote_kubectl -n gitea get pod -o json | jq -r '
  .items[] |
  select(.status.phase == "Running") |
  select(any(.spec.volumes[]?; .persistentVolumeClaim?.claimName == "gitea-data")) |
  .metadata.name
' | head -n 1)
[[ -n ${gitea_pod} ]] || fail precondition 'running gitea-data Pod is absent'

remote_kubectl -n velero apply -f - <<YAML >/dev/null
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${backup_name}
  namespace: velero
  labels:
    app.kubernetes.io/part-of: platform-gitops
    pol-03-fix-01.imcherry5778.xyz/transient: "true"
spec:
  includedNamespaces:
    - gitea
  defaultVolumesToFsBackup: false
  ttl: 1h
YAML

pvb_result=
backup_phase=
for _ in {1..72}; do
  backup=$(remote_kubectl -n velero get backup "${backup_name}" -o json)
  backup_phase=$(jq -r '.status.phase // empty' <<<"${backup}")
  pvb_result=$(remote_kubectl -n velero get podvolumebackups.velero.io -o json | jq -c --arg backup "${backup_name}" '
    [.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Backup" and .name == $backup)) |
      {name:.metadata.name,phase:(.status.phase // ""),bytes:(.status.progress.bytesDone // 0)}]
  ')
  if [[ ${backup_phase} == Completed ]] && jq -e 'length == 1 and .[0].phase == "Completed" and .[0].bytes > 0' <<<"${pvb_result}" >/dev/null; then
    break
  fi
  if [[ ${backup_phase} == Failed || ${backup_phase} == PartiallyFailed ]]; then
    fail pvb "backup phase=${backup_phase}"
  fi
  sleep 5
done

[[ ${backup_phase} == Completed ]] \
  || fail pvb "backup did not complete in bounded wait phase=${backup_phase:-unknown}"
jq -e 'length == 1 and .[0].phase == "Completed" and .[0].bytes > 0' <<<"${pvb_result}" >/dev/null \
  || fail pvb 'exactly one completed PVB with progress is absent'
echo 'POL03FIX01_PVB=PASS backup=completed pvb=completed gitea_data=read_only'

remote_kubectl -n velero delete backup "${backup_name}" --wait=false >/dev/null
for _ in {1..36}; do
  backup_absent=false
  pvb_absent=false
  if ! remote_kubectl -n velero get backup "${backup_name}" >/dev/null 2>&1; then
    backup_absent=true
  fi
  pvb_count=$(remote_kubectl -n velero get podvolumebackups.velero.io -o json | jq --arg backup "${backup_name}" '
    [.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Backup" and .name == $backup))] | length
  ')
  if [[ ${pvb_count} == 0 ]]; then
    pvb_absent=true
  fi
  if [[ ${backup_absent} == true && ${pvb_absent} == true ]]; then
    break
  fi
  sleep 5
done
[[ ${backup_absent} == true && ${pvb_absent} == true ]] || fail cleanup 'task-owned Backup or PVB remains'
trap - EXIT

apps=$(remote_kubectl -n argocd get applications.argoproj.io platform-root policy-baseline velero -o json)
jq -e --arg task "${task_sha}" --arg main "${main_sha}" '
  ([.items[] | select(.metadata.name == "platform-root")][0]) as $root |
  ([.items[] | select(.metadata.name == "policy-baseline")][0]) as $policy |
  ([.items[] | select(.metadata.name == "velero")][0]) as $velero |
  $root.spec.source.targetRevision == $task and $root.status.sync.revision == $task and
  $root.status.sync.status == "Synced" and $root.status.health.status == "Healthy" and
  $policy.spec.source.targetRevision == $task and $policy.status.sync.revision == $task and
  $policy.status.sync.status == "Synced" and $policy.status.health.status == "Healthy" and
  $velero.spec.source.targetRevision == "main" and $velero.status.sync.revision == $main and
  $velero.status.sync.status == "Synced" and $velero.status.health.status == "Healthy"
' <<<"${apps}" >/dev/null || fail argo 'root/policy task SHA or Velero main state is not Synced/Healthy'
echo 'POL03FIX01_LIVE=PASS pvb=completed negative=denied transient_resources=0'
