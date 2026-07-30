#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

AUTO01_POC_MAGIC=ktcloud4-auto01-poc-v1
AUTO01_POC_FQDN=auto01-poc.example.invalid
AUTO01_POC_CIDR=192.0.2.10/24
AUTO01_POC_GATEWAY=192.0.2.2
AUTO01_POC_DNS=192.0.2.3
AUTO01_POC_MAC=52:54:00:12:34:56
AUTO01_POC_DISK_SERIAL=AUTO01POC0001

usage() {
  cat <<EOF
사용법:
  $0 prepare <auto-01-poc.* 디렉터리> <검증된 source.iso> <SSH-host-port> <HTTPS-host-port>
  $0 start <auto-01-poc.* 디렉터리>
  $0 verify <auto-01-poc.* 디렉터리>
  $0 cleanup <auto-01-poc.* 디렉터리>

prepare 대상은 mktemp로 새로 만든 빈 디렉터리여야 합니다. cleanup은 marker와
QEMU 명령행을 확인한 뒤 그 디렉터리 하나만 삭제합니다.
EOF
}

auto01_poc_dir() {
  auto01_assert_poc_dir_name "$1"
}

auto01_require_marker() {
  local auto01_dir=$1
  local auto01_marker

  auto01_read_one_line "$auto01_dir/.auto01-poc-root" auto01_marker
  [ "$auto01_marker" = "$AUTO01_POC_MAGIC" ] || auto01_die "PoC marker가 올바르지 않습니다."
}

auto01_read_poc_port() {
  local auto01_dir=$1
  local auto01_name=$2
  local auto01_variable=$3

  auto01_read_one_line "$auto01_dir/$auto01_name" "$auto01_variable"
  auto01_validate_port "${!auto01_variable}"
}

