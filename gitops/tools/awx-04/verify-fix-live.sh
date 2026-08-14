#!/usr/bin/env bash
# AWX-04-FIX-01의 AppRole recovery와 main SCM sync만 판정한다.
set -Eeuo pipefail

mode=${1:-}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

recover_main() {
  ssh "${ssh_options[@]}" "${k3s_host}" bash -s <<'REMOTE' >/dev/null
set -Eeuo pipefail
sudo -n /usr/local/bin/k3s kubectl -n argocd patch applications.argoproj.io awx --type=merge \
  --subresource=status -p '{"status":{"operationState":{"phase":"Terminating"}}}'
REMOTE
  printf 'AWX04_FIX_OPERATION=TERMINATING target=main\n'
}

verify_main() {
  local main_revision=${AWX04_FIX_MAIN_REVISION:?latest main SHA가 필요하다}
  local min_update=${AWX04_FIX_MIN_PROJECT_UPDATE:?실패한 project update ID가 필요하다}
  [[ ${main_revision} =~ ^[0-9a-f]{40}$ && ${min_update} =~ ^[0-9]+$ ]]
  local argo state
  for _ in $(seq 1 72); do
    argo=$(remote_kubectl -n argocd get application platform-root awx -o json 2>/dev/null || true)
    if jq -e --arg main "${main_revision}" '
      . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
      (app("platform-root") | .spec.source.targetRevision == "main" and .status.sync.revision == $main and .status.sync.status == "Synced" and .status.health.status == "Healthy") and
      (app("awx") | .spec.source.targetRevision == "main" and .status.sync.revision == $main and .status.sync.status == "Synced" and .status.health.status == "Healthy")
    ' <<<"${argo}" >/dev/null; then break; fi
    sleep 5
  done
  jq -e --arg main "${main_revision}" '
    . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
    (app("platform-root") | .spec.source.targetRevision == "main" and .status.sync.revision == $main and .status.sync.status == "Synced" and .status.health.status == "Healthy") and
    (app("awx") | .spec.source.targetRevision == "main" and .status.sync.revision == $main and .status.sync.status == "Synced" and .status.health.status == "Healthy")
  ' <<<"${argo}" >/dev/null
  state=$(remote_kubectl -n awx exec -i deploy/awx-web -c awx-web -- awx-manage shell <<PY
import json
from awx.main.models import Organization, Project, ProjectUpdate
org = Organization.objects.get(name="Platform")
project = Project.objects.get(name="AWX-04 platform 운영 원본", organization=org)
update = ProjectUpdate.objects.filter(project=project, id__gt=${min_update}).order_by("-id").first()
print(json.dumps({"update": None if update is None else {"id": update.id, "status": update.status}, "scm_revision": project.scm_revision}, sort_keys=True))
PY
)
  state=$(tail -n 1 <<<"${state}")
  jq -e '.update != null and .update.status == "successful" and (.scm_revision | test("^[0-9a-f]{40}$"))' <<<"${state}" >/dev/null
  printf 'AWX04_FIX_LIVE=PASS main=%s project_update=%s scm_revision=present\n' "${main_revision}" "$(jq -r '.update.id' <<<"${state}")"
}

case ${mode} in
  recover-main) recover_main ;;
  verify-main) verify_main ;;
  *) echo "사용법: $0 recover-main|verify-main" >&2; exit 2 ;;
esac
