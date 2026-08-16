#!/usr/bin/env bash
set -euo pipefail

readonly tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root=$(cd -- "${tool_dir}/../../.." && pwd)

bash -n "${tool_dir}/demo.sh"
python3 - <<'PY' "${tool_dir}/check-portal.py"
import ast
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
PY

grep -Fq 'create --dry-run=server -f "${state_dir}/negative.json"' "${tool_dir}/demo.sh"
grep -Fq 'create --dry-run=server -f "${state_dir}/positive.json"' "${tool_dir}/demo.sh"
grep -Fq 'remote_delete=0' "${tool_dir}/demo.sh"
grep -Fq 'new_replicasets=0 new_pods=0' "${tool_dir}/demo.sh"
grep -Fq 'quality-06-employee' "${tool_dir}/check-portal.py"
grep -Fq '/api/employee/me/history' "${tool_dir}/check-portal.py"
if rg -n '(^|[^-])(kubectl|eks_kube) (apply|delete|patch|rollout)' "${tool_dir}/demo.sh"; then
  echo 'DEMO_AWS_HR_STATIC=FAIL mutable Kubernetes command detected' >&2
  exit 1
fi
if rg -n 'build|replicat|git push|git commit|docker push|aws ecr put' "${tool_dir}/demo.sh"; then
  echo 'DEMO_AWS_HR_STATIC=FAIL prohibited production workflow command detected' >&2
  exit 1
fi

git -C "${repo_root}" diff --check
"${repo_root}/scripts/check-backlog.sh"
printf '%s\n' 'DEMO_AWS_HR_STATIC=PASS dry_run_only=true mutable_kubernetes=0 secret_output=0'
