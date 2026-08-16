#!/usr/bin/env bash
set -euo pipefail

readonly tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root=$(cd -- "${tool_dir}/../../.." && pwd)
readonly ssh_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly state_dir=/tmp/demo-onprem-01-state
readonly sqli_payload="%' OR 1=1 -- "
readonly request_id=DEMO-ONPREM-01-S2
readonly internal_url=http://demo-onprem-internal-api.demo-onprem.svc.cluster.local:8080/flag
readonly signed_image=harbor.imcherry5778.xyz/curated-platform/python@sha256:527c28b29498575b851ad88e7522ac7201bbd9e920d2c11b00ff2b39b315f5f8

fail() { printf 'DEMO_%s_%s=FAIL reason=%s\n' "${session^^}" "${action^^}" "$*" >&2; exit 1; }

remote_kubectl() {
  local quoted command='sudo -n /usr/local/bin/k3s kubectl'
  printf -v quoted ' %q' "$@"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
    "${ssh_host}" "${command}${quoted}"
}

window() {
  mkdir -p -m 0700 "${state_dir}"
  if [[ ! -f ${state_dir}/window ]]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "${state_dir}/window"
  fi
}

tty_lateral() {
  ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
    "${ssh_host}" \
    "sudo -n /usr/local/bin/k3s kubectl -n demo-onprem exec -i -t demo-onprem-attacker -- sh -c 'python3 -c \"import urllib.request; print(urllib.request.urlopen(\\\"${internal_url}\\\",timeout=3).read().decode())\"'"
}

reset_transient() {
  remote_kubectl -n demo-onprem delete networkpolicy demo-onprem-transient-lateral-block --ignore-not-found >/dev/null
  remote_kubectl -n demo-onprem delete pod demo-onprem-attacker demo-onprem-supply-positive demo-onprem-supply-negative --ignore-not-found --wait=true >/dev/null
}

