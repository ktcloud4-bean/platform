#!/usr/bin/env bash
# DEMO-AWS-HR-01: EKS 공급망 경계를 실제 HR Pod shape의 server-side dry-run으로만 촬영한다.
set -Eeuo pipefail

readonly tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root=$(cd -- "${tool_dir}/../../.." && pwd)
readonly state_dir=/tmp/demo-aws-hr-01-state
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly k3s_kubeconfig=${K3S_KUBECONFIG:-/home/imcherry/.kube/k3s-01-admin.yaml}
readonly eks_kubeconfig=${EKS_KUBECONFIG:-/home/imcherry/.kube/eks-hr-system-prod.yaml}
readonly socks_port=${DEMO_AWS_HR_SOCKS_PORT:-1099}
readonly socks_control=${state_dir}/socks-control
readonly deployment_file=${repo_root}/gitops/apps/hr-system/deployments.yaml
readonly synthetic_secret_dir=${DEMO_AWS_HR_SECRET_DIR:-/home/imcherry/secrets/ktcloud4-bean/hr-system-e2e}
readonly inert_tag_image=465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-frontend:demo-inert-tag-only
readonly -a components=(frontend employee-service hr-service)

socks_started=0

fail() {
  printf 'DEMO_AWS_HR=FAIL reason=%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
usage: gitops/tools/demo-aws-hr-01/demo.sh {attack|control|evidence|reset|prove}

attack   현재 HR deployment snapshot 뒤 inert tag-only ECR Pod를 server-side dry-run으로 DENIED 확인
control  같은 frontend Pod shape의 현재 signed exact digest를 server-side dry-run으로 ALLOWED 확인
evidence 기존 HR workload 무변화, 합성 포털 read-only 200, Argo hr-system Synced/Healthy 확인
reset    원격 delete 없이 snapshot을 대조한 뒤 로컬 state만 제거
prove    attack -> control -> evidence -> reset을 한 번에 실행
USAGE
}

stop_socks() {
  if [[ ${socks_started} -eq 1 ]]; then
    ssh -S "${socks_control}" -O exit "${k3s_host}" >/dev/null 2>&1 || true
    socks_started=0
  fi
}

ensure_socks() {
  [[ -r ${eks_kubeconfig} && -r ${known_hosts} ]] || fail 'EKS kubeconfig 또는 known_hosts를 읽을 수 없다'
  if [[ ${socks_started} -eq 1 ]]; then
    return
  fi
  if nc -z 127.0.0.1 "${socks_port}" 2>/dev/null; then
    fail "SOCKS port ${socks_port} is already in use; do not share a tunnel"
  fi
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
    -M -S "${socks_control}" -f -N -D "127.0.0.1:${socks_port}" "${k3s_host}"
  for _ in $(seq 1 10); do
    nc -z 127.0.0.1 "${socks_port}" && break
    sleep 1
  done
  nc -z 127.0.0.1 "${socks_port}" || fail 'EKS SOCKS tunnel did not become ready'
  socks_started=1
}

eks_kube() {
  ensure_socks
  HTTPS_PROXY="socks5h://127.0.0.1:${socks_port}" KUBECONFIG="${eks_kubeconfig}" kubectl "$@"
}

k3s_kube() {
  [[ -r ${k3s_kubeconfig} ]] || fail 'k3s kubeconfig를 읽을 수 없다'
  KUBECONFIG="${k3s_kubeconfig}" kubectl "$@"
}

require_state() {
  [[ -f ${state_dir}/baseline.json ]] || fail 'baseline is absent; run attack first'
}

