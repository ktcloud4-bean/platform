#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  printf '사용법: %s <외부-cache-dir>\n' "$0"
}

auto01_fetch() {
  local auto01_url=$1
  local auto01_destination=$2
  local auto01_partial="$auto01_destination.part"

  if [ -e "$auto01_destination" ]; then
    auto01_assert_regular_file "$auto01_destination"
    return
  fi
  if [ -e "$auto01_partial" ]; then
    auto01_assert_regular_file "$auto01_partial"
  fi

  printf '다운로드: %s\n' "$(basename -- "$auto01_destination")"
  curl --fail --location --continue-at - --silent --show-error \
    "$auto01_url" --output "$auto01_partial"
  [ ! -e "$auto01_destination" ] || auto01_die "다운로드 중 대상 파일이 생겼습니다: $auto01_destination"
  mv -- "$auto01_partial" "$auto01_destination"
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }

auto01_require_command curl
auto01_require_command realpath

AUTO01_CACHE_INPUT=$1
AUTO01_CACHE_DIR="$(auto01_create_external_dir "$AUTO01_CACHE_INPUT")"
for AUTO01_CACHE_SUBDIR in iso keys assistant; do
  if [ -e "$AUTO01_CACHE_DIR/$AUTO01_CACHE_SUBDIR" ]; then
    [ -d "$AUTO01_CACHE_DIR/$AUTO01_CACHE_SUBDIR" ] \
      && [ ! -L "$AUTO01_CACHE_DIR/$AUTO01_CACHE_SUBDIR" ] \
      || auto01_die "cache 하위 경로가 안전한 디렉터리가 아닙니다: $AUTO01_CACHE_SUBDIR"
  else
    mkdir -- "$AUTO01_CACHE_DIR/$AUTO01_CACHE_SUBDIR"
  fi
done

auto01_fetch "$PVE_ISO_URL" "$AUTO01_CACHE_DIR/iso/$PVE_ISO_FILENAME"
auto01_fetch "$PVE_ISO_SIGNATURE_URL" "$AUTO01_CACHE_DIR/iso/$PVE_ISO_FILENAME.asc"
auto01_fetch "$PVE_TRIXIE_KEY_URL" "$AUTO01_CACHE_DIR/keys/$PVE_TRIXIE_KEY_FILENAME"
auto01_fetch "$PVE_BOOKWORM_KEY_URL" "$AUTO01_CACHE_DIR/keys/$PVE_BOOKWORM_KEY_FILENAME"
auto01_fetch "$PVE_ASSISTANT_URL" "$AUTO01_CACHE_DIR/assistant/$PVE_ASSISTANT_FILENAME"

"$SCRIPT_DIR/verify-sources.sh" "$AUTO01_CACHE_DIR"
