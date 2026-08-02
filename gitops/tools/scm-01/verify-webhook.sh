#!/usr/bin/env bash
# SCM-01 완료 증거 3: repo 범위 webhook 전달 성공과 잘못된 secret 403 거부.
# shellcheck disable=SC2029
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly env_file=${SCM01_ENV_FILE:-"$KTC_SECRET_ROOT/gitea/env"}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly local_port=${SCM01_LOCAL_PORT:-33000}
readonly vault_image=hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54
readonly python_image=docker.io/library/python:3.14.1-alpine3.23@sha256:b80c82b1a282283bd3e3cd3c6a4c895d56d1385879c8c82fa673e9eb4d6d4aa5
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

[[ -f "${env_file}" && ! -L "${env_file}" ]] || { echo "SCM-01 env invalid" >&2; exit 1; }
[[ "$(stat -c %u "${env_file}")" -eq "$(id -u)" && "$(stat -c %a "${env_file}")" == 600 ]] || {
  echo "SCM-01 env must be caller-owned mode 0600" >&2
  exit 1
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
curl_config=${temp_dir}/curl.conf
api_response=${temp_dir}/api.json
webhook_secret_file=${temp_dir}/webhook-secret
local_admin_password=$(awk -F= '$1=="GITEA_LOCAL_ADMIN_PASSWORD"{print substr($0,index($0,"=")+1)}' "${env_file}")
awk -F= '$1=="GITEA_WEBHOOK_SECRET"{print substr($0,index($0,"=")+1)}' "${env_file}" >"${webhook_secret_file}"
[[ "${local_admin_password}" =~ ^[A-Za-z0-9]{32,}$ ]]
[[ "$(tr -d '\n' <"${webhook_secret_file}" | wc -c)" -eq 64 ]]
printf 'user = "scm-recovery:%s"\nheader = "Host: git.imcherry5778.xyz"\nheader = "X-Forwarded-Proto: https"\nsilent\nshow-error\n' \
  "${local_admin_password}" >"${curl_config}"

port_forward_pid=
hook_id=
wrong_hook_id=
receiver_created=false
api_call() { curl --config "${curl_config}" "$@"; }
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

cleanup() {
  local status=$?
  set +e
  if [[ -n "${wrong_hook_id}" ]]; then
    api_call --request DELETE --output /dev/null \
      "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/hooks/${wrong_hook_id}"
  fi
  if [[ -n "${hook_id}" ]]; then
    api_call --request DELETE --output /dev/null \
      "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/hooks/${hook_id}"
  fi
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null
    wait "${port_forward_pid}" 2>/dev/null
  fi
  if [[ "${receiver_created}" == true ]]; then
    kube -n gitea delete pod scm01-webhook-receiver --ignore-not-found --wait=true >/dev/null
    kube -n gitea delete service scm01-webhook-receiver --ignore-not-found >/dev/null
    kube -n gitea delete configmap scm01-webhook-receiver scm01-webhook-agent --ignore-not-found >/dev/null
  fi
  rm -rf "${temp_dir}"
  exit "${status}"
}
trap cleanup EXIT INT TERM

kubectl -n gitea create configmap scm01-webhook-receiver \
  --from-file="server.py=${repo_root}/gitops/tools/scm-01/webhook-receiver.py" \
  --dry-run=client -o yaml \
  | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" >/dev/null
cat <<YAML | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: scm01-webhook-agent
  namespace: gitea
data:
  receiver.hcl: |
    exit_after_auth = true
    pid_file = "/tmp/vault-agent.pid"
    vault {
      address = "https://vault.vault.svc.cluster.local:8200"
      ca_cert = "/vault/tls/vault.crt"
      retry { num_retries = 12 }
    }
    auto_auth {
      method "kubernetes" {
        mount_path = "auth/kubernetes"
        config = { role = "gitea", token_path = "/var/run/secrets/vault/token" }
      }
    }
    template {
      destination = "/receiver-secret/webhook-secret"
      perms = "0440"
      error_on_missing_key = true
      contents = <<EOT
    {{- with secret "kv/data/gitea/runtime" -}}{{ .Data.data.webhook_secret }}{{- end -}}
    EOT
    }
---
apiVersion: v1
kind: Service
metadata:
  name: scm01-webhook-receiver
  namespace: gitea
spec:
  selector: {app: scm01-webhook-receiver}
  ports:
    - {name: http, port: 8080, targetPort: http}
---
apiVersion: v1
kind: Pod
metadata:
  name: scm01-webhook-receiver
  namespace: gitea
  labels: {app: scm01-webhook-receiver}
spec:
  restartPolicy: Never
  serviceAccountName: gitea
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  initContainers:
    - name: vault-agent
      image: ${vault_image}
      args: ["agent", "-config=/vault/config/receiver.hcl"]
      securityContext:
        runAsUser: 100
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: agent, mountPath: /vault/config, readOnly: true}
        - {name: trust, mountPath: /vault/tls, readOnly: true}
        - {name: receiver-secret, mountPath: /receiver-secret}
        - {name: agent-tmp, mountPath: /tmp}
        - {name: token, mountPath: /var/run/secrets/vault, readOnly: true}
  containers:
    - name: receiver
      image: ${python_image}
      command: ["python3", "/receiver/server.py"]
      ports: [{name: http, containerPort: 8080}]
      readinessProbe:
        httpGet: {path: /healthz, port: http}
        periodSeconds: 2
        failureThreshold: 30
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: receiver-code, mountPath: /receiver, readOnly: true}
        - {name: receiver-secret, mountPath: /receiver-secret, readOnly: true}
        - {name: receiver-tmp, mountPath: /tmp}
  volumes:
    - {name: agent, configMap: {name: scm01-webhook-agent}}
    - {name: receiver-code, configMap: {name: scm01-webhook-receiver}}
    - {name: trust, configMap: {name: gitea-trust-bundles}}
    - {name: receiver-secret, emptyDir: {medium: Memory, sizeLimit: 1Mi}}
    - {name: agent-tmp, emptyDir: {medium: Memory, sizeLimit: 8Mi}}
    - {name: receiver-tmp, emptyDir: {sizeLimit: 8Mi}}
    - name: token
      projected:
        sources:
          - serviceAccountToken: {path: token, expirationSeconds: 600, audience: vault}
