#!/usr/bin/env bash
set -euo pipefail

readonly tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root=$(cd -- "${tool_dir}/../../.." && pwd)
readonly current=${repo_root}/policies/k3s-image-supply-chain-policy.yaml
readonly rollback=${repo_root}/policies/rollback/k3s-image-supply-chain-policy.yaml
readonly scratch=$(mktemp -d /tmp/supply-05-fix-04-static.XXXXXX)
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

python3 - <<'PY' "${current}" "${rollback}"
import pathlib
import sys
import yaml

manager = "docker.io/wazuh/wazuh-manager:4.14.7@sha256:a65dcdb61e48b7064bd7250c5cbd6aceeb9b8043a1a413931a8868793146f06d"
vault = "hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54"
for index, value in enumerate(sys.argv[1:]):
    document = yaml.safe_load(pathlib.Path(value).read_text(encoding="utf-8"))
    spec = document["spec"]
    expression = spec["matchConditions"][0]["expression"]
    required = (
        'object.metadata.name == "wazuh-manager-master-0"',
        'object.spec.serviceAccountName == "wazuh-manager"',
        'object.spec.?containers.orValue([]).size() == 1',
        manager,
        'object.spec.?initContainers.orValue([]).size() == 1',
        vault,
        'object.spec.?ephemeralContainers.orValue([]).size() == 0',
    )
    assert expression.count('object.metadata.namespace == "wazuh"') >= 2, value
    assert all(expression.count(item) == 1 for item in required), value
    if index == 0:
        assert spec["failurePolicy"] == "Fail" and spec["validationActions"] == ["Deny"]
    else:
        assert spec["failurePolicy"] == "Ignore" and spec["validationActions"] == ["Audit"]
PY

"${repo_root}/scripts/check-backlog.sh" "${repo_root}/docs/backlog.md"
git -C "${repo_root}" diff --check
echo 'SUPPLY05FIX04_STATIC=PASS renders=2 exact_manager_exception=2 backlog=valid'
