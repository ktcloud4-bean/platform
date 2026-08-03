#!/bin/sh
set -eu

: "${PKI01_CRL_URL:?PKI01_CRL_URL is required}"
: "${PKI01_CRL_DEST:?PKI01_CRL_DEST is required}"
: "${SSL_CERT_FILE:?SSL_CERT_FILE is required}"

refresh_seconds=${PKI01_REFRESH_SECONDS:-10}
mode=${PKI01_MODE:-loop}
tmp_file=${PKI01_CRL_DEST}.new

fetch_crl() {
  rm -f -- "${tmp_file}"
  if ! wget -q -T 5 -O "${tmp_file}" "${PKI01_CRL_URL}"; then
    rm -f -- "${tmp_file}"
    return 1
  fi
  if ! grep -q '^-----BEGIN X509 CRL-----$' "${tmp_file}" ||
     ! grep -q '^-----END X509 CRL-----$' "${tmp_file}"; then
    rm -f -- "${tmp_file}"
    return 1
  fi
  chmod 0444 "${tmp_file}"
  mv -f -- "${tmp_file}" "${PKI01_CRL_DEST}"
}

if [ "${mode}" = once ]; then
  fetch_crl
  echo 'PKI01CRL=PASS mode=initial'
  exit 0
fi

while :; do
  if ! fetch_crl; then
    echo 'PKI01CRL=DEGRADED reason=fetch-failed existing-crl-preserved' >&2
  fi
  sleep "${refresh_seconds}"
done
