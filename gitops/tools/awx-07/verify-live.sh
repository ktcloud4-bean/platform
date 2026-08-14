#!/usr/bin/env bash
# AWX-07 완료 증거만 immutable Argo, fixed SCM/EE, 단일 승인 workflow와 관측 결과로 판정한다.
set -Eeuo pipefail

mode=${1:-}
readonly repo_root=$(git rev-parse --show-toplevel)
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly target_fqdn=netbird-01.imcherry5778.xyz
readonly platform_ee=harbor.imcherry5778.xyz/awx-ee/platform-ee@sha256:0a35dcb1933fd6439730dd2a57e325be1bd175852c29dd0e2894728b16137bb9
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

remote_kubectl() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }
remote_awx_shell() { remote_kubectl -n awx exec -i deploy/awx-web -c awx-web -- awx-manage shell; }

capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'EOF'
set -euo pipefail
awk "/MemAvailable:/ {printf \"guest_available_bytes=%d\\n\", \$2*1024}" /proc/meminfo
printf "swap_devices="; awk "NR>1 {n++} END {print n+0}" /proc/swaps
pvc=$(sudo -n /usr/local/bin/k3s kubectl -n awx get pvc -o json)
jq -r '"pvc_count=\(.items | length)"' <<<"${pvc}"
if ! jq -e '(.items | length) == 0' <<<"${pvc}" >/dev/null; then
  jq -rc '"pvc_objects=" + ([.items[] | {name:.metadata.name,phase:.status.phase,storage:.spec.resources.requests.storage,owner:.metadata.ownerReferences}] | tojson)' <<<"${pvc}"
fi
EOF
}

capacity_gate() {
  local cap=$1
  awk -F= '/^guest_available_bytes=/{exit !($2 >= 8589934592)}' <<<"${cap}" || { echo 'AWX-07 중지: guest available이 8 GiB 미만이다' >&2; return 1; }
  grep -qx 'swap_devices=0' <<<"${cap}" || { echo 'AWX-07 중지: swap이 0이 아니다' >&2; return 1; }
  grep -qx 'pvc_count=0' <<<"${cap}" || { printf 'AWX-07 중지: PVC가 생성됐다 %s\n' "$(tr '\n' ' ' <<<"${cap}")" >&2; return 1; }
}

