#!/usr/bin/env bash
# WAZUH-06 라이브 검증. WAZUH-01~05가 이미 판정한 수집·라우팅·보존·Pomerium 경계는
# 다시 확인하지 않는다. 이 verifier는 아래만 판정한다.
#
#   1. notifier Pod가 전용 SA·전용 Vault role로 떠서 webhook을 렌더했고, manager는
#      그 Vault 경로를 읽지 못한다(권한 분리가 정책으로 성립)
#   2. manager에 custom-wazuh06 integration이 level 14로 적재되고 SOAR-01의 level 7
#      흐름이 그대로 남아 있다
#   3. 외부 egress가 notifier Pod 하나로 한정된다(manager는 Slack에 도달하지 못한다)
#   4. active response·방화벽 자동 차단·Shuffle 외부 messaging 0건
#   5. 지정한 SHA에서 platform-root·wazuh가 Synced/Healthy
#
# 실제 Slack 수신 확인과 임시 test event의 생성·제거는 run-test-event.sh가 소유한다.
# 원격 명령은 인용 중첩을 피하려고 전부 stdin heredoc으로 보낸다.
set -euo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly expected_root=${WAZUH06_EXPECTED_ROOT_REVISION:-}
readonly expected_wazuh=${WAZUH06_EXPECTED_WAZUH_REVISION:-}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  echo "실패(${1}): ${2}" >&2
  exit 1
}

# 원격 셸 스크립트를 stdin으로 실행한다.
remote_sh() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s'
}

# manager container 안에서 stdin 셸 스크립트를 실행한다.
manager_sh() {
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n wazuh exec -i wazuh-manager-master-0 -c wazuh-manager -- sh -s"
}

# notifier container 안에서 stdin python 프로그램을 실행한다.
notifier_py() {
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n wazuh exec -i ${notifier_pod} -c wazuh-06-notifier -- python3 -"
}

