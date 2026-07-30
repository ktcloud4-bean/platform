#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  printf '사용법: %s <외부-cache-dir>\n' "$0"
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }

auto01_require_command podman
auto01_require_command sha256sum
[ "$(uname -m)" = "x86_64" ] || auto01_die "고정한 assistant 패키지는 x86_64 전용입니다."

AUTO01_CACHE_DIR="$(auto01_assert_safe_external_dir "$1")"
AUTO01_ASSISTANT_DIR="$AUTO01_CACHE_DIR/assistant"
AUTO01_ASSISTANT_DEB="$AUTO01_ASSISTANT_DIR/$PVE_ASSISTANT_FILENAME"
auto01_verify_sha256 "$AUTO01_ASSISTANT_DEB" "$PVE_ASSISTANT_SHA256"

if ! podman image exists "$PVE_ASSISTANT_IMAGE"; then
  podman build --pull=never --tag "$PVE_ASSISTANT_IMAGE" \
    --file "$AUTO01_COMPONENT_DIR/Containerfile.assistant" "$AUTO01_ASSISTANT_DIR"
fi

AUTO01_ACTUAL_VERSION="$(podman run --rm --network=none --pull=never \
  --security-opt=no-new-privileges --cap-drop=all \
  "$PVE_ASSISTANT_IMAGE" --version 2>&1)"
case "$AUTO01_ACTUAL_VERSION" in
  *"$PVE_ASSISTANT_VERSION") ;;
  *) auto01_die "assistant 이미지 버전이 다릅니다: $AUTO01_ACTUAL_VERSION" ;;
esac

printf 'assistant 이미지 준비 완료: %s (%s)\n' "$PVE_ASSISTANT_IMAGE" "$AUTO01_ACTUAL_VERSION"