YAML
receiver_created=true
kube -n gitea wait --for=condition=Ready pod/scm01-webhook-receiver --timeout=120s >/dev/null

service_ip=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n gitea get service/gitea-http -o jsonpath='{.spec.clusterIP}'")
[[ "${service_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  echo "gitea-http service did not resolve to IPv4" >&2
  exit 1
}
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
  -L "${local_port}:${service_ip}:3000" "${k3s_host}" \
  >"${temp_dir}/port-forward.log" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 30); do
  curl --silent --show-error --fail --header 'Host: git.imcherry5778.xyz' \
    "http://127.0.0.1:${local_port}/api/healthz" >/dev/null 2>&1 && break
  sleep 1
done

jq -n --rawfile secret "${webhook_secret_file}" '{
  type:"gitea",name:"SCM-01 CI repository webhook",
  config:{url:"http://scm01-webhook-receiver.gitea.svc.cluster.local:8080/hook",
    content_type:"json",secret:($secret|rtrimstr("\n"))},
  events:["push"],active:true,branch_filter:"main"
}' >"${temp_dir}/hook-correct.json"
hook_status=$(api_call --request POST --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/hook-correct.json" --output "${api_response}" --write-out '%{http_code}' \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/hooks")
[[ "${hook_status}" == 201 ]]
hook_id=$(jq -r '.id' "${api_response}")
[[ "${hook_id}" =~ ^[0-9]+$ ]]

test_status=$(api_call --request POST --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/hooks/${hook_id}/tests?ref=main")
[[ "${test_status}" == 204 ]]
for _ in $(seq 1 30); do
  kube -n gitea logs scm01-webhook-receiver -c receiver \
    | grep -Fq 'webhook-signature=valid target=repository' && break
  sleep 1
done
kube -n gitea logs scm01-webhook-receiver -c receiver \
  | grep -Fq 'webhook-signature=valid target=repository'

jq -n '{
  type:"gitea",name:"SCM-01 wrong-secret negative webhook",
  config:{url:"http://scm01-webhook-receiver.gitea.svc.cluster.local:8080/hook",
    content_type:"json",secret:"0000000000000000000000000000000000000000000000000000000000000000"},
  events:["push"],active:true,branch_filter:"main"
}' >"${temp_dir}/hook-wrong.json"
hook_status=$(api_call --request POST --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/hook-wrong.json" --output "${api_response}" --write-out '%{http_code}' \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/hooks")
[[ "${hook_status}" == 201 ]]
wrong_hook_id=$(jq -r '.id' "${api_response}")
[[ "${wrong_hook_id}" =~ ^[0-9]+$ ]]
test_status=$(api_call --request POST --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/hooks/${wrong_hook_id}/tests?ref=main")
[[ "${test_status}" == 204 ]]
for _ in $(seq 1 30); do
  kube -n gitea logs scm01-webhook-receiver -c receiver \
    | grep -Fq 'webhook-signature=invalid target=repository' && break
  sleep 1
done
kube -n gitea logs scm01-webhook-receiver -c receiver \
  | grep -Fq 'webhook-signature=invalid target=repository'

api_call --request DELETE --output /dev/null \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/hooks/${wrong_hook_id}"
wrong_hook_id=
api_call --request DELETE --output /dev/null \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/hooks/${hook_id}"
hook_id=
kube -n gitea delete pod scm01-webhook-receiver --wait=true >/dev/null
kube -n gitea delete service scm01-webhook-receiver >/dev/null
kube -n gitea delete configmap scm01-webhook-receiver scm01-webhook-agent >/dev/null
receiver_created=false
echo "SCM-01 webhook: repo scope, correct HMAC delivery 204, wrong secret 403, 임시 hook/receiver 정리 통과"
