#!/usr/bin/env bash
# shellcheck disable=SC2029
# REG-01 backlog의 완료 증거 5개만 한 번씩 판정하고 임시 자원을 정리한다.
set -Eeuo pipefail

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly env_file=${secret_root}/harbor/env
readonly vault_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly k3s_host=${K3S_HOST:-rocky@10.10.20.10}
readonly k3s_known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly pg_known_hosts=${PG_SSH_KNOWN_HOSTS:-/home/imcherry/.ansible/pg01/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly registry=harbor.imcherry5778.xyz
readonly busybox_digest=sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0
readonly hello_digest=sha256:b44f8077f3cc983f21adf071c813599ff805af75196a456a326253c7b3357c48
readonly busybox_source=docker://docker.io/library/busybox@${busybox_digest}
readonly hello_source=docker://docker.io/library/hello-world@${hello_digest}

for private_file in "${env_file}" "${vault_token_file}"; do
  [[ -f ${private_file} && ! -L ${private_file} && $(stat -c %a "${private_file}") == 600 ]] || {
    echo "private input이 없거나 mode 0600이 아니다: ${private_file}" >&2
    exit 1
  }
done

umask 077
temp_root=$(mktemp -d)
readonly temp_root
readonly state_file=${temp_root}/harbor-state.json
readonly auth_file=${temp_root}/containers-auth.json
readonly live_inventory=${temp_root}/s3-live.json
readonly restore_inventory=${temp_root}/s3-restore.json
readonly restore_manifest=${temp_root}/harbor-restore.yaml
readonly pg_dump_path=/var/tmp/reg-01-harbor-restore.dump
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${k3s_known_hosts}"
  -o PasswordAuthentication=no
)
readonly pg_ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${pg_known_hosts}"
  -o PasswordAuthentication=no
)

live_tunnel_pid=
restore_tunnel_pid=
projects_created=false
restore_namespace_created=false
restore_db_created=false
vault_role_expanded=false
pulled_image=

vault_role_main() {
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault write auth/kubernetes/role/harbor bound_service_account_names=harbor bound_service_account_namespaces=harbor audience=vault token_policies=harbor token_no_default_policy=true token_ttl=15m token_max_ttl=1h >/dev/null'"
}

