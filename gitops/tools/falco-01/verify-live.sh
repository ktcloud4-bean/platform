#!/usr/bin/env bash
set -euo pipefail

readonly expected_config_revision=${FALCO01_EXPECTED_CONFIG_REVISION:?Falco 설정 commit SHA가 필요하다}
readonly expected_root_revision=${FALCO01_EXPECTED_ROOT_REVISION:?platform-root pointer commit SHA가 필요하다}
readonly pre_available_mib=${FALCO01_PRE_AVAILABLE_MIB:?배포 전 k3s available MiB가 필요하다}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly falco_image_index_digest=sha256:d0cfe422d6ac0e0f20857798f46c7d7273210e1b064b22821e4e6e7f843cde6b
readonly test_image='docker.io/library/busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0'
readonly test_rule='FALCO-01 Test Runtime File Write'
readonly noise_window_seconds=60
readonly noise_max_events=1
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo '검증 실패 단계=deployment 원인=인증된 known_hosts 파일이 없다.' >&2
  exit 1
}
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] || {
  echo '검증 실패 단계=deployment 원인=immutable commit SHA 형식이 아니다.' >&2
  exit 1
}
[[ ${pre_available_mib} =~ ^[0-9]+$ ]] || {
  echo '검증 실패 단계=capacity 원인=배포 전 available MiB가 정수가 아니다.' >&2
  exit 1
}

