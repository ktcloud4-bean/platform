#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
사용법:
  $0 validate <외부-answer.toml>
  $0 prepare <공식-source.iso> <외부-answer.toml> <외부-output.iso>
  $0 inspect-safe <iso>
EOF
}

auto01_run() {
  podman run --rm --network=none --pull=never \
    --security-opt=no-new-privileges --cap-drop=all "$@"
}

auto01_cleanup_stage() {
  if [ -n "${AUTO01_STAGE_DIR:-}" ] && [ -d "$AUTO01_STAGE_DIR" ]; then
    find "$AUTO01_STAGE_DIR" -xdev -depth -delete
  fi
}
trap auto01_cleanup_stage EXIT

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
auto01_assert_image_available

case "$1" in
  validate)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    AUTO01_ANSWER="$(realpath -e -- "$2")"
    auto01_assert_regular_file "$AUTO01_ANSWER"
    auto01_run -v "$AUTO01_ANSWER:/answer.toml:ro,Z" \
      "$PVE_ASSISTANT_IMAGE" validate-answer /answer.toml
    ;;
  prepare)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    AUTO01_SOURCE_ISO="$(realpath -e -- "$2")"
    AUTO01_ANSWER="$(realpath -e -- "$3")"
    AUTO01_OUTPUT="$(auto01_assert_external_target "$4")"
    auto01_assert_regular_file "$AUTO01_SOURCE_ISO"
    auto01_assert_regular_file "$AUTO01_ANSWER"
    auto01_verify_sha256 "$AUTO01_SOURCE_ISO" "$PVE_ISO_SHA256"
    [ ! -e "$AUTO01_OUTPUT" ] || auto01_die "기존 ISO를 덮어쓰지 않습니다: $AUTO01_OUTPUT"
    [[ "$(basename -- "$AUTO01_OUTPUT")" =~ ^[A-Za-z0-9._-]+\.iso$ ]] \
      || auto01_die "출력 ISO 파일명은 안전한 문자와 .iso 확장자만 사용합니다."

    AUTO01_STAGE_DIR="$(mktemp -d "$(dirname -- "$AUTO01_OUTPUT")/.assistant-stage.XXXXXX")"
    chmod 700 "$AUTO01_STAGE_DIR"
    auto01_run \
      -v "$AUTO01_SOURCE_ISO:/source.iso:ro,Z" \
      -v "$AUTO01_ANSWER:/answer.toml:ro,Z" \
      -v "$AUTO01_STAGE_DIR:/staging:rw,Z" \
      "$PVE_ASSISTANT_IMAGE" prepare-iso /source.iso \
      --fetch-from iso --answer-file /answer.toml \
      --tmp /staging --output /staging/prepared.iso

    auto01_assert_regular_file "$AUTO01_STAGE_DIR/prepared.iso"
    chmod 600 "$AUTO01_STAGE_DIR/prepared.iso"
    mv -- "$AUTO01_STAGE_DIR/prepared.iso" "$AUTO01_OUTPUT"
    chmod 600 "$AUTO01_OUTPUT"
    auto01_run -v "$AUTO01_OUTPUT:/prepared.iso:ro,Z" \
      "$PVE_ASSISTANT_IMAGE" inspect-iso /prepared.iso \
      | awk '/^(Product:|Auto-install:|Fetch mode:)/ { print }'
    printf '자동설치 ISO 생성 완료: %s\n' "$AUTO01_OUTPUT"
    ;;
  inspect-safe)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    AUTO01_INSPECT_ISO="$(realpath -e -- "$2")"
    auto01_assert_regular_file "$AUTO01_INSPECT_ISO"
    auto01_run -v "$AUTO01_INSPECT_ISO:/inspect.iso:ro,Z" \
      "$PVE_ASSISTANT_IMAGE" inspect-iso /inspect.iso \
      | awk '/^(Product:|Auto-install:|Fetch mode:)/ { print }'
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
