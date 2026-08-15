#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
linter="$repo_root/scripts/check-backlog.sh"
fixtures="$repo_root/scripts/tests/backlog-lint"

assert_pass() {
  local path=$1
  local output

  output=$("$linter" "$path")
  if [[ $output != BACKLOG_LINT=PASS* ]]; then
    printf 'ERROR expected PASS: %s\n' "$path" >&2
    exit 1
  fi
}

assert_failure() {
  local expected=$1
  local path=$2
  local output

  if output=$("$linter" "$path" 2>&1); then
    printf 'ERROR expected failure: %s\n' "$path" >&2
    exit 1
  fi

  if [[ $output != *"$expected"* ]]; then
    printf 'ERROR expected %s from %s\n' "$expected" "$path" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_pass "$repo_root/docs/backlog.md"
assert_pass "$fixtures/clean.md"
assert_failure 'ERROR duplicate ID:' "$fixtures/duplicate-id.md"
assert_failure 'ERROR missing predecessor:' "$fixtures/missing-predecessor.md"
assert_failure 'ERROR invalid status:' "$fixtures/invalid-status.md"
assert_failure 'ERROR premature READY:' "$fixtures/premature-ready.md"

printf 'BACKLOG_LINT_TEST=PASS fixtures=4\n'
