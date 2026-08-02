#!/usr/bin/env bash
# SCM-01 완료 증거 1: 실제 SSH push와 DB dump+repository data 격리 복원.
# shellcheck disable=SC2029
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly env_file=${SCM01_ENV_FILE:-"$KTC_SECRET_ROOT/gitea/env"}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly postgres_host=${POSTGRES_HOST:-rocky@postgres-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly local_port=${SCM01_LOCAL_PORT:-33000}
readonly restore_port=${SCM01_RESTORE_PORT:-33001}
readonly git_url=ssh://git@git.imcherry5778.xyz:30022/scm-recovery/platform-smoke.git
readonly gitea_image=docker.gitea.com/gitea:1.27.1-rootless@sha256:36cce26be71609091e1236d5b5de2c66a81fb8a7d45756a5fd3b7a28c11733b7
readonly vault_image=hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")
postgres_ssh_options=("${ssh_options[@]}" -o HostKeyAlias=10.10.50.10)

[[ -f "${env_file}" && ! -L "${env_file}" ]] || { echo "SCM-01 env invalid" >&2; exit 1; }
[[ "$(stat -c %u "${env_file}")" -eq "$(id -u)" && "$(stat -c %a "${env_file}")" == 600 ]] || {
  echo "SCM-01 env must be caller-owned mode 0600" >&2
  exit 1
}
local_admin_password=$(awk -F= '$1=="GITEA_LOCAL_ADMIN_PASSWORD"{print substr($0,index($0,"=")+1)}' "${env_file}")
[[ "${local_admin_password}" =~ ^[A-Za-z0-9]{32,}$ ]]

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
curl_config=${temp_dir}/curl.conf
api_response=${temp_dir}/api.json
deploy_key=${temp_dir}/deploy-key
gitea_known_hosts=${temp_dir}/gitea-known-hosts
trusted_keys=${temp_dir}/trusted-host-keys
scanned_keys=${temp_dir}/scanned-host-keys
backup_db=${temp_dir}/gitea.dump
backup_repos=${temp_dir}/repositories.tar
work_repo=${temp_dir}/repo
port_forward_pid=
deploy_key_id=
scaled_down=false
root_reconcile_paused=false
gitea_reconcile_paused=false
backup_helper=false
restore_helper=false
restore_pod=false
restore_pvc=false
restore_db=false

printf 'user = "scm-recovery:%s"\nheader = "Host: git.imcherry5778.xyz"\nheader = "X-Forwarded-Proto: https"\nsilent\nshow-error\n' \
  "${local_admin_password}" >"${curl_config}"

api_call() {
  curl --config "${curl_config}" "$@"
}

stop_port_forward() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
    port_forward_pid=
  fi
}

