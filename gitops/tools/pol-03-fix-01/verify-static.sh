#!/usr/bin/env bash
set -euo pipefail

readonly tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root=$(cd -- "${tool_dir}/../../.." && pwd)
readonly exceptions=${repo_root}/policies/pol-02-policy-exceptions.yaml
readonly scratch=$(mktemp -d /tmp/pol-03-fix-01-static.XXXXXX)
trap 'rmdir "${scratch}" 2>/dev/null || true' EXIT

bash -n "${tool_dir}/verify-live.sh"
python3 - <<'PY' "${tool_dir}/verify-immutable-argo.py"
import ast
import pathlib
import sys
ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), filename=sys.argv[1])
PY
shellcheck "${tool_dir}/verify-live.sh"
kubectl kustomize "${repo_root}/policies" > "${scratch}/policies.yaml"
kubectl kustomize "${repo_root}/gitops/root" > "${scratch}/root.yaml"

python3 - <<'PY' "${exceptions}"
import pathlib
import sys
import yaml

documents = list(yaml.safe_load_all(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")))
exceptions = {item["metadata"]["name"]: item for item in documents if item and item.get("kind") == "PolicyException"}

node_agent = exceptions["pol-02-velero-run-as-non-root"]
node_match = node_agent["spec"]["match"]["any"]
assert len(node_match) == 2
assert node_match[0]["resources"]["names"] == ["node-agent-*"]
assert node_match[1]["resources"]["names"] == ["node-agent"]

pvb = exceptions["pol-03-velero-pvb-hosting-run-as-non-root"]
assert pvb["metadata"]["namespace"] == "kyverno"
assert pvb["spec"]["background"] is False
assert pvb["spec"]["exceptions"] == [{
    "policyName": "pol-01-require-pod-run-as-non-root",
    "ruleNames": ["require-pod-run-as-non-root"],
}]
match = pvb["spec"]["match"]["any"]
assert len(match) == 1
entry = match[0]
assert entry["resources"]["kinds"] == ["Pod"]
assert entry["resources"]["namespaces"] == ["velero"]
assert "names" not in entry["resources"]
assert entry["resources"]["selector"]["matchExpressions"] == [{
    "key": "velero.io/pod-volume-backup", "operator": "Exists"
}]
assert entry["subjects"] == [{
    "kind": "ServiceAccount", "name": "velero-server", "namespace": "velero"
}]
conditions = pvb["spec"]["conditions"]["all"]
assert len(conditions) == 4
assert all(item["operator"] == "Equals" for item in conditions)
serialized = "\n".join(str(item) for item in conditions)
for required in (
    'velero.io/pod-volume-backup',
    'request.object.metadata.name',
    'request.object.spec.serviceAccountName',
    "PodVolumeBackup",
    "velero.io/v1",
):
    assert required in serialized, required
PY

"${repo_root}/scripts/check-backlog.sh" "${repo_root}/docs/backlog.md"
git -C "${repo_root}" diff --check
echo 'POL03FIX01_STATIC=PASS renders=2 pvb_boundary=label-ownerref-serviceaccount backlog=valid'
