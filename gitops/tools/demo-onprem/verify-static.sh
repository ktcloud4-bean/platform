#!/usr/bin/env bash
set -euo pipefail

readonly tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root=$(cd -- "${tool_dir}/../../.." && pwd)
readonly scratch=$(mktemp -d /tmp/demo-onprem-static.XXXXXX)
trap 'rm -rf -- "${scratch}"' EXIT

bash -n "${tool_dir}/demo.sh"
python3 - <<'PY' "${repo_root}/gitops/apps/demo-onprem/server.py" "${tool_dir}/identity.py" "${tool_dir}/session1.py" "${tool_dir}/evidence.py" "${tool_dir}/verify-immutable-argo.py"
import ast
import pathlib
import sys
for value in sys.argv[1:]:
    ast.parse(pathlib.Path(value).read_text(encoding="utf-8"), filename=value)
PY
xmllint --noout "${repo_root}/gitops/apps/wazuh/files/wazuh-04-d30-waf-runtime.xml"

kubectl kustomize "${repo_root}/gitops/apps/demo-onprem" > "${scratch}/demo.yaml"
kubectl kustomize "${repo_root}/gitops/apps/pomerium" > "${scratch}/pomerium.yaml"
kubectl kustomize "${repo_root}/gitops/apps/wazuh" > "${scratch}/wazuh.yaml"
kubectl kustomize "${repo_root}/gitops/root" > "${scratch}/root.yaml"

[[ $(grep -c '^kind: PersistentVolumeClaim$' "${scratch}/demo.yaml" || true) -eq 0 ]]
[[ $(grep -c '^kind: Secret$' "${scratch}/demo.yaml" || true) -eq 0 ]]
[[ $(grep -c '^kind: Deployment$' "${scratch}/demo.yaml") -eq 2 ]]
[[ $(grep -c 'image: harbor.imcherry5778.xyz/curated-platform/python@sha256:527c28b29498575b851ad88e7522ac7201bbd9e920d2c11b00ff2b39b315f5f8' "${scratch}/demo.yaml") -eq 2 ]]
grep -q 'targetRevision: main' "${repo_root}/gitops/root/demo-onprem-application.yaml"
grep -A6 -F 'destination          = "/vault/secrets/soar01-hook-url"' \
  "${repo_root}/gitops/apps/wazuh/files/vault-agent-manager.hcl" | grep -q 'perms                = "0444"'
grep -q 'rule id="100123" level="7"' "${repo_root}/gitops/apps/wazuh/files/wazuh-04-d30-waf-runtime.xml"
grep -Fq '<match type="pcre2">(?=.*"k8s\.ns\.name":"demo-onprem")(?=.*"k8s\.pod\.name":"demo-onprem-attacker")</match>' \
  "${repo_root}/gitops/apps/wazuh/files/wazuh-04-d30-waf-runtime.xml"
grep -q 'same_payload=true' "${tool_dir}/demo.sh"
grep -q 'transient_attack_resources=0' "${tool_dir}/demo.sh"

git -C "${repo_root}" diff --check
"${repo_root}/scripts/check-backlog.sh"
echo 'DEMO_ONPREM_STATIC=PASS renders=4 pvc=0 secret=0 signed_workloads=2'
