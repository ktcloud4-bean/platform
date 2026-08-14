#!/usr/bin/env bash
# AWX-05 완료 증거만: immutable Argo, Machine external lookup, one-host check job,
# exact NetworkPolicy와 secret 원문 비노출을 한 번 판정한다.
set -Eeuo pipefail

mode=${1:-}
readonly repo_root=$(git rev-parse --show-toplevel)
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly platform_ee=harbor.imcherry5778.xyz/awx-ee/platform-ee@sha256:0a35dcb1933fd6439730dd2a57e325be1bd175852c29dd0e2894728b16137bb9
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

remote_awx_shell() {
  remote_kubectl -n awx exec -i deploy/awx-web -c awx-web -- awx-manage shell
}

capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" '
    set -eu
    awk "/MemAvailable:/ {printf \"guest_available_bytes=%d\\n\", \$2*1024}" /proc/meminfo
    printf "swap_devices="; awk "NR>1 {count++} END {print count+0}" /proc/swaps
  '
}

verify_platform() {
  local expected_root=${AWX05_EXPECTED_ROOT_REVISION:?root targetRevision이 필요하다}
  local expected_child=${AWX05_EXPECTED_CHILD_REVISION:?AWX targetRevision이 필요하다}
  local expected_root_sync=${AWX05_EXPECTED_ROOT_SYNC_REVISION:-${expected_root}}
  local expected_child_sync=${AWX05_EXPECTED_CHILD_SYNC_REVISION:-${expected_child}}
  [[ ${expected_root} =~ ^(main|[0-9a-f]{40})$ && ${expected_child} =~ ^(main|[0-9a-f]{40})$ ]]
  [[ ${expected_root_sync} =~ ^[0-9a-f]{40}$ && ${expected_child_sync} =~ ^[0-9a-f]{40}$ ]]

  local argo state network awx_cr secrets pvc cap
  argo=$(remote_kubectl -n argocd get application platform-root awx -o json)
  jq -e --arg root "${expected_root}" --arg child "${expected_child}" \
    --arg root_sync "${expected_root_sync}" --arg child_sync "${expected_child_sync}" '
      . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
      (app("platform-root") | .spec.source.targetRevision == $root and .status.sync.revision == $root_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded") and
      (app("awx") | .spec.source.targetRevision == $child and .status.sync.revision == $child_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded")
    ' <<<"${argo}" >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-web --timeout=240s >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-task --timeout=240s >/dev/null

  awx_cr=$(remote_kubectl -n awx get awx.awx.ansible.com awx -o json)
  jq -e '
    [.spec.extra_settings[] | select(.setting == "DEFAULT_EXECUTION_QUEUE_POD_SPEC_OVERRIDE") | .value | ltrimstr("\u0027") | rtrimstr("\u0027") | fromjson] as $override |
    $override | length == 1 and
    .[0].spec.imagePullSecrets == [{"name":"awx-ee-pull"}] and
    ([.[0].spec.volumes[] | select(.name == "awx-ssh-canary-known-hosts" and .secret == {"secretName":"awx-ssh-canary-known-hosts","defaultMode":292})] | length == 1) and
    ([.[0].spec.volumes[] | select(.name == "awx-execution-runner" and .emptyDir == {"sizeLimit":"32Mi"})] | length == 1) and
    ([.[0].spec.containers[] | select(.name == "worker") | .volumeMounts[] | select(.name == "awx-ssh-canary-known-hosts" and .mountPath == "/etc/awx-ssh-canary" and .readOnly == true)] | length == 1) and
    ([.[0].spec.containers[] | select(.name == "worker") | .volumeMounts[] | select(.name == "awx-execution-runner" and .mountPath == "/runner")] | length == 1)
  ' <<<"${awx_cr}" >/dev/null
  network=$(remote_kubectl -n awx get networkpolicy awx-execution-k3s-ssh-canary-egress -o json)
  jq -e '
    .spec.podSelector.matchExpressions == [{"key":"ansible-awx","operator":"Exists"}] and
    .spec.policyTypes == ["Egress"] and
    .spec.egress == [{"to":[{"ipBlock":{"cidr":"10.10.20.10/32"}}],"ports":[{"protocol":"TCP","port":22}]}]
  ' <<<"${network}" >/dev/null
  secrets=$(remote_kubectl -n awx get secret awx-ssh-canary-known-hosts -o json)
  jq -e '.type == "Opaque" and (.data | keys) == ["known_hosts"]' <<<"${secrets}" >/dev/null
  pvc=$(remote_kubectl -n awx get pvc -o json)
  jq -e '(.items | length) == 0' <<<"${pvc}" >/dev/null

  state=$(remote_awx_shell <<'PY'
import json
from awx.main.models import Credential, CredentialInputSource, Host, Inventory, JobTemplate, Organization

org = Organization.objects.get(name="Platform")
inventory = Inventory.objects.get(name="AWX-05 k3s-01 SSH canary", organization=org)
host = Host.objects.get(name="k3s-01.imcherry5778.xyz", inventory=inventory)
lookup = Credential.objects.get(name="AWX-05 Vault Machine lookup", organization=org)
credential = Credential.objects.get(name="AWX-05 k3s-01 SSH canary", organization=org)
source = CredentialInputSource.objects.get(target_credential=credential, input_field_name="ssh_key_data")
template = JobTemplate.objects.get(name="AWX-05 k3s-01 SSH canary", organization=org)
print(json.dumps({
  "inventory": {"hosts": inventory.hosts.count(), "variables": inventory.variables},
  "host": {"variables": host.variables},
  "lookup": {"type": lookup.credential_type.name, "input_keys": sorted(lookup.inputs.keys())},
  "credential": {"type": credential.credential_type.name, "input_keys": sorted(credential.inputs.keys())},
  "source": {"source_credential": source.source_credential_id, "input_field": source.input_field_name, "metadata": source.metadata},
  "template": {
    "project": template.project.name if template.project else None,
    "playbook": template.playbook, "job_type": template.job_type, "inventory": template.inventory_id,
    "limit": template.limit, "forks": template.forks, "become_enabled": template.become_enabled,
    "allow_simultaneous": template.allow_simultaneous,
    "ask": {name: getattr(template, name) for name in (
      "ask_limit_on_launch", "ask_inventory_on_launch", "ask_credential_on_launch", "ask_job_type_on_launch",
      "ask_scm_branch_on_launch", "ask_variables_on_launch", "ask_execution_environment_on_launch", "ask_forks_on_launch")},
    "credential_ids": sorted(template.credentials.values_list("id", flat=True)),
    "execution_environment": template.execution_environment.image if template.execution_environment else None,
  },
}, sort_keys=True))
PY
)
  state=$(tail -n 1 <<<"${state}")
  jq -e --arg ee "${platform_ee}" '
    .inventory.hosts == 1 and (.inventory.variables | fromjson | .ansible_become == false and .awx05_single_target == true) and
    (.host.variables | fromjson | .ansible_become == false and (.ansible_ssh_common_args | contains("StrictHostKeyChecking=yes")) and (.ansible_ssh_common_args | contains("/etc/awx-ssh-canary/known_hosts"))) and
    .lookup.type == "HashiCorp Vault Secret Lookup" and .lookup.input_keys == ["api_version","cacert","default_auth_path","role_id","secret_id","url"] and
    .credential.type == "Machine" and .credential.input_keys == ["username"] and
    .source.source_credential != null and .source.input_field == "ssh_key_data" and
    .source.metadata == {"auth_path":"approle","secret_backend":"kv","secret_key":"ssh_private_key","secret_path":"awx/ssh-canary"} and
    .template.project == "AWX-01 선언 저장소" and .template.playbook == "awx05-ssh-canary.yml" and
    .template.job_type == "check" and .template.inventory != null and .template.limit == "k3s-01.imcherry5778.xyz" and
    .template.forks == 1 and .template.become_enabled == false and .template.allow_simultaneous == false and
    (.template.ask | all(. == false)) and (.template.credential_ids | length == 1) and .template.execution_environment == $ee
  ' <<<"${state}" >/dev/null
  cap=$(capacity)
  awk -F= '/^guest_available_bytes=/{if ($2 < 8589934592) exit 1}' <<<"${cap}" || { echo "AWX-05 중지: guest available이 8 GiB 미만이다" >&2; exit 1; }
  grep -qx 'swap_devices=0' <<<"${cap}" || { echo "AWX-05 중지: swap이 0이 아니다" >&2; exit 1; }
  printf 'AWX05_PLATFORM=PASS root=%s root_sync=%s child=%s child_sync=%s inventory=1 network=10.10.20.10/32:22 pvc=0 %s\n' \
    "${expected_root}" "${expected_root_sync}" "${expected_child}" "${expected_child_sync}" "$(tr '\n' ' ' <<<"${cap}")"
}

job_status() {
  local job_id=$1
  remote_awx_shell <<PY
import json
from awx.main.models import Job, JobHostSummary
job = Job.objects.get(id=${job_id})
summary = JobHostSummary.objects.filter(job=job).values("changed", "dark", "failed", "ignored", "ok", "rescued", "skipped").first()
print(json.dumps({
  "status": job.status,
  "stdout_has_network_boundary": "AWX05_NETWORK_BOUNDARIES=PASS" in job.result_stdout,
  "summary": summary,
}, sort_keys=True))
PY
}

read_private_key() {
  { tr -d '\n' <"${root_token_file}"; printf '\n'; } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'set -eu; read -r VAULT_TOKEN; export VAULT_TOKEN; vault kv get -field=ssh_private_key kv/awx/ssh-canary'"
}

run_canary() {
  [[ -r ${root_token_file} && ! -L ${root_token_file} && $(stat -c %a "${root_token_file}") == 600 ]] || {
    echo "secret 원문 비노출 판정용 Vault root token 파일을 읽을 수 없거나 mode 0600이 아니다" >&2
    exit 1
  }
  local start job_id pod='' attempt pod_doc state tmp_dir log_pid
  start=$(remote_awx_shell <<'PY'
import json
from awx.main.models import JobTemplate, Organization
org = Organization.objects.get(name="Platform")
template = JobTemplate.objects.get(name="AWX-05 k3s-01 SSH canary", organization=org)
job = template.create_unified_job()
job.signal_start()
print(json.dumps({"job": job.id, "status": job.status}))
PY
)
  start=$(tail -n 1 <<<"${start}")
  job_id=$(jq -er '.job | tostring' <<<"${start}")
  for attempt in {1..30}; do
    pod_doc=$(remote_kubectl -n awx get pods -o json)
    pod=$(jq -r --arg job "${job_id}" '.items[] | select(.metadata.labels["ansible-awx"] == $job) | .metadata.name' <<<"${pod_doc}" | head -n 1)
    [[ -n ${pod} ]] && break
    sleep 1
  done
  [[ -n ${pod} ]] || { echo "AWX-05 job ${job_id}의 execution Pod를 관찰하지 못했다" >&2; exit 1; }
  jq -e --arg ee "${platform_ee}" '
    [.spec.imagePullSecrets[]?.name] == ["awx-ee-pull"] and
    ([.spec.containers[] | select(.name == "worker") | .image] == [$ee]) and
    ([.spec.containers[] | select(.name == "worker") | .volumeMounts[] | select(.name == "awx-ssh-canary-known-hosts" and .mountPath == "/etc/awx-ssh-canary" and .readOnly == true)] | length == 1) and
    ([.spec.containers[] | select(.name == "worker") | .volumeMounts[] | select(.name == "awx-execution-runner" and .mountPath == "/runner")] | length == 1)
  ' <<<"$(jq -c --arg pod "${pod}" '.items[] | select(.metadata.name == $pod)' <<<"${pod_doc}")" >/dev/null

  umask 077
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "${tmp_dir}"' RETURN
  # execution Pod는 성공/실패 직후 정리되므로 stream을 먼저 열어 traceback도 같은 job에서
  # 확보한다. 로그 내용은 출력하지 않고 secret 원문 대조와 안전한 실패 분류에만 사용한다.
  remote_kubectl -n awx logs -f "${pod}" --all-containers=true >"${tmp_dir}/pod.log" 2>&1 &
  log_pid=$!
  for attempt in {1..120}; do
    state=$(job_status "${job_id}")
    state=$(tail -n 1 <<<"${state}")
    case $(jq -r '.status' <<<"${state}") in
      successful|failed|error|canceled) break ;;
    esac
    sleep 2
  done
  wait "${log_pid}" || true
  if ! jq -e '
    .status == "successful" and .stdout_has_network_boundary == true and
    .summary.changed == 0 and .summary.dark == 0 and .summary.failed == 0
  ' <<<"${state}" >/dev/null; then
    printf 'AWX-05 canary job=%s status=%s runner_traceback=%s exception=%s\n' "${job_id}" \
      "$(jq -r '.status' <<<"${state}")" \
      "$(grep -E -q 'Traceback|Exception|Error' "${tmp_dir}/pod.log" && echo present || echo absent)" \
      "$(awk '/^[A-Za-z][A-Za-z0-9_.]*(Error|Exception):/{value=$1} END{if (value == "") print "none"; else print value}' "${tmp_dir}/pod.log")" >&2
    return 1
  fi
  remote_awx_shell <<PY >"${tmp_dir}/job.stdout"
from awx.main.models import Job
print(Job.objects.get(id=${job_id}).result_stdout, end="")
PY
  read_private_key >"${tmp_dir}/private-key"
  ! grep -F -f "${tmp_dir}/private-key" "${tmp_dir}/job.stdout" "${tmp_dir}/pod.log" >/dev/null
  printf 'AWX05_CANARY=PASS job=%s status=successful changed=0 network=blocked_other_host_and_port pod=%s secret_raw=0\n' \
    "${job_id}" "${pod}"
}

case ${mode} in
  platform) verify_platform ;;
  run-canary) run_canary ;;
  *) echo "사용법: $0 platform|run-canary" >&2; exit 2 ;;
esac
