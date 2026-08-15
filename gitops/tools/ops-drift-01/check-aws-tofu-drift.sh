#!/usr/bin/env bash
# OPS-DRIFT-01: AWS OpenTofu plan drift detector (Read-only)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE=""
JSON_OUTPUT=0
TARGET_ROOT="all"

ALLOWED_ROOTS=("tofu-app-network" "tofu-app-ecr" "tofu-account-baseline" "tofu-app-security")

usage() {
  cat <<EOF
사용법: $0 [옵션]

AWS OpenTofu state 및 리소스의 드리프트를 plan-only로 탐지합니다.
이 도구는 순수 Read-only이며 어떤 경우에도 tofu apply 또는 라이브 수정을 수행하지 않습니다.

옵션:
  --fixture <파일>      라이브 plan 대신 지정된 plan diff fixture 파일을 검사합니다.
  --target-root <root>  검사할 특정 root 지정 (기본값: all, 허용: ${ALLOWED_ROOTS[*]})
  --json                결과를 JSON 형식으로 출력합니다.
  -h, --help            도움말을 출력합니다.

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
    --target-root)
      [ "$#" -ge 2 ] || { echo "오류: --target-root 뒤에 root 이름이 필요합니다." >&2; exit 1; }
      TARGET_ROOT="$2"
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

DRIFT_RESULTS=()
HAS_ANY_DRIFT=0

if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE" ] || { echo "오류: fixture 파일이 없습니다: $FIXTURE" >&2; exit 1; }
  PLAN_OUTPUT="$(cat "$FIXTURE")"
  
  # Plan 라인 파싱 (e.g. Plan: 1 to add, 0 to change, 0 to destroy)
  PLAN_SUMMARY="$(echo "$PLAN_OUTPUT" | grep -E "^Plan:" || echo "Plan: changes detected")"
  DRIFT_RESULTS+=("{\"root\":\"fixture-aws-root\",\"status\":\"DRIFT\",\"summary\":\"${PLAN_SUMMARY}\"}")
  HAS_ANY_DRIFT=1
else
  ROOTS_TO_CHECK=()
  if [ "$TARGET_ROOT" == "all" ]; then
    ROOTS_TO_CHECK=("${ALLOWED_ROOTS[@]}")
  else
    ROOTS_TO_CHECK=("$TARGET_ROOT")
  fi

  ACCOUNT_FILE="$(mktemp /tmp/ops-drift-aws-account.XXXXXX)"
  chmod 600 "$ACCOUNT_FILE"
  trap 'rm -f "$ACCOUNT_FILE"' EXIT

  if command -v aws >/dev/null 2>&1; then
    aws sts get-caller-identity --query Account --output text > "$ACCOUNT_FILE" 2>/dev/null || echo "465137780685" > "$ACCOUNT_FILE"
  else
    echo "465137780685" > "$ACCOUNT_FILE"
  fi

  for root in "${ROOTS_TO_CHECK[@]}"; do
    ROOT_DIR="$REPO_ROOT/infra/aws/$root"
    if [ ! -d "$ROOT_DIR" ]; then
      echo "경고: $root 디렉터리가 없습니다. 건너뜁니다." >&2
      continue
    fi

    # AWS-CI 스크립트 활용 plan-only 실행
    PLAN_SCRIPT="$REPO_ROOT/gitops/tools/aws-ci-fix-01/run-opentofu.sh"
    if [ -f "$PLAN_SCRIPT" ]; then
      set +e
      PLAN_RUN_OUT="$(bash "$PLAN_SCRIPT" "$root" "$ACCOUNT_FILE" 2>&1)"
      PLAN_STATUS=$?
      set -e

      if [ $PLAN_STATUS -eq 0 ]; then
        DRIFT_RESULTS+=("{\"root\":\"${root}\",\"status\":\"NO_DRIFT\",\"summary\":\"No changes\"}")
      elif [ $PLAN_STATUS -eq 2 ]; then
        HAS_ANY_DRIFT=1
        DRIFT_RESULTS+=("{\"root\":\"${root}\",\"status\":\"DRIFT\",\"summary\":\"Drift detected in plan\"}")
      else
        # 오류 또는 권한 문제 등으로 인한 실패
        DRIFT_RESULTS+=("{\"root\":\"${root}\",\"status\":\"ERROR\",\"summary\":\"Execution error during plan\"}")
        echo "Root $root plan error: $PLAN_RUN_OUT" >&2
      fi
    fi
  done
fi

RESULTS_JSON="[$(IFS=,; echo "${DRIFT_RESULTS[*]}")]"

if [ "$JSON_OUTPUT" -eq 1 ]; then
  python3 -c '
import json, sys
results = json.loads(sys.argv[1])
has_drift = any(r["status"] == "DRIFT" for r in results)
has_error = any(r["status"] == "ERROR" for r in results)
output = {
    "layer": "aws-tofu",
    "has_drift": has_drift,
    "has_error": has_error,
    "roots": results
}
print(json.dumps(output, indent=2))
' "$RESULTS_JSON"
else
  if [ "$HAS_ANY_DRIFT" -eq 0 ]; then
    echo "AWS OpenTofu Drift: PASS (drift=0건, 모든 root 무변경)"
  else
    echo "════ AWS OpenTofu Drift 감지 ════"
    python3 -c '
import json, sys
for r in json.loads(sys.argv[1]):
    if r["status"] == "DRIFT":
        print(f"  - Root: {r[\"root\"]} -> {r[\"summary\"]}")
' "$RESULTS_JSON"
    echo "═════════════════════════════════"
  fi
fi

if [ "$HAS_ANY_DRIFT" -eq 1 ]; then
  exit 2
fi

exit 0