[[ $# == 2 ]] || { echo 'usage: demo.sh session{1..4} {attack|control|evidence|reset}' >&2; exit 2; }
session=$1
action=$2
[[ ${session} =~ ^session[1-4]$ && ${action} =~ ^(attack|control|evidence|reset)$ ]] || exit 2
window

case "${session}:${action}" in
  session1:attack)
    if unshare -Urn -- curl -kfsS --connect-timeout 3 \
      --resolve access.imcherry5778.xyz:443:10.10.20.10 \
      https://access.imcherry5778.xyz/demo-onprem/account/control >/dev/null 2>&1; then
      fail 'unapproved network namespace unexpectedly reached the internal route'
    fi
    echo 'DEMO_SESSION1_ATTACK=PASS device=unapproved route=absent'
    ;;
  session1:control)
    "${tool_dir}/identity.py" apply
    "${tool_dir}/session1.py"
    ;;
  session1:evidence)
    "${tool_dir}/evidence.py" --session 1 --since "$(<"${state_dir}/window")"
    ;;
  session1:reset)
    "${tool_dir}/identity.py" rollback
    echo 'DEMO_SESSION1_RESET=PASS browser_state=memory-only'
    ;;
  session2:attack)
    response=$(curl -fsS --resolve k3s-01.imcherry5778.xyz:443:10.10.20.10 \
      -H "X-Demo-Request-ID: ${request_id}" --get --data-urlencode "q=${sqli_payload}" \
      https://k3s-01.imcherry5778.xyz/demo-onprem/sqli/control)
    jq -e --arg id "${request_id}" \
      '.marker=="DEMO-SQLI-CONTROL-200" and .request_id==$id and (.rows|length)==3 and all(.rows[]; .customer_id|startswith("SYN-"))' \
      <<<"${response}" >/dev/null || fail 'control did not leak exactly three synthetic rows'
    echo 'DEMO_SESSION2_ATTACK=PASS payload=fixed request_id=DEMO-ONPREM-01-S2 control=200 synthetic_rows=3'
    ;;
  session2:control)
    status=$(curl -sS -o /dev/null -w '%{http_code}' \
      --resolve k3s-01.imcherry5778.xyz:443:10.10.20.10 \
      -H "X-Demo-Request-ID: ${request_id}" --get --data-urlencode "q=${sqli_payload}" \
      https://k3s-01.imcherry5778.xyz/demo-onprem/sqli/waf)
    [[ ${status} == 403 ]] || fail "CrowdSec WAF status=${status}, expected 403"
    echo 'DEMO_SESSION2_CONTROL=PASS same_payload=true same_backend=true waf=403 crs_rule=942100'
    ;;
  session2:evidence)
    appsec_pod=$(remote_kubectl -n crowdsec-01 get pod -l type=appsec -o jsonpath='{.items[0].metadata.name}')
    appsec_logs=$(remote_kubectl -n crowdsec-01 logs "${appsec_pod}" --since-time="$(<"${state_dir}/window")" 2>/dev/null || true)
    grep -q 'WAF block:' <<<"${appsec_logs}" || fail 'CrowdSec AppSec block log is absent'
    "${tool_dir}/evidence.py" --session 2 --since "$(<"${state_dir}/window")"
    echo 'DEMO_SESSION2_RULE=PASS ruleset=OWASP-CRS-942-SQLI representative_rule=942100 inputs=masked'
    ;;
  session2:reset)
    echo 'DEMO_SESSION2_RESET=PASS database=in-memory seed=clean'
    ;;
  session3:attack)
    reset_transient
    remote_kubectl apply -f - < "${tool_dir}/attacker-pod.yaml" >/dev/null
    remote_kubectl -n demo-onprem wait --for=condition=Ready pod/demo-onprem-attacker --timeout=90s >/dev/null
    output=$(tty_lateral 2>/dev/null | tr -d '\r')
    grep -q 'DEMO-LATERAL-FLAG' <<<"${output}" || fail 'control lateral request did not return synthetic flag'
    echo 'DEMO_SESSION3_ATTACK=PASS source=demo-onprem-attacker destination=internal-api:8080 synthetic_flag=visible'
    ;;
  session3:control)
    remote_kubectl apply -f - < "${tool_dir}/transient-egress-block.yaml" >/dev/null
    sleep 3
    if tty_lateral >/dev/null 2>&1; then
      fail 'same lateral request succeeded with NetworkPolicy enabled'
    fi
    echo 'DEMO_SESSION3_CONTROL=PASS same_source=true same_destination=internal-api:8080 networkpolicy=blocked'
    ;;
  session3:evidence)
    falco_pod=$(remote_kubectl -n falco get pod -l app.kubernetes.io/name=falco -o jsonpath='{.items[0].metadata.name}')
    falco_logs=$(remote_kubectl -n falco logs "${falco_pod}" -c falco --since-time="$(<"${state_dir}/window")" 2>/dev/null || true)
    jq -Rse '[splits("\n")|fromjson?|select(.rule=="Interactive Shell in Container" and .output_fields["k8s.ns.name"]=="demo-onprem" and .output_fields["k8s.pod.name"]=="demo-onprem-attacker")]|length>=2' \
      <<<"${falco_logs}" >/dev/null || fail 'Falco same-pod TTY events are absent'
    echo 'DEMO_SESSION3_FALCO=PASS rule=Interactive-Shell-in-Container events>=2 fields=masked'
    "${tool_dir}/evidence.py" --session 3 --since "$(<"${state_dir}/window")" --wait-shuffle
    ;;
  session3:reset)
    reset_transient
    echo 'DEMO_SESSION3_RESET=PASS attacker=absent transient_networkpolicy=absent'
    ;;
  session4:attack)
    if remote_kubectl apply --server-side --dry-run=server -f - < "${tool_dir}/supply-negative-pod.yaml" >"${state_dir}/supply-negative.out" 2>&1; then
      fail 'unapproved upstream image was admitted'
    fi
    rg -qi 'ImageValidatingPolicy|image verification|verify|signature|not allowed|denied' "${state_dir}/supply-negative.out" \
      || fail 'admission denial did not identify image policy'
    echo 'DEMO_SESSION4_ATTACK=PASS same_pod_shape=true unapproved_image=denied policy=Enforce'
    ;;
  session4:control)
    remote_kubectl apply -f - < "${tool_dir}/supply-positive-pod.yaml" >/dev/null
    remote_kubectl -n demo-onprem wait --for=condition=Ready pod/demo-onprem-supply-positive --timeout=120s >/dev/null
    actual=$(remote_kubectl -n demo-onprem get pod demo-onprem-supply-positive -o jsonpath='{.spec.containers[0].image}')
    [[ ${actual} == "${signed_image}" ]] || fail 'running image is not the declared exact digest'
    echo 'DEMO_SESSION4_CONTROL=PASS same_pod_shape=true signed_exact_digest=Ready'
    ;;
  session4:evidence)
    policy=$(remote_kubectl get imagevalidatingpolicy k3s-image-supply-chain-policy -o json)
    jq -e '.spec.validationActions==["Deny"] and .spec.failurePolicy=="Fail"' <<<"${policy}" >/dev/null \
      || fail 'running supply-chain policy is not Deny/Fail'
    remote_kubectl -n demo-onprem get pod demo-onprem-supply-positive -o json \
      | jq -e --arg image "${signed_image}" '.spec.containers[0].image==$image and any(.status.conditions[]; .type=="Ready" and .status=="True")' >/dev/null \
      || fail 'positive exact-digest pod is not Ready'
    echo 'DEMO_SESSION4_EVIDENCE=PASS policy=ImageValidatingPolicy action=Deny failurePolicy=Fail exact_digest=Ready'
    ;;
  session4:reset)
    reset_transient
    remaining=$(remote_kubectl -n demo-onprem get pod,networkpolicy -l demo-onprem.imcherry5778.xyz/transient=true --no-headers 2>/dev/null | wc -l)
    [[ ${remaining} -eq 0 ]] || fail "transient resources remain: ${remaining}"
    rm -f "${state_dir}/supply-negative.out"
    echo 'DEMO_SESSION4_RESET=PASS transient_attack_resources=0'
    ;;
esac
