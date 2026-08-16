#!/usr/bin/env bash
set -euo pipefail

readonly ssh_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly source_namespace=demo-onprem
readonly restore_namespace=demo-recovery-01-restore
readonly portal_deployment=demo-onprem-portal
readonly backup_name=demo-recovery-01-backup
readonly restore_name=demo-recovery-01-restore
readonly normal_hash=659c0c983579f4a4c67bea29be9da7ad7b8e384c5aede6d1827cbd7090e45d1c

fail() { printf 'DEMO_RECOVERY_%s=FAIL reason=%s\n' "${action^^}" "$*" >&2; exit 1; }

remote_kubectl() {
  local command='sudo -n /usr/local/bin/k3s kubectl'
  local quoted
  printf -v quoted ' %q' "$@"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
    "${ssh_host}" "${command}${quoted}"
}

portal_status() {
  local namespace=$1
  remote_kubectl -n "${namespace}" exec "deployment/${portal_deployment}" -c portal -- \
    python3 -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/demo-onprem/recovery/status", timeout=3).read().decode())'
}

assert_normal() {
  local namespace=$1
  local response
  response=$(portal_status "${namespace}")
  jq -e --arg hash "${normal_hash}" \
    '.marker == "DEMO-RECOVERY-STATUS" and .state == "normal" and .sha256 == $hash' \
    <<<"${response}" >/dev/null || fail "${namespace} recovery response is not the expected normal marker"
}

assert_corrupt() {
  local response
  response=$(portal_status "${source_namespace}")
  jq -e --arg hash "${normal_hash}" \
    '.marker == "DEMO-RECOVERY-STATUS" and .state == "corrupt" and .sha256 != $hash' \
    <<<"${response}" >/dev/null || fail 'source recovery response did not retain corruption'
}

wait_deployment() {
  local namespace=$1
  remote_kubectl -n "${namespace}" rollout status "deployment/${portal_deployment}" --timeout=180s >/dev/null
}

write_source() {
  local value=$1
  remote_kubectl -n "${source_namespace}" exec "deployment/${portal_deployment}" -c portal -- \
    python3 -c "from pathlib import Path; Path('/var/lib/demo-recovery/customer-marker.json').write_bytes(b'${value}\\n')"
}