auto01_pid_is_ours() {
  local auto01_dir=$1
  local auto01_pid=$2
  local auto01_cmdline

  [[ "$auto01_pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$auto01_pid" 2>/dev/null || return 1
  [ -r "/proc/$auto01_pid/cmdline" ] || return 1
  auto01_cmdline="$(tr '\0' '\n' < "/proc/$auto01_pid/cmdline")"
  [[ "$auto01_cmdline" == *qemu-system-x86_64* ]] || return 1
  [[ "$auto01_cmdline" == *auto-01-installer-poc* ]] || return 1
  [[ "$auto01_cmdline" == *"$auto01_dir/target.qcow2"* ]] || return 1
}

auto01_find_ovmf() {
  local auto01_code_candidate
  local auto01_vars_candidate

  if [ -n "${AUTO01_OVMF_CODE_PATH:-}" ] || [ -n "${AUTO01_OVMF_VARS_PATH:-}" ]; then
    [ -n "${AUTO01_OVMF_CODE_PATH:-}" ] && [ -n "${AUTO01_OVMF_VARS_PATH:-}" ] \
      || auto01_die "AUTO01_OVMF_CODE_PATH와 AUTO01_OVMF_VARS_PATH를 함께 지정하세요."
    auto01_assert_regular_file "$AUTO01_OVMF_CODE_PATH"
    auto01_assert_regular_file "$AUTO01_OVMF_VARS_PATH"
    AUTO01_OVMF_CODE=$AUTO01_OVMF_CODE_PATH
    AUTO01_OVMF_VARS=$AUTO01_OVMF_VARS_PATH
    return
  fi

  for auto01_code_candidate in \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd; do
    auto01_vars_candidate="$(dirname -- "$auto01_code_candidate")/OVMF_VARS.fd"
    if [ -f "$auto01_code_candidate" ] && [ -f "$auto01_vars_candidate" ]; then
      AUTO01_OVMF_CODE=$auto01_code_candidate
      AUTO01_OVMF_VARS=$auto01_vars_candidate
      return
    fi
  done

  auto01_die "OVMF_CODE.fd/OVMF_VARS.fd를 찾지 못했습니다."
}

auto01_prepare() {
  local auto01_dir
  local auto01_source_iso
  local auto01_ssh_port=$3
  local auto01_https_port=$4

  auto01_dir="$(auto01_poc_dir "$1")"
  auto01_source_iso="$(realpath -e -- "$2")"
  [ -z "$(find "$auto01_dir" -mindepth 1 -print -quit)" ] \
    || auto01_die "prepare 대상 디렉터리는 비어 있어야 합니다: $auto01_dir"
  auto01_validate_port "$auto01_ssh_port"
  auto01_validate_port "$auto01_https_port"
  [ "$auto01_ssh_port" != "$auto01_https_port" ] || auto01_die "SSH와 HTTPS host port가 같습니다."
  auto01_verify_sha256 "$auto01_source_iso" "$PVE_ISO_SHA256"
  auto01_assert_image_available
  auto01_require_command openssl
  auto01_require_command qemu-img
  auto01_require_command ssh-keygen

  mkdir -p -- "$auto01_dir/inputs" "$auto01_dir/ssh" "$auto01_dir/evidence"
  chmod 700 "$auto01_dir" "$auto01_dir/inputs" "$auto01_dir/ssh" "$auto01_dir/evidence"
  printf '%s\n' "$AUTO01_POC_MAGIC" > "$auto01_dir/.auto01-poc-root"
  printf '%s\n' "$auto01_ssh_port" > "$auto01_dir/ssh-port"
  printf '%s\n' "$auto01_https_port" > "$auto01_dir/https-port"

  ssh-keygen -q -t ed25519 -N '' -C auto-01-poc -f "$auto01_dir/ssh/id_ed25519"
  openssl rand -base64 48 | openssl passwd -6 -stdin > "$auto01_dir/inputs/root-password-hash"

  printf '%s\n' "$AUTO01_POC_FQDN" > "$auto01_dir/inputs/fqdn"
  printf '%s\n' 'auto01-poc@example.invalid' > "$auto01_dir/inputs/mailto"
  cp -- "$auto01_dir/ssh/id_ed25519.pub" "$auto01_dir/inputs/root-ssh-key"
  printf '%s\n' "$AUTO01_POC_CIDR" > "$auto01_dir/inputs/cidr"
  printf '%s\n' "$AUTO01_POC_GATEWAY" > "$auto01_dir/inputs/gateway"
  printf '%s\n' "$AUTO01_POC_DNS" > "$auto01_dir/inputs/dns"
  printf '%s\n' "$AUTO01_POC_MAC" > "$auto01_dir/inputs/nic-mac"
  printf '%s\n' "$AUTO01_POC_DISK_SERIAL" > "$auto01_dir/inputs/disk-serial"

  "$SCRIPT_DIR/render-answer.sh" "$auto01_dir/inputs" "$auto01_dir/answer.toml"
  "$SCRIPT_DIR/assistant.sh" validate "$auto01_dir/answer.toml"
  qemu-img create -f qcow2 "$auto01_dir/target.qcow2" 96G
  auto01_assert_regular_file "$auto01_dir/target.qcow2"
  "$SCRIPT_DIR/assistant.sh" prepare "$auto01_source_iso" \
    "$auto01_dir/answer.toml" "$auto01_dir/proxmox-auto.iso"
  chmod 600 "$auto01_dir/answer.toml" "$auto01_dir/proxmox-auto.iso" \
    "$auto01_dir/target.qcow2" "$auto01_dir/ssh/id_ed25519"
  date -Is > "$auto01_dir/prepared-at"

  printf 'PoC 준비 완료: %s\n' "$auto01_dir"
  stat --format='target=%n type=%F logical-bytes=%s' "$auto01_dir/target.qcow2"
  qemu-img info "$auto01_dir/target.qcow2" | sed -n '1,8p'
}

auto01_start() {
  local auto01_dir
  local auto01_ssh_port
  local auto01_https_port
  local auto01_pid
  local auto01_cmdline_file

  auto01_dir="$(auto01_poc_dir "$1")"
  auto01_require_marker "$auto01_dir"
  auto01_read_poc_port "$auto01_dir" ssh-port auto01_ssh_port
  auto01_read_poc_port "$auto01_dir" https-port auto01_https_port
  auto01_require_command qemu-system-x86_64
  auto01_find_ovmf

  auto01_assert_regular_file "$auto01_dir/target.qcow2"
  auto01_assert_regular_file "$auto01_dir/proxmox-auto.iso"
  auto01_assert_regular_file "$auto01_dir/answer.toml"
  case "$auto01_dir/target.qcow2" in
    /dev/*) auto01_die "대상 디스크에 /dev 경로를 사용할 수 없습니다." ;;
    *','*) auto01_die "QEMU drive 경로에 쉼표를 사용할 수 없습니다." ;;
  esac
  [ ! -b "$auto01_dir/target.qcow2" ] || auto01_die "target이 block device입니다."
  [ ! -e "$auto01_dir/qemu.pid" ] || auto01_die "기존 qemu.pid가 있습니다. 상태를 먼저 확인하세요."
  [ ! -e "$auto01_dir/OVMF_VARS.fd" ] || auto01_die "기존 OVMF_VARS.fd를 덮어쓰지 않습니다."
  if nc -z -w 1 127.0.0.1 "$auto01_ssh_port" 2>/dev/null; then
    auto01_die "SSH host port가 이미 사용 중입니다: $auto01_ssh_port"
  fi
  if nc -z -w 1 127.0.0.1 "$auto01_https_port" 2>/dev/null; then
    auto01_die "HTTPS host port가 이미 사용 중입니다: $auto01_https_port"
  fi

  cp -- "$AUTO01_OVMF_VARS" "$auto01_dir/OVMF_VARS.fd"
  chmod 600 "$auto01_dir/OVMF_VARS.fd"

  qemu-system-x86_64 \
    -name auto-01-installer-poc \
    -machine q35,accel=kvm \
    -cpu host \
    -smp 4 \
    -m 8192 \
    -drive "if=pflash,format=raw,readonly=on,file=$AUTO01_OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$auto01_dir/OVMF_VARS.fd" \
    -drive "if=none,id=auto01target,file=$auto01_dir/target.qcow2,format=qcow2,cache=none,aio=native,discard=unmap,detect-zeroes=unmap" \
    -device "nvme,drive=auto01target,serial=$AUTO01_POC_DISK_SERIAL" \
    -cdrom "$auto01_dir/proxmox-auto.iso" \
    -boot order=c,once=d,menu=off \
    -nic none \
    -netdev "user,id=auto01net,restrict=on,net=192.0.2.0/24,dhcpstart=192.0.2.100,hostfwd=tcp:127.0.0.1:$auto01_ssh_port-192.0.2.10:22,hostfwd=tcp:127.0.0.1:$auto01_https_port-192.0.2.10:8006" \
    -device "virtio-net-pci,netdev=auto01net,mac=$AUTO01_POC_MAC" \
    -display none \
    -serial "file:$auto01_dir/serial.log" \
    -monitor "unix:$auto01_dir/qemu-monitor.sock,server=on,wait=off" \
    -pidfile "$auto01_dir/qemu.pid" \
    -daemonize \
    > "$auto01_dir/qemu-launch.log" 2>&1

  auto01_read_one_line "$auto01_dir/qemu.pid" auto01_pid
  auto01_pid_is_ours "$auto01_dir" "$auto01_pid" \
    || auto01_die "시작한 QEMU process의 소유 범위를 확인하지 못했습니다."

  auto01_cmdline_file="$auto01_dir/evidence/qemu-command-line.txt"
  tr '\0' '\n' < "/proc/$auto01_pid/cmdline" > "$auto01_cmdline_file"
  [ "$(grep -Fc "$auto01_dir/target.qcow2" "$auto01_cmdline_file")" -eq 1 ] \
    || auto01_die "target qcow2가 QEMU 명령행에 정확히 한 번 나타나지 않습니다."
  if grep -Eq '^/dev/(sd|nvme|vd|xvd)' "$auto01_cmdline_file"; then
    auto01_die "QEMU 명령행에 host block device 경로가 있습니다."
  fi
  date -Is > "$auto01_dir/started-at"
  printf 'Headless QEMU 시작 완료: pid=%s, target=%s\n' "$auto01_pid" "$auto01_dir/target.qcow2"
}

auto01_ssh_setup() {
  local auto01_dir=$1
  local auto01_ssh_port=$2

  AUTO01_SSH=(
    ssh
    -i "$auto01_dir/ssh/id_ed25519"
    -p "$auto01_ssh_port"
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$auto01_dir/ssh/known_hosts"
    root@127.0.0.1
  )
}

auto01_wait_for_ssh() {
  local auto01_dir=$1
  local auto01_pid=$2
  local auto01_timeout=${AUTO01_INSTALL_TIMEOUT_SECONDS:-2700}
  local auto01_elapsed=0

  while [ "$auto01_elapsed" -lt "$auto01_timeout" ]; do
    auto01_pid_is_ours "$auto01_dir" "$auto01_pid" \
      || auto01_die "설치 대기 중 QEMU가 종료됐습니다. qemu-launch.log/serial.log를 확인하세요."
    if "${AUTO01_SSH[@]}" true >/dev/null 2>&1; then
      return
    fi
    sleep 5
    auto01_elapsed=$((auto01_elapsed + 5))
  done

  auto01_die "제한 시간 안에 설치된 시스템의 SSH가 열리지 않았습니다."
}

auto01_collect_guest_evidence() {
  local auto01_output=$1

  "${AUTO01_SSH[@]}" 'bash -se' > "$auto01_output" <<'GUEST_CHECKS'
set -euo pipefail

test "$(hostname -f)" = "auto01-poc.example.invalid"
pveversion | grep -Eq '^pve-manager/9\.2\.'
test "$(findmnt -n -o FSTYPE /)" = "ext4"
test "$(findmnt -n -o SOURCE /)" = "/dev/mapper/pve-root"
test "$(timedatectl show --property=Timezone --value)" = "Asia/Seoul"
test -d /sys/firmware/efi
test "$(lsblk -dn -o TYPE | grep -c '^disk$')" -eq 1
udevadm info --query=property --name=/dev/nvme0n1 | grep -Fx 'ID_SERIAL_SHORT=AUTO01POC0001'
pvesm status | awk '$1 == "local" && $3 == "active" { local_ok=1 } $1 == "local-lvm" && $3 == "active" { lvm_ok=1 } END { exit !(local_ok && lvm_ok) }'
for auto01_service in pve-cluster pvedaemon pveproxy pvestatd ssh; do
  test "$(systemctl is-active "$auto01_service")" = "active"
  test "$(systemctl is-enabled "$auto01_service")" = "enabled"
done
test "$(systemctl --failed --no-legend --plain | wc -l)" -eq 0
ss -ltn | grep -Eq '[:.]22[[:space:]]'
ss -ltn | grep -Eq '[:.]8006[[:space:]]'

printf 'hostname=%s\n' "$(hostname -f)"
printf 'version=%s\n' "$(pveversion)"
printf 'root=%s %s\n' "$(findmnt -n -o SOURCE /)" "$(findmnt -n -o FSTYPE /)"
printf 'timezone=%s\n' "$(timedatectl show --property=Timezone --value)"
printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'boot_time=%s\n' "$(uptime -s)"
printf 'disk_count=%s\n' "$(lsblk -dn -o TYPE | grep -c '^disk$')"
lsblk -dn -o NAME,TYPE,SIZE,MODEL,SERIAL
pvesm status
systemctl is-active pve-cluster pvedaemon pveproxy pvestatd ssh
ip -4 -br address show
ip -4 route show
GUEST_CHECKS
}

auto01_wait_and_collect() {
  local auto01_output=$1
  local auto01_attempt=0
  local auto01_candidate="$auto01_output.pending"

  while [ "$auto01_attempt" -lt 60 ]; do
    if auto01_collect_guest_evidence "$auto01_candidate" 2>/dev/null; then
      mv -- "$auto01_candidate" "$auto01_output"
      return
    fi
    sleep 5
    auto01_attempt=$((auto01_attempt + 1))
  done

  [ ! -f "$auto01_candidate" ] || sed -n '1,200p' "$auto01_candidate" >&2
  auto01_die "게스트 성공 판정이 5분 안에 모두 충족되지 않았습니다."
}

auto01_verify_https() {
  local auto01_https_port=$1
  local auto01_code

  auto01_code="$(curl -sk --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' \
    "https://127.0.0.1:$auto01_https_port/")"
  [ "$auto01_code" = 200 ] || auto01_die "PVE HTTPS 응답이 200이 아닙니다: $auto01_code"
  printf 'https_status=%s\n' "$auto01_code"
}

auto01_verify() {
  local auto01_dir
  local auto01_ssh_port
  local auto01_https_port
  local auto01_pid
  local auto01_first_boot_id
  local auto01_second_boot_id
  local auto01_down_seen=0
  local auto01_attempt

  auto01_dir="$(auto01_poc_dir "$1")"
  auto01_require_marker "$auto01_dir"
  auto01_read_poc_port "$auto01_dir" ssh-port auto01_ssh_port
  auto01_read_poc_port "$auto01_dir" https-port auto01_https_port
  auto01_read_one_line "$auto01_dir/qemu.pid" auto01_pid
  auto01_pid_is_ours "$auto01_dir" "$auto01_pid" || auto01_die "QEMU process가 실행 중이 아닙니다."
  auto01_require_command curl
  auto01_require_command ssh
  auto01_ssh_setup "$auto01_dir" "$auto01_ssh_port"

  printf '무인 설치 완료와 첫 디스크 부팅을 기다립니다(최대 %s초).\n' "${AUTO01_INSTALL_TIMEOUT_SECONDS:-2700}"
  auto01_wait_for_ssh "$auto01_dir" "$auto01_pid"
  auto01_wait_and_collect "$auto01_dir/evidence/initial-boot.txt"
  auto01_verify_https "$auto01_https_port" > "$auto01_dir/evidence/initial-https.txt"
  auto01_first_boot_id="$("${AUTO01_SSH[@]}" cat /proc/sys/kernel/random/boot_id)"

  "${AUTO01_SSH[@]}" systemctl reboot >/dev/null 2>&1 || true
  for auto01_attempt in $(seq 1 120); do
    if ! "${AUTO01_SSH[@]}" true >/dev/null 2>&1; then
      auto01_down_seen=1
      break
    fi
    sleep 1
  done
  [ "$auto01_down_seen" -eq 1 ] || auto01_die "재부팅 중 SSH port down을 관찰하지 못했습니다."

  auto01_wait_for_ssh "$auto01_dir" "$auto01_pid"
  auto01_wait_and_collect "$auto01_dir/evidence/post-reboot.txt"
  auto01_verify_https "$auto01_https_port" > "$auto01_dir/evidence/post-reboot-https.txt"
  auto01_second_boot_id="$("${AUTO01_SSH[@]}" cat /proc/sys/kernel/random/boot_id)"
  [ "$auto01_first_boot_id" != "$auto01_second_boot_id" ] \
    || auto01_die "재부팅 전후 boot_id가 같습니다."

  {
    printf 'qemu_pid=%s\n' "$auto01_pid"
    printf 'target=%s\n' "$auto01_dir/target.qcow2"
    printf 'target_type=%s\n' "$(stat --format='%F' "$auto01_dir/target.qcow2")"
    printf 'target_is_block=%s\n' "$([ -b "$auto01_dir/target.qcow2" ] && printf yes || printf no)"
    printf 'first_boot_id=%s\n' "$auto01_first_boot_id"
    printf 'second_boot_id=%s\n' "$auto01_second_boot_id"
    printf 'display=none\n'
    printf 'host_block_device_argument=none\n'
  } > "$auto01_dir/evidence/host-safety.txt"
  date -Is > "$auto01_dir/verified-at"

  printf '무인 설치·첫 부팅·명시적 재부팅 검증 완료.\n'
  sed -n '1,40p' "$auto01_dir/evidence/initial-boot.txt"
  sed -n '1,20p' "$auto01_dir/evidence/host-safety.txt"
}

auto01_cleanup() {
  local auto01_dir
  local auto01_pid=
  local auto01_ssh_port=
  local auto01_attempt

  auto01_dir="$(auto01_poc_dir "$1")"
  auto01_require_marker "$auto01_dir"

  if [ -f "$auto01_dir/qemu.pid" ]; then
    auto01_read_one_line "$auto01_dir/qemu.pid" auto01_pid
  fi

  if [ -n "$auto01_pid" ] && kill -0 "$auto01_pid" 2>/dev/null; then
    auto01_pid_is_ours "$auto01_dir" "$auto01_pid" \
      || auto01_die "정리할 QEMU process가 이 PoC 소유임을 확인하지 못했습니다."

    if [ -f "$auto01_dir/ssh-port" ] && [ -f "$auto01_dir/ssh/id_ed25519" ]; then
      auto01_read_poc_port "$auto01_dir" ssh-port auto01_ssh_port
      auto01_ssh_setup "$auto01_dir" "$auto01_ssh_port"
      "${AUTO01_SSH[@]}" systemctl poweroff >/dev/null 2>&1 || true
    fi

    for auto01_attempt in $(seq 1 30); do
      kill -0 "$auto01_pid" 2>/dev/null || break
      sleep 1
    done

    if kill -0 "$auto01_pid" 2>/dev/null && [ -S "$auto01_dir/qemu-monitor.sock" ]; then
      printf 'quit\n' | socat - "UNIX-CONNECT:$auto01_dir/qemu-monitor.sock" >/dev/null 2>&1 || true
    fi
    sleep 1
    if kill -0 "$auto01_pid" 2>/dev/null; then
      kill -TERM "$auto01_pid"
    fi
    for auto01_attempt in $(seq 1 10); do
      kill -0 "$auto01_pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$auto01_pid" 2>/dev/null; then
      kill -KILL "$auto01_pid"
    fi
  fi

  find "$auto01_dir" -xdev -depth -delete
  printf '삭제 완료(복구 불가, 모두 재생성 가능): %s\n' "$auto01_dir"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }

case "$1" in
  prepare)
    [ "$#" -eq 5 ] || { usage >&2; exit 2; }
    auto01_prepare "$2" "$3" "$4" "$5"
    ;;
  start)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    auto01_start "$2"
    ;;
  verify)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    auto01_verify "$2"
    ;;
  cleanup)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    auto01_cleanup "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