verify_platform() {
  local root=${AWX07_EXPECTED_ROOT_REVISION:?root pointer commit SHA 필요}
  local child=${AWX07_EXPECTED_CHILD_REVISION:?AWX 설정 commit SHA 필요}
  local root_sync=${AWX07_EXPECTED_ROOT_SYNC_REVISION:-${root}}
  local child_sync=${AWX07_EXPECTED_CHILD_SYNC_REVISION:-${child}}
  local scm=${AWX07_EXPECTED_SCM_REVISION:?AWX-04 main SCM revision 필요}
  [[ ${root} =~ ^[0-9a-f]{40}$ && ${child} =~ ^[0-9a-f]{40}$ && ${root_sync} =~ ^[0-9a-f]{40}$ && ${child_sync} =~ ^[0-9a-f]{40}$ && ${scm} =~ ^[0-9a-f]{40}$ ]]

  local argo awx_cr state cap pvc
  argo=$(remote_kubectl -n argocd get application platform-root awx -o json)
  jq -e --arg root "${root}" --arg child "${child}" --arg root_sync "${root_sync}" --arg child_sync "${child_sync}" '
    . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
    (app("platform-root") | .spec.source.targetRevision == $root and .status.sync.revision == $root_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded") and
    (app("awx") | .spec.source.targetRevision == $child and .status.sync.revision == $child_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded")
  ' <<<"${argo}" >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-web --timeout=240s >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-task --timeout=240s >/dev/null
  pvc=$(remote_kubectl -n awx get pvc -o json)
  if ! jq -e '(.items | length) == 0' <<<"${pvc}" >/dev/null; then
    echo 'AWX-07 실패 단계=AWX namespace에 PVC가 생성됐다' >&2
    jq -c '[.items[] | {name:.metadata.name,phase:.status.phase,storage:.spec.resources.requests.storage,owner:.metadata.ownerReferences}]' <<<"${pvc}" >&2
    return 1
  fi
  awx_cr=$(remote_kubectl -n awx get awx.awx.ansible.com awx -o json)
  jq -e '
    [.spec.extra_settings[] | select(.setting == "DEFAULT_EXECUTION_QUEUE_POD_SPEC_OVERRIDE") | .value | ltrimstr("\u0027") | rtrimstr("\u0027") | fromjson] as $override |
    $override | length == 1 and
    ([.[0].spec.volumes[] | select(.name == "awx-ssh-marker-known-hosts" and .secret == {"secretName":"awx-ssh-marker-known-hosts","defaultMode":292})] | length == 1) and
    ([.[0].spec.containers[] | select(.name == "worker") | .volumeMounts[] | select(.name == "awx-ssh-marker-known-hosts" and .mountPath == "/etc/awx-ssh-marker" and .readOnly == true)] | length == 1)
  ' <<<"${awx_cr}" >/dev/null
  state=$(remote_awx_shell <<'PY'
import json
from awx.main.models import Credential, CredentialInputSource, Group, Host, Inventory, JobTemplate, Organization, Project, Team, WorkflowJobTemplate, WorkflowJobTemplateNode
org = Organization.objects.get(name="Platform")
project = Project.objects.get(name="AWX-04 platform 운영 원본", organization=org)
inventory = Inventory.objects.get(name="AWX-07 netbird-01 node exporter", organization=org)
host = Host.objects.get(name="netbird-01.imcherry5778.xyz", inventory=inventory)
group = Group.objects.get(name="node_exporter_fleet", inventory=inventory)
lookup = Credential.objects.get(name="AWX-07 Vault Machine lookup", organization=org)
credential = Credential.objects.get(name="AWX-07 netbird-01 node exporter", organization=org)
source = CredentialInputSource.objects.get(target_credential=credential, input_field_name="ssh_key_data")
templates = {item.name:item for item in JobTemplate.objects.filter(name__startswith="AWX-07 netbird node exporter", organization=org)}
workflow = WorkflowJobTemplate.objects.get(name="AWX-07 netbird node exporter 승인", organization=org)
operators = Team.objects.get(name="AWX Operators", organization=org)
approvers = Team.objects.get(name="AWX Approvers", organization=org)
ask = ("ask_limit_on_launch","ask_inventory_on_launch","ask_credential_on_launch","ask_job_type_on_launch","ask_scm_branch_on_launch","ask_variables_on_launch","ask_execution_environment_on_launch","ask_forks_on_launch","ask_job_slice_count_on_launch")
def role(team, obj, name): return team.role_assignments.filter(object_id=str(obj.id),role_definition__name=name).exists()
print(json.dumps({
 "project":[project.scm_branch,project.scm_revision,project.scm_clean,project.scm_delete_on_update,project.scm_update_on_launch,project.allow_override],
 "inventory":[inventory.hosts.count(),inventory.variables,sorted(group.hosts.values_list("name",flat=True))],"host":host.variables,
 "lookup":[lookup.credential_type.name,sorted(lookup.inputs.keys())],"credential":[credential.credential_type.name,sorted(credential.inputs.keys())],"source":source.metadata,
 "templates":{n:[t.project.name,t.playbook,t.job_type,t.limit,t.become_enabled,t.forks,t.job_slice_count,t.allow_simultaneous,[getattr(t,k) for k in ask],sorted(t.credentials.values_list("id",flat=True)),t.execution_environment.image] for n,t in templates.items()},
 "nodes":sorted(WorkflowJobTemplateNode.objects.filter(workflow_job_template=workflow).values_list("identifier",flat=True)),
 "roles":[role(operators,templates["AWX-07 netbird node exporter check"],"JobTemplate Execute"),role(operators,workflow,"WorkflowJobTemplate Execute"),role(operators,templates["AWX-07 netbird node exporter apply"],"JobTemplate Execute"),role(operators,workflow,"WorkflowJobTemplate Approve"),role(approvers,workflow,"WorkflowJobTemplate Approve"),role(approvers,templates["AWX-07 netbird node exporter check"],"JobTemplate Execute")],
},sort_keys=True))
PY
)
  state=$(tail -n1 <<<"${state}")
  if ! jq -e --arg scm "${scm}" --arg ee "${platform_ee}" '
    .project == ["main",$scm,true,true,false,false] and .inventory[0] == 1 and (.inventory[1]|fromjson|.ansible_become == true and .awx07_single_target == true) and .inventory[2] == ["netbird-01.imcherry5778.xyz"] and
    (.host|fromjson|.ansible_become == true and .node_exporter_listen_address == "10.10.40.10" and (.ansible_ssh_common_args|contains("StrictHostKeyChecking=yes")) and (.ansible_ssh_common_args|contains("/etc/awx-ssh-marker/known_hosts"))) and
    .lookup == ["HashiCorp Vault Secret Lookup",["api_version","cacert","default_auth_path","role_id","secret_id","url"]] and .credential == ["Machine",["username"]] and .source == {"auth_path":"approle","secret_backend":"kv","secret_key":"ssh_private_key","secret_path":"awx/ssh-node-exporter"} and
    (.templates|keys|sort) == ["AWX-07 netbird node exporter apply","AWX-07 netbird node exporter check","AWX-07 netbird node exporter idempotency"] and
    (.templates[] | .[0] == "AWX-04 platform 운영 원본" and .[1] == "infra/ansible/playbooks/node-exporter-baseline.yml" and .[3] == "netbird-01.imcherry5778.xyz" and .[4] == true and .[5] == 1 and .[6] == 1 and .[7] == false and (.[8]|all(. == false)) and (.[9]|length == 1) and .[10] == $ee) and
    .templates["AWX-07 netbird node exporter check"][2] == "check" and .templates["AWX-07 netbird node exporter apply"][2] == "run" and .templates["AWX-07 netbird node exporter idempotency"][2] == "check" and
    .nodes == ["approved-node-exporter-apply","human-approval","node-exporter-check","node-exporter-idempotency"] and .roles == [true,true,false,false,true,false]
  ' <<<"${state}" >/dev/null; then
    echo 'AWX-07 실패 단계=AWX-07 선언 객체 또는 최소권한 역할이 기대값과 다르다' >&2
    jq -c '{project,inventory,lookup,credential,source,templates,nodes,roles}' <<<"${state}" >&2
    return 1
  fi
  cap=$(capacity); capacity_gate "${cap}"
  printf 'AWX07_PLATFORM=PASS root=%s child=%s scm=%s inventory=1 limit=netbird-01 forks=1 workflow=approval-gated pvc=0 %s\n' "${root}" "${child}" "${scm}" "$(tr '\n' ' ' <<<"${cap}")"
}

job_stdout() {
  local job_id=$1
  remote_awx_shell <<PY
from awx.main.models import UnifiedJob
job = UnifiedJob.objects.get(pk=${job_id})
print(''.join(event.stdout for event in job.get_event_queryset().order_by('counter')))
PY
}

verify_jobs() {
  local workflow_id=${AWX07_WORKFLOW_ID:?승인 완료 workflow job ID 필요}
  local check_job_id=${AWX07_CHECK_JOB_ID:?operator check job ID 필요}
  local scm=${AWX07_EXPECTED_SCM_REVISION:?AWX-04 main SCM revision 필요}
  [[ ${workflow_id} =~ ^[0-9]+$ && ${check_job_id} =~ ^[0-9]+$ && ${scm} =~ ^[0-9a-f]{40}$ ]]
  [[ -r ${root_token_file} && ! -L ${root_token_file} && $(stat -c %a "${root_token_file}") == 600 ]] || { echo 'Vault root token 입력이 없거나 mode 0600이 아니다' >&2; exit 1; }
  local state cap temp_dir job_id
  state=$(remote_awx_shell <<PY
import json,re
from awx.main.models import Job,WorkflowJob,WorkflowJobNode
workflow=WorkflowJob.objects.get(pk=${workflow_id}); check=Job.objects.get(pk=${check_job_id})
nodes={n.identifier:n.job for n in WorkflowJobNode.objects.filter(workflow_job=workflow)}
def state(job):
 stdout=''.join(e.stdout for e in job.get_event_queryset().order_by('counter'))
 stdout=re.sub(r'\x1b\[[0-9;]*m','',stdout)
 recap=re.search(r'netbird-01\\.imcherry5778\\.xyz\\s*:\\s*ok=\\d+\\s+changed=(\\d+)\\s+unreachable=0\\s+failed=0',stdout)
 return [job.id,job.job_template.name,job.status,getattr(job.created_by,'username',None),job.limit,job.inventory.name,job.scm_revision,int(recap.group(1)) if recap else None]
approval=nodes['human-approval']
print(json.dumps({"workflow":[workflow.status,getattr(workflow.created_by,'username',None)],"approval":[approval.status,getattr(approval.approved_or_denied_by,'username',None),approval.timed_out],"check":state(check),"nodes":{n:state(nodes[n]) for n in ["node-exporter-check","approved-node-exporter-apply","node-exporter-idempotency"]}},sort_keys=True))
PY
)
  state=$(tail -n1 <<<"${state}")
  jq -e --arg scm "${scm}" '
    .workflow == ["successful","imcherry5778"] and .approval == ["successful","imcherry5778-admin",false] and
    (.check | .[1] == "AWX-07 netbird node exporter check" and .[2] == "successful" and .[3] == "imcherry5778" and .[4] == "netbird-01.imcherry5778.xyz" and .[5] == "AWX-07 netbird-01 node exporter" and .[6] == $scm and .[7] == 0) and
    (.nodes|keys|sort) == ["approved-node-exporter-apply","node-exporter-check","node-exporter-idempotency"] and
    (.nodes[] | .[2] == "successful" and .[3] == "imcherry5778" and .[4] == "netbird-01.imcherry5778.xyz" and .[5] == "AWX-07 netbird-01 node exporter" and .[6] == $scm) and
    .nodes["node-exporter-check"][1] == "AWX-07 netbird node exporter check" and .nodes["node-exporter-check"][7] == 0 and
    .nodes["approved-node-exporter-apply"][1] == "AWX-07 netbird node exporter apply" and
    .nodes["node-exporter-idempotency"][1] == "AWX-07 netbird node exporter idempotency" and .nodes["node-exporter-idempotency"][7] == 0
  ' <<<"${state}" >/dev/null
  temp_dir=$(mktemp -d); trap 'rm -rf "${temp_dir}"' RETURN
  { tr -d '\n' <"${root_token_file}"; printf '\n'; } | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'set -eu; read -r VAULT_TOKEN; export VAULT_TOKEN; vault kv get -field=ssh_private_key kv/awx/ssh-node-exporter'" >"${temp_dir}/private-key"
  awk 'length($0) >= 20' "${temp_dir}/private-key" >"${temp_dir}/patterns"
  for job_id in "${check_job_id}" $(jq -r '.nodes[] | .[0]' <<<"${state}"); do job_stdout "${job_id}" >>"${temp_dir}/jobs.out"; done
  ! grep -F -f "${temp_dir}/patterns" "${temp_dir}/jobs.out" >/dev/null 2>&1 || { echo 'AWX-07 job stdout에서 private key 원문을 찾았다.' >&2; return 1; }
  [[ $(ssh "${ssh_options[@]}" "rocky@${target_fqdn}" 'systemctl is-enabled node_exporter.service; systemctl is-active node_exporter.service') == $'enabled\nactive' ]]
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'EOF' | jq -e '.data.result | length == 1 and .[0].value[1] == "1"' >/dev/null
set -euo pipefail
svc=$(sudo -n /usr/local/bin/k3s kubectl -n obs get svc obs-prometheus -o jsonpath='{.spec.clusterIP}')
curl -fsS --get "http://${svc}:9090/api/v1/query" --data-urlencode 'query=up{job="node-exporter",instance="10.10.40.10:9100"}'
EOF
  cap=$(capacity); capacity_gate "${cap}"
  printf 'AWX07_JOBS=PASS workflow=%s check=%s approver=imcherry5778-admin target=netbird-01 scm=%s changed=0 node_exporter=enabled-active prometheus_up=1 secret_stdout=0 %s\n' "${workflow_id}" "${check_job_id}" "${scm}" "$(tr '\n' ' ' <<<"${cap}")"
}

verify_browser_rbac() {
  local kc_dir=${secret_root}/keycloak
  local temp_dir objects_file
  for required in "${kc_dir}/daily-password" "${kc_dir}/daily-totp" "${kc_dir}/privileged-password" "${kc_dir}/privileged-totp"; do
    [[ -s ${required} && $(stat -c %a "${required}") == 600 ]] || { echo "필수 외부 MFA 입력이 없거나 mode 0600이 아니다: ${required}" >&2; return 1; }
  done
  temp_dir=$(mktemp -d); trap 'rm -rf "${temp_dir}"' RETURN
  objects_file=${temp_dir}/objects.json
  remote_awx_shell <<'PY' | tail -n1 >"${objects_file}"
import json
from awx.main.models import Credential, JobTemplate, Organization, WorkflowApproval, WorkflowJobTemplate
org = Organization.objects.get(name="Platform")
workflow = WorkflowJobTemplate.objects.get(name="AWX-07 netbird node exporter 승인", organization=org)
approval = WorkflowApproval.objects.filter(unified_job_node__workflow_job__unified_job_template=workflow, status="pending").order_by("-id").first()
if approval is None:
    raise RuntimeError("AWX-07 pending approval이 없다")
print(json.dumps({
 "check": JobTemplate.objects.get(name="AWX-07 netbird node exporter check", organization=org).id,
 "apply": JobTemplate.objects.get(name="AWX-07 netbird node exporter apply", organization=org).id,
 "credential": Credential.objects.get(name="AWX-07 netbird-01 node exporter", organization=org).id,
 "workflow": workflow.id, "approval": approval.id,
}, sort_keys=True))
PY
  node "${repo_root}/gitops/tools/awx-07/browser-rbac.js" \
    --connect-ip "${AWX07_CONNECT_IP:-10.10.20.10}" \
    --daily-username imcherry5778 --privileged-username imcherry5778-admin \
    --daily-password-file "${kc_dir}/daily-password" --daily-totp-file "${kc_dir}/daily-totp" \
    --privileged-password-file "${kc_dir}/privileged-password" --privileged-totp-file "${kc_dir}/privileged-totp" \
    --object-file "${objects_file}"
}

case ${mode} in
  platform) verify_platform ;;
  jobs) verify_jobs ;;
  browser-rbac) verify_browser_rbac ;;
  *) echo "사용법: $0 platform|jobs|browser-rbac" >&2; exit 2 ;;
esac
