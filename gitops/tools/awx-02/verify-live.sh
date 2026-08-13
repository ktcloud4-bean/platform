#!/usr/bin/env bash
# AWX-02 완료 증거만 policy/workload와 human-session RBAC 두 단계로 판정한다.
# shellcheck disable=SC2029 # 고정 kubectl 명령을 인증된 원격 host에서 확장한다.
set -Eeuo pipefail

mode=${1:-}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

verify_platform() {
  local expected_root=${AWX02_EXPECTED_ROOT_REVISION:?root pointer commit SHA가 필요하다}
  local expected_child=${AWX02_EXPECTED_CHILD_REVISION:?AWX-02 설정 commit SHA가 필요하다}
  [[ ${expected_root} =~ ^[0-9a-f]{40}$ && ${expected_child} =~ ^[0-9a-f]{40}$ ]]

  local argo
  argo=$(remote_kubectl -n argocd get application platform-root awx policy-baseline -o json)
  jq -e --arg root "${expected_root}" --arg child "${expected_child}" '
    . as $doc |
    def app($name): $doc.items[] | select(.metadata.name == $name);
    (app("platform-root") |
      .spec.source.targetRevision == $root and .status.sync.revision == $root and
      .status.sync.status == "Synced" and .status.health.status == "Healthy") and
    (["awx", "policy-baseline"] | all(. as $name |
      (app($name) | .spec.source.targetRevision == $child and
        .status.sync.revision == $child and .status.sync.status == "Synced" and
        .status.health.status == "Healthy")))
  ' <<<"${argo}" >/dev/null

  remote_kubectl -n awx rollout status deploy/awx-operator-controller-manager --timeout=120s >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-web --timeout=300s >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-task --timeout=300s >/dev/null

  local awx_json deployments pods migration mutation exception_count execution_pod_spec
  awx_json=$(remote_kubectl -n awx get awx awx -o json)
  jq -e '
    .spec.security_context_settings == {
      runAsNonRoot:true, runAsUser:1000, runAsGroup:0, fsGroup:1000,
      fsGroupChangePolicy:"OnRootMismatch", seccompProfile:{type:"RuntimeDefault"}
    } and
    ([.status.conditions[] | select(.type == "Successful" and .status == "True")] | length) == 1 and
    .status.version == "24.6.1"
  ' <<<"${awx_json}" >/dev/null

  execution_pod_spec=$(ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} -n awx exec deploy/awx-web -c awx-web -- awx-manage shell -c 'from django.conf import settings; print(settings.DEFAULT_EXECUTION_QUEUE_POD_SPEC_OVERRIDE)'" | tail -n 1)
  jq -e '
    .spec.securityContext == {
      runAsNonRoot:true, runAsUser:1000, runAsGroup:0, fsGroup:1000,
      fsGroupChangePolicy:"OnRootMismatch", seccompProfile:{type:"RuntimeDefault"}
    }
  ' <<<"${execution_pod_spec}" >/dev/null

  deployments=$(remote_kubectl -n awx get deployment awx-web awx-task -o json)
  jq -e '
    .items as $items | ($items | length == 2) and ($items | all(
      .status.availableReplicas == 1 and .status.updatedReplicas == 1 and
      .spec.template.spec.securityContext == {
        runAsNonRoot:true, runAsUser:1000, runAsGroup:0, fsGroup:1000,
        fsGroupChangePolicy:"OnRootMismatch", seccompProfile:{type:"RuntimeDefault"}
      }
    ))
  ' <<<"${deployments}" >/dev/null

  pods=$(remote_kubectl -n awx get pod -l app.kubernetes.io/managed-by=awx-operator -o json)
  jq -e '
    [.items[] | select(.metadata.name | test("^awx-(web|task)-"))] as $items |
    ($items | length == 2) and ($items | all(.status.phase == "Running" and
      ([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length) == 1 and
      .spec.securityContext.runAsNonRoot == true and .spec.securityContext.runAsUser == 1000))
  ' <<<"${pods}" >/dev/null
  for deployment in awx-web awx-task; do
    local container
    while IFS= read -r container; do
      [[ $(remote_kubectl -n awx exec deploy/${deployment} -c "${container}" -- id -u) == 1000 ]]
      [[ $(remote_kubectl -n awx exec deploy/${deployment} -c "${container}" -- id -g) == 0 ]]
    done < <(jq -r --arg name "${deployment}" '
      .items[] | select(.metadata.name == $name) | .spec.template.spec.containers[].name
    ' <<<"${deployments}")
  done

  migration=$(remote_kubectl -n awx get job awx-migration-24.6.1 -o json)
  jq -e '.status.succeeded == 1 and (.status.failed // 0) == 0' <<<"${migration}" >/dev/null

  mutation=$(ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} create --dry-run=server -f - -o json" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: awx-migration-awx02-admission
  namespace: awx
  labels:
    app.kubernetes.io/component: awx
    app.kubernetes.io/managed-by: awx-operator
spec:
  template:
    metadata:
      labels:
        app.kubernetes.io/component: awx
        app.kubernetes.io/managed-by: awx-operator
    spec:
      restartPolicy: Never
      containers:
        - name: migration-job
          image: registry.k8s.io/pause:3.10
YAML
  )
  jq -e '.spec.template.spec.securityContext == {
    runAsNonRoot:true, runAsUser:1000, runAsGroup:0, fsGroup:1000,
    fsGroupChangePolicy:"OnRootMismatch", seccompProfile:{type:"RuntimeDefault"}
  }' <<<"${mutation}" >/dev/null

  if ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} create --dry-run=server -f - -o name" \
    >/dev/null 2>&1 <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: awx-migration-awx02-wrong-label
  namespace: awx
  labels:
    app.kubernetes.io/component: awx
    app.kubernetes.io/managed-by: not-awx-operator
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migration-job
          image: registry.k8s.io/pause:3.10
