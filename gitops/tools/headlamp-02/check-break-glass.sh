#!/usr/bin/env bash
# Keycloak·Pomerium·Headlamp과 독립된 SSH + root-only kubeconfig 복구 경계를 조회한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}

[[ -f "${known_hosts}" && ! -L "${known_hosts}" ]] || {
  echo "인증된 SSH known_hosts 파일이 없다." >&2
  exit 1
}

ssh -T \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=${known_hosts}" \
  "${k3s_host}" \
  'sudo -n /bin/bash -s' <<'REMOTE'
set -Eeuo pipefail

[[ "$(stat -c "%u:%g:%a" /etc/rancher/k3s/k3s.yaml)" == "0:0:600" ]] || {
  echo "break-glass kubeconfig ownership/mode mismatch" >&2
  exit 1
}
systemctl is-active --quiet k3s
/usr/local/bin/k3s kubectl get --raw=/readyz | grep -Fx ok >/dev/null
/usr/local/bin/k3s kubectl get node -o json | jq -e '
  .items | length == 1 and
  ([.[0].status.conditions[] | select(.type == "Ready") | .status] == ["True"])
' >/dev/null
/usr/local/bin/k3s kubectl -n vault exec vault-0 -- vault status -format=json | jq -e '
  .initialized == true and .sealed == false
' >/dev/null
for deployment in headlamp/headlamp pomerium/pomerium; do
  namespace=${deployment%/*}
  name=${deployment#*/}
  /usr/local/bin/k3s kubectl -n "${namespace}" get deployment "${name}" -o json | jq -e '
    ((.status.availableReplicas // 0) >= 1) and ((.status.unavailableReplicas // 0) == 0)
  ' >/dev/null
done
REMOTE

echo "HEADLAMP-02 break-glass: trusted SSH, root-only kubeconfig, readyz, Node, Vault unsealed, Headlamp/Pomerium=ok"
