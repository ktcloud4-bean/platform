#!/usr/bin/env bash
# AWX-03 완료 증거의 NetworkPolicy와 현재 허용/차단 경로만 판정한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

mode=${1:-}

verify_policy() {
  local expected_root=${AWX03_EXPECTED_ROOT_REVISION:?root commit SHA가 필요하다}
  local expected_child=${AWX03_EXPECTED_CHILD_REVISION:?AWX child commit SHA가 필요하다}
  [[ ${expected_root} =~ ^[0-9a-f]{40}$ && ${expected_child} =~ ^[0-9a-f]{40}$ ]]

  local argo policies
  argo=$(remote_kubectl -n argocd get application platform-root awx -o json)
  jq -e --arg root "${expected_root}" --arg child "${expected_child}" '
    def app($name): .items[] | select(.metadata.name == $name);
    (app("platform-root") | .spec.source.targetRevision == $root and .status.sync.revision == $root and .status.sync.status == "Synced" and .status.health.status == "Healthy") and
    (app("awx") | .spec.source.targetRevision == $child and .status.sync.revision == $child and .status.sync.status == "Synced" and .status.health.status == "Healthy")
  ' <<<"${argo}" >/dev/null

  policies=$(remote_kubectl -n awx get networkpolicy -o json)
  jq -e '
    ([.items[].metadata.name] | sort) == [
      "awx-bootstrap-kubernetes-api-egress", "awx-default-deny", "awx-dns-egress",
      "awx-execution-kubernetes-api-egress", "awx-execution-verifier-egress", "awx-hook-vault-agent-egress",
      "awx-operator-kubernetes-api-egress", "awx-postgres-egress", "awx-provision-web-egress",
      "awx-runtime-kubernetes-api-egress", "awx-task-web-egress", "awx-vault-agent-egress",
      "awx-verifier-execution-ingress", "awx-web-keycloak-egress", "awx-web-pomerium-ingress", "awx-web-runtime-ingress"
    ] and
    ([.items[] | select(.metadata.name == "awx-default-deny") | .spec.podSelector == {} and (.spec.policyTypes | sort) == ["Egress", "Ingress"]] | length) == 1
  ' <<<"${policies}" >/dev/null

  remote_kubectl -n awx rollout status deploy/awx-web --timeout=180s >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-task --timeout=180s >/dev/null
  remote_kubectl -n awx rollout status deploy/awx-verifier --timeout=120s >/dev/null

  echo "AWX03_POLICY=PASS root=${expected_root} child=${expected_child} default_deny=exact policies=16"
}

verify_paths() {
  local phase
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} -n awx create -f - -o name" <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: awx03-path-probe
  namespace: awx
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: probe
      image: curlimages/curl:8.10.1
      command: [sh, -ec]
      args:
        - >-
          code=$(curl --connect-timeout 3 --max-time 5 -sS -o /dev/null -w '%{http_code}' http://10.10.50.10:22/ || true);
          test "$code" = 000
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
YAML
  for _ in {1..10}; do
    phase=$(remote_kubectl -n awx get pod awx03-path-probe -o jsonpath='{.status.phase}')
    [[ ${phase} == Succeeded ]] && break
    sleep 1
  done
  [[ ${phase} == Succeeded ]]
  remote_kubectl -n awx delete pod awx03-path-probe --wait=true >/dev/null

  # kube-router의 Service DNAT 전후 판정까지 포함해, 실제 AWX container에서 필요한 네 경로를 확인한다.
  remote_kubectl -n awx exec deploy/awx-web -c awx-web -- python3 - <<'PY'
import socket
checks = [("postgres-01.imcherry5778.xyz", 5432), ("sso.imcherry5778.xyz", 443)]
for host, port in checks:
    with socket.create_connection((host, port), timeout=5):
        pass
print("web_paths=postgres,keycloak")
PY
  remote_kubectl -n awx exec deploy/awx-task -c awx-task -- python3 - <<'PY'
import socket
for host, port in [("postgres-01.imcherry5778.xyz", 5432), ("awx-service.awx.svc.cluster.local", 80)]:
    with socket.create_connection((host, port), timeout=5):
        pass
print("task_paths=postgres,web")
PY
  remote_kubectl -n awx exec deploy/awx-operator-controller-manager -c awx-manager -- ls /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null

  echo 'AWX03_PATHS=PASS web=postgres,keycloak task=postgres,web operator=kubernetes_api forbidden_rfc1918_tcp22=blocked'
}

case ${mode} in
  policy) verify_policy ;;
  paths) verify_paths ;;
  *) echo "사용법: $0 policy|paths" >&2; exit 2 ;;
esac