capture_snapshot() {
  local output=$1 deployments pods replica_sets
  [[ ! -e ${output} ]] || fail "refusing to overwrite state file: ${output}"
  # command substitution 안에서 만든 tunnel 상태는 부모 셸로 돌아오지 않는다.
  # snapshot 시작에서 한 번만 확보해 이후 세 read-only 조회가 같은 tunnel을 사용하게 한다.
  ensure_socks
  deployments=$(eks_kube -n hr-system get deployment "${components[@]}" -o json)
  pods=$(eks_kube -n hr-system get pods -l app.kubernetes.io/part-of=hr-system -o json)
  replica_sets=$(eks_kube -n hr-system get replicasets -l app.kubernetes.io/part-of=hr-system -o json)
  jq -n --argjson deployments "${deployments}" --argjson pods "${pods}" --argjson replica_sets "${replica_sets}" '
    def selected:
      .metadata.labels["app.kubernetes.io/name"] as $component |
      $component == "frontend" or $component == "employee-service" or $component == "hr-service";
    {
      deployments: ($deployments.items | map({
        name: .metadata.name,
        uid: .metadata.uid,
        desired: (.spec.replicas // 1),
        ready: (.status.readyReplicas // 0),
        available: (.status.availableReplicas // 0),
        images: [.spec.template.spec.containers[] | {name: .name, image: .image}]
      }) | sort_by(.name)),
      replica_sets: ($replica_sets.items | map(select(selected) | {
        name: .metadata.name,
        uid: .metadata.uid,
        component: .metadata.labels["app.kubernetes.io/name"],
        desired: (.spec.replicas // 0),
        ready: (.status.readyReplicas // 0)
      }) | sort_by(.name)),
      pods: ($pods.items | map(select(selected) | {
        name: .metadata.name,
        uid: .metadata.uid,
        component: .metadata.labels["app.kubernetes.io/name"],
        phase: (.status.phase // "Unknown"),
        ready: (any(.status.conditions[]?; .type == "Ready" and .status == "True")),
        images: [.spec.containers[] | {name: .name, image: .image}]
      }) | sort_by(.name))
    }
  ' >"${output}"
}

validate_workloads() {
  local snapshot=$1
  jq -e '
    ([.deployments[].name] | sort) == ["employee-service", "frontend", "hr-service"] and
    all(.deployments[];
      .desired == 1 and .ready == 1 and .available == 1 and
      ([.images[].image] | length == 1 and all(.[]; test("@sha256:[0-9a-f]{64}$")))
    ) and
    ([.pods[].component] | sort) == ["employee-service", "frontend", "hr-service"] and
    all(.pods[];
      .phase == "Running" and .ready and
      ([.images[].image] | length == 1 and all(.[]; test("@sha256:[0-9a-f]{64}$")))
    )
  ' "${snapshot}" >/dev/null || fail 'existing HR deployment is not exactly Ready with digest-pinned service Pods'
}

assert_declared_images() {
  local snapshot=$1 name image
  [[ -r ${deployment_file} ]] || fail 'HR deployment declaration is absent'
  while IFS=$'\t' read -r name image; do
    rg -Fq -- "image: ${image}" "${deployment_file}" || fail "live ${name} image differs from Git declaration"
  done < <(jq -r '.deployments[] | .name + "\t" + .images[0].image' "${snapshot}")
}

write_same_shape_pods() {
  local positive=${state_dir}/positive.json
  local negative=${state_dir}/negative.json
  [[ ! -e ${positive} && ! -e ${negative} ]] || fail 'pod fixture state already exists'
  eks_kube -n hr-system get deployment frontend -o json | jq '
    .spec.template as $template |
    {
      apiVersion: "v1",
      kind: "Pod",
      metadata: {
        name: "demo-aws-hr-positive",
        namespace: .metadata.namespace,
        labels: ($template.metadata.labels // {}),
        annotations: ($template.metadata.annotations // {})
      },
      spec: $template.spec
    }
  ' >"${positive}"
  jq --arg image "${inert_tag_image}" '
    .metadata.name = "demo-aws-hr-negative" |
    .spec.containers[0].image = $image
  ' "${positive}" >"${negative}"
  jq -s -e '
    (.[0].metadata.namespace == "hr-system") and
    (.[0].spec.containers | length == 1) and
    ((.[0].spec | del(.containers[].image)) == (.[1].spec | del(.containers[].image))) and
    (.[0].spec.containers[0].image | test("@sha256:[0-9a-f]{64}$")) and
    (.[1].spec.containers[0].image | endswith(":demo-inert-tag-only"))
  ' "${positive}" "${negative}" >/dev/null || fail 'positive and negative Pod shapes diverged'
}

assert_unchanged() {
  local current=${state_dir}/current.json
  require_state
  [[ ! -e ${current} ]] || fail 'previous current snapshot remains; run reset'
  capture_snapshot "${current}"
  if ! cmp -s "${state_dir}/baseline.json" "${current}"; then
    fail 'HR Deployment, ReplicaSet, or Pod changed since the negative dry-run baseline'
  fi
  unlink "${current}"
}

check_supply_policy() {
  eks_kube get imagevalidatingpolicy -o json | jq -e '
    any(.items[];
      .spec.validationActions == ["Deny"] and
      .spec.failurePolicy == "Fail"
    )
  ' >/dev/null || fail 'no EKS ImageValidatingPolicy is Deny/Fail'
}

check_argo() {
  k3s_kube -n argocd get application hr-system -o json | jq -e '
    .spec.source.targetRevision == "main" and
    .status.sync.status == "Synced" and
    .status.health.status == "Healthy"
  ' >/dev/null || fail 'Argo hr-system is not main/Synced/Healthy'
}

action_attack() {
  [[ ! -e ${state_dir} ]] || fail 'previous demo state remains; run reset first'
  install -d -m 0700 "${state_dir}"
  capture_snapshot "${state_dir}/baseline.json"
  validate_workloads "${state_dir}/baseline.json"
  assert_declared_images "${state_dir}/baseline.json"
  write_same_shape_pods
  if eks_kube create --dry-run=server -f "${state_dir}/negative.json" >"${state_dir}/negative.out" 2>&1; then
    fail 'inert tag-only ECR fixture was unexpectedly admitted'
  fi
  rg -qi 'admission webhook.*denied|imagevalidatingpolicy|digest|sha256|tag-only' "${state_dir}/negative.out" \
    || fail 'negative request failed outside the image admission boundary'
  assert_unchanged
  printf '%s\n' 'DEMO_AWS_HR_ATTACK=PASS pod_shape=frontend fixture=tag-only dry_run=server result=DENIED new_replicasets=0 new_pods=0'
  printf '%s\n' 'attack=DENIED' >"${state_dir}/attack.ok"
}

action_control() {
  require_state
  [[ -f ${state_dir}/attack.ok ]] || fail 'negative dry-run evidence is absent; run attack first'
  [[ ! -e ${state_dir}/control.ok ]] || fail 'control already ran; use evidence or reset'
  eks_kube create --dry-run=server -f "${state_dir}/positive.json" >/dev/null
  assert_unchanged
  printf '%s\n' 'DEMO_AWS_HR_CONTROL=PASS pod_shape=frontend signed_exact_digest=true dry_run=server result=ALLOWED new_replicasets=0 new_pods=0'
  printf '%s\n' 'control=ALLOWED' >"${state_dir}/control.ok"
}

action_evidence() {
  require_state
  [[ -f ${state_dir}/attack.ok && -f ${state_dir}/control.ok ]] || fail 'attack/control result is incomplete'
  assert_unchanged
  validate_workloads "${state_dir}/baseline.json"
  assert_declared_images "${state_dir}/baseline.json"
  check_supply_policy
  check_argo
  "${tool_dir}/check-portal.py" --secret-dir "${synthetic_secret_dir}"
  printf '%s\n' 'DEMO_AWS_HR_EVIDENCE=PASS workloads=frontend,employee-service,hr-service ready=true uid_unchanged=true argo=Synced/Healthy'
}

clear_local_state() {
  local file
  for file in baseline.json positive.json negative.json negative.out attack.ok control.ok current.json; do
    if [[ -e ${state_dir}/${file} ]]; then
      unlink "${state_dir}/${file}"
    fi
  done
  rmdir "${state_dir}" || fail 'unexpected demo state content remains; refusing to remove it'
}

action_reset() {
  if [[ ! -e ${state_dir} ]]; then
    printf '%s\n' 'DEMO_AWS_HR_RESET=PASS remote_delete=0 state=absent no_op=true'
    return
  fi
  if [[ -f ${state_dir}/baseline.json ]]; then
    assert_unchanged
  fi
  stop_socks
  clear_local_state
  printf '%s\n' 'DEMO_AWS_HR_RESET=PASS remote_delete=0 state=cleared no_op=true'
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
readonly action=$1
case ${action} in
  attack|control|evidence|reset|prove) ;;
  *) usage >&2; exit 2 ;;
esac
trap stop_socks EXIT

case ${action} in
  attack) action_attack ;;
  control) action_control ;;
  evidence) action_evidence ;;
  reset) action_reset ;;
  prove)
    action_attack
    action_control
    action_evidence
    action_reset
    ;;
esac
