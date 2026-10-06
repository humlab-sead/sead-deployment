#!/bin/bash
# Generates the SAML Service Provider's keys: a signing pair and an encryption pair,
# self-signed for https://$DOMAIN/shibboleth, into router/mounts/shibboleth-keys/.
#
# Run it on each server (and on each developer's machine) - keys are never committed
# or copied between servers. On super.sead.se and browser.sead.se the certificates
# are part of that server's SWAMID registration: generating new ones means updating
# the registration, so existing keys are kept unless --force is given.
#
# Usage: router/scripts/generate-sp-keys.sh [--force]   (DOMAIN is read from .env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEY_DIR="${DEPLOY_DIR}/router/mounts/shibboleth-keys"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ -z "${DOMAIN:-}" && -f "${DEPLOY_DIR}/.env" ]]; then
    DOMAIN="$(grep -m1 -E '^DOMAIN=' "${DEPLOY_DIR}/.env" | cut -d= -f2-)"
fi
: "${DOMAIN:?DOMAIN is not set and not found in .env}"

if [[ -f "${KEY_DIR}/sp-signing-key.pem" && -f "${KEY_DIR}/sp-encrypt-key.pem" && $FORCE -eq 0 ]]; then
    echo "SP keys already exist in ${KEY_DIR}; leaving them alone (use --force to replace them)."
    exit 0
fi

mkdir -p "$KEY_DIR"
# The certificates are public (the dev IdP reads them); the keys are not
chmod 755 "$KEY_DIR"

for use in signing encrypt; do
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -sha256 \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=URI:https://${DOMAIN}/shibboleth" \
        -keyout "${KEY_DIR}/sp-${use}-key.pem" \
        -out "${KEY_DIR}/sp-${use}-cert.pem" 2>/dev/null
    chmod 600 "${KEY_DIR}/sp-${use}-key.pem"
    chmod 644 "${KEY_DIR}/sp-${use}-cert.pem"
done

echo "Generated SP signing and encryption keys for https://${DOMAIN}/shibboleth in ${KEY_DIR}"
if [[ $FORCE -eq 1 ]]; then
    echo "If this SP is registered with SWAMID, its registration needs the new certificates."
fi