wait_backup() {
  local phase=
  local pvb=
  for _ in {1..72}; do
    phase=$(remote_kubectl -n velero get backup "${backup_name}" -o json | jq -r '.status.phase // empty')
    pvb=$(remote_kubectl -n velero get podvolumebackups.velero.io -o json | jq -c --arg backup "${backup_name}" '
      [.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Backup" and .name == $backup)) |
       {phase:(.status.phase // ""), bytes:(.status.progress.bytesDone // 0)}]
    ')
    if [[ ${phase} == Completed ]] && jq -e 'length == 1 and .[0].phase == "Completed" and .[0].bytes > 0' <<<"${pvb}" >/dev/null; then
      return
    fi
    if [[ ${phase} == Failed || ${phase} == PartiallyFailed ]]; then
      fail "Backup phase=${phase}"
    fi
    sleep 5
  done
  fail "Backup bounded wait exceeded phase=${phase:-unknown}"
}

wait_restore() {
  local phase=
  local pvr=
  for _ in {1..72}; do
    phase=$(remote_kubectl -n velero get restore "${restore_name}" -o json | jq -r '.status.phase // empty')
    pvr=$(remote_kubectl -n velero get podvolumerestores.velero.io -o json | jq -c --arg restore "${restore_name}" '
      [.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Restore" and .name == $restore)) |
       {phase:(.status.phase // "")}]
    ')
    if [[ ${phase} == Completed ]] && jq -e 'length == 1 and .[0].phase == "Completed"' <<<"${pvr}" >/dev/null; then
      return
    fi
    if [[ ${phase} == Failed || ${phase} == PartiallyFailed ]]; then
      fail "Restore phase=${phase}"
    fi
    sleep 5
  done
  fail "Restore bounded wait exceeded phase=${phase:-unknown}"
}

cleanup() {
  local cleanup_backup backup_uid request_phase request_errors
  local backup_count restore_count namespace_absent request_absent pvb_count pvr_count
  local -a cleanup_backups=()
  local backups_json='[]'

  while IFS= read -r cleanup_backup; do
    [[ -n ${cleanup_backup} ]] || continue
    cleanup_backups+=("${cleanup_backup}")
  done < <(remote_kubectl -n velero get backups.velero.io \
    -l app.kubernetes.io/part-of=demo-recovery-01 \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

  if (( ${#cleanup_backups[@]} > 0 )); then
    backups_json=$(printf '%s\n' "${cleanup_backups[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  fi

  remote_kubectl -n velero delete restores.velero.io \
    -l app.kubernetes.io/part-of=demo-recovery-01 --ignore-not-found --wait=true >/dev/null 2>&1 || true

  for cleanup_backup in "${cleanup_backups[@]}"; do
    backup_uid=$(remote_kubectl -n velero get backup "${cleanup_backup}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
    [[ -n ${backup_uid} ]] || continue
    remote_kubectl -n velero create -f - -o name <<YAML >/dev/null
apiVersion: velero.io/v1
kind: DeleteBackupRequest
metadata:
  generateName: demo-recovery-01-delete-
  namespace: velero
  labels:
    app.kubernetes.io/part-of: demo-recovery-01
    velero.io/backup-name: ${cleanup_backup}
    velero.io/backup-uid: ${backup_uid}
spec:
  backupName: ${cleanup_backup}
YAML
  done

  remote_kubectl delete namespace "${restore_namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  for _ in {1..48}; do
    namespace_absent=false
    request_absent=true
    remote_kubectl get namespace "${restore_namespace}" >/dev/null 2>&1 || namespace_absent=true
    backup_count=$(remote_kubectl -n velero get backups.velero.io \
      -l app.kubernetes.io/part-of=demo-recovery-01 -o json | jq '.items | length')
    restore_count=$(remote_kubectl -n velero get restores.velero.io \
      -l app.kubernetes.io/part-of=demo-recovery-01 -o json | jq '.items | length')
    request_phase=$(remote_kubectl -n velero get deletebackuprequests.velero.io \
      -l app.kubernetes.io/part-of=demo-recovery-01 -o json | jq -r '[.items[].status.phase // empty] | join(",")')
    request_errors=$(remote_kubectl -n velero get deletebackuprequests.velero.io \
      -l app.kubernetes.io/part-of=demo-recovery-01 -o json | jq '[.items[].status.errors[]?] | length')
    if [[ ${request_phase} == *Processed* && ${request_errors} != 0 ]]; then
      fail 'DeleteBackupRequest reported errors'
    fi
    [[ -z ${request_phase} ]] || request_absent=false
    pvb_count=$(remote_kubectl -n velero get podvolumebackups.velero.io -o json | jq --argjson backups "${backups_json}" \
      '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Backup" and (.name as $name | $backups | index($name))))] | length')
    pvr_count=$(remote_kubectl -n velero get podvolumerestores.velero.io -o json | jq --arg restore "${restore_name}" \
      '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Restore" and .name == $restore))] | length')
    if [[ ${backup_count} == 0 && ${restore_count} == 0 && ${namespace_absent} == true && ${pvb_count} == 0 && ${pvr_count} == 0 && ${request_absent} == true ]]; then
      return
    fi
    sleep 5
  done
  fail 'task-owned Backup, Restore, PVB, PVR, or isolation namespace remains'
}

[[ $# == 1 ]] || { echo 'usage: recovery.sh {backup|attack|restore|reset}' >&2; exit 2; }
action=$1
[[ ${action} =~ ^(backup|attack|restore|reset)$ ]] || exit 2

case "${action}" in
  backup)
    remote_kubectl -n velero get backup "${backup_name}" >/dev/null 2>&1 \
      && fail 'task-owned Backup already exists; run reset first'
    assert_normal "${source_namespace}"
    remote_kubectl -n velero apply -f - <<YAML >/dev/null
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${backup_name}
  namespace: velero
  labels:
    app.kubernetes.io/part-of: demo-recovery-01
spec:
  includedNamespaces:
    - ${source_namespace}
  includedResources:
    - configmaps
    - deployments
    - persistentvolumeclaims
    - pods
    - serviceaccounts
    - services
  defaultVolumesToFsBackup: false
  ttl: 1h
YAML
    wait_backup
    echo 'DEMO_RECOVERY_BACKUP=PASS source=synthetic marker=normal pvb=completed bytes>0'
    ;;
  attack)
    remote_kubectl -n velero get backup "${backup_name}" >/dev/null 2>&1 \
      || fail 'known normal Backup is absent'
    assert_normal "${source_namespace}"
    old_uid=$(remote_kubectl -n "${source_namespace}" get deployment "${portal_deployment}" -o jsonpath='{.metadata.uid}')
    [[ -n ${old_uid} ]] || fail 'source Deployment UID is absent'
    write_source '{"marker":"DEMO-RECOVERY-01-CORRUPTED","record":"synthetic-only"}'
    assert_corrupt
    remote_kubectl -n "${source_namespace}" delete deployment "${portal_deployment}" --wait=true >/dev/null
    for _ in {1..48}; do
      if remote_kubectl -n "${source_namespace}" get deployment "${portal_deployment}" >/dev/null 2>&1; then
        if wait_deployment "${source_namespace}"; then
          break
        fi
      fi
      sleep 5
    done
    new_uid=$(remote_kubectl -n "${source_namespace}" get deployment "${portal_deployment}" -o jsonpath='{.metadata.uid}')
    [[ -n ${new_uid} && ${new_uid} != "${old_uid}" ]] || fail 'Argo self-heal did not recreate the Deployment'
    assert_corrupt
    echo 'DEMO_RECOVERY_SELFHEAL=PASS deployment_uid_changed=true data_state=corrupt'
    ;;
  restore)
    remote_kubectl -n velero get backup "${backup_name}" >/dev/null 2>&1 \
      || fail 'known normal Backup is absent'
    remote_kubectl -n velero get restore "${restore_name}" >/dev/null 2>&1 \
      && fail 'task-owned Restore already exists; run reset first'
    remote_kubectl get namespace "${restore_namespace}" >/dev/null 2>&1 \
      && fail 'task-owned isolation namespace already exists; run reset first'
    assert_corrupt
    started=$(date +%s)
    remote_kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${restore_namespace}
  labels:
    app.kubernetes.io/part-of: demo-recovery-01
    demo-recovery-01.imcherry5778.xyz/transient: "true"
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
YAML
    remote_kubectl -n "${restore_namespace}" apply -f - <<YAML >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-recovery-data
  labels:
    app.kubernetes.io/part-of: demo-recovery-01
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 512Mi
YAML
    remote_kubectl -n velero apply -f - <<YAML >/dev/null
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${restore_name}
  namespace: velero
  labels:
    app.kubernetes.io/part-of: demo-recovery-01
spec:
  backupName: ${backup_name}
  includedNamespaces:
    - ${source_namespace}
  includedResources:
    - configmaps
    - deployments
    - persistentvolumeclaims
    - persistentvolumes
    - pods
    - serviceaccounts
    - services
  namespaceMapping:
    ${source_namespace}: ${restore_namespace}
  restorePVs: false
YAML
    wait_restore
    wait_deployment "${restore_namespace}"
    assert_normal "${restore_namespace}"
    elapsed=$(( $(date +%s) - started ))
    echo "DEMO_RECOVERY_RESTORE=PASS restore=completed pvr=completed marker_hash=match service=200 rto_seconds=${elapsed}"
    ;;
  reset)
    if remote_kubectl -n "${source_namespace}" get deployment "${portal_deployment}" >/dev/null 2>&1; then
      wait_deployment "${source_namespace}"
      write_source '{"marker":"DEMO-RECOVERY-01-NORMAL","record":"synthetic-only"}'
      assert_normal "${source_namespace}"
    fi
    cleanup
    echo 'DEMO_RECOVERY_RESET=PASS backup=absent restore=absent pvb=absent pvr=absent namespace=absent source=normal'
    ;;
esac
