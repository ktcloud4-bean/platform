#!/usr/bin/env bash
# AWX-04 완료 증거만 immutable Argo 상태, SCM 원본, EE와 실제 OIDC RBAC로 판정한다.
# shellcheck disable=SC2029
set -Eeuo pipefail

mode=${1:-}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly repo_root=$(git rev-parse --show-toplevel)
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

verify_platform() {
  local expected_root=${AWX04_EXPECTED_ROOT_REVISION:?root pointer 참조가 필요하다}
  local expected_child=${AWX04_EXPECTED_CHILD_REVISION:?AWX 설정 참조가 필요하다}
  local expected_root_sync=${AWX04_EXPECTED_ROOT_SYNC_REVISION:-${expected_root}}
  local expected_child_sync=${AWX04_EXPECTED_CHILD_SYNC_REVISION:-${expected_child}}
  local expected_scm=${AWX04_EXPECTED_SCM_REVISION:?Gitea main SHA가 필요하다}
  local expected_ee_digest=${AWX04_EXPECTED_EE_DIGEST:?Harbor EE digest가 필요하다}
  [[ ${expected_root} =~ ^(main|[0-9a-f]{40})$ && ${expected_child} =~ ^(main|[0-9a-f]{40})$ && ${expected_root_sync} =~ ^[0-9a-f]{40}$ && ${expected_child_sync} =~ ^[0-9a-f]{40}$ && ${expected_scm} =~ ^[0-9a-f]{40}$ ]]
  [[ ${expected_ee_digest} =~ ^sha256:[0-9a-f]{64}$ ]]

  local argo awx_cr pvc state
  argo=$(remote_kubectl -n argocd get application platform-root awx jenkins -o json)
  jq -e --arg root "${expected_root}" --arg child "${expected_child}" --arg root_sync "${expected_root_sync}" --arg child_sync "${expected_child_sync}" '
    . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
    (app("platform-root") | .spec.source.targetRevision == $root and .status.sync.revision == $root_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy") and
    (["awx", "jenkins"] | all(. as $name | (app($name) | .spec.source.targetRevision == $child and .status.sync.revision == $child_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy")))
  ' <<<"${argo}" >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-web --timeout=240s >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-task --timeout=240s >/dev/null
  awx_cr=$(remote_kubectl -n awx get awx awx -o json)
  jq -e '.spec.projects_persistence == false' <<<"${awx_cr}" >/dev/null
  pvc=$(remote_kubectl -n awx get pvc -o json)
  jq -e '(.items | length) == 0' <<<"${pvc}" >/dev/null

  state=$(remote_kubectl -n awx exec -i deploy/awx-web -c awx-web -- awx-manage shell <<'PY'
import json
from awx.main.models import Credential, CredentialInputSource, ExecutionEnvironment, Job, JobTemplate, Organization, Project

org = Organization.objects.get(name="Platform")
project = Project.objects.get(name="AWX-04 platform 운영 원본", organization=org)
template = JobTemplate.objects.get(name="AWX-04 운영 원본 정보", organization=org)
credential = Credential.objects.get(name="AWX-04 platform mirror read-only", organization=org)
lookup = Credential.objects.get(name="AWX-04 Vault SCM lookup", organization=org)
source = CredentialInputSource.objects.get(target_credential=credential, input_field_name="ssh_key_data")
ee = ExecutionEnvironment.objects.get(name="AWX-04 platform EE")
print(json.dumps({
  "project": {"scm_revision": project.scm_revision, "scm_type": project.scm_type, "scm_branch": project.scm_branch,
              "scm_clean": project.scm_clean, "scm_delete_on_update": project.scm_delete_on_update,
              "scm_update_on_launch": project.scm_update_on_launch, "allow_override": project.allow_override,
              "credential": project.credential_id},
  "template": {"project": template.project_id, "job_type": template.job_type, "execution_environment": template.execution_environment_id, "ask_scm_branch_on_launch": template.ask_scm_branch_on_launch},
  "credential": {"id": credential.id, "input_keys": sorted(credential.inputs.keys())},
  "input_source": {"source_credential": source.source_credential_id, "input_field": source.input_field_name, "metadata": source.metadata},
  "lookup": {"id": lookup.id, "type": lookup.credential_type.name},
  "ee": {"id": ee.id, "image": ee.image},
  "operational_jobs": Job.objects.filter(job_template=template).count(),
}, sort_keys=True))
PY
)
  state=$(tail -n 1 <<<"${state}")
  jq -e --arg scm "${expected_scm}" --arg digest "${expected_ee_digest}" '
    .project.scm_revision == $scm and .project.scm_type == "git" and .project.scm_branch == "main" and
    .project.scm_clean == true and .project.scm_delete_on_update == true and .project.scm_update_on_launch == false and .project.allow_override == false and
    .template.project != null and .template.job_type == "check" and .template.execution_environment == .ee.id and .template.ask_scm_branch_on_launch == false and
    .credential.input_keys == ["username"] and .input_source.input_field == "ssh_key_data" and
    .input_source.metadata == {"auth_path":"approle", "secret_backend":"kv", "secret_key":"gitea_deploy_key", "secret_path":"awx/scm"} and
    .lookup.type == "HashiCorp Vault Secret Lookup" and
    (.ee.image | endswith("@" + $digest)) and .operational_jobs == 0
  ' <<<"${state}" >/dev/null

  printf 'AWX04_PLATFORM=PASS root=%s root_sync=%s child=%s child_sync=%s scm=%s ee=%s projects_persistence=false pvc=0 operational_jobs=0\n' \
    "${expected_root}" "${expected_root_sync}" "${expected_child}" "${expected_child_sync}" "${expected_scm}" "${expected_ee_digest}"
}

verify_browser_rbac() {
  local object_file state
  object_file=$(mktemp)
  trap 'find "${object_file}" -type f -delete' RETURN
  state=$(remote_kubectl -n awx exec -i deploy/awx-web -c awx-web -- awx-manage shell <<'PY'
import json
from awx.main.models import Credential, ExecutionEnvironment, JobTemplate, Organization, Project
org = Organization.objects.get(name="Platform")
print(json.dumps({
  "project": Project.objects.get(name="AWX-04 platform 운영 원본", organization=org).id,
  "template": JobTemplate.objects.get(name="AWX-04 운영 원본 정보", organization=org).id,
  "credential": Credential.objects.get(name="AWX-04 platform mirror read-only", organization=org).id,
  "execution_environment": ExecutionEnvironment.objects.get(name="AWX-04 platform EE").id,
}, sort_keys=True))
PY
)
  tail -n 1 <<<"${state}" >"${object_file}"
  node "${repo_root}/gitops/tools/awx-04/browser-rbac.js" \
    --connect-ip "${AWX04_CONNECT_IP:-10.10.20.10}" --username imcherry5778 \
    --password-file "${secret_root}/keycloak/daily-password" --totp-file "${secret_root}/keycloak/daily-totp" \
    --object-file "${object_file}"
}

case ${mode} in
  platform) verify_platform ;;
  browser-rbac) verify_browser_rbac ;;
  *) echo "사용법: $0 platform|browser-rbac" >&2; exit 2 ;;
esac
