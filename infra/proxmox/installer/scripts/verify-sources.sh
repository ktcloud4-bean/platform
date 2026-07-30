#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  printf '사용법: %s <외부-cache-dir>\n' "$0"
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }

auto01_require_command gpg
auto01_require_command gpgv
auto01_require_command sha256sum
auto01_require_command stat

AUTO01_CACHE_DIR="$(auto01_assert_safe_external_dir "$1")"
AUTO01_ISO="$AUTO01_CACHE_DIR/iso/$PVE_ISO_FILENAME"
AUTO01_SIGNATURE="$AUTO01_CACHE_DIR/iso/$PVE_ISO_FILENAME.asc"
AUTO01_TRIXIE_KEY="$AUTO01_CACHE_DIR/keys/$PVE_TRIXIE_KEY_FILENAME"
AUTO01_BOOKWORM_KEY="$AUTO01_CACHE_DIR/keys/$PVE_BOOKWORM_KEY_FILENAME"
AUTO01_ASSISTANT="$AUTO01_CACHE_DIR/assistant/$PVE_ASSISTANT_FILENAME"

auto01_verify_sha256 "$AUTO01_ISO" "$PVE_ISO_SHA256"
[ "$(stat --format='%s' "$AUTO01_ISO")" = "$PVE_ISO_SIZE" ] \
  || auto01_die "ISO 크기가 manifest와 다릅니다: $AUTO01_ISO"
auto01_verify_sha256 "$AUTO01_ASSISTANT" "$PVE_ASSISTANT_SHA256"
auto01_assert_regular_file "$AUTO01_SIGNATURE"
auto01_assert_regular_file "$AUTO01_TRIXIE_KEY"
auto01_assert_regular_file "$AUTO01_BOOKWORM_KEY"

AUTO01_TRIXIE_FINGERPRINT="$(gpg --batch --show-keys --with-colons "$AUTO01_TRIXIE_KEY" \
  | awk -F: '$1 == "fpr" { print $10; exit }')"
AUTO01_BOOKWORM_FINGERPRINT="$(gpg --batch --show-keys --with-colons "$AUTO01_BOOKWORM_KEY" \
  | awk -F: '$1 == "fpr" { print $10; exit }')"

[ "$AUTO01_TRIXIE_FINGERPRINT" = "$PVE_TRIXIE_KEY_FINGERPRINT" ] \
  || auto01_die "Trixie release key fingerprint가 다릅니다."
[ "$AUTO01_BOOKWORM_FINGERPRINT" = "$PVE_BOOKWORM_KEY_FINGERPRINT" ] \
  || auto01_die "Bookworm release key fingerprint가 다릅니다."

gpgv --keyring "$AUTO01_TRIXIE_KEY" --keyring "$AUTO01_BOOKWORM_KEY" \
  "$AUTO01_SIGNATURE" "$AUTO01_ISO"

printf '원본 ISO SHA256/크기/서명 검증 완료: %s (%s)\n' "$PVE_ISO_FILENAME" "$PVE_ISO_VERSION"
printf '공식 assistant 패키지 SHA256 검증 완료: %s\n' "$PVE_ASSISTANT_VERSION"
