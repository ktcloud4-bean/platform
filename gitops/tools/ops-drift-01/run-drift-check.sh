#!/usr/bin/env bash
# OPS-DRIFT-01: Integrated Platform Drift Checker & Notifier
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET_LAYER="all"
FIXTURE_DRIFT="none"
SKIP_IF_LOCKED="false"
MAINTENANCE_LOCK="false"
JSON_OUTPUT=0
NOTIFY_WEBHOOK=""

usage() {
  cat <<EOF
사용법: $0 [옵션]

플랫폼 전체(Argo, OPNsense, AWS OpenTofu, Proxmox OpenTofu)의 정기 drift를 판정하고 요약 보고를 생성합니다.

옵션:
  --target-layer <layer>       검사 대상 (all, argo, opnsense, aws-tofu, pve-tofu, 기본값: all)
  --fixture-drift <layer>      특정 레이어의 fixture drift 주입 (none, argo, opnsense, aws-tofu, pve-tofu)
  --skip-if-locked <bool>      공유 잠금 또는 유지보수 중일 때 실행을 건너뜁니다 (true/false, 기본값: false)
  --maintenance-lock <bool>    유지보수 상태 강제 지정 (true/false)
  --notify-webhook <URL>       드리프트 감지 시 알림을 전송할 Webhook URL (선택)
  --json                       결과를 JSON 형식으로 출력합니다.
  -h, --help                   도움말을 출력합니다.

종료 코드:
  0: 정상 완료 (드리프트 0건 또는 skip)
  2: 드리프트 감지 (1개 이상의 계층에서 불일치 확인)
  1: 실행 오류
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-layer)
      [ "$#" -ge 2 ] || { echo "오류: --target-layer 뒤에 값이 필요합니다." >&2; exit 1; }
      TARGET_LAYER="$2"
      shift 2
      ;;
    --fixture-drift)
      [ "$#" -ge 2 ] || { echo "오류: --fixture-drift 뒤에 값이 필요합니다." >&2; exit 1; }
      FIXTURE_DRIFT="$2"
      shift 2
      ;;
    --skip-if-locked)
      [ "$#" -ge 2 ] || { echo "오류: --skip-if-locked 뒤에 값이 필요합니다." >&2; exit 1; }
      SKIP_IF_LOCKED="$2"
      shift 2
      ;;
    --maintenance-lock)
      [ "$#" -ge 2 ] || { echo "오류: --maintenance-lock 뒤에 값이 필요합니다." >&2; exit 1; }
      MAINTENANCE_LOCK="$2"
      shift 2
      ;;
    --notify-webhook)
      [ "$#" -ge 2 ] || { echo "오류: --notify-webhook 뒤에 URL이 필요합니다." >&2; exit 1; }
      NOTIFY_WEBHOOK="$2"
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

# 1. 유지보수 및 잠금 확인
if [ "$SKIP_IF_LOCKED" == "true" ] || [ "$MAINTENANCE_LOCK" == "true" ]; then
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    echo '{"status": "SKIPPED", "reason": "maintenance_or_shared_lock"}'
  else
    echo "OPS-DRIFT-01: 유지보수 또는 공유 잠금 활성화 상태로 판정되어 drift 검사를 건너뜁니다 (SKIP)."
  fi
  exit 0
fi

FIXTURES_DIR="$SCRIPT_DIR/fixtures"

LAYER_RESULTS=()
TOTAL_DRIFTS=0

run_check() {
  local layer=$1
  local script=$2
  local fixture_file=$3
  
  local args=(--json)
  if [ "$FIXTURE_DRIFT" == "$layer" ] && [ -n "$fixture_file" ] && [ -f "$fixture_file" ]; then
    args+=(--fixture "$fixture_file")
  fi

  set +e
  local out
  out="$(bash "$script" "${args[@]}" 2>&1)"
  local code=$?
  set -e

  if [ $code -eq 2 ]; then
    TOTAL_DRIFTS=$((TOTAL_DRIFTS + 1))
  fi
  LAYER_RESULTS+=("$out")
}

