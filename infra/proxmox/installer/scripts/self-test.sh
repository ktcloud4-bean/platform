#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

auto01_require_command python3
auto01_require_command shellcheck

AUTO01_TEST_DIR="$(mktemp -d /tmp/auto01-tests.XXXXXX)"
chmod 700 "$AUTO01_TEST_DIR"

auto01_cleanup_tests() {
  if [ -d "$AUTO01_TEST_DIR" ]; then
    find "$AUTO01_TEST_DIR" -xdev -depth -delete
  fi
}
trap auto01_cleanup_tests EXIT

bash -n "$AUTO01_COMPONENT_DIR/sources.lock" "$AUTO01_SCRIPT_DIR"/*.sh
shellcheck -x -P SCRIPTDIR "$AUTO01_SCRIPT_DIR"/*.sh
python3 -c 'import pathlib, sys, tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text())' \
  "$AUTO01_COMPONENT_DIR/answer.toml.template"

printf 'not-the-expected-content\n' > "$AUTO01_TEST_DIR/wrong-checksum"
if (auto01_verify_sha256 "$AUTO01_TEST_DIR/wrong-checksum" \
    0000000000000000000000000000000000000000000000000000000000000000) \
    >/dev/null 2>&1; then
  auto01_die "잘못된 checksum이 성공했습니다."
fi

mkdir "$AUTO01_TEST_DIR/incomplete-inputs"
if "$AUTO01_SCRIPT_DIR/render-answer.sh" "$AUTO01_TEST_DIR/incomplete-inputs" \
    "$AUTO01_TEST_DIR/answer.toml" >/dev/null 2>&1; then
  auto01_die "누락 입력이 성공했습니다."
fi

for AUTO01_IGNORED_PATH in \
  "$AUTO01_COMPONENT_DIR/answer.toml" \
  "$AUTO01_COMPONENT_DIR/generated.iso" \
  "$AUTO01_COMPONENT_DIR/target.qcow2"; do
  git -C "$AUTO01_REPO_ROOT" check-ignore -q --no-index "$AUTO01_IGNORED_PATH" \
    || auto01_die "민감/생성 산출물 ignore 규칙이 빠졌습니다: $AUTO01_IGNORED_PATH"
done

printf '정적 검사, TOML parse, checksum 실패, 누락 입력, ignore 규칙 검증 완료.\n'
