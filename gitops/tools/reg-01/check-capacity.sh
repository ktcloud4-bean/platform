#!/usr/bin/env bash
# capacity-plan.md의 REG-01 직후 stop/go와 Harbor PVC=0을 한 번 판정한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@10.10.20.10}
readonly pve_host=${PVE_HOST:-root@10.10.10.10}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly ssh_options=(
  -T
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)

pve_metrics=$(ssh "${ssh_options[@]}" "${pve_host}" 'bash -s' <<'PVE'
set -Eeuo pipefail
printf 'pve_memory_available_mib='; free -m | awk '/Mem:/ {print $7}'
printf 'pve_swap_used_mib='; free -m | awk '/Swap:/ {print $3}'
printf 'pve_load15='; awk '{print $3}' /proc/loadavg
printf 'pve_root_used_percent='; df -P / | awk 'NR==2 {sub(/%/, "", $5); print $5}'
thin=$(lvs --noheadings --units p --nosuffix --separator '|' -o data_percent,metadata_percent pve/data | tr -d ' ')
IFS='|' read -r data_percent metadata_percent <<<"${thin}"
printf 'pve_thin_data_percent=%s\n' "${data_percent}"
printf 'pve_thin_metadata_percent=%s\n' "${metadata_percent}"
PVE
)

k3s_metrics=$(ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'K3S'
set -Eeuo pipefail
printf 'k3s_root_used_percent='; df -P / | awk 'NR==2 {sub(/%/, "", $5); print $5}'
printf 'k3s_memory_available_mib='; free -m | awk '/Mem:/ {print $7}'
printf 'k3s_data_used_mib='; sudo -n du -sm /var/lib/rancher/k3s | awk '{print $1}'
sudo -n /usr/local/bin/k3s kubectl get pvc -A -o json | jq -r '
  def gib:
    capture("^(?<n>[0-9]+)(?<u>Ki|Mi|Gi|Ti)?$") as $q
    | ($q.n | tonumber) *
      (if $q.u == "Ti" then 1024
       elif $q.u == "Gi" then 1
       elif $q.u == "Mi" then 0.0009765625
       elif $q.u == "Ki" then 0.00000095367431640625
       else 0 end);
  ([.items[] | .spec.resources.requests.storage? // "0" | gib] | add // 0)
  | "k3s_pvc_request_gib=\(.)"
'
printf 'harbor_pvc_count='; sudo -n /usr/local/bin/k3s kubectl -n harbor get pvc -o json | jq '.items | length'
printf 'k3s_disk_pressure='; sudo -n /usr/local/bin/k3s kubectl get nodes -o json | jq -er '
  if (.items | length) != 1 then error("REG-01은 단일 k3s node 기준선만 판정한다")
  else .items[0].status.conditions[] | select(.type == "DiskPressure") | .status
  end
'
K3S
)

python3 - "${pve_metrics}" "${k3s_metrics}" <<'PY'
import sys

def values(text):
    result = {}
    for line in text.splitlines():
        key, value = line.split("=", 1)
        result[key] = value
    return result

pve, k3s = values(sys.argv[1]), values(sys.argv[2])
checks = [
    (float(pve["pve_memory_available_mib"]) >= 8192, "PVE available memory < 8 GiB"),
    (float(pve["pve_swap_used_mib"]) == 0, "PVE swap is in use"),
    (float(pve["pve_load15"]) < 30, "PVE load15 >= 30"),
    (float(pve["pve_root_used_percent"]) < 80, "PVE root >= 80%"),
    (float(pve["pve_thin_data_percent"]) < 70, "PVE thin data >= 70%"),
    (float(pve["pve_thin_metadata_percent"]) < 70, "PVE thin metadata >= 70%"),
    (float(k3s["k3s_memory_available_mib"]) >= 8192, "k3s available memory < 8 GiB"),
    (float(k3s["k3s_root_used_percent"]) < 80, "k3s root >= 80%"),
    (float(k3s["k3s_pvc_request_gib"]) < 120, "PVC request >= 120 GiB"),
    (int(k3s["harbor_pvc_count"]) == 0, "Harbor requested a PVC; layers are not S3-only"),
    (k3s["k3s_disk_pressure"] == "False", "k3s DiskPressure=True"),
]
for passed, reason in checks:
    if not passed:
        raise SystemExit(f"REG-01 capacity stop: {reason}")
merged = {**pve, **k3s}
for key in sorted(merged):
    print(f"{key}={merged[key]}")
PY

echo "REG-01 capacity-plan stop criteria=pass, stop/go=GO"
