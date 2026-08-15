#!/usr/bin/env bash
# OPS-DRIFT-01: OPNsense config XML drift detector (Read-only)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE=""
JSON_OUTPUT=0
ENV_FILE=""

usage() {
  cat <<EOF
사용법: $0 [옵션]

OPNsense의 라이브 설정과 Git 사본을 비교하여 드리프트를 탐지합니다.
이 도구는 순수 Read-only이며 어떤 경우에도 --update 또는 라이브 수정을 수행하지 않습니다.

옵션:
  --fixture <파일>   라이브 API 호출 대신 지정된 diff fixture 파일을 검사합니다.
  --env-file <파일>  OPNsense 접속 정보를 담은 env 파일 경로입니다.
  --json             결과를 JSON 형식으로 출력합니다.
  -h, --help         도움말을 출력합니다.

종료 코드:
  0: 드리프트 없음
  2: 드리프트 감지
  1: 실행 오류
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixture)
      [ "$#" -ge 2 ] || { echo "오류: --fixture 뒤에 파일 경로가 필요합니다." >&2; exit 1; }
      FIXTURE="$2"
      shift 2
      ;;
    --env-file)
      [ "$#" -ge 2 ] || { echo "오류: --env-file 뒤에 파일 경로가 필요합니다." >&2; exit 1; }
      ENV_FILE="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "오류: 알 수 없는 옵션: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

TMP_DIR="$(mktemp -d /tmp/ops-drift-opnsense.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

DRIFT_DIFF=""
DRIFT_FOUND=0

if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE" ] || { echo "오류: fixture 파일이 없습니다: $FIXTURE" >&2; exit 1; }
  DRIFT_DIFF="$(cat "$FIXTURE")"
  if [ -n "$DRIFT_DIFF" ]; then
    DRIFT_FOUND=1
  fi
else
  OPN_SCRIPT="$REPO_ROOT/infra/opnsense/scripts/check-drift.sh"
  [ -f "$OPN_SCRIPT" ] || { echo "오류: $OPN_SCRIPT 가 존재하지 않습니다." >&2; exit 1; }

  OPN_ARGS=()
  if [ -n "$ENV_FILE" ]; then
    OPN_ARGS+=(--env-file "$ENV_FILE")
  fi

  # 실행 (절대 --update 전달 금지)
  set +e
  RAW_OUTPUT="$(bash "$OPN_SCRIPT" "${OPN_ARGS[@]}" 2>&1)"
  EXIT_CODE=$?
  set -e

  if [ $EXIT_CODE -eq 0 ]; then
    DRIFT_FOUND=0
  elif [ $EXIT_CODE -eq 1 ]; then
    DRIFT_FOUND=1
    DRIFT_DIFF="$RAW_OUTPUT"
  else
    echo "OPNsense 드리프트 조회 중 오류 발생 (exit $EXIT_CODE):" >&2
    echo "$RAW_OUTPUT" >&2
    exit 1
  fi
fi

# diff 요약 (비밀/민감정보 제외)
DIFF_SUMMARY="$(echo "$DRIFT_DIFF" | python3 -c '
import sys, re
lines = sys.stdin.read().splitlines()
summary_lines = []
for line in lines:
    # 민감 key 마스킹 및 요약 필터링
    if line.startswith(("+", "-", "@@")):
        # password/key 등 민감 문자열 마스킹
        sanitized = re.sub(r"(password|secret|key|token)[^<>\n]*", r"\1=***REDACTED***", line, flags=re.IGNORECASE)
        summary_lines.append(sanitized)

print("\n".join(summary_lines[:50]))
if len(summary_lines) > 50:
    print(f"... ({len(summary_lines) - 50} lines truncated)")
')"

if [ "$JSON_OUTPUT" -eq 1 ]; then
  python3 -c '
import json, sys
found = int(sys.argv[1])
summary = sys.argv[2]
result = {
    "layer": "opnsense",
    "has_drift": found == 1,
    "drift_summary": summary if found == 1 else ""
}
print(json.dumps(result, indent=2))
' "$DRIFT_FOUND" "$DIFF_SUMMARY"
else
  if [ "$DRIFT_FOUND" -eq 0 ]; then
    echo "OPNsense Drift: PASS (drift=0건, Git 사본과 일치)"
  else
    echo "════ OPNsense Config XML Drift 감지 ════"
    echo "$DIFF_SUMMARY"
    echo "═══════════════════════════════════════"
  fi
fi

if [ "$DRIFT_FOUND" -eq 1 ]; then
  exit 2
fi

exit 0
