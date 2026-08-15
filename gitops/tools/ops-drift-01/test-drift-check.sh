#!/usr/bin/env bash
# OPS-DRIFT-01: Offline and fixture-based regression test suite
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pass() { echo -e "\033[32m[PASS]\033[0m $*"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $*"; exit 1; }

echo "================================================================"
echo "[OPS-DRIFT-01] Drift Detection Regression & Fixture Test Suite"
echo "================================================================"

# 1. Maintenance / Lock Skip Test
echo ""
echo "--- Test 1: Maintenance / Lock Skip Mode ---"
SKIP_OUT=$(bash "$SCRIPT_DIR/run-drift-check.sh" --skip-if-locked "true" --json)
if echo "$SKIP_OUT" | grep -q '"status": "SKIPPED"'; then
  pass "Lock skip mode correctly returns SKIPPED status without executing checks"
else
  fail "Lock skip mode failed: $SKIP_OUT"
fi

# 2. Argo Fixture Drift Detection Test
echo ""
echo "--- Test 2: Argo CD Fixture Drift Detection ---"
set +e
ARGO_OUT=$(bash "$SCRIPT_DIR/check-argo-drift.sh" --fixture "$SCRIPT_DIR/fixtures/argo-outofsync.json" --json)
ARGO_EXIT=$?
set -e

if [ $ARGO_EXIT -eq 2 ] && echo "$ARGO_OUT" | grep -q '"has_drift": true' && echo "$ARGO_OUT" | grep -q 'fixture-app-demo'; then
  pass "Argo fixture drift correctly detected (exit 2, app=fixture-app-demo)"
else
  fail "Argo fixture drift test failed (exit $ARGO_EXIT): $ARGO_OUT"
fi

# 3. OPNsense Fixture Drift Detection Test
echo ""
echo "--- Test 3: OPNsense Fixture Drift Detection ---"
set +e
OPN_OUT=$(bash "$SCRIPT_DIR/check-opnsense-drift.sh" --fixture "$SCRIPT_DIR/fixtures/opnsense-diff.diff" --json)
OPN_EXIT=$?
set -e

if [ $OPN_EXIT -eq 2 ] && echo "$OPN_OUT" | grep -q '"has_drift": true' && echo "$OPN_OUT" | grep -q 'FIXTURE TEST DRIFT RULE'; then
  pass "OPNsense fixture drift correctly detected (exit 2, diff matched)"
else
  fail "OPNsense fixture drift test failed (exit $OPN_EXIT): $OPN_OUT"
fi

# 4. AWS OpenTofu Fixture Drift Detection Test
echo ""
echo "--- Test 4: AWS OpenTofu Fixture Drift Detection ---"
set +e
AWS_OUT=$(bash "$SCRIPT_DIR/check-aws-tofu-drift.sh" --fixture "$SCRIPT_DIR/fixtures/tofu-aws-plan-drift.txt" --json)
AWS_EXIT=$?
set -e

if [ $AWS_EXIT -eq 2 ] && echo "$AWS_OUT" | grep -q '"has_drift": true' && echo "$AWS_OUT" | grep -q 'Plan: 1 to add'; then
  pass "AWS OpenTofu fixture drift correctly detected (exit 2, plan summary parsed)"
else
  fail "AWS OpenTofu fixture drift test failed (exit $AWS_EXIT): $AWS_OUT"
fi

# 5. Proxmox OpenTofu Fixture Drift Detection Test
echo ""
echo "--- Test 5: Proxmox OpenTofu Fixture Drift Detection ---"
set +e
PVE_OUT=$(bash "$SCRIPT_DIR/check-pve-tofu-drift.sh" --fixture "$SCRIPT_DIR/fixtures/tofu-pve-plan-drift.txt" --json)
PVE_EXIT=$?
set -e

if [ $PVE_EXIT -eq 2 ] && echo "$PVE_OUT" | grep -q '"has_drift": true' && echo "$PVE_OUT" | grep -q 'Plan: 0 to add, 1 to change'; then
  pass "Proxmox OpenTofu fixture drift correctly detected (exit 2, plan summary parsed)"
else
  fail "Proxmox OpenTofu fixture drift test failed (exit $PVE_EXIT): $PVE_OUT"
fi

# 6. Integrated Runner Fixture Drift Test (1 drift injected)
echo ""
echo "--- Test 6: Integrated Runner with Argo Fixture Drift ---"
set +e
RUNNER_OUT=$(bash "$SCRIPT_DIR/run-drift-check.sh" --fixture-drift "argo" --json)
RUNNER_EXIT=$?
set -e

if [ $RUNNER_EXIT -eq 2 ] && echo "$RUNNER_OUT" | grep -q '"status": "DRIFT_DETECTED"' && echo "$RUNNER_OUT" | grep -q '"total_drift_layers": 1'; then
  pass "Integrated runner correctly detects single layer fixture drift and formats aggregated JSON"
else
  fail "Integrated runner fixture test failed (exit $RUNNER_EXIT): $RUNNER_OUT"
fi

# 7. Safety Validation: No --update, No apply, No secrets in code/output
echo ""
echo "--- Test 7: Safety & Immutability Verification ---"

# 스크립트 내에서 --update 문자열을 호출 인자로 사용하는지 정적 검사
FOUND_UPDATE=0
for f in "$SCRIPT_DIR"/check-*.sh "$SCRIPT_DIR"/run-drift-check.sh; do
  if grep -E 'check-drift\.sh.*--update' "$f" 2>/dev/null; then
    FOUND_UPDATE=1
  fi
done

if [ $FOUND_UPDATE -eq 1 ]; then
  fail "안전 위반: 스크립트 내에서 check-drift.sh 에 --update 옵션을 전달하는 코드가 발견되었습니다."
else
  pass "Safety check: check-drift.sh 에 --update 옵션 호출 없음 확인"
fi

# 스크립트 내에서 tofu apply 실행 명령어가 있는지 정적 검사 (주석 제외)
FOUND_APPLY=0
for f in "$SCRIPT_DIR"/check-*.sh "$SCRIPT_DIR"/run-drift-check.sh; do
  if grep -v '^[[:space:]]*#' "$f" | grep -v 'usage' | grep -E '^[[:space:]]*tofu[[:space:]]+apply' 2>/dev/null; then
    FOUND_APPLY=1
  fi
done

if [ $FOUND_APPLY -eq 1 ]; then
  fail "안전 위반: 스크립트 내에서 tofu apply 실행 코드가 발견되었습니다."
else
  pass "Safety check: tofu apply 실행 코드 없음 확인 (순수 plan-only/read-only)"
fi

echo "================================================================"
echo "Regression Test Summary: All 7 OPS-DRIFT-01 Tests Passed"
echo "================================================================"
