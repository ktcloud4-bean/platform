#!/usr/bin/env bash

set -euo pipefail

AUTO01_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO01_COMPONENT_DIR="$(cd "$AUTO01_SCRIPT_DIR/.." && pwd)"
AUTO01_REPO_ROOT="$(git -C "$AUTO01_COMPONENT_DIR" rev-parse --show-toplevel)"

# shellcheck source=../sources.lock
. "$AUTO01_COMPONENT_DIR/sources.lock"

auto01_die() {
  printf '오류: %s\n' "$*" >&2
  exit 1
}

auto01_require_command() {
  command -v "$1" >/dev/null 2>&1 || auto01_die "필수 명령을 찾을 수 없습니다: $1"
}

auto01_assert_regular_file() {
  local auto01_path=$1

  [ -e "$auto01_path" ] || auto01_die "파일이 없습니다: $auto01_path"
  [ ! -L "$auto01_path" ] || auto01_die "심볼릭 링크는 허용하지 않습니다: $auto01_path"
  [ ! -b "$auto01_path" ] || auto01_die "블록 장치는 허용하지 않습니다: $auto01_path"
  [ -f "$auto01_path" ] || auto01_die "regular file이 아닙니다: $auto01_path"
}

auto01_assert_safe_external_dir() {
  local auto01_dir=$1
  local auto01_real_dir

  [ -d "$auto01_dir" ] || auto01_die "디렉터리가 없습니다: $auto01_dir"
  [ ! -L "$auto01_dir" ] || auto01_die "심볼릭 링크 디렉터리는 허용하지 않습니다: $auto01_dir"
  auto01_real_dir="$(realpath -e -- "$auto01_dir")"

  case "$auto01_real_dir" in
    /|/home|/home/imcherry|"$AUTO01_REPO_ROOT"|"$AUTO01_REPO_ROOT"/*)
      auto01_die "저장소 또는 광범위한 경로는 산출물 디렉터리로 사용할 수 없습니다: $auto01_real_dir"
      ;;
  esac

  printf '%s\n' "$auto01_real_dir"
}

auto01_create_external_dir() {
  local auto01_dir=$1
  local auto01_parent
  local auto01_name
  local auto01_real_parent
  local auto01_candidate

  if [ -e "$auto01_dir" ]; then
    auto01_assert_safe_external_dir "$auto01_dir"
    return
  fi

  [ ! -L "$auto01_dir" ] || auto01_die "심볼릭 링크 디렉터리는 허용하지 않습니다: $auto01_dir"
  auto01_parent="$(dirname -- "$auto01_dir")"
  auto01_name="$(basename -- "$auto01_dir")"
  [ -d "$auto01_parent" ] || auto01_die "새 디렉터리의 부모가 없습니다: $auto01_parent"
  [ ! -L "$auto01_parent" ] || auto01_die "새 디렉터리의 부모가 심볼릭 링크입니다: $auto01_parent"
  auto01_real_parent="$(realpath -e -- "$auto01_parent")"
  auto01_candidate="$auto01_real_parent/$auto01_name"

  case "$auto01_candidate" in
    /|/home|/home/imcherry|"$AUTO01_REPO_ROOT"|"$AUTO01_REPO_ROOT"/*)
      auto01_die "저장소 또는 광범위한 경로는 만들 수 없습니다: $auto01_candidate"
      ;;
  esac

  mkdir -- "$auto01_candidate"
  auto01_assert_safe_external_dir "$auto01_candidate"
}

auto01_assert_external_target() {
  local auto01_target=$1
  local auto01_parent
  local auto01_name
  local auto01_real_parent
  local auto01_resolved

  [ ! -L "$auto01_target" ] || auto01_die "출력 경로가 심볼릭 링크입니다: $auto01_target"
  auto01_parent="$(dirname -- "$auto01_target")"
  auto01_name="$(basename -- "$auto01_target")"
  [ -d "$auto01_parent" ] || auto01_die "출력 부모 디렉터리가 없습니다: $auto01_parent"
  auto01_real_parent="$(auto01_assert_safe_external_dir "$auto01_parent")"
  auto01_resolved="$auto01_real_parent/$auto01_name"

  case "$auto01_resolved" in
    "$AUTO01_REPO_ROOT"|"$AUTO01_REPO_ROOT"/*)
      auto01_die "출력은 저장소 밖이어야 합니다: $auto01_resolved"
      ;;
  esac

  printf '%s\n' "$auto01_resolved"
}

auto01_verify_sha256() {
  local auto01_path=$1
  local auto01_expected=$2

  auto01_assert_regular_file "$auto01_path"
  printf '%s  %s\n' "$auto01_expected" "$auto01_path" | sha256sum --check --status \
    || auto01_die "SHA256 불일치: $auto01_path"
}

auto01_read_one_line() {
  local auto01_path=$1
  local auto01_variable_name=$2
  local -a auto01_lines=()

  auto01_assert_regular_file "$auto01_path"
  mapfile -t auto01_lines < "$auto01_path"
  [ "${#auto01_lines[@]}" -eq 1 ] || auto01_die "정확히 한 줄이어야 합니다: $auto01_path"
  [ -n "${auto01_lines[0]}" ] || auto01_die "빈 입력은 허용하지 않습니다: $auto01_path"
  printf -v "$auto01_variable_name" '%s' "${auto01_lines[0]}"
}

auto01_validate_port() {
  local auto01_port=$1

  [[ "$auto01_port" =~ ^[0-9]+$ ]] || auto01_die "포트가 숫자가 아닙니다: $auto01_port"
  [ "$auto01_port" -ge 1024 ] && [ "$auto01_port" -le 65535 ] \
    || auto01_die "포트는 1024..65535 범위여야 합니다: $auto01_port"
}

auto01_assert_poc_dir_name() {
  local auto01_dir=$1
  local auto01_real_dir

  auto01_real_dir="$(auto01_assert_safe_external_dir "$auto01_dir")"
  case "$(basename -- "$auto01_real_dir")" in
    auto-01-poc.*) ;;
    *) auto01_die "PoC 디렉터리 이름은 auto-01-poc.* 이어야 합니다: $auto01_real_dir" ;;
  esac
  printf '%s\n' "$auto01_real_dir"
}

auto01_assert_image_available() {
  auto01_require_command podman
  podman image exists "$PVE_ASSISTANT_IMAGE" \
    || auto01_die "assistant 이미지가 없습니다. scripts/build-assistant-image.sh를 먼저 실행하세요."
}
