#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Proxmox ACME DNS-01 Setup Script
#
# Usage:
#   ./setup-acme.sh staging     # Register staging account, setup plugin, order staging cert
#   ./setup-acme.sh rollback    # Revert to default PVE Cluster Manager CA cert
#   ./setup-acme.sh production  # Register production account, order production cert
#   ./setup-acme.sh verify      # Perform strict TLS verification and sanity checks
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${ACME_DIR}/../../.." && pwd)"

PVE_HOST="10.10.10.10"
CANONICAL_FQDN="proxmox-01.imcherry5778.xyz"
PORT="8006"
PLUGIN_ID="cf-dns"
STAGING_ACCOUNT="le-staging"
PROD_ACCOUNT="le-production"
STAGING_DIRECTORY="https://acme-staging-v02.api.letsencrypt.org/directory"
PROD_DIRECTORY="https://acme-v02.api.letsencrypt.org/directory"

# Load environment variables without sourcing (prevent shell pollute / code execution)
load_env() {
    local env_file=""
    if [[ -f "${ACME_DIR}/.env" ]]; then
        env_file="${ACME_DIR}/.env"
    elif [[ -f "${REPO_ROOT}/.env" ]]; then
        env_file="${REPO_ROOT}/.env"
    else
        echo "[ERROR] No .env file found in ${ACME_DIR} or ${REPO_ROOT}" >&2
        exit 1
    fi

    # Read keys safely
    CF_TOKEN="$(grep -E '^CLOUDFLARE_API_TOKEN=' "${env_file}" | cut -d'=' -f2- | tr -d '\r"' || true)"
    if [[ -z "${CF_TOKEN}" ]]; then
        echo "[ERROR] CLOUDFLARE_API_TOKEN is missing or empty in ${env_file}" >&2
        exit 1
    fi

    ACME_EMAIL="$(grep -E '^PROXMOX_ACME_EMAIL=' "${env_file}" | cut -d'=' -f2- | tr -d '\r"' || true)"
    if [[ -z "${ACME_EMAIL}" ]]; then
        ACME_EMAIL="admin@imcherry5778.xyz"
    fi
}

run_ssh() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PVE_HOST}" "$@"
}

setup_plugin() {
    load_env
    echo "[INFO] Configuring Proxmox ACME Plugin '${PLUGIN_ID}' via Cloudflare API token..."

    # Write plugin data to temporary file locally and push to host securely
    local tmp_data
    tmp_data="$(mktemp)"
    chmod 600 "${tmp_data}"
    trap 'rm -f "${tmp_data}"' EXIT

    cat <<EOF > "${tmp_data}"
CF_Token=${CF_TOKEN}
EOF

    # Copy data to Proxmox temp location securely
    ssh -o BatchMode=yes "root@${PVE_HOST}" "cat > /tmp/pve_acme_cf.data && chmod 600 /tmp/pve_acme_cf.data" < "${tmp_data}"
    rm -f "${tmp_data}"
    trap - EXIT

    # Execute plugin configuration on Proxmox
    run_ssh "
        set -euo pipefail
        if pvenode acme plugin list | grep -q '^│ ${PLUGIN_ID} '; then
            echo '[INFO] Plugin ${PLUGIN_ID} already exists, updating configuration...'
            pvenode acme plugin set ${PLUGIN_ID} --data /tmp/pve_acme_cf.data
        else
            echo '[INFO] Adding plugin ${PLUGIN_ID}...'
            pvenode acme plugin add dns ${PLUGIN_ID} --api cf --data /tmp/pve_acme_cf.data
        fi
        rm -f /tmp/pve_acme_cf.data
    "
    echo "[INFO] ACME Plugin '${PLUGIN_ID}' configuration completed."
}

register_account() {
    local acc_name="$1"
    local directory="$2"

    load_env
    echo "[INFO] Registering/checking ACME Account '${acc_name}'..."

    run_ssh "
        set -euo pipefail
        if pvenode acme account list | grep -q '^│ ${acc_name} '; then
            echo '[INFO] ACME Account ${acc_name} already registered.'
        else
            echo '[INFO] Registering ACME Account ${acc_name} with directory ${directory}...'
            echo 'y' | pvenode acme account register ${acc_name} ${ACME_EMAIL} --directory ${directory}
        fi
    "
}

set_node_domain() {
    local acc_name="$1"

    echo "[INFO] Setting node domain '${CANONICAL_FQDN}' with plugin '${PLUGIN_ID}' and account '${acc_name}'..."
    run_ssh "
        set -euo pipefail
        pvenode config set --acme account=${acc_name} --acmedomain0 domain=${CANONICAL_FQDN},plugin=${PLUGIN_ID}
    "
}

