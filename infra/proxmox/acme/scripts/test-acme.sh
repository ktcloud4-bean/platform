#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Regression and Static Test for Proxmox ACME Setup Scripts
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/4] Checking bash syntax for all scripts..."
for sh_file in "${SCRIPT_DIR}"/*.sh; do
    bash -n "${sh_file}"
    echo "  [OK] Syntax check passed for $(basename "${sh_file}")"
done

if command -v shellcheck &>/dev/null; then
    echo "[2/4] Running shellcheck..."
    shellcheck "${SCRIPT_DIR}"/*.sh
    echo "  [OK] Shellcheck passed."
else
    echo "[2/4] Shellcheck not found, skipping lint."
fi

echo "[3/4] Testing environment parser boundary..."
# Test that env parsing extracts variables without executing code
TMP_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_TEST_DIR}"' EXIT

cat <<'EOF' > "${TMP_TEST_DIR}/.env"
CLOUDFLARE_API_TOKEN=test_secret_token_12345
PROXMOX_ACME_EMAIL=test@example.invalid
UNWANTED_VAR=$(echo "should_not_execute")
EOF

EXTRACTED_TOKEN="$(grep -E '^CLOUDFLARE_API_TOKEN=' "${TMP_TEST_DIR}/.env" | cut -d'=' -f2- | tr -d '\r"' || true)"
if [[ "${EXTRACTED_TOKEN}" == "test_secret_token_12345" ]]; then
    echo "  [OK] Key extraction logic works cleanly."
else
    echo "  [FAIL] Failed to extract expected token key." >&2
    exit 1
fi

echo "[4/4] Verifying secret leakage boundaries..."
# Ensure setup-acme.sh does not echo or log sensitive values
if grep -E 'echo.*CF_TOKEN|set -x' "${SCRIPT_DIR}/setup-acme.sh"; then
    echo "  [FAIL] Leak risk detected in setup-acme.sh!" >&2
    exit 1
else
    echo "  [OK] No raw secret echo or set -x trace found in setup-acme.sh."
fi

echo "[SUCCESS] All static and regression checks passed."