cleanup() {
  set +e
  if [[ -n ${restore_tunnel_pid} ]]; then
    kill "${restore_tunnel_pid}" 2>/dev/null
    wait "${restore_tunnel_pid}" 2>/dev/null
  fi
  if [[ ${restore_namespace_created} == true ]]; then
    ssh "${ssh_options[@]}" "${k3s_host}" \
      "${kubectl_command} delete namespace harbor-restore --wait=true --timeout=120s" >/dev/null
  fi
  if [[ ${vault_role_expanded} == true ]]; then
    vault_role_main >/dev/null
  fi
  if [[ ${restore_db_created} == true ]]; then
    ssh "${pg_ssh_options[@]}" rocky@10.10.50.10 \
      "sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='harbor_restore' AND pid <> pg_backend_pid();\" >/dev/null && sudo -u postgres dropdb --if-exists harbor_restore && sudo rm -f ${pg_dump_path}" >/dev/null
  else
    ssh "${pg_ssh_options[@]}" rocky@10.10.50.10 "sudo rm -f ${pg_dump_path}" >/dev/null 2>&1
  fi
  if [[ ${projects_created} == true && -n ${live_tunnel_pid} ]]; then
    python3 "${repo_root}/gitops/tools/reg-01/harbor-api.py" --env-file "${env_file}" cleanup >/dev/null
  fi
  [[ -n ${pulled_image} ]] && podman rmi --force "${pulled_image}" >/dev/null 2>&1
  if [[ -n ${live_tunnel_pid} ]]; then
    kill "${live_tunnel_pid}" 2>/dev/null
    wait "${live_tunnel_pid}" 2>/dev/null
  fi
  [[ ${temp_root} == /tmp/* ]] && rm -rf -- "${temp_root}"
}
trap cleanup EXIT INT TERM

live_service_ip=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n harbor get service harbor -o jsonpath='{.spec.clusterIP}'")
[[ ${live_service_ip} =~ ^[0-9]+(\.[0-9]+){3}$ ]] || { echo "live Harbor ClusterIP가 IPv4가 아니다" >&2; exit 1; }
ssh "${ssh_options[@]}" -N -o ExitOnForwardFailure=yes \
  -L "18443:${live_service_ip}:80" -L 18333:10.10.50.20:8333 "${k3s_host}" \
  >"${temp_root}/live-port-forward.log" 2>&1 &
live_tunnel_pid=$!
live_ready=false
for _ in {1..30}; do
  if curl --silent --fail http://127.0.0.1:18443/api/v2.0/ping >/dev/null; then
    live_ready=true
    break
  fi
  if ! kill -0 "${live_tunnel_pid}" 2>/dev/null; then
    echo "live Harbor SSH tunnel이 준비 전에 종료됐다" >&2
    sed -n '1,120p' "${temp_root}/live-port-forward.log" >&2
    exit 1
  fi
  sleep 1
done
if [[ ${live_ready} != true ]]; then
  echo "live Harbor SSH tunnel 준비 timeout" >&2
  sed -n '1,120p' "${temp_root}/live-port-forward.log" >&2
  exit 1
fi

projects_created=true
python3 "${repo_root}/gitops/tools/reg-01/harbor-api.py" \
  --env-file "${env_file}" --state-file "${state_file}" setup
python3 - "${state_file}" "${auth_file}" <<'PY'
import base64, json, os, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
token = base64.b64encode(f"{state['robot_name']}:{state['robot_secret']}".encode()).decode()
auth = {"auths": {
    "harbor.imcherry5778.xyz": {"auth": token},
    "127.0.0.1:28443": {"auth": token},
}}
fd = os.open(sys.argv[2], os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    json.dump(auth, stream)
PY

readonly pushpull_ref=${registry}/reg01-evidence/pushpull:evidence
skopeo copy --dest-authfile "${auth_file}" "${busybox_source}" "docker://${pushpull_ref}" >/dev/null
pushed_digest=$(skopeo inspect --authfile "${auth_file}" "docker://${pushpull_ref}" --format '{{.Digest}}')
[[ ${pushed_digest} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "push 뒤 manifest digest 형식이 잘못됐다" >&2; exit 1; }
podman pull --quiet --authfile "${auth_file}" "${pushpull_ref}" >/dev/null
pulled_image=${pushpull_ref}
pulled_digest=$(podman image inspect "${pushpull_ref}" --format '{{.Digest}}')
[[ ${pulled_digest} == "${pushed_digest}" ]] || { echo "다른 client pull digest 불일치" >&2; exit 1; }
echo "push/pull 성공: skopeo -> Podman, digest=${pushed_digest}"

if skopeo copy --dest-authfile "${auth_file}" "${busybox_source}" \
  "docker://${registry}/reg01-denied/forbidden:must-fail" >"${temp_root}/denied.log" 2>&1; then
  echo "project-scoped robot이 다른 project에 push했다" >&2
  exit 1
fi
skopeo inspect --authfile "${auth_file}" "docker://${pushpull_ref}" >/dev/null
echo "robot account 대조 성공: 지정 project push/pull=허용, 다른 project push=거부"

skopeo copy --dest-authfile "${auth_file}" "${hello_source}" \
  "docker://${registry}/reg01-evidence/retention:remove" >/dev/null
sleep 2
skopeo copy --dest-authfile "${auth_file}" "${busybox_source}" \
  "docker://${registry}/reg01-evidence/retention:keep" >/dev/null
python3 "${repo_root}/gitops/tools/reg-01/harbor-api.py" \
  --env-file "${env_file}" --state-file "${state_file}" retention
if skopeo inspect --authfile "${auth_file}" \
  "docker://${registry}/reg01-evidence/retention:remove" >/dev/null 2>&1; then
  echo "retention 제거 대상 tag가 pull 가능하다" >&2
  exit 1
fi
skopeo inspect --authfile "${auth_file}" \
  "docker://${registry}/reg01-evidence/retention:keep" >/dev/null

python3 "${repo_root}/gitops/tools/reg-01/s3-client.py" --env-file "${env_file}" \
  --ca-file "${repo_root}/gitops/apps/harbor/files/s3.crt" \
  --connect-host 127.0.0.1 --connect-port 18333 inventory >"${live_inventory}"
if ssh "${pg_ssh_options[@]}" rocky@10.10.50.10 \
  "sudo -u postgres psql -Atqc \"SELECT 1 FROM pg_database WHERE datname='harbor_restore'\"" | grep -q 1; then
  echo "기존 harbor_restore DB가 남아 있어 복원 검증을 중단한다" >&2
  exit 1
fi
restore_db_created=true
ssh "${pg_ssh_options[@]}" rocky@10.10.50.10 \
  "sudo rm -f ${pg_dump_path} && sudo -u postgres pg_dump --format=custom --file=${pg_dump_path} harbor && sudo -u postgres createdb --owner=harbor_user harbor_restore && sudo -u postgres pg_restore --no-owner --role=harbor_user --dbname=harbor_restore ${pg_dump_path} && sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c 'REVOKE CONNECT ON DATABASE harbor_restore FROM PUBLIC' >/dev/null"

vault_role_expanded=true
{ tr -d '\n' <"${vault_token_file}"; printf '\n'; } | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault write auth/kubernetes/role/harbor bound_service_account_names=harbor bound_service_account_namespaces=harbor,harbor-restore audience=vault token_policies=harbor token_no_default_policy=true token_ttl=15m token_max_ttl=1h >/dev/null'"

helm template harbor-restore "${repo_root}/gitops/apps/harbor" --namespace harbor-restore \
  -f "${repo_root}/gitops/apps/harbor/values-reg-01.yaml" \
  --set-string externalURL=http://127.0.0.1:28443 \
  --set-string database.external.coreDatabase=harbor_restore \
  --set jobservice.replicas=0 \
  --set registryApiIngress.enabled=false >"${restore_manifest}"
if rg -q '^kind: (Secret|PersistentVolumeClaim|Ingress)$' "${restore_manifest}"; then
  echo "복원 manifest에 금지된 Secret/PVC/Ingress가 있다" >&2
  exit 1
fi
restore_namespace_created=true
ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" <"${restore_manifest}" >/dev/null
for workload in harbor-restore-core harbor-restore-jobservice harbor-restore-nginx harbor-restore-portal harbor-restore-registry; do
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n harbor-restore rollout status deployment/${workload} --timeout=300s" >/dev/null
done
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n harbor-restore rollout status statefulset/harbor-restore-redis --timeout=300s" >/dev/null

restore_service_ip=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n harbor-restore get service harbor -o jsonpath='{.spec.clusterIP}'")
[[ ${restore_service_ip} =~ ^[0-9]+(\.[0-9]+){3}$ ]] || { echo "restore Harbor ClusterIP가 IPv4가 아니다" >&2; exit 1; }
ssh "${ssh_options[@]}" -N -o ExitOnForwardFailure=yes \
  -L "28443:${restore_service_ip}:80" "${k3s_host}" \
  >"${temp_root}/restore-port-forward.log" 2>&1 &
restore_tunnel_pid=$!
restore_ready=false
for _ in {1..30}; do
  if curl --silent --fail http://127.0.0.1:28443/api/v2.0/ping >/dev/null; then
    restore_ready=true
    break
  fi
  if ! kill -0 "${restore_tunnel_pid}" 2>/dev/null; then
    echo "restore Harbor SSH tunnel이 준비 전에 종료됐다" >&2
    sed -n '1,120p' "${temp_root}/restore-port-forward.log" >&2
    exit 1
  fi
  sleep 1
done
if [[ ${restore_ready} != true ]]; then
  echo "restore Harbor SSH tunnel 준비 timeout" >&2
  sed -n '1,120p' "${temp_root}/restore-port-forward.log" >&2
  exit 1
fi
restored_digest=$(skopeo inspect --tls-verify=false --authfile "${auth_file}" \
  docker://127.0.0.1:28443/reg01-evidence/pushpull:evidence --format '{{.Digest}}')
[[ ${restored_digest} == "${pushed_digest}" ]] || { echo "복원 Harbor pull digest 불일치" >&2; exit 1; }
python3 "${repo_root}/gitops/tools/reg-01/s3-client.py" --env-file "${env_file}" \
  --ca-file "${repo_root}/gitops/apps/harbor/files/s3.crt" \
  --connect-host 127.0.0.1 --connect-port 18333 inventory >"${restore_inventory}"
cmp -s "${live_inventory}" "${restore_inventory}" || { echo "복원 전후 S3 bucket inventory 불일치" >&2; exit 1; }
echo "restore 성공: DB dump + 동일 S3 bucket inventory에서 격리 Harbor pull digest=${restored_digest}"

kill "${restore_tunnel_pid}" 2>/dev/null || true
wait "${restore_tunnel_pid}" 2>/dev/null || true
restore_tunnel_pid=
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} delete namespace harbor-restore --wait=true --timeout=120s" >/dev/null
restore_namespace_created=false
vault_role_main
vault_role_expanded=false
ssh "${pg_ssh_options[@]}" rocky@10.10.50.10 \
  "sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='harbor_restore' AND pid <> pg_backend_pid();\" >/dev/null && sudo -u postgres dropdb harbor_restore && sudo rm -f ${pg_dump_path}" >/dev/null
restore_db_created=false
echo "restore instance/DB/dump 정리 완료"

python3 "${repo_root}/gitops/tools/reg-01/harbor-api.py" --env-file "${env_file}" cleanup
projects_created=false

"${repo_root}/gitops/tools/reg-01/check-capacity.sh"
echo "REG-01 완료 증거 5항목 실행 완료"