remote_kubectl() {
  # 인자는 이 스크립트가 만든 비밀 없는 고정값만 전달한다.
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

fail() {
  local stage=$1
  shift
  echo "검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

argo_state=''
for _ in $(seq 1 36); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root falco -o json 2>/dev/null || true)
  if jq -e \
    --arg root_rev "${expected_root_revision}" \
    --arg config "${expected_config_revision}" '
      ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
      ([.items[] | select(.metadata.name == "falco")][0] // {}) as $falco |
      $root_app.status.sync.status == "Synced" and
      $root_app.status.health.status == "Healthy" and
      $root_app.spec.source.targetRevision == $root_rev and
      $root_app.status.sync.revision == $root_rev and
      $falco.status.sync.status == "Synced" and
      $falco.status.health.status == "Healthy" and
      $falco.spec.source.targetRevision == $config and
      $falco.status.sync.revision == $config
    ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if ! jq -e \
  --arg root "${expected_root_revision}" \
  --arg config "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "falco")][0] // {}) as $falco_app |
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $falco_app.status.sync.status == "Synced" and
    $falco_app.status.health.status == "Healthy" and
    $falco_app.spec.source.targetRevision == $config and
    $falco_app.status.sync.revision == $config
  ' <<<"${argo_state}" >/dev/null; then
  fail deployment 'platform-root 또는 Falco child가 immutable SHA에서 Synced/Healthy가 아니다.'
fi
echo "Argo=PASS root=${expected_root_revision} falco=${expected_config_revision}"

if ! remote_kubectl -n falco rollout status daemonset/falco --timeout=120s >/dev/null; then
  pod_summary=$(remote_kubectl -n falco get pods -l app.kubernetes.io/name=falco -o json 2>/dev/null \
    | jq -c '[.items[] | {name:.metadata.name,phase:.status.phase,restarts:([.status.containerStatuses[]?.restartCount] | add // 0),waiting:[.status.containerStatuses[]?.state.waiting.reason]}]' || true)
  lifecycle=$(remote_kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=120 2>/dev/null || true)
  if grep -Eqi 'modern.?ebpf|bpf.*(failed|error|denied)|driver.*(failed|error)' <<<"${lifecycle}"; then
    fail kernel/driver "modern eBPF 초기화 실패; Pod=${pod_summary}"
  fi
  fail deployment "Falco DaemonSet Ready 실패; Pod=${pod_summary}"
fi

daemonset_state=$(remote_kubectl -n falco get daemonset falco -o json)
jq -e '
  .status.desiredNumberScheduled == 1 and
  .status.numberReady == 1 and
  .status.numberAvailable == 1 and
  (.status.numberUnavailable // 0) == 0 and
  .spec.template.spec.automountServiceAccountToken == false and
  (.spec.template.spec.containers[] | select(.name == "falco") |
    .securityContext.privileged == false and
    .securityContext.allowPrivilegeEscalation == false and
    .securityContext.seccompProfile.type == "RuntimeDefault" and
    .securityContext.seLinuxOptions.type == "spc_t" and
    (.securityContext.capabilities.drop == ["ALL"]) and
    ((.securityContext.capabilities.add | sort) == ["BPF", "PERFMON", "SYS_PTRACE", "SYS_RESOURCE"]))
' <<<"${daemonset_state}" >/dev/null || fail deployment 'Falco Ready 또는 최소권한 선언이 기대와 다르다.'

falco_pod=$(remote_kubectl -n falco get pod -l app.kubernetes.io/name=falco -o jsonpath='{.items[0].metadata.name}')
falco_pod_state=$(remote_kubectl -n falco get pod "${falco_pod}" -o json)
image_id=$(jq -r '.status.containerStatuses[] | select(.name == "falco") | .imageID' <<<"${falco_pod_state}")
[[ ${image_id} == *"${falco_image_index_digest}"* || ${image_id} == *sha256:9f02feb5544a54a4ca2974bd8ab3a0cca287f3fe7c697d612814357af0cc55e5* ]] \
  || fail deployment '실행 Falco imageID가 고정한 index/amd64 digest와 다르다.'
echo "FalcoPod=PASS pod=${falco_pod} ready=1/1 engine=modern_ebpf"

test_suffix=$(date -u +%Y%m%d%H%M%S)
test_namespace="falco-01-test-${test_suffix}"
test_pod="falco-01-event-${test_suffix}"
test_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
test_cleaned=false

cleanup_test() {
  if [[ ${test_cleaned} == false ]]; then
    remote_kubectl delete namespace "${test_namespace}" --wait=true --timeout=60s >/dev/null 2>&1 || true
    test_cleaned=true
  fi
}
trap cleanup_test EXIT HUP INT TERM

remote_kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${test_namespace}
  labels:
    app.kubernetes.io/part-of: falco-01-verification
---
apiVersion: v1
kind: Pod
metadata:
  name: ${test_pod}
  namespace: ${test_namespace}
  labels:
    app.kubernetes.io/name: falco-01-event
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  restartPolicy: Never
  activeDeadlineSeconds: 30
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: event
      image: ${test_image}
      imagePullPolicy: IfNotPresent
      command: ["/bin/sh", "-c"]
      args:
        - 'sleep 3; : > /tmp/falco-01-runtime-event; sleep 3'
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          cpu: 20m
          memory: 16Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 8Mi
YAML

remote_kubectl -n "${test_namespace}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${test_pod}" --timeout=60s >/dev/null \
  || fail rule_match '비특권 test Pod의 실제 파일 쓰기 실행이 완료되지 않았다.'
sleep 3

test_log_lines=$(remote_kubectl -n falco logs "${falco_pod}" -c falco --since-time="${test_start}" 2>/dev/null || true)
test_events=$(jq -Rsc \
  --arg rule "${test_rule}" \
  --arg ns "${test_namespace}" \
  --arg pod "${test_pod}" '
    [splits("\n") | fromjson? |
      select(.rule == $rule and
             .output_fields["k8s.ns.name"] == $ns and
             .output_fields["k8s.pod.name"] == $pod)]
  ' <<<"${test_log_lines}")
test_count=$(jq 'length' <<<"${test_events}")

if (( test_count < 1 )); then
  metrics=$(remote_kubectl get --raw "/api/v1/namespaces/falco/pods/${falco_pod}:8765/proxy/metrics" 2>/dev/null || true)
  if awk -v rule="${test_rule}" '
    index($0, "falcosecurity_falco_rules_matches_total{") == 1 && index($0, "rule_name=\"" rule "\"") {
      if ($NF + 0 > 0) found=1
    }
    END {exit(found ? 0 : 1)}
  ' <<<"${metrics}"; then
    fail output 'rule counter는 증가했지만 JSON stdout에 기대 event가 없다.'
  fi
  fail rule_match '실제 파일 쓰기는 완료됐지만 전용 rule counter와 JSON event가 없다.'
fi

jq -c '.[0] | {
  time,
  rule,
  priority,
  namespace:.output_fields["k8s.ns.name"],
  pod:.output_fields["k8s.pod.name"],
  container:.output_fields["container.name"]
}' <<<"${test_events}" | sed 's/^/TestEvent=PASS /'

cleanup_test
remote_kubectl get namespace "${test_namespace}" >/dev/null 2>&1 \
  && fail cleanup 'test namespace가 남았다.'
echo 'TestCleanup=PASS namespace=absent'

sleep 1
noise_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "NoiseWindow=START seconds=${noise_window_seconds} start=${noise_start}"
sleep "${noise_window_seconds}"
noise_log_lines=$(remote_kubectl -n falco logs "${falco_pod}" -c falco --since-time="${noise_start}" 2>/dev/null || true)
noise_events=$(jq -Rsc \
  --arg test_rule "${test_rule}" '
    [splits("\n") | fromjson? | select(.rule? != null and .rule != $test_rule)]
  ' <<<"${noise_log_lines}")
noise_count=$(jq 'length' <<<"${noise_events}")
noise_hourly_rate=$((noise_count * 3600 / noise_window_seconds))
top_rule=$(jq -r '
  if length == 0 then "none|0"
  else group_by(.rule) | map({rule:.[0].rule,count:length}) | sort_by(-.count,.rule) | .[0] | [.rule,(.count|tostring)] | join("|")
  end
' <<<"${noise_events}")
IFS='|' read -r top_rule_name top_rule_count <<<"${top_rule}"
top_rule_hourly_rate=$((top_rule_count * 3600 / noise_window_seconds))
echo "NoiseWindow=RESULT seconds=${noise_window_seconds} total=${noise_count} hourly_rate=${noise_hourly_rate} top_rule=${top_rule_name} top_rule_count=${top_rule_count} top_rule_hourly_rate=${top_rule_hourly_rate}"
(( noise_count <= noise_max_events )) \
  || fail noise "고정 창 event ${noise_count}건이 기준 ${noise_max_events}건을 넘었다; 상위 rule=${top_rule_name}."
echo 'NoiseWindow=PASS'

capacity=$(ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'REMOTE'
set -euo pipefail
k='sudo -n /usr/local/bin/k3s kubectl'
free -m | awk '/Mem:/{printf "POST_AVAILABLE_MIB=%s\n",$7} /Swap:/{printf "POST_SWAP_USED_MIB=%s\n",$3}'
df -P / | awk 'NR==2{printf "POST_ROOT_USE_PERCENT=%s\n",$5}'
${k} top node --no-headers | awk '{printf "POST_NODE_CPU=%s\nPOST_NODE_MEMORY=%s\n",$2,$4}'
${k} -n falco top pod -l app.kubernetes.io/name=falco --containers --no-headers \
  | awk '$2=="falco"{printf "FALCO_CPU=%s\nFALCO_MEMORY=%s\n",$3,$4}'
${k} get pvc -A -o json | jq -r '[.items[].spec.resources.requests.storage] | "POST_PVC_REQUESTS="+join("+")'
REMOTE
)
post_available_mib=$(awk -F= '$1=="POST_AVAILABLE_MIB"{print $2}' <<<"${capacity}")
post_swap_used_mib=$(awk -F= '$1=="POST_SWAP_USED_MIB"{print $2}' <<<"${capacity}")
[[ ${post_available_mib} =~ ^[0-9]+$ && ${post_swap_used_mib} =~ ^[0-9]+$ ]] \
  || fail capacity '배포 후 capacity 값을 읽지 못했다.'
capacity_delta_mib=$((post_available_mib - pre_available_mib))
printf '%s\n' "${capacity}"
(( post_available_mib >= 8192 )) || fail capacity 'k3s available이 8GiB 정지선 아래다.'
(( post_swap_used_mib == 0 )) || fail capacity 'k3s swap 사용량이 0이 아니다.'
echo "CAPACITY=PASS PRE_AVAILABLE_MIB=${pre_available_mib} POST_AVAILABLE_MIB=${post_available_mib} DELTA_MIB=${capacity_delta_mib}"

echo 'FALCO-01 live verification: PASS'
