#!/usr/bin/env bash
# AWX-06 완료 증거: immutable Argo, exact cross-VLAN egress, Vault external lookup과 승인 workflow 선언만 판정한다.
set -Eeuo pipefail

mode=${1:-}
readonly repo_root=$(git rev-parse --show-toplevel)
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly target_fqdn=netbird-01.imcherry5778.xyz
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly platform_ee=harbor.imcherry5778.xyz/awx-ee/platform-ee@sha256:0a35dcb1933fd6439730dd2a57e325be1bd175852c29dd0e2894728b16137bb9
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

remote_kubectl() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }
remote_awx_shell() { remote_kubectl -n awx exec -i deploy/awx-web -c awx-web -- awx-manage shell; }
capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'awk "/MemAvailable:/ {printf \"guest_available_bytes=%d\\n\", \$2*1024}" /proc/meminfo; printf "swap_devices="; awk "NR>1 {n++} END {print n+0}" /proc/swaps'
}
verify_platform() {
  local root=${AWX06_EXPECTED_ROOT_REVISION:?root targetRevision 필요}
  local child=${AWX06_EXPECTED_CHILD_REVISION:?AWX targetRevision 필요}
  local root_sync=${AWX06_EXPECTED_ROOT_SYNC_REVISION:-${root}}
  local child_sync=${AWX06_EXPECTED_CHILD_SYNC_REVISION:-${child}}
  [[ ${root} =~ ^(main|[0-9a-f]{40})$ && ${child} =~ ^(main|[0-9a-f]{40})$ && ${root_sync} =~ ^[0-9a-f]{40}$ && ${child_sync} =~ ^[0-9a-f]{40}$ ]]

  local argo awx_cr network secret pvc state cap
  argo=$(remote_kubectl -n argocd get application platform-root awx -o json)
  jq -e --arg root "${root}" --arg child "${child}" --arg root_sync "${root_sync}" --arg child_sync "${child_sync}" '
    . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
    (app("platform-root") | .spec.source.targetRevision == $root and .status.sync.revision == $root_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded") and
    (app("awx") | .spec.source.targetRevision == $child and .status.sync.revision == $child_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded")' <<<"${argo}" >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-web --timeout=240s >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-task --timeout=240s >/dev/null
  awx_cr=$(remote_kubectl -n awx get awx.awx.ansible.com awx -o json)
  jq -e '
    [.spec.extra_settings[] | select(.setting == "DEFAULT_EXECUTION_QUEUE_POD_SPEC_OVERRIDE") | .value | ltrimstr("\u0027") | rtrimstr("\u0027") | fromjson] as $o |
    $o | length == 1 and
    ([.[0].spec.volumes[] | select(.name == "awx-ssh-marker-known-hosts" and .secret == {"secretName":"awx-ssh-marker-known-hosts","defaultMode":292})] | length == 1) and
    ([.[0].spec.containers[] | select(.name == "worker") | .volumeMounts[] | select(.name == "awx-ssh-marker-known-hosts" and .mountPath == "/etc/awx-ssh-marker" and .readOnly == true)] | length == 1)
  ' <<<"${awx_cr}" >/dev/null
  network=$(remote_kubectl -n awx get networkpolicy awx-execution-netbird-marker-ssh-egress -o json)
  jq -e '.spec.podSelector.matchExpressions == [{"key":"ansible-awx","operator":"Exists"}] and .spec.policyTypes == ["Egress"] and .spec.egress == [{"to":[{"ipBlock":{"cidr":"10.10.40.10/32"}}],"ports":[{"protocol":"TCP","port":22}]}]' <<<"${network}" >/dev/null
  secret=$(remote_kubectl -n awx get secret awx-ssh-marker-known-hosts -o json)
  jq -e '.type == "Opaque" and (.data | keys) == ["known_hosts"]' <<<"${secret}" >/dev/null
  pvc=$(remote_kubectl -n awx get pvc -o json); jq -e '(.items | length) == 0' <<<"${pvc}" >/dev/null
  state=$(remote_awx_shell <<'PY'
import json
from awx.main.models import Credential, CredentialInputSource, Host, Inventory, JobTemplate, Organization, Team, WorkflowJobTemplate, WorkflowJobTemplateNode
org = Organization.objects.get(name="Platform")
inventory = Inventory.objects.get(name="AWX-06 netbird-01 marker", organization=org)
host = Host.objects.get(name="netbird-01.imcherry5778.xyz", inventory=inventory)
lookup = Credential.objects.get(name="AWX-06 Vault Machine lookup", organization=org)
credential = Credential.objects.get(name="AWX-06 netbird-01 marker", organization=org)
source = CredentialInputSource.objects.get(target_credential=credential, input_field_name="ssh_key_data")
templates = {x.name: x for x in JobTemplate.objects.filter(name__startswith="AWX-06 netbird marker", organization=org)}
workflow = WorkflowJobTemplate.objects.get(name="AWX-06 netbird marker 승인", organization=org)
nodes = {x.identifier: x for x in WorkflowJobTemplateNode.objects.filter(workflow_job_template=workflow)}
operators = Team.objects.get(name="AWX Operators", organization=org)
approvers = Team.objects.get(name="AWX Approvers", organization=org)
print(json.dumps({
 "inventory": {"hosts": inventory.hosts.count(), "variables": inventory.variables},
 "host": host.variables,
 "lookup": {"type":lookup.credential_type.name,"input_keys":sorted(lookup.inputs.keys())},
 "credential": {"type":credential.credential_type.name,"input_keys":sorted(credential.inputs.keys())},
 "source": source.metadata,
 "templates": {n: {"playbook": t.playbook, "job_type":t.job_type, "limit":t.limit, "become":t.become_enabled, "forks":t.forks, "asks":[getattr(t,k) for k in ("ask_limit_on_launch","ask_inventory_on_launch","ask_credential_on_launch","ask_job_type_on_launch","ask_scm_branch_on_launch","ask_variables_on_launch")], "credentials":sorted(t.credentials.values_list("id",flat=True))} for n,t in templates.items()},
 "workflow_nodes": sorted(nodes),
 "operator_roles": sorted(operators.role_assignments.values_list("object_role_id", flat=True)),
 "approver_roles": sorted(approvers.role_assignments.values_list("object_role_id", flat=True)),
 "marker_roles": {
   "operator_execute": operators.role_assignments.filter(object_id=str(workflow.id), role_definition__name="WorkflowJobTemplate Execute").exists(),
   "approver_only": approvers.role_assignments.filter(object_id=str(workflow.id), role_definition__name="WorkflowJobTemplate Approve").exists(),
   "operator_approval": operators.role_assignments.filter(object_id=str(workflow.id), role_definition__name="WorkflowJobTemplate Approve").exists(),
 },
}, sort_keys=True))
PY
)
  state=$(tail -n1 <<<"${state}")
  jq -e --arg ee "${platform_ee}" '
    .inventory.hosts == 1 and (.inventory.variables|fromjson|.ansible_become == false and .awx06_single_target == true) and
    (.host|fromjson|.ansible_become == false and (.ansible_ssh_common_args|contains("StrictHostKeyChecking=yes")) and (.ansible_ssh_common_args|contains("/etc/awx-ssh-marker/known_hosts"))) and
    .lookup.type == "HashiCorp Vault Secret Lookup" and .lookup.input_keys == ["api_version","cacert","default_auth_path","role_id","secret_id","url"] and
    .credential.type == "Machine" and .credential.input_keys == ["username"] and
    .source == {"auth_path":"approle","secret_backend":"kv","secret_key":"ssh_private_key","secret_path":"awx/ssh-marker"} and
    (.templates|keys|sort) == ["AWX-06 netbird marker apply","AWX-06 netbird marker cleanup","AWX-06 netbird marker idempotency","AWX-06 netbird marker precheck"] and
    (.templates[] | .limit == "netbird-01.imcherry5778.xyz" and .become == false and .forks == 1 and (.asks|all(. == false)) and (.credentials|length == 1)) and
    .templates["AWX-06 netbird marker precheck"].job_type == "check" and .templates["AWX-06 netbird marker precheck"].playbook == "awx06-marker-precheck.yml" and
    .templates["AWX-06 netbird marker apply"].job_type == "run" and .templates["AWX-06 netbird marker apply"].playbook == "awx06-marker-apply.yml" and
    .templates["AWX-06 netbird marker idempotency"].job_type == "check" and .templates["AWX-06 netbird marker idempotency"].playbook == "awx06-marker-idempotency.yml" and
    .templates["AWX-06 netbird marker cleanup"].job_type == "run" and .templates["AWX-06 netbird marker cleanup"].playbook == "awx06-marker-cleanup.yml" and
    .workflow_nodes == ["approved-marker-apply","approved-marker-cleanup","human-approval","marker-idempotency","marker-precheck"] and
    .marker_roles.operator_execute and .marker_roles.approver_only and (.marker_roles.operator_approval|not)
  ' <<<"${state}" >/dev/null
  cap=$(capacity); awk -F= '/guest_available_bytes=/{exit !($2 >= 8589934592)}' <<<"${cap}" || { echo 'AWX-06 중지: guest available이 8GiB 미만' >&2; exit 1; }; grep -qx 'swap_devices=0' <<<"${cap}" || { echo 'AWX-06 중지: swap이 0이 아님' >&2; exit 1; }
  printf 'AWX06_PLATFORM=PASS root=%s child=%s egress=10.10.40.10/32:22 inventory=1 workflow=approval-gated pvc=0 %s\n' "${root}" "${child}" "$(tr '\n' ' ' <<<"${cap}")"
}
case ${mode} in platform) verify_platform ;; *) echo "사용법: $0 platform" >&2; exit 2 ;; esac