# 2. 각 계층별 검사 실행
if [ "$TARGET_LAYER" == "all" ] || [ "$TARGET_LAYER" == "argo" ]; then
  run_check "argo" "$SCRIPT_DIR/check-argo-drift.sh" "$FIXTURES_DIR/argo-outofsync.json"
fi

if [ "$TARGET_LAYER" == "all" ] || [ "$TARGET_LAYER" == "opnsense" ]; then
  run_check "opnsense" "$SCRIPT_DIR/check-opnsense-drift.sh" "$FIXTURES_DIR/opnsense-diff.diff"
fi

if [ "$TARGET_LAYER" == "all" ] || [ "$TARGET_LAYER" == "aws-tofu" ]; then
  run_check "aws-tofu" "$SCRIPT_DIR/check-aws-tofu-drift.sh" "$FIXTURES_DIR/tofu-aws-plan-drift.txt"
fi

if [ "$TARGET_LAYER" == "all" ] || [ "$TARGET_LAYER" == "pve-tofu" ]; then
  run_check "pve-tofu" "$SCRIPT_DIR/check-pve-tofu-drift.sh" "$FIXTURES_DIR/tofu-pve-plan-drift.txt"
fi

# 3. 결과 종합
SUMMARY_JSON=$(python3 -c '
import json, sys
raw_layers = sys.argv[1:]
parsed = []
for r in raw_layers:
    try:
        parsed.append(json.loads(r))
    except Exception:
        pass

has_any_drift = any(p.get("has_drift", False) for p in parsed)
total_drift_count = sum(1 for p in parsed if p.get("has_drift", False))

output = {
    "status": "DRIFT_DETECTED" if has_any_drift else "PASS",
    "total_drift_layers": total_drift_count,
    "has_drift": has_any_drift,
    "layers": parsed
}
print(json.dumps(output, indent=2))
' "${LAYER_RESULTS[@]}")

if [ "$JSON_OUTPUT" -eq 1 ]; then
  echo "$SUMMARY_JSON"
else
  echo "================================================================"
  echo "OPS-DRIFT-01: 플랫폼 Drift 종합 판정 보고서"
  echo "================================================================"
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
status = data.get("status", "UNKNOWN")
drift_count = data.get("total_drift_layers", 0)

print(f"종합 판정: {status} (드리프트 감지 계층: {drift_count}건)")
print("----------------------------------------------------------------")

for layer in data.get("layers", []):
    l_name = layer.get("layer", "unknown")
    has_d = layer.get("has_drift", False)
    stat_str = "DRIFT 감지" if has_d else "PASS (일치)"
    print(f"[{l_name.upper()}] {stat_str}")
    if has_d:
        if l_name == "argo":
            for app in layer.get("out_of_sync_apps", []):
                print(f"  * Application: {app.get(\"name\")} (sync: {app.get(\"sync_status\")})")
        elif l_name == "opnsense":
            lines = layer.get("drift_summary", "").strip().splitlines()
            for l in lines[:10]:
                print(f"  * {l}")
        elif l_name == "aws-tofu":
            for r in layer.get("roots", []):
                if r.get("status") == "DRIFT":
                    print(f"  * Root: {r.get(\"root\")} ({r.get(\"summary\")})")
        elif l_name == "pve-tofu":
            print(f"  * {layer.get(\"drift_summary\", \"\")}")
print("================================================================")
' "$SUMMARY_JSON"
fi

# 4. 알림 전송 (단일 종합 알림, 중복 방지)
if [ "$TOTAL_DRIFTS" -gt 0 ] && [ -n "$NOTIFY_WEBHOOK" ]; then
  PAYLOAD=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
text = f"[OPS-DRIFT-01] 플랫폼 드리프트 감지 ({data[\"total_drift_layers\"]}개 계층 불일치)\n"
for l in data.get("layers", []):
    if l.get("has_drift", False):
        text += f"- {l.get(\"layer\").upper()}: 드리프트 발생\n"

payload = {
    "text": text,
    "summary": data
}
print(json.dumps(payload))
' "$SUMMARY_JSON")

  curl -s -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
fi

if [ "$TOTAL_DRIFTS" -gt 0 ]; then
  exit 2
fi

exit 0
