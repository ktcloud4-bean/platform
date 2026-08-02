#!/usr/bin/env bash
# SCAN-01 배포 직후 k3s RAM과 새 Trivy PVC만 판정한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly ssh_options=(
  -T
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)

metrics=$(ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'REMOTE'
set -Eeuo pipefail
kubectl='sudo -n /usr/local/bin/k3s kubectl'
printf 'k3s_memory_available_mib='; free -m | awk '/Mem:/ {print $7}'
printf 'k3s_swap_used_mib='; free -m | awk '/Swap:/ {print $3}'
${kubectl} get pvc -A -o json | jq -r '
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
printf 'trivy_pvc_request='; ${kubectl} -n jenkins get pvc trivy-cache -o jsonpath='{.spec.resources.requests.storage}'
printf '\n'
REMOTE
)

python3 - "${metrics}" <<'PY'
import sys

values = {}
for line in sys.argv[1].splitlines():
    key, value = line.split("=", 1)
    values[key] = value

available = int(values["k3s_memory_available_mib"])
swap = int(values["k3s_swap_used_mib"])
pvc_gib = float(values["k3s_pvc_request_gib"])

if available < 8192:
    raise SystemExit("SCAN-01 capacity stop: k3s available memory < 8 GiB")
if swap != 0:
    raise SystemExit("SCAN-01 capacity stop: k3s swap is in use")
if pvc_gib >= 120:
    raise SystemExit("SCAN-01 capacity stop: PVC request >= 120 GiB")
if values["trivy_pvc_request"] != "1Gi":
    raise SystemExit("SCAN-01 Trivy PVC 요청이 선언한 1Gi와 다르다")

for key in sorted(values):
    print(f"{key}={values[key]}")
warning = available < 12288 or pvc_gib >= 96
print(f"capacity_warning_band={'yes' if warning else 'no'}")
print("SCAN-01 capacity stop/go=GO")
PY