start_port_forward() {
  local resource=$1
  local port=$2
  local target_ip
  stop_port_forward
  case "${resource}" in
    service/*) target_ip=$(kube -n gitea get "${resource}" -o "jsonpath='{.spec.clusterIP}'") ;;
    pod/*) target_ip=$(kube -n gitea get "${resource}" -o "jsonpath='{.status.podIP}'") ;;
    *) echo "unsupported forward resource: ${resource}" >&2; exit 1 ;;
  esac
  [[ "${target_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "forward target did not resolve to IPv4: ${resource}" >&2
    exit 1
  }
  ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
    -L "${port}:${target_ip}:3000" "${k3s_host}" \
    >"${temp_dir}/port-forward-${port}.log" 2>&1 &
  port_forward_pid=$!
  for _ in $(seq 1 45); do
    kill -0 "${port_forward_pid}" 2>/dev/null || break
    if curl --silent --show-error --fail \
      --header 'Host: git.imcherry5778.xyz' --header 'X-Forwarded-Proto: https' \
      "http://127.0.0.1:${port}/api/healthz" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "port-forward health timeout: ${resource}" >&2
  sed -n '1,80p' "${temp_dir}/port-forward-${port}.log" >&2
  exit 1
}

kube() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

cleanup() {
  local status=$?
  set +e
  stop_port_forward
  [[ "${backup_helper}" == false ]] || kube -n gitea delete pod scm01-backup-helper --ignore-not-found --wait=true >/dev/null
  [[ "${restore_helper}" == false ]] || kube -n gitea delete pod scm01-restore-helper --ignore-not-found --wait=true >/dev/null
  [[ "${restore_pod}" == false ]] || kube -n gitea delete pod scm01-restore --ignore-not-found --wait=true >/dev/null
  [[ "${restore_pvc}" == false ]] || kube -n gitea delete pvc scm01-restore --ignore-not-found --wait=true >/dev/null
  if [[ "${scaled_down}" == true ]]; then
    kube -n gitea scale deployment/gitea --replicas=1 >/dev/null
  fi
  [[ "${gitea_reconcile_paused}" == false ]] || \
    kube -n argocd annotate application gitea argocd.argoproj.io/skip-reconcile- >/dev/null
  [[ "${root_reconcile_paused}" == false ]] || \
    kube -n argocd annotate application platform-root argocd.argoproj.io/skip-reconcile- >/dev/null
  [[ "${scaled_down}" == false ]] || kube -n gitea rollout status deployment/gitea --timeout=180s >/dev/null
  if [[ -n "${deploy_key_id}" ]]; then
    start_port_forward service/gitea-http "${local_port}"
    api_call --request DELETE --output /dev/null \
      "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/keys/${deploy_key_id}"
    stop_port_forward
  fi
  if [[ "${restore_db}" == true ]]; then
    ssh "${postgres_ssh_options[@]}" "${postgres_host}" \
      "sudo -u postgres dropdb --if-exists gitea_scm01_restore" >/dev/null
  fi
  rm -rf "${temp_dir}"
  exit "${status}"
}
trap cleanup EXIT INT TERM

start_port_forward service/gitea-http "${local_port}"
repo_status=$(api_call --output "${api_response}" --write-out '%{http_code}' \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke")
if [[ "${repo_status}" == 404 ]]; then
  repo_status=$(api_call --request POST --header 'Content-Type: application/json' \
    --data-binary '{"name":"platform-smoke","description":"SCM-01 push/restore evidence","private":true}' \
    --output "${api_response}" --write-out '%{http_code}' \
    "http://127.0.0.1:${local_port}/api/v1/user/repos")
  [[ "${repo_status}" == 201 ]]
elif [[ "${repo_status}" == 200 ]]; then
  jq -e '.full_name == "scm-recovery/platform-smoke" and .private == true' "${api_response}" >/dev/null
else
  echo "platform-smoke repository preflight status=${repo_status}" >&2
  exit 1
fi

ssh-keygen -q -t ed25519 -N '' -C scm01-ephemeral -f "${deploy_key}"
jq -n --rawfile key "${deploy_key}.pub" \
  '{title:"scm01-ephemeral-push",key:($key|rtrimstr("\n")),read_only:false}' \
  >"${temp_dir}/deploy-key.json"
key_status=$(api_call --request POST --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/deploy-key.json" --output "${api_response}" --write-out '%{http_code}' \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/keys")
[[ "${key_status}" == 201 ]]
deploy_key_id=$(jq -r '.id' "${api_response}")
[[ "${deploy_key_id}" =~ ^[0-9]+$ ]]

kube -n gitea exec deployment/gitea -c gitea -- sh -c \
  "'for file in /var/lib/gitea/data/ssh/gitea.*.pub; do [ ! -f \"\$file\" ] || cat \"\$file\"; done'" \
  >"${trusted_keys}"
ssh-keyscan -T 5 -p 30022 git.imcherry5778.xyz >"${scanned_keys}" 2>/dev/null
awk '{print $1" "$2}' "${trusted_keys}" | sort -u >"${temp_dir}/trusted-pairs"
while read -r host key_type key_data; do
  if grep -Fxq "${key_type} ${key_data}" "${temp_dir}/trusted-pairs"; then
    printf '%s %s %s\n' "${host}" "${key_type}" "${key_data}"
  fi
done <"${scanned_keys}" >"${gitea_known_hosts}"
[[ -s "${gitea_known_hosts}" ]] || { echo "Gitea SSH host key did not match trusted Pod data" >&2; exit 1; }

GIT_SSH_COMMAND="ssh -F /dev/null -i ${deploy_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${gitea_known_hosts}" \
  git clone --quiet "${git_url}" "${work_repo}"
if git -C "${work_repo}" show-ref --verify --quiet refs/remotes/origin/main; then
  git -C "${work_repo}" checkout -q -B main refs/remotes/origin/main
else
  git -C "${work_repo}" symbolic-ref HEAD refs/heads/main
fi
git -C "${work_repo}" config user.name SCM-01
git -C "${work_repo}" config user.email scm-01@imcherry5778.xyz
printf 'SCM-01 push/restore marker %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >"${work_repo}/README.md"
git -C "${work_repo}" add README.md
git -C "${work_repo}" commit -q -m 'SCM-01 push/restore evidence'
commit_sha=$(git -C "${work_repo}" rev-parse HEAD)
GIT_SSH_COMMAND="ssh -F /dev/null -i ${deploy_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${gitea_known_hosts}" \
  git -C "${work_repo}" push origin HEAD:refs/heads/main
commit_status=$(api_call --output "${api_response}" --write-out '%{http_code}' \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/git/commits/${commit_sha}")
[[ "${commit_status}" == 200 ]]
jq -e --arg sha "${commit_sha}" '.sha == $sha' "${api_response}" >/dev/null
echo "SCM-01 push: repository=scm-recovery/platform-smoke commit=${commit_sha}"

stop_port_forward
kube -n argocd annotate application platform-root argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
root_reconcile_paused=true
kube -n argocd annotate application gitea argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
gitea_reconcile_paused=true
kube -n gitea scale deployment/gitea --replicas=0 >/dev/null
scaled_down=true
kube -n gitea wait --for=delete pod -l app.kubernetes.io/name=gitea --timeout=120s >/dev/null
ssh "${postgres_ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres pg_dump --format=custom gitea" >"${backup_db}"
cat <<YAML | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: scm01-backup-helper
  namespace: gitea
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  containers:
    - name: helper
      image: ${gitea_image}
      command: ["/bin/sh", "-c", "sleep 600"]
      volumeMounts:
        - name: data
          mountPath: /var/lib/gitea
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: gitea-data
YAML
backup_helper=true
kube -n gitea wait --for=condition=Ready pod/scm01-backup-helper --timeout=120s >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n gitea exec scm01-backup-helper -- tar -C /var/lib/gitea -cf - git/repositories" \
  >"${backup_repos}"
kube -n gitea delete pod scm01-backup-helper --wait=true >/dev/null
backup_helper=false
[[ -s "${backup_db}" && -s "${backup_repos}" ]]
kube -n gitea scale deployment/gitea --replicas=1 >/dev/null
kube -n argocd annotate application gitea argocd.argoproj.io/skip-reconcile- >/dev/null
gitea_reconcile_paused=false
kube -n argocd annotate application platform-root argocd.argoproj.io/skip-reconcile- >/dev/null
root_reconcile_paused=false
kube -n gitea rollout status deployment/gitea --timeout=180s >/dev/null
scaled_down=false

restore_db_count=$(ssh "${postgres_ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres psql -XAt -d postgres -c \"SELECT count(*) FROM pg_database WHERE datname='gitea_scm01_restore';\"")
[[ "${restore_db_count}" == 0 ]] || { echo "restore database already exists" >&2; exit 1; }
ssh "${postgres_ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres createdb --owner=gitea_user gitea_scm01_restore"
restore_db=true
ssh "${postgres_ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres pg_restore --no-owner --role=gitea_user --dbname=gitea_scm01_restore" \
  <"${backup_db}"

cat <<YAML | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: scm01-restore
  namespace: gitea
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: scm01-restore-helper
  namespace: gitea
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  containers:
    - name: helper
      image: ${gitea_image}
      command: ["/bin/sh", "-c", "sleep 600"]
      volumeMounts:
        - name: data
          mountPath: /var/lib/gitea
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: scm01-restore
YAML
restore_pvc=true
restore_helper=true
kube -n gitea wait --for=condition=Ready pod/scm01-restore-helper --timeout=120s >/dev/null
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n gitea exec -i scm01-restore-helper -- tar -C /var/lib/gitea -xf -" \
  <"${backup_repos}"
kube -n gitea delete pod scm01-restore-helper --wait=true >/dev/null
restore_helper=false

cat <<YAML | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: scm01-restore
  namespace: gitea
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
      command: ["/bin/sh", "-ec"]
      args:
        - mkdir -p /gitea/runtime/trust; cp /vault/tls/postgres-01.crt /gitea/runtime/trust/postgres-01.crt; chmod 0444 /gitea/runtime/trust/postgres-01.crt; exec vault agent -config=/vault/config/runtime.hcl
      securityContext:
        runAsUser: 100
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: agent, mountPath: /vault/config, readOnly: true}
        - {name: trust, mountPath: /vault/tls, readOnly: true}
        - {name: runtime, mountPath: /gitea/runtime}
        - {name: bootstrap, mountPath: /gitea/bootstrap}
        - {name: agent-tmp, mountPath: /tmp}
        - {name: token, mountPath: /var/run/secrets/vault, readOnly: true}
    - name: restore-config
      image: ${gitea_image}
      command: ["/bin/sh", "-c"]
      args:
        - chmod 0640 /gitea/runtime/app.ini && sed -i '0,/NAME = gitea/s//NAME = gitea_scm01_restore/' /gitea/runtime/app.ini && chmod 0440 /gitea/runtime/app.ini
      securityContext:
        runAsUser: 100
        runAsGroup: 1000
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: runtime, mountPath: /gitea/runtime}
  containers:
    - name: gitea
      image: ${gitea_image}
      command: ["/usr/bin/dumb-init", "--", "/usr/local/bin/gitea"]
      args: ["web", "--config", "/etc/gitea/app.ini"]
      env:
        - {name: PGSSLROOTCERT, value: /etc/gitea/trust/postgres-01.crt}
      ports:
        - {name: http, containerPort: 3000}
      readinessProbe:
        httpGet: {path: /api/healthz, port: http}
        periodSeconds: 3
        failureThreshold: 40
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: data, mountPath: /var/lib/gitea}
        - {name: runtime, mountPath: /etc/gitea, readOnly: true}
        - {name: gitea-tmp, mountPath: /tmp}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: scm01-restore}
    - name: agent
      configMap:
        name: gitea-vault-agent
        items: [{key: runtime.hcl, path: runtime.hcl}]
    - {name: trust, configMap: {name: gitea-trust-bundles}}
    - {name: runtime, emptyDir: {medium: Memory, sizeLimit: 2Mi}}
    - {name: bootstrap, emptyDir: {medium: Memory, sizeLimit: 1Mi}}
    - {name: agent-tmp, emptyDir: {medium: Memory, sizeLimit: 8Mi}}
    - {name: gitea-tmp, emptyDir: {sizeLimit: 1Gi}}
    - name: token
      projected:
        sources:
          - serviceAccountToken: {path: token, expirationSeconds: 600, audience: vault}
YAML
restore_pod=true
kube -n gitea wait --for=condition=Ready pod/scm01-restore --timeout=180s >/dev/null
start_port_forward pod/scm01-restore "${restore_port}"
restore_status=$(api_call --output "${api_response}" --write-out '%{http_code}' \
  "http://127.0.0.1:${restore_port}/api/v1/repos/scm-recovery/platform-smoke/git/commits/${commit_sha}")
[[ "${restore_status}" == 200 ]]
jq -e --arg sha "${commit_sha}" '.sha == $sha' "${api_response}" >/dev/null
echo "SCM-01 restore: isolated-db=gitea_scm01_restore isolated-pvc=scm01-restore commit=${commit_sha}"

stop_port_forward
kube -n gitea delete pod scm01-restore --wait=true >/dev/null
restore_pod=false
kube -n gitea delete pvc scm01-restore --wait=true >/dev/null
restore_pvc=false
ssh "${postgres_ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres dropdb gitea_scm01_restore"
restore_db=false
start_port_forward service/gitea-http "${local_port}"
api_call --request DELETE --output /dev/null \
  "http://127.0.0.1:${local_port}/api/v1/repos/scm-recovery/platform-smoke/keys/${deploy_key_id}"
deploy_key_id=
echo "SCM-01 push/restore: 실제 SSH push, 격리 앱 복원 commit 조회, 임시 key/DB/PVC/Pod 정리 통과"
