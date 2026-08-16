#!/usr/bin/env bash
set -euo pipefail

readonly ssh_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}

remote_kubectl() {
  local command='sudo -n /usr/local/bin/k3s kubectl'
  local quoted
  printf -v quoted ' %q' "$@"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
    "${ssh_host}" "${command}${quoted}"
}

pvc_json=$(remote_kubectl get pvc -A -o json)
root_line=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}" \
  "${ssh_host}" 'df -Pk / | awk "NR==2{print \$2,\$4}"')
disk_pressure=$(remote_kubectl get node k3s-01.imcherry5778.xyz -o json | jq -r '
  [.status.conditions[] | select(.type == "DiskPressure") | .status][0] // "unknown"
')

python3 - "${pvc_json}" "${root_line}" "${disk_pressure}" <<'PY'
import json
import sys

pvc = json.loads(sys.argv[1])
total_kib, available_kib = (int(value) for value in sys.argv[2].split())
disk_pressure = sys.argv[3]
units = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40}

def quantity(value: str) -> int:
    for suffix, scale in units.items():
        if value.endswith(suffix):
            return int(value[:-len(suffix)]) * scale
    return int(value)

requests = sum(
    quantity(item.get("spec", {}).get("resources", {}).get("requests", {}).get("storage", "0"))
    for item in pvc.get("items", [])
    if item.get("status", {}).get("phase") == "Bound"
)
if any(item.get("metadata", {}).get("namespace") == "demo-onprem" and
       item.get("metadata", {}).get("name") == "demo-recovery-data" for item in pvc.get("items", [])):
    raise SystemExit("DEMO_RECOVERY_CAPACITY=FAIL reason=task PVC already exists before immutable apply")
after = requests + 512 * 2**20
hard = 120 * 2**30
free_pct = available_kib * 100 / total_kib
if after >= hard:
    raise SystemExit("DEMO_RECOVERY_CAPACITY=FAIL reason=PVC hard cap reached")
if free_pct < 25:
    raise SystemExit("DEMO_RECOVERY_CAPACITY=FAIL reason=root free below 25 percent")
if disk_pressure != "False":
    raise SystemExit("DEMO_RECOVERY_CAPACITY=FAIL reason=DiskPressure is not false")
print("DEMO_RECOVERY_CAPACITY=PASS "
      f"pvc_before_gib={requests / 2**30:.3f} pvc_after_gib={after / 2**30:.3f} "
      f"root_free_pct={free_pct:.0f} diskpressure=false")
PY
