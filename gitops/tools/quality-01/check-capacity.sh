#!/usr/bin/env bash
# 완료 증거 5: capacity-plan.md의 동일 지표와 k3s guest RAM 경계를 배포 직후 읽는다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly pve_host=${PVE_HOST:-root@proxmox-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
ssh_options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

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
printf 'k3s_swap_used_mib='; free -m | awk '/Swap:/ {print $3}'
sudo -n /usr/local/bin/k3s kubectl get pvc -A -o json | jq -r '
  def gib:
    capture("^(?<n>[0-9]+)(?<u>Ki|Mi|Gi|Ti)?$") as $q
    | ($q.n | tonumber) *
      (if $q.u == "Ti" then 1024 elif $q.u == "Gi" then 1
       elif $q.u == "Mi" then 0.0009765625 elif $q.u == "Ki" then 0.00000095367431640625
       else 0 end);
  ([.items[] | .spec.resources.requests.storage? // "0" | gib] | add // 0)
  | "k3s_pvc_request_gib=\(.)"
'
sudo -n /usr/local/bin/k3s kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | jq -r '
  .items[0].usage as $u
  | "k3s_node_cpu=\($u.cpu)\nk3s_node_memory=\($u.memory)"
'
sudo -n /usr/local/bin/k3s kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/sonarqube/pods | jq -r '
  [.items[].containers[].usage.memory
   | capture("^(?<n>[0-9]+)(?<u>Ki|Mi|Gi)$")
   | (.n|tonumber) * (if .u=="Gi" then 1024 elif .u=="Mi" then 1 else 0.0009765625 end)]
  | "sonarqube_pod_memory_mib=\(add // 0)"
'
K3S
)

python3 - "${pve_metrics}" "${k3s_metrics}" <<'PY'
import sys

values = {}
for text in sys.argv[1:]:
    for line in text.splitlines():
        key, value = line.split("=", 1)
        values[key] = value

numeric = {key: float(value) for key, value in values.items() if key not in {"k3s_node_cpu", "k3s_node_memory"}}
stop_checks = [
    (numeric["pve_memory_available_mib"] >= 8192, "PVE available RAM < 8 GiB"),
    (numeric["pve_swap_used_mib"] == 0, "PVE swap in use"),
    (numeric["pve_load15"] < 30, "PVE load15 >= 30"),
    (numeric["pve_root_used_percent"] < 80, "PVE root >= 80%"),
    (numeric["pve_thin_data_percent"] < 70, "thin data >= 70%"),
    (numeric["pve_thin_metadata_percent"] < 70, "thin metadata >= 70%"),
    (numeric["k3s_root_used_percent"] < 80, "k3s root >= 80%"),
    (numeric["k3s_memory_available_mib"] >= 8192, "k3s guest available RAM < 8 GiB"),
    (numeric["k3s_swap_used_mib"] == 0, "k3s guest swap in use"),
    (numeric["k3s_pvc_request_gib"] < 120, "PVC request >= 120 GiB"),
]
failed = [message for passed, message in stop_checks if not passed]
if failed:
    decision = "STOP"
elif numeric["k3s_memory_available_mib"] < 12288:
    decision = "WARN"
else:
    decision = "GO"

for key in sorted(values):
    print(f"{key}={values[key]}")
print(f"QUALITY01_CAPACITY_DECISION={decision}")
print(f"QUALITY01_K3S_GUEST_AVAILABLE_MIB={numeric['k3s_memory_available_mib']:g}")
if failed:
    raise SystemExit("; ".join(failed))
PY
