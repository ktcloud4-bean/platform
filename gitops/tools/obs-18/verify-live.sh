#!/usr/bin/env bash
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly expected_root_revision=${OBS18_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}
readonly expected_config_revision=${OBS18_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}

fail() {
  echo "OBS-18 검증 실패 단계=$1 원인=$2" >&2
  exit 1
}

[[ -f $known_hosts && ! -L $known_hosts ]] || fail preflight '인증된 k3s known_hosts 파일이 없다.'
[[ $expected_root_revision =~ ^[0-9a-f]{40}$ && $expected_config_revision =~ ^[0-9a-f]{40}$ ]] || fail preflight 'immutable SHA 형식이 아니다.'

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

echo '== immutable Argo revision =='
argo_state=''
for _ in $(seq 1 36); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg config "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $obs_app.spec.source.targetRevision == $config and
    $obs_app.status.sync.revision == $config and
    $obs_app.status.sync.status == "Synced" and
    $obs_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${expected_root_revision}" --arg config "${expected_config_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
  $root_app.spec.source.targetRevision == $root and
  $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $config and
  $obs_app.status.sync.revision == $config and
  $obs_app.status.sync.status == "Synced" and
  $obs_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || fail argo 'platform-root 또는 obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

remote_kubectl -n obs rollout status statefulset/alertmanager-obs-alertmanager --timeout=180s >/dev/null || fail deployment 'Alertmanager가 Ready가 아니다.'
remote_kubectl -n obs rollout status deployment/obs-18-slack-egress-proxy --timeout=180s >/dev/null || fail deployment 'Slack CONNECT proxy가 Ready가 아니다.'

proxy_pod=$(remote_kubectl -n obs get pod -l app.kubernetes.io/name=obs-18-slack-egress-proxy -o jsonpath='{.items[0].metadata.name}')
[[ $proxy_pod =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail deployment 'Slack CONNECT proxy Pod 이름을 읽지 못했다.'
proxy_state=$(remote_kubectl -n obs get pod "$proxy_pod" -o json)
jq -e '
  .spec.hostNetwork == true and
  .spec.dnsPolicy == "ClusterFirstWithHostNet" and
  .spec.nodeName == "k3s-01.imcherry5778.xyz" and
  .spec.serviceAccountName == "obs-18-slack-egress-proxy" and
  .spec.automountServiceAccountToken == false and
  (.spec.containers | length == 1) and
  .spec.containers[0].securityContext.allowPrivilegeEscalation == false and
  .spec.containers[0].securityContext.readOnlyRootFilesystem == true and
  (.spec.containers[0].securityContext.capabilities.drop == ["ALL"])
' <<<"$proxy_state" >/dev/null || fail proxy 'proxy Pod의 host network·service account·hardening 선언이 정확하지 않다.'
echo "ProxyPod=PASS pod=$proxy_pod hostNetwork=true source_identity=dedicated"

echo '== Vault file과 receiver route =='
if ! ssh "${ssh_options[@]}" "$k3s_host" bash -s <<'REMOTE'
set -Eeuo pipefail
k=(sudo -n /usr/local/bin/k3s kubectl)
pod=$("${k[@]}" -n obs get pod -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}')
test -n "$pod"
"${k[@]}" -n obs exec "$pod" -- sh -ceu '
  test "$(stat -c %a /vault/secrets/slack-webhook-url)" = 440
  webhook=$(cat /vault/secrets/slack-webhook-url)
  case "$webhook" in
    https://hooks.slack.com/services/*) ;;
    *) exit 1 ;;
  esac
  config=/etc/alertmanager/config_out/alertmanager.env.yaml
  grep -F -- "api_url_file: /vault/secrets/slack-webhook-url" "$config" >/dev/null
  grep -F -- "proxy_url: http://obs-18-slack-egress-proxy.obs.svc:8444" "$config" >/dev/null
  grep -F -- "#platform-alerts" "$config" >/dev/null
'
REMOTE
then
  fail credential 'Vault file mode 또는 host가 기대와 다르다.'
fi
echo 'Receiver=PASS vault_file=0440 api_url_file=enabled proxy_tcp_8444=enabled'

echo '== Alertmanager NetworkPolicy =='
policies=$(remote_kubectl -n obs get networkpolicy obs-alertmanager-vault-egress obs-alertmanager-slack-proxy-egress -o json)
if ! python3 - <<'PY' <<<"$policies"
import json
import sys

items = {item["metadata"]["name"]: item["spec"] for item in json.load(sys.stdin)["items"]}
selector = {
    "app.kubernetes.io/name": "alertmanager",
    "alertmanager": "obs-alertmanager",
}
vault = items.get("obs-alertmanager-vault-egress", {})
proxy = items.get("obs-alertmanager-slack-proxy-egress", {})

def exact(spec, to, port):
    return (
        spec.get("podSelector", {}).get("matchLabels") == selector
        and spec.get("policyTypes") == ["Egress"]
        and spec.get("egress") == [{"to": to, "ports": [{"protocol": "TCP", "port": port}]}]
    )

vault_to = [{
    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "vault"}},
    "podSelector": {"matchLabels": {"app.kubernetes.io/name": "vault"}},
}]
proxy_to = [{"ipBlock": {"cidr": "10.10.20.10/32"}}]
raise SystemExit(0 if exact(vault, vault_to, 8200) and exact(proxy, proxy_to, 8444) else 1)
PY
then
  fail networkpolicy 'Alertmanager의 Vault TCP 8200 또는 proxy TCP 8444 egress가 exact 선언이 아니다.'
fi
echo 'NetworkPolicy=PASS alertmanager_vault_tcp_8200 proxy_tcp_8444_exact'

echo '== dedicated source FQDN egress =='
egress_source=$(ssh "${ssh_options[@]}" "$k3s_host" bash -s -- "$proxy_pod" <<'REMOTE'
set -Eeuo pipefail
pod=$1
k=(sudo -n /usr/local/bin/k3s kubectl)
"${k[@]}" -n obs exec -i "$pod" -- python3 - <<'PY'
import importlib.util

spec = importlib.util.spec_from_file_location("obs18proxy", "/app/obs-18-slack-egress-proxy.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
sock = module.connect_slack()
try:
    print(sock.getsockname()[0])
finally:
    sock.close()
PY
REMOTE
)
[[ $egress_source == 10.10.20.11 ]] || fail egress "proxy가 전용 source identity로 Slack TCP 443에 도달하지 못했다(source=$egress_source)."
echo 'FQDNAlias=PASS proxy_source=10.10.20.11 destination=hooks.slack.com:443'
echo 'VerifyLive=PASS'