YAML
  then
    echo '범위 밖 migration Job이 mutation 없이 admission을 통과했다.' >&2
    return 1
  fi

  exception_count=$(remote_kubectl -n kyverno get policyexception pol-02-awx-run-as-non-root \
    --ignore-not-found -o name | wc -l)
  [[ ${exception_count} == 0 ]]
  remote_kubectl get clusterpolicy pol-02-awx-migration-run-as-non-root -o json | jq -e '
    .spec.background == false and (.spec.rules | length) == 1 and
    .spec.rules[0].name == "set-awx-migration-pod-security-context"
  ' >/dev/null

  echo "AWX02_PLATFORM=PASS root=${expected_root} child=${expected_child} web_task_uid_gid=1000:0 execution_pod=nonroot migration=succeeded admission=exact exception=absent"
}

verify_identity_state() {
  local state
  state=$(ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} -n awx exec deploy/awx-web -c awx-web -- awx-manage shell -c 'import json; from django.contrib.auth import get_user_model; from awx.main.models import Organization,Team; U=get_user_model(); org=Organization.objects.get(name=\"Platform\"); teams=list(Team.objects.filter(organization=org).order_by(\"name\")); names=[\"imcherry5778\",\"imcherry5778-admin\",\"imcherry\",\"imcherry-admin\"]; out=[]; [(out.append({\"username\":n,\"exists\":False}) if not U.objects.filter(username=n).exists() else (lambda u: out.append({\"username\":n,\"exists\":True,\"superuser\":u.is_superuser,\"org_member\":org.member_role.members.filter(pk=u.pk).exists(),\"org_admin\":org.admin_role.members.filter(pk=u.pk).exists(),\"teams\":[t.name for t in teams if t.member_role.members.filter(pk=u.pk).exists()]}))(U.objects.get(username=n))) for n in names]; print(json.dumps(out,sort_keys=True))'" | tail -n 1)
  jq -e '
    def user($name): .[] | select(.username == $name);
    (user("imcherry5778") |
      .exists == true and .superuser == false and .org_member == true and
      .org_admin == false and .teams == ["AWX Operators"]) and
    (user("imcherry5778-admin") |
      .exists == true and .superuser == false and .org_member == true and
      .org_admin == false and .teams == ["AWX Approvers"]) and
    ([user("imcherry"), user("imcherry-admin")] |
      all((.org_member // false) == false and (.org_admin // false) == false and
        ((.teams // []) | length) == 0))
  ' <<<"${state}" >/dev/null || {
    echo 'AWX02_IDENTITY=PENDING 신규 두 ID의 첫 SSO 또는 exact membership 확인이 필요하다.' >&2
    return 3
  }
  echo 'AWX02_IDENTITY=PASS daily=Platform/AWX_Operators privileged=Platform/AWX_Approvers legacy_membership=0 superuser=0 org_admin=0'
}

verify_secret_literals() {
  local kc_dir=${secret_root}/keycloak
  local awx_env=${secret_root}/awx/env
  local temp_dir pattern_file pod_log pods pod container pod_containers
  for required in "${awx_env}" "${kc_dir}/daily-password" "${kc_dir}/daily-totp" \
    "${kc_dir}/privileged-password" "${kc_dir}/privileged-totp"; do
    [[ -s ${required} && $(stat -c %a "${required}") == 600 ]] || {
      echo "필수 외부 입력이 없거나 mode 0600이 아니다: ${required}" >&2
      return 1
    }
  done
  temp_dir=$(mktemp -d)
  trap 'rm -rf "${temp_dir}"' RETURN
  pattern_file=${temp_dir}/patterns
  pod_log=${temp_dir}/awx.log

  awk -F= 'NF >= 2 {value=substr($0,index($0,"=")+1); if (length(value)>=20) print value}' \
    "${awx_env}" >"${pattern_file}"
  for required in "${kc_dir}/daily-password" "${kc_dir}/daily-totp" \
    "${kc_dir}/privileged-password" "${kc_dir}/privileged-totp"; do
    tr -d '\r\n' <"${required}" >>"${pattern_file}"
    printf '\n' >>"${pattern_file}"
  done
  if git -C "${repo_root}" grep -F -f "${pattern_file}" -- . >/dev/null 2>&1; then
    echo 'Git 추적 파일에서 AWX secret 원문을 찾았다.' >&2
    return 1
  fi
  pods=$(remote_kubectl -n awx get pod -o json)
  pod_containers=$(jq -r '.items[] | .metadata.name as $pod |
    ((.spec.initContainers // []) + .spec.containers)[] | [$pod, .name] | @tsv' <<<"${pods}")
  while IFS=$'\t' read -r pod container; do
    remote_kubectl -n awx logs "${pod}" -c "${container}" --tail=2000 --request-timeout=10s \
      >>"${pod_log}" 2>/dev/null || {
        echo "AWX Pod 로그 수집이 제한 시간 안에 끝나지 않았다: ${pod}/${container}" >&2
        return 1
      }
  done <<<"${pod_containers}"
  if grep -F -f "${pattern_file}" "${pod_log}" >/dev/null 2>&1; then
    echo 'AWX Pod 로그에서 secret 원문을 찾았다.' >&2
    return 1
  fi
  echo 'AWX02_SECRETS=PASS git_tracked=0 current_pod_logs=0'
}

verify_browser_rbac() {
  local kc_dir=${secret_root}/keycloak
  local awx_env=${secret_root}/awx/env
  local temp_dir objects_file
  for required in "${awx_env}" "${kc_dir}/daily-password" "${kc_dir}/daily-totp" \
    "${kc_dir}/privileged-password" "${kc_dir}/privileged-totp"; do
    [[ -s ${required} && $(stat -c %a "${required}") == 600 ]] || {
      echo "필수 외부 입력이 없거나 mode 0600이 아니다: ${required}" >&2
      return 1
    }
  done
  temp_dir=$(mktemp -d)
  trap 'rm -rf "${temp_dir}"' RETURN
  objects_file=${temp_dir}/objects.json

  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} -n awx exec deploy/awx-web -c awx-web -- awx-manage shell -c 'import json; from awx.main.models import Credential,JobTemplate,WorkflowJobTemplate,Team; print(json.dumps({\"allowed_credential\":Credential.objects.get(name=\"AWX-01 verifier allowed\").id,\"denied_credential\":Credential.objects.get(name=\"AWX-01 verifier denied\").id,\"check_template\":JobTemplate.objects.get(name=\"AWX-01 credential check\").id,\"denied_template\":JobTemplate.objects.get(name=\"AWX-01 credential denied\").id,\"apply_template\":JobTemplate.objects.get(name=\"AWX-01 approved apply\").id,\"workflow\":WorkflowJobTemplate.objects.get(name=\"AWX-01 check-to-apply 승인\").id,\"operators_team\":Team.objects.get(name=\"AWX Operators\").id}))'" | tail -n 1 >"${objects_file}"

  node "${repo_root}/gitops/tools/awx-01/browser-verify.js" \
    --connect-ip "${AWX02_CONNECT_IP:-10.10.20.10}" \
    --daily-username imcherry5778 --privileged-username imcherry5778-admin \
    --daily-password-file "${kc_dir}/daily-password" --daily-totp-file "${kc_dir}/daily-totp" \
    --privileged-password-file "${kc_dir}/privileged-password" \
    --privileged-totp-file "${kc_dir}/privileged-totp" \
    --object-file "${objects_file}" --secret-env-file "${awx_env}"

  echo 'AWX02_RBAC=PASS daily_apply_approval=403 privileged_execute_permission_manage=403'
}

case ${mode} in
  platform) verify_platform ;;
  identity-state) verify_identity_state ;;
  secrets) verify_secret_literals ;;
  browser-rbac) verify_browser_rbac ;;
  *) echo "사용법: $0 platform|identity-state|secrets|browser-rbac" >&2; exit 2 ;;
esac
