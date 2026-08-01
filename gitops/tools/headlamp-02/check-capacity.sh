#!/usr/bin/env bash
# capacity-plan의 HEADLAMP-02 적용 중단 기준을 변경 없이 확인한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly pve_host=${PVE_HOST:-root@proxmox-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}

[[ -f "${known_hosts}" && ! -L "${known_hosts}" ]] || {
  echo "인증된 SSH known_hosts 파일이 없다." >&2
  exit 1
}

ssh_options=(
  -T
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
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
K3S
)

python3 - "${pve_metrics}" "${k3s_metrics}" <<'PY'
import sys


def values(text):
    result = {}
    for line in text.splitlines():
        key, value = line.split("=", 1)
        result[key] = float(value)
    return result


pve = values(sys.argv[1])
k3s = values(sys.argv[2])
checks = [
    (pve["pve_memory_available_mib"] >= 8192, "PVE available memory is below 8 GiB stop threshold"),
    (pve["pve_swap_used_mib"] == 0, "PVE swap is in use"),
    (pve["pve_load15"] < 30, "PVE 15-minute load reached stop threshold"),
    (pve["pve_root_used_percent"] < 80, "PVE root filesystem reached stop threshold"),
    (pve["pve_thin_data_percent"] < 70, "PVE thin data reached stop threshold"),
    (pve["pve_thin_metadata_percent"] < 70, "PVE thin metadata reached stop threshold"),
    (k3s["k3s_root_used_percent"] < 80, "k3s guest free space is at or below 20 percent"),
    (k3s["k3s_pvc_request_gib"] < 120, "PVC requested capacity reached 120 GiB stop threshold"),
]
for passed, message in checks:
    if not passed:
        raise SystemExit(message)
merged = {**pve, **k3s}
for key in sorted(merged):
    print(f"{key}={merged[key]:g}")
PY

echo "HEADLAMP-02 capacity-plan stop criteria=pass"
