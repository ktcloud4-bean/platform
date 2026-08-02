#!/usr/bin/env bash
# E2E-01 적용 직전 새 상시 workload가 없는 상태에서 k3s RAM 정지선만 판정한다.
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
printf 'k3s_memory_available_mib='; free -m | awk '/Mem:/ {print $7}'
printf 'k3s_swap_used_mib='; free -m | awk '/Swap:/ {print $3}'
REMOTE
)

python3 - "${metrics}" <<'PY'
import sys

values = {}
for line in sys.argv[1].splitlines():
    key, value = line.split("=", 1)
    values[key] = int(value)

available = values["k3s_memory_available_mib"]
swap = values["k3s_swap_used_mib"]
if available < 8192:
    raise SystemExit("E2E-01 capacity stop: k3s available memory < 8 GiB")
if swap != 0:
    raise SystemExit("E2E-01 capacity stop: k3s swap is in use")

for key in sorted(values):
    print(f"{key}={values[key]}")
print(f"capacity_warning_band={'yes' if available < 12288 else 'no'}")
print("E2E-01 capacity stop/go=GO")
PY
