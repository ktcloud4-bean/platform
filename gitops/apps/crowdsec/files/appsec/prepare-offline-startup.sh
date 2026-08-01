#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: prepare-offline-startup.sh SOURCE OUTPUT SOURCE_SHA256 OUTPUT_SHA256" >&2
  exit 2
fi

source_path=$1
output_path=$2
source_sha256=$3
output_sha256=$4

printf '%s\n' "$source_sha256" "$output_sha256" | grep -Eq '^[0-9a-f]{64}$' || {
  echo "invalid startup SHA-256" >&2
  exit 2
}

actual_source_sha256=$(sha256sum "$source_path" | cut -d ' ' -f 1)
if [ "$actual_source_sha256" != "$source_sha256" ]; then
  echo "upstream startup SHA-256 mismatch: $actual_source_sha256" >&2
  exit 1
fi

if [ -e "$output_path" ]; then
  if [ ! -f "$output_path" ]; then
    echo "existing offline startup is not a regular file" >&2
    exit 1
  fi
  actual_output_sha256=$(sha256sum "$output_path" | cut -d ' ' -f 1)
  if [ "$actual_output_sha256" != "$output_sha256" ]; then
    echo "existing offline startup SHA-256 mismatch: $actual_output_sha256" >&2
    exit 1
  fi
  test "$(grep -xc 'echo "CROWDSEC-01_OFFLINE_STARTUP: Hub preparation disabled"' "$output_path")" -eq 1
  test "$(grep -xc 'prepare_hub' "$output_path" || true)" -eq 0
  echo "CROWDSEC-01_OFFLINE_STARTUP_REUSED"
  exit 0
fi

prepare_hub_calls=$(grep -xc 'prepare_hub' "$source_path" || true)
if [ "$prepare_hub_calls" -ne 1 ]; then
  echo "expected exactly one prepare_hub call, found $prepare_hub_calls" >&2
  exit 1
fi

umask 022
awk '
  $0 == "prepare_hub" {
    print "echo \"CROWDSEC-01_OFFLINE_STARTUP: Hub preparation disabled\""
    replaced++
    next
  }
  { print }
  END { if (replaced != 1) exit 42 }
' "$source_path" > "$output_path"
chmod 0555 "$output_path"

actual_output_sha256=$(sha256sum "$output_path" | cut -d ' ' -f 1)
if [ "$actual_output_sha256" != "$output_sha256" ]; then
  echo "offline startup SHA-256 mismatch: $actual_output_sha256" >&2
  exit 1
fi

test "$(grep -xc 'echo "CROWDSEC-01_OFFLINE_STARTUP: Hub preparation disabled"' "$output_path")" -eq 1
test "$(grep -xc 'prepare_hub' "$output_path" || true)" -eq 0
echo "CROWDSEC-01_OFFLINE_STARTUP_PREPARED"