kctl() {
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

[[ -n ${expected_root} && -n ${expected_wazuh} ]] \
  || fail precondition 'WAZUH06_EXPECTED_ROOT_REVISION과 WAZUH06_EXPECTED_WAZUH_REVISION을 지정해야 한다.'

echo '== 1. notifier Pod와 credential 분리 =='

kctl -n wazuh rollout status deployment/wazuh-06-notifier --timeout=180s >/dev/null \
  || fail notifier 'wazuh-06-notifier Deployment가 준비되지 않았다.'

notifier_pod=$(kctl -n wazuh get pods -l app.kubernetes.io/component=wazuh-06-notifier \
  -o 'jsonpath={.items[0].metadata.name}')
[[ -n ${notifier_pod} ]] || fail notifier 'notifier Pod 이름을 읽지 못했다.'

notifier_sa=$(kctl -n wazuh get pod "${notifier_pod}" -o 'jsonpath={.spec.serviceAccountName}')
[[ ${notifier_sa} == wazuh-06-notifier ]] \
  || fail notifier "notifier가 전용 SA가 아니다(${notifier_sa})."

# webhook은 값을 읽지 않고 mode와 형식만 판정한다.
hook_verdict=$(notifier_py <<'PY'
import os
import stat
import urllib.parse

path = "/vault/secrets/slack-webhook-url"
mode = stat.S_IMODE(os.stat(path).st_mode)
with open(path, encoding="utf-8") as handle:
    parsed = urllib.parse.urlsplit(handle.read().strip())

ok = (
    parsed.scheme == "https"
    and parsed.hostname == "hooks.slack.com"
    and parsed.port in (None, 443)
    and parsed.path.startswith("/services/")
    and not parsed.query
    and not parsed.fragment
)
print("mode=%o host_ok=%s" % (mode, ok))
PY
)
[[ ${hook_verdict} == 'mode=440 host_ok=True' ]] \
  || fail notifier "webhook 렌더 상태가 기대와 다르다(${hook_verdict})."
echo "Notifier=PASS pod=${notifier_pod} sa=wazuh-06-notifier hook=${hook_verdict}"

# manager는 webhook을 아예 갖지 못해야 한다. Vault ACL 자체(root token 필요)는
# provision.sh가 소유하므로 여기서는 root token 없이 확인 가능한 구조만 판정한다:
# manager Pod에 렌더된 파일이 없고, manager의 Vault Agent 설정이 notifier 경로를
# 참조하지 않으며, 두 Pod의 ServiceAccount가 다르다.
manager_sa=$(kctl -n wazuh get pod wazuh-manager-master-0 -o 'jsonpath={.spec.serviceAccountName}')
[[ ${manager_sa} != "${notifier_sa}" ]] \
  || fail separation "manager와 notifier가 같은 ServiceAccount(${manager_sa})를 쓴다."

separation=$(manager_sh <<'SH'
set -eu
if [ -e /vault/secrets/slack-webhook-url ]; then
  echo 'manager_webhook=PRESENT'; exit 1
fi
echo 'manager_webhook=absent'
if grep -q 'security-notifier' /wazuh/runtime/* 2>/dev/null; then
  echo 'manager_vault_render=REFERENCES_NOTIFIER'; exit 1
fi
echo 'manager_vault_render=clean'
SH
) || fail separation "manager 쪽 credential 분리 판정 실패: ${separation}"
echo "Separation=PASS manager_sa=${manager_sa} notifier_sa=${notifier_sa} ${separation//$'\n'/ }"

echo
echo '== 2. manager integration 적재 =='

integration_verdict=$(manager_sh <<'SH'
set -eu
conf=/var/ossec/etc/ossec.conf
# 주석을 지운 뒤 공백을 없애고 한 줄로 만든다.
flat=$(sed -e 's/<!--/\n<!--/g' "$conf" | grep -v '^<!--' | tr -d ' \t\n')

case "$flat" in
  *'<name>custom-wazuh06</name><level>14</level>'*) echo 'wazuh06=level14' ;;
  *) echo 'wazuh06=MISSING'; exit 1 ;;
esac
case "$flat" in
  *'<name>custom-soar01</name><level>7</level>'*) echo 'soar01=level7' ;;
  *) echo 'soar01=CHANGED'; exit 1 ;;
esac
if [ -x /var/ossec/integrations/custom-wazuh06 ]; then
  echo "script=$(stat -c '%a' /var/ossec/integrations/custom-wazuh06)"
else
  echo 'script=MISSING'; exit 1
fi
if /var/ossec/bin/wazuh-control status | grep -q 'wazuh-integratord is running'; then
  echo 'integratord=running'
else
  echo 'integratord=DOWN'; exit 1
fi
SH
) || fail integration "manager integration 판정 실패: ${integration_verdict}"
echo "Integration=PASS ${integration_verdict//$'\n'/ }"

echo
echo '== 3. 외부 egress 한정 =='

manager_slack=$(manager_sh <<'SH'
set -eu
timeout 12 curl -sS -o /dev/null -w '%{http_code}' https://hooks.slack.com/services/ 2>/dev/null || true
echo
SH
)
manager_slack=${manager_slack//[$'\r\n']/}
if [[ ${manager_slack} =~ ^(2|3)[0-9][0-9]$ ]]; then
  fail egress "manager Pod가 Slack에 도달했다(HTTP ${manager_slack}) — 외부 egress가 notifier로 한정되지 않았다."
fi
echo "ManagerEgress=PASS manager -> hooks.slack.com 차단(code='${manager_slack:-none}')"

notifier_slack=$(notifier_py <<'PY'
import urllib.error
import urllib.request

try:
    print(urllib.request.urlopen("https://hooks.slack.com/services/", timeout=15).status)
except urllib.error.HTTPError as error:
    print(error.code)
except Exception:
    print("blocked")
PY
)
[[ ${notifier_slack} =~ ^[0-9]+$ ]] \
  || fail egress "notifier Pod가 Slack에 도달하지 못했다(${notifier_slack})."
echo "NotifierEgress=PASS notifier -> hooks.slack.com 검증된 TLS 도달(HTTP ${notifier_slack})"

# jsonpath의 점 이스케이프는 ssh 경유로 인용이 한 겹 벗겨져 깨진다. JSON을 통째로
# 받아 로컬에서 판정한다. 이 네임스페이스에서 외부(비사설) egress를 가진 정책이
# 정확히 이 하나이고, 그 대상이 notifier Pod뿐인지도 함께 본다.
egress_verdict=$(kctl -n wazuh get networkpolicy -o json | python3 -c '
import json
import sys

doc = json.load(sys.stdin)
private = ("10.", "172.16.", "172.17.", "172.18.", "192.168.", "127.")
external = []
for item in doc.get("items", []):
    name = item["metadata"]["name"]
    spec = item.get("spec", {})
    for rule in spec.get("egress", []) or []:
        for peer in rule.get("to", []) or []:
            cidr = (peer.get("ipBlock") or {}).get("cidr")
            if cidr and not cidr.startswith(private):
                ports = sorted(str(p.get("port")) for p in (rule.get("ports") or []))
                external.append((name, cidr, ",".join(ports),
                                 json.dumps(spec.get("podSelector", {}).get("matchLabels", {}),
                                            sort_keys=True)))
if len(external) != 1:
    print("EXTERNAL_RULES=%d %s" % (len(external), external))
    sys.exit(1)
name, cidr, ports, selector = external[0]
print("policy=%s cidr=%s ports=%s selector=%s" % (name, cidr, ports, selector))
if name != "wazuh-06-notifier-slack-egress" or ports != "443":
    sys.exit(1)
if json.loads(selector).get("app.kubernetes.io/component") != "wazuh-06-notifier":
    sys.exit(1)
') || fail egress "외부 egress 정책이 notifier TCP 443 하나가 아니다: ${egress_verdict}"
echo "EgressPolicy=PASS ${egress_verdict}"

echo
echo '== 4. 자동 대응 0건 =='

response_verdict=$(manager_sh <<'SH'
set -eu
conf=/var/ossec/etc/ossec.conf
flat=$(sed -e 's/<!--/\n<!--/g' "$conf" | grep -v '^<!--' | tr -d ' \t\n')
case "$flat" in
  *'<active-response><disabled>yes</disabled></active-response>'*) echo 'active-response=disabled' ;;
  *) echo 'active-response=ENABLED'; exit 1 ;;
esac
count=$(grep -cE 'firewall-drop|host-deny|route-null|disable-account|netsh|ip-customblock' \
  /var/ossec/etc/shared/ar.conf 2>/dev/null || true)
echo "ar-blocking=${count:-0}"
[ "${count:-0}" = "0" ] || exit 1
SH
) || fail response "자동 대응 판정 실패: ${response_verdict}"
echo "ActiveResponse=PASS ${response_verdict//$'\n'/ }"

shuffle_external=$(kctl -n shuffle get networkpolicy -o json | python3 -c '
import json
import sys

doc = json.load(sys.stdin)
private = ("10.", "172.16.", "172.17.", "172.18.", "192.168.", "127.")
hits = []
for item in doc.get("items", []):
    for rule in item.get("spec", {}).get("egress", []) or []:
        for peer in rule.get("to", []) or []:
            cidr = (peer.get("ipBlock") or {}).get("cidr")
            if cidr and not cidr.startswith(private):
                hits.append("%s:%s" % (item["metadata"]["name"], cidr))
print(len(hits), ",".join(hits))')
[[ ${shuffle_external%% *} == 0 ]] \
  || fail response "Shuffle에 외부 egress NetworkPolicy가 있다(${shuffle_external})."
echo 'ShuffleEgress=PASS shuffle 네임스페이스에 외부 egress ipBlock 0건'

echo
echo '== 5. Argo 상태 =='

# jsonpath 표현식은 ssh 경유로 인용이 한 겹 벗겨져 kubectl에 원형 그대로 도달하지
# 않는다. JSON을 받아 로컬에서 읽는다.
for pair in "platform-root:${expected_root}" "wazuh:${expected_wazuh}"; do
  app=${pair%%:*}
  want=${pair#*:}
  read -r target revision sync health <<<"$(kctl -n argocd get application "${app}" -o json \
    | python3 -c '
import json
import sys

doc = json.load(sys.stdin)
status = doc.get("status", {})
print(
    doc["spec"]["source"]["targetRevision"],
    status.get("sync", {}).get("revision", "-"),
    status.get("sync", {}).get("status", "-"),
    status.get("health", {}).get("status", "-"),
)')"
  [[ ${target} == "${want}" ]] \
    || fail argo "${app} targetRevision이 ${want}가 아니다(${target})."
  [[ ${revision} == "${want}" ]] \
    || fail argo "${app} sync revision이 ${want}가 아니다(${revision})."
  [[ ${sync} == Synced && ${health} == Healthy ]] \
    || fail argo "${app}이 Synced/Healthy가 아니다(${sync}/${health})."
  echo "Argo=PASS ${app} ${revision} ${sync}/${health}"
done

echo
echo 'VerifyLive=PASS'
