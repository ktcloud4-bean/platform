#!/usr/bin/env bash
# AWX-04-FIX-04를 immutable Argo SHA에서 판정하고 literal main으로 복구한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly main_revision=${AWX04_PULL_MAIN_REVISION:?시작 main SHA가 필요하다}
readonly config_revision=${AWX04_PULL_CONFIG_REVISION:?AWX 설정 commit SHA가 필요하다}
readonly root_revision=${AWX04_PULL_ROOT_REVISION:?immutable root pointer SHA가 필요하다}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'AWX-04-FIX-04 적용 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
for revision in "${main_revision}" "${config_revision}" "${root_revision}"; do
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || {
    echo 'AWX-04-FIX-04 적용 실패 단계=preflight 원인=immutable SHA 형식이 아니다.' >&2
    exit 1
  }
done

exec 9>/tmp/ktcloud4-bean-argo-root.lock
flock -n 9 || {
  echo 'AWX-04-FIX-04 적용 실패 단계=lock 원인=다른 ARGO-ROOT 작업이 실행 중이다.' >&2
  exit 1
}

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

patch_root_revision() {
  local revision=$1
  ssh "${ssh_options[@]}" "${k3s_host}" bash -s -- "${revision}" <<'REMOTE'
set -Eeuo pipefail
revision=$1
sudo -n /usr/local/bin/k3s kubectl -n argocd patch applications.argoproj.io platform-root --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"${revision}\"}}}"
REMOTE
}

