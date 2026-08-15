#!/usr/bin/env bash
# OPS-DRIFT-01: Argo Application OutOfSync drift detector (Read-only)
set -Eeuo pipefail

FIXTURE=""
JSON_OUTPUT=0

usage() {
  cat <<EOF
사용법: $0 [옵션]

Argo CD Application들의 동기화 상태(Sync Status)를 점검하여 OutOfSync drift를 탐지합니다.

옵션:
  --fixture <파일>   라이브 클러스터 대신 지정된 JSON fixture 파일을 검사합니다.
  --json             결과를 JSON 형식으로 출력합니다.
  -h, --help         도움말을 출력합니다.

종료 코드:
  0: 드리프트 없음 (모든 앱 Synced)
  2: 드리프트 감지 (1개 이상의 앱이 OutOfSync)
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

if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE" ] || { echo "오류: fixture 파일이 존재하지 않습니다: $FIXTURE" >&2; exit 1; }
  RAW_JSON="$(cat "$FIXTURE")"
else
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "오류: kubectl 명령어를 찾을 수 없습니다." >&2
    exit 1
  fi
  RAW_JSON="$(kubectl get applications.argoproj.io -n argocd -o json 2>/dev/null || echo '{"items":[]}')"
fi

# jq를 사용하여 OutOfSync인 Application 목록 추출
OUT_OF_SYNC_APPS=$(echo "$RAW_JSON" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"JSON 파싱 오류: {e}", file=sys.stderr)
    sys.exit(1)

items = data.get("items", [])
drifts = []

for item in items:
    name = item.get("metadata", {}).get("name", "unknown")
    status = item.get("status", {})
    sync_status = status.get("sync", {}).get("status", "Unknown")
    health_status = status.get("health", {}).get("status", "Unknown")
    
    if sync_status != "Synced":
        drifts.append({
            "name": name,
            "sync_status": sync_status,
            "health_status": health_status
        })

print(json.dumps(drifts))
')

DRIFT_COUNT=$(echo "$OUT_OF_SYNC_APPS" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')

if [ "$JSON_OUTPUT" -eq 1 ]; then
  python3 -c '
import json, sys
apps = json.loads(sys.argv[1])
count = int(sys.argv[2])
result = {
    "layer": "argo",
    "drift_count": count,
    "has_drift": count > 0,
    "out_of_sync_apps": apps
}
print(json.dumps(result, indent=2))
' "$OUT_OF_SYNC_APPS" "$DRIFT_COUNT"
else
  if [ "$DRIFT_COUNT" -eq 0 ]; then
    echo "Argo CD Drift: PASS (drift=0건, 모든 Application Synced)"
  else
    echo "════ Argo CD OutOfSync Drift 감지 ════"
    echo "드리프트 Application 수: ${DRIFT_COUNT}건"
    echo "$OUT_OF_SYNC_APPS" | python3 -c '
import json, sys
for app in json.load(sys.stdin):
    print(f"  - Application: {app[\"name\"]} (sync: {app[\"sync_status\"]}, health: {app[\"health_status\"]})")
'
    echo "═══════════════════════════════════════"
  fi
fi

if [ "$DRIFT_COUNT" -gt 0 ]; then
  exit 2
fi

exit 0
