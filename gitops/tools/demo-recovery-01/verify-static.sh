#!/usr/bin/env bash
set -euo pipefail

readonly tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root=$(cd -- "${tool_dir}/../../.." && pwd)

bash -n "${tool_dir}/recovery.sh"
bash -n "${tool_dir}/verify-capacity.sh"
bash -n "${tool_dir}/verify-live.sh"
python3 - <<'PY' \
  "${repo_root}/gitops/apps/demo-onprem/server.py" \
  "${repo_root}/gitops/apps/demo-onprem/recovery_seed.py" \
  "${tool_dir}/verify-immutable-argo.py"
import ast
import pathlib
import sys
for value in sys.argv[1:]:
    ast.parse(pathlib.Path(value).read_text(encoding="utf-8"), filename=value)
PY
shellcheck "${tool_dir}/recovery.sh" "${tool_dir}/verify-capacity.sh" "${tool_dir}/verify-live.sh"
kubectl kustomize "${repo_root}/gitops/apps/demo-onprem" >/dev/null
kubectl kustomize "${repo_root}/gitops/root" >/dev/null
kubectl kustomize "${repo_root}/policies" >/dev/null

python3 - <<'PY' \
  "${repo_root}/gitops/apps/demo-onprem/recovery-pvc.yaml" \
  "${repo_root}/gitops/apps/demo-onprem/workloads.yaml" \
  "${repo_root}/gitops/root/demo-onprem-project.yaml" \
  "${repo_root}/docs/capacity-plan.md"
import pathlib
import sys
import yaml

pvc = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
workloads = list(yaml.safe_load_all(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")))
project = yaml.safe_load(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
capacity = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")

assert pvc["kind"] == "PersistentVolumeClaim"
assert pvc["metadata"]["name"] == "demo-recovery-data"
assert pvc["spec"]["storageClassName"] == "local-path"
assert pvc["spec"]["resources"]["requests"]["storage"] == "512Mi"
portal = next(item for item in workloads if item and item.get("kind") == "Deployment" and item["metadata"]["name"] == "demo-onprem-portal")
template = portal["spec"]["template"]
assert template["metadata"]["annotations"]["backup.velero.io/backup-volumes"] == "recovery-data"
assert any(item["name"] == "recovery-seed" for item in template["spec"]["initContainers"])
container = next(item for item in template["spec"]["containers"] if item["name"] == "portal")
assert any(item["name"] == "recovery-data" and item["mountPath"] == "/var/lib/demo-recovery" for item in container["volumeMounts"])
assert any(item["name"] == "recovery-data" and item["persistentVolumeClaim"]["claimName"] == "demo-recovery-data" for item in template["spec"]["volumes"])
assert {"group": "", "kind": "PersistentVolumeClaim"} in project["spec"]["namespaceResourceWhitelist"]
for required in ("DEMO-RECOVERY-01", "96 GiB는", "120 GiB 이상", "root 여유 25%"):
    assert required in capacity, required
PY

python3 - <<'PY' "${repo_root}/policies/pol-02-policy-exceptions.yaml"
import pathlib
import sys
import yaml

documents = list(yaml.safe_load_all(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")))
pvr = next(item for item in documents if item and item.get("metadata", {}).get("name") == "pol-03-velero-pvr-hosting-run-as-non-root")
assert pvr["metadata"]["namespace"] == "kyverno"
assert pvr["spec"]["background"] is False
assert pvr["spec"]["exceptions"] == [{"policyName": "pol-01-require-pod-run-as-non-root", "ruleNames": ["require-pod-run-as-non-root"]}]
entry = pvr["spec"]["match"]["any"][0]
assert entry["resources"]["kinds"] == ["Pod"]
assert entry["resources"]["namespaces"] == ["velero"]
assert entry["resources"]["selector"]["matchExpressions"] == [{"key": "velero.io/pod-volume-restore", "operator": "Exists"}]
assert entry["subjects"] == [{"kind": "ServiceAccount", "name": "velero-server", "namespace": "velero"}]
conditions = pvr["spec"]["conditions"]["all"]
assert len(conditions) == 4
assert all(item["operator"] == "Equals" for item in conditions)
serialized = "\n".join(str(item) for item in conditions)
for required in ("velero.io/pod-volume-restore", "request.object.metadata.name", "request.object.spec.serviceAccountName", "PodVolumeRestore", "velero.io/v1"):
    assert required in serialized, required
PY

"${repo_root}/scripts/check-backlog.sh" "${repo_root}/docs/backlog.md"
git -C "${repo_root}" diff --check
echo 'DEMO_RECOVERY_STATIC=PASS renders=2 pvc=512Mi capacity=rebased recovery_boundary=synthetic-only'
