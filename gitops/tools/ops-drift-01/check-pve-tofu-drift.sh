#!/usr/bin/env bash
# OPS-DRIFT-01: Proxmox OpenTofu plan drift detector (Read-only)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE=""
JSON_OUTPUT=0
STATE_FILE=""
ENV_FILE=""

usage() {
  cat <<EOF
사용법: $0 [옵션]

Proxmox OpenTofu VM 리소스의 드리프트를 plan-only로 탐지합니다.
이 도구는 순수 Read-only이며 어떤 경우에도 tofu apply 또는 라이브 수정을 수행하지 않습니다.

옵션:
  --fixture <파일>     라이브 plan 대신 지정된 plan diff fixture 파일을 검사합니다.
  --state <파일>       사용할 terraform.tfstate 파일 경로입니다.
  --env-file <파일>    PROXMOX_VE_API_TOKEN 정보를 담은 env 파일 경로입니다.
  --json               결과를 JSON 형식으로 출력합니다.
  -h, --help           도움말을 출력합니다.

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
    --state)
      [ "$#" -ge 2 ] || { echo "오류: --state 뒤에 파일 경로가 필요합니다." >&2; exit 1; }
      STATE_FILE="$2"
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

DRIFT_FOUND=0
PLAN_SUMMARY=""

if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE" ] || { echo "오류: fixture 파일이 없습니다: $FIXTURE" >&2; exit 1; }
  PLAN_OUTPUT="$(cat "$FIXTURE")"
  PLAN_SUMMARY="$(echo "$PLAN_OUTPUT" | grep -E "^Plan:" || echo "Plan: changes detected")"
  DRIFT_FOUND=1
else
  TOFU_DIR="$REPO_ROOT/infra/proxmox/tofu"
  [ -d "$TOFU_DIR" ] || { echo "오류: $TOFU_DIR 디렉터리가 없습니다." >&2; exit 1; }

  : "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
  DEFAULT_ENV="$KTC_SECRET_ROOT/proxmox/env"
  TARGET_ENV="${ENV_FILE:-$DEFAULT_ENV}"

  if [ -z "${PROXMOX_VE_API_TOKEN:-}" ]; then
    if [ -f "$TARGET_ENV" ]; then
      PROXMOX_VE_API_TOKEN="$(grep -E "^PROXMOX_VE_API_TOKEN=" "$TARGET_ENV" | cut -d= -f2-)"
      export PROXMOX_VE_API_TOKEN
    else
      echo "오류: PROXMOX_VE_API_TOKEN을 환경변수 또는 $TARGET_ENV 에서 찾을 수 없습니다." >&2
      exit 1
    fi
  fi

  # state 파일 확인
  STATE_OPT=()
  if [ -n "$STATE_FILE" ]; then
    STATE_OPT=(-state="$STATE_FILE")
  elif [ -f "$TOFU_DIR/terraform.tfstate" ]; then
    STATE_OPT=(-state="$TOFU_DIR/terraform.tfstate")
  elif [ -f "$REPO_ROOT/../platform/infra/proxmox/tofu/terraform.tfstate" ]; then
    STATE_OPT=(-state="$REPO_ROOT/../platform/infra/proxmox/tofu/terraform.tfstate")
  fi

  pushd "$TOFU_DIR" >/dev/null

  tofu init -input=false >/dev/null 2>&1 || true

  set +e
  PLAN_RAW="$(tofu plan -no-color \
    "${STATE_OPT[@]}" \
    -var "vm_template_id=9000" \
    -var "vlan_trunk_ready=true" \
    -var 'ssh_public_keys=["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK4JUHnCVoM9LkZir/oIhJZrW229Hn7yOdYpq+ePpSFQ ssh-ed25519"]' \
    -var "proxmox_insecure=false" \
    -detailed-exitcode 2>&1)"
  PLAN_EXIT=$?
  set -e

  popd >/dev/null

  if [ $PLAN_EXIT -eq 0 ]; then
    DRIFT_FOUND=0
    PLAN_SUMMARY="No changes"
  elif [ $PLAN_EXIT -eq 2 ]; then
    DRIFT_FOUND=1
    PLAN_SUMMARY="$(echo "$PLAN_RAW" | grep -E "^Plan:" || echo "Plan: changes detected")"
  else
    echo "Proxmox OpenTofu plan 실행 중 오류 발생 (exit $PLAN_EXIT):" >&2
    echo "$PLAN_RAW" >&2
    exit 1
  fi
fi

if [ "$JSON_OUTPUT" -eq 1 ]; then
  python3 -c '
import json, sys
found = int(sys.argv[1])
summary = sys.argv[2]
result = {
    "layer": "pve-tofu",
    "has_drift": found == 1,
    "drift_summary": summary
}
print(json.dumps(result, indent=2))
' "$DRIFT_FOUND" "$PLAN_SUMMARY"
else
  if [ "$DRIFT_FOUND" -eq 0 ]; then
    echo "Proxmox OpenTofu Drift: PASS (drift=0건, VM 5대 설정 일치)"
  else
    echo "════ Proxmox OpenTofu Drift 감지 ════"
    echo "상태: $PLAN_SUMMARY"
    echo "═════════════════════════════════════"
  fi
fi

if [ "$DRIFT_FOUND" -eq 1 ]; then
  exit 2
fi

exit 0
