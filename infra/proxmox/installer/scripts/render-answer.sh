#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
사용법: $0 <외부-input-dir> <외부-output-answer.toml>

input-dir에 다음 한 줄 파일이 모두 있어야 합니다.
  fqdn, mailto, root-password-hash, root-ssh-key,
  cidr, gateway, dns, nic-mac, disk-serial
EOF
}

auto01_validate_ipv4() {
  local auto01_address=$1
  local auto01_octet
  local -a auto01_octets=()

  IFS=. read -r -a auto01_octets <<< "$auto01_address"
  [ "${#auto01_octets[@]}" -eq 4 ] || return 1
  for auto01_octet in "${auto01_octets[@]}"; do
    [[ "$auto01_octet" =~ ^[0-9]{1,3}$ ]] || return 1
    [ "$((10#$auto01_octet))" -le 255 ] || return 1
  done
}

[ "$#" -eq 2 ] || { usage >&2; exit 2; }

AUTO01_INPUT_DIR="$(auto01_assert_safe_external_dir "$1")"
AUTO01_OUTPUT="$(auto01_assert_external_target "$2")"
[ ! -e "$AUTO01_OUTPUT" ] || auto01_die "기존 answer를 덮어쓰지 않습니다: $AUTO01_OUTPUT"

auto01_read_one_line "$AUTO01_INPUT_DIR/fqdn" AUTO01_FQDN
auto01_read_one_line "$AUTO01_INPUT_DIR/mailto" AUTO01_MAILTO
auto01_read_one_line "$AUTO01_INPUT_DIR/root-password-hash" AUTO01_ROOT_PASSWORD_HASH
auto01_read_one_line "$AUTO01_INPUT_DIR/root-ssh-key" AUTO01_ROOT_SSH_KEY
auto01_read_one_line "$AUTO01_INPUT_DIR/cidr" AUTO01_CIDR
auto01_read_one_line "$AUTO01_INPUT_DIR/gateway" AUTO01_GATEWAY
auto01_read_one_line "$AUTO01_INPUT_DIR/dns" AUTO01_DNS
auto01_read_one_line "$AUTO01_INPUT_DIR/nic-mac" AUTO01_NIC_MAC
auto01_read_one_line "$AUTO01_INPUT_DIR/disk-serial" AUTO01_DISK_SERIAL

[[ "$AUTO01_FQDN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$ ]] \
  || auto01_die "FQDN 형식이 올바르지 않습니다."
[[ "$AUTO01_MAILTO" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] \
  || auto01_die "mailto 형식이 올바르지 않습니다."
[[ "$AUTO01_ROOT_PASSWORD_HASH" == \$* ]] || auto01_die "root password는 crypt hash여야 합니다."
case "$AUTO01_ROOT_PASSWORD_HASH" in
  *\"*|*\\*) auto01_die "root password hash에 TOML 문자열 금지 문자가 있습니다." ;;
esac
[[ "$AUTO01_ROOT_SSH_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com)[[:space:]][A-Za-z0-9+/=]+([[:space:]][A-Za-z0-9._@:+/-]+)?$ ]] \
  || auto01_die "SSH 공개키 형식이 허용 범위 밖입니다."

AUTO01_CIDR_ADDRESS=${AUTO01_CIDR%/*}
AUTO01_CIDR_PREFIX=${AUTO01_CIDR##*/}
[ "$AUTO01_CIDR_ADDRESS" != "$AUTO01_CIDR" ] || auto01_die "CIDR prefix가 없습니다."
auto01_validate_ipv4 "$AUTO01_CIDR_ADDRESS" || auto01_die "CIDR 주소가 올바르지 않습니다."
[[ "$AUTO01_CIDR_PREFIX" =~ ^[0-9]{1,2}$ ]] \
  && [ "$AUTO01_CIDR_PREFIX" -ge 1 ] && [ "$AUTO01_CIDR_PREFIX" -le 32 ] \
  || auto01_die "CIDR prefix가 1..32 범위가 아닙니다."
auto01_validate_ipv4 "$AUTO01_GATEWAY" || auto01_die "gateway IPv4가 올바르지 않습니다."
auto01_validate_ipv4 "$AUTO01_DNS" || auto01_die "DNS IPv4가 올바르지 않습니다."
[[ "$AUTO01_NIC_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] \
  || auto01_die "NIC MAC 형식이 올바르지 않습니다."
[[ "$AUTO01_DISK_SERIAL" =~ ^[A-Za-z0-9._-]{4,64}$ ]] \
  || auto01_die "disk serial 형식이 올바르지 않습니다."

AUTO01_NIC_HEX=${AUTO01_NIC_MAC//:/}
AUTO01_NIC_HEX=${AUTO01_NIC_HEX,,}
AUTO01_TEMP_OUTPUT="$(mktemp "$(dirname -- "$AUTO01_OUTPUT")/.answer.toml.XXXXXX")"
chmod 600 "$AUTO01_TEMP_OUTPUT"

auto01_cleanup_render() {
  if [ -n "${AUTO01_TEMP_OUTPUT:-}" ] && [ -f "$AUTO01_TEMP_OUTPUT" ]; then
    unlink "$AUTO01_TEMP_OUTPUT"
  fi
}
trap auto01_cleanup_render EXIT

while IFS= read -r AUTO01_TEMPLATE_LINE || [ -n "$AUTO01_TEMPLATE_LINE" ]; do
  case "$AUTO01_TEMPLATE_LINE" in
    'fqdn = "@@FQDN@@"') printf 'fqdn = "%s"\n' "$AUTO01_FQDN" ;;
    'mailto = "@@MAILTO@@"') printf 'mailto = "%s"\n' "$AUTO01_MAILTO" ;;
    'root-password-hashed = "@@ROOT_PASSWORD_HASH@@"') printf 'root-password-hashed = "%s"\n' "$AUTO01_ROOT_PASSWORD_HASH" ;;
    'root-ssh-keys = ["@@ROOT_SSH_KEY@@"]') printf 'root-ssh-keys = ["%s"]\n' "$AUTO01_ROOT_SSH_KEY" ;;
    'cidr = "@@CIDR@@"') printf 'cidr = "%s"\n' "$AUTO01_CIDR" ;;
    'dns = "@@DNS@@"') printf 'dns = "%s"\n' "$AUTO01_DNS" ;;
    'gateway = "@@GATEWAY@@"') printf 'gateway = "%s"\n' "$AUTO01_GATEWAY" ;;
    'filter.ID_NET_NAME_MAC = "@@NIC_ID_NET_NAME_MAC@@"') printf 'filter.ID_NET_NAME_MAC = "*%s"\n' "$AUTO01_NIC_HEX" ;;
    'filter.ID_SERIAL_SHORT = "@@DISK_ID_SERIAL_SHORT@@"') printf 'filter.ID_SERIAL_SHORT = "%s"\n' "$AUTO01_DISK_SERIAL" ;;
    *) printf '%s\n' "$AUTO01_TEMPLATE_LINE" ;;
  esac
done < "$AUTO01_COMPONENT_DIR/answer.toml.template" > "$AUTO01_TEMP_OUTPUT"

if grep -q '@@[A-Z_]*@@' "$AUTO01_TEMP_OUTPUT"; then
  auto01_die "치환되지 않은 template token이 남았습니다."
fi

mv -- "$AUTO01_TEMP_OUTPUT" "$AUTO01_OUTPUT"
AUTO01_TEMP_OUTPUT=
chmod 600 "$AUTO01_OUTPUT"
printf '실제 answer 생성 완료(내용 비출력): %s\n' "$AUTO01_OUTPUT"