order_certificate() {
    echo "[INFO] Ordering ACME Certificate for ${CANONICAL_FQDN}..."
    run_ssh "
        set -euo pipefail
        pvenode acme cert order --force 1
    "
}

do_staging() {
    echo "=== Starting ACME Staging Setup ==="
    setup_plugin
    register_account "${STAGING_ACCOUNT}" "${STAGING_DIRECTORY}"
    set_node_domain "${STAGING_ACCOUNT}"
    order_certificate
    echo "[INFO] Staging certificate ordering completed. Validating staging cert..."
    verify_cert "staging"
}

do_rollback() {
    echo "=== Starting ACME Rollback ==="
    echo "[INFO] Reverting Proxmox certificate to default PVE Cluster Manager CA..."
    run_ssh "
        set -euo pipefail
        pvenode cert delete --restart 1
    "
    echo "[INFO] Certificate deleted and pveproxy restarted. Verifying default certificate..."
    sleep 3
    run_ssh "
        set -euo pipefail
        systemctl is-active pveproxy pvedaemon pve-cluster
        curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:${PORT}/ | grep -q '200'
    "
    echo "[INFO] Rollback completed successfully."
}

do_production() {
    echo "=== Starting ACME Production Setup ==="
    setup_plugin
    register_account "${PROD_ACCOUNT}" "${PROD_DIRECTORY}"
    set_node_domain "${PROD_ACCOUNT}"
    order_certificate
    echo "[INFO] Production certificate ordering completed. Validating production cert..."
    verify_cert "production"
}

verify_cert() {
    local mode="${1:-production}"
    echo "=== Certificate Verification (${mode}) ==="

    local cert_info
    cert_info="$(echo | openssl s_client -connect "${PVE_HOST}:${PORT}" 2>/dev/null | openssl x509 -text -noout)"

    echo "[INFO] Checking Subject Alternative Name (SAN)..."
    if echo "${cert_info}" | grep -A1 "Subject Alternative Name" | grep -q "DNS:${CANONICAL_FQDN}"; then
        echo "[OK] SAN matches canonical FQDN: ${CANONICAL_FQDN}"
    else
        echo "[ERROR] SAN does not match canonical FQDN!" >&2
        echo "${cert_info}" | grep -A1 "Subject Alternative Name" >&2
        exit 1
    fi

    # Ensure no wildcard or internal IP in SAN for production
    if [[ "${mode}" == "production" ]]; then
        if echo "${cert_info}" | grep -A1 "Subject Alternative Name" | grep -E -q '\*|IP Address:10\.'; then
            echo "[ERROR] Wildcard or internal IP address found in production SAN!" >&2
            exit 1
        fi
        echo "[INFO] Checking Certificate Issuer..."
        if echo "${cert_info}" | grep "Issuer:" | grep -q "Let's Encrypt"; then
            echo "[OK] Valid Let's Encrypt production issuer found."
        else
            echo "[ERROR] Unexpected issuer for production mode!" >&2
            echo "${cert_info}" | grep "Issuer:" >&2
            exit 1
        fi
    fi

    echo "[INFO] Checking Certificate Expiration and System Time..."
    echo | openssl s_client -connect "${PVE_HOST}:${PORT}" 2>/dev/null | openssl x509 -noout -dates
    run_ssh "timedatectl | grep 'System clock synchronized'"

    if [[ "${mode}" == "production" ]]; then
        echo "[INFO] Testing Strict TLS Connection with system trust store..."
        local http_code
        http_code="$(curl -s -o /dev/null -w '%{http_code}' "https://${CANONICAL_FQDN}:${PORT}/" || true)"
        if [[ "${http_code}" == "200" ]]; then
            echo "[OK] Strict HTTPS curl to https://${CANONICAL_FQDN}:${PORT}/ returned HTTP 200 with 0 exit code."
        else
            echo "[ERROR] Strict HTTPS curl failed with HTTP code '${http_code}'" >&2
            exit 1
        fi
    fi

    echo "[INFO] Checking _acme-challenge TXT cleanup in DNS..."
    local txt_record
    txt_record="$(dig +short TXT "_acme-challenge.${CANONICAL_FQDN}" @1.1.1.1 || true)"
    if [[ -z "${txt_record}" ]]; then
        echo "[OK] No residual _acme-challenge TXT record in public DNS."
    else
        echo "[WARNING] Residual TXT record found: ${txt_record}"
    fi

    echo "[INFO] Verification succeeded for mode '${mode}'."
}

case "${1:-}" in
    staging)
        do_staging
        ;;
    rollback)
        do_rollback
        ;;
    production)
        do_production
        ;;
    plugin)
        setup_plugin
        ;;
    verify)
        verify_cert "production"
        ;;
    *)
        echo "Usage: $0 {staging|rollback|production|plugin|verify}"
        exit 1
        ;;
esac