app_state_matches() {
  local root_target=$1 root_sync=$2 awx_target=$3 awx_sync=$4
  remote_kubectl -n argocd get applications.argoproj.io platform-root awx -o json | jq -e \
    --arg root_target "${root_target}" --arg root_sync "${root_sync}" \
    --arg awx_target "${awx_target}" --arg awx_sync "${awx_sync}" '
      . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
      (app("platform-root") | .spec.source.targetRevision == $root_target and .status.sync.revision == $root_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded" and .status.operationState.operation.sync.revision == $root_sync) and
      (app("awx") | .spec.source.targetRevision == $awx_target and .status.sync.revision == $awx_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded" and .status.operationState.operation.sync.revision == $awx_sync)
    ' >/dev/null
}

starting_state_matches() {
  local awx_cr
  remote_kubectl -n argocd get applications.argoproj.io platform-root awx -o json | jq -e \
    --arg main "${main_revision}" '
      . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
      (app("platform-root") | .spec.source.targetRevision == "main" and .status.sync.revision == $main and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded" and .status.operationState.operation.sync.revision == $main) and
      (app("awx") | .spec.source.targetRevision == "main" and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded" and (.status.sync.revision | test("^[0-9a-f]{40}$")))
    ' >/dev/null
  awx_cr=$(remote_kubectl -n awx get awx.awx.ansible.com awx -o json)
  jq -e '.spec.ee_pull_credentials_secret == "awx-ee-pull" and .spec.image_pull_secrets == null' <<<"${awx_cr}" >/dev/null
  ! remote_kubectl -n awx get secret awx-ee-pull-credentials >/dev/null 2>&1
}

wait_for_app_state() {
  local root_target=$1 root_sync=$2 awx_target=$3 awx_sync=$4 label=$5
  for _ in $(seq 1 72); do
    if app_state_matches "${root_target}" "${root_sync}" "${awx_target}" "${awx_sync}" 2>/dev/null; then
      printf 'AWX04_PULL_ARGO=PASS state=%s\n' "${label}"
      return 0
    fi
    sleep 5
  done
  printf 'AWX-04-FIX-04 적용 실패 단계=argo 원인=%s 상태가 Synced/Healthy/Succeeded가 아니다.\n' "${label}" >&2
  return 1
}

runtime_state_matches() {
  local awx_cr secrets instance_group
  awx_cr=$(remote_kubectl -n awx get awx.awx.ansible.com awx -o json)
  jq -e '
    .spec.ee_pull_credentials_secret == "awx-ee-pull-credentials" and
    .spec.image_pull_secrets == ["awx-ee-pull"]
  ' <<<"${awx_cr}" >/dev/null

  secrets=$(remote_kubectl -n awx get secret awx-ee-pull awx-ee-pull-credentials -o json)
  jq -e '
    def secret($name): .items[] | select(.metadata.name == $name);
    (secret("awx-ee-pull") | .type == "kubernetes.io/dockerconfigjson" and (.data | keys) == [".dockerconfigjson"]) and
    (secret("awx-ee-pull-credentials") | .type == "Opaque" and (.data | keys) == ["password", "ssl_verify", "url", "username"])
  ' <<<"${secrets}" >/dev/null

  instance_group=$(remote_kubectl -n awx exec -i deploy/awx-web -c awx-web -- awx-manage shell <<'PY'
import json
from awx.main.models import InstanceGroup

group = InstanceGroup.objects.get(name="default")
override = group.pod_spec_override
if isinstance(override, str):
    override = json.loads(override)
print(json.dumps({"override": override}, sort_keys=True))
PY
)
  instance_group=$(tail -n 1 <<<"${instance_group}")
  jq -e '
    .override.spec.imagePullSecrets == [{"name":"awx-ee-pull"}] and
    .override.spec.securityContext == {
      "runAsNonRoot":true,
      "runAsUser":1000,
      "runAsGroup":0,
      "fsGroup":1000,
      "fsGroupChangePolicy":"OnRootMismatch",
      "seccompProfile":{"type":"RuntimeDefault"}
    }
  ' <<<"${instance_group}" >/dev/null
}

wait_for_runtime_state() {
  for _ in $(seq 1 72); do
    if runtime_state_matches 2>/dev/null; then
      echo 'AWX04_PULL_RUNTIME=PASS secrets=types-and-keys cr=references instance_group=default'
      return 0
    fi
    sleep 5
  done
  echo 'AWX-04-FIX-04 적용 실패 단계=runtime 원인=Secret/CR/default Instance Group 선언이 수렴하지 않았다.' >&2
  return 1
}

remove_test_secret() {
  local awx_cr
  awx_cr=$(remote_kubectl -n awx get awx.awx.ansible.com awx -o json)
  jq -e '.spec.ee_pull_credentials_secret == "awx-ee-pull" and .spec.image_pull_secrets == null' <<<"${awx_cr}" >/dev/null
  remote_kubectl -n awx delete secret awx-ee-pull-credentials --ignore-not-found >/dev/null
  if remote_kubectl -n awx get secret awx-ee-pull-credentials >/dev/null 2>&1; then
    echo 'AWX-04-FIX-04 적용 실패 단계=rollback 원인=검증용 EE credential Secret이 남아 있다.' >&2
    return 1
  fi
  echo 'AWX04_PULL_ROLLBACK_SECRET=PASS deleted=awx-ee-pull-credentials'
}

root_patched=false
restore() {
  local status=$?
  trap - EXIT
  if [[ ${root_patched} == true ]]; then
    patch_root_revision main >/dev/null || status=1
    wait_for_app_state main "${main_revision}" main "${main_revision}" rollback || status=1
    remove_test_secret || status=1
  fi
  exit "${status}"
}
trap restore EXIT

starting_state_matches || {
  echo 'AWX-04-FIX-04 적용 실패 단계=preflight 원인=platform-root/AWX가 시작 main에서 Synced/Healthy가 아니다.' >&2
  exit 1
}

patch_root_revision "${root_revision}" >/dev/null
root_patched=true
wait_for_app_state "${root_revision}" "${root_revision}" "${config_revision}" "${config_revision}" immutable
wait_for_runtime_state

patch_root_revision main >/dev/null
wait_for_app_state main "${main_revision}" main "${main_revision}" rollback
remove_test_secret
root_patched=false
trap - EXIT
printf 'AWX04_PULL=PASS main=%s config=%s root=%s\n' \
  "${main_revision}" "${config_revision}" "${root_revision}"
