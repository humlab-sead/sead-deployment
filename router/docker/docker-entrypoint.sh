#!/bin/sh
set -eu

# Require DOMAIN, others optional depending on how you pass the creds
: "${DOMAIN:?Set DOMAIN in env}"

# Allow override, otherwise detect the container DNS resolver dynamically.
# This supports both Docker (typically 127.0.0.11) and Podman/Aardvark setups.
if [ -z "${CONTAINER_DNS_RESOLVER:-}" ]; then
  CONTAINER_DNS_RESOLVER="$(awk '/^nameserver[[:space:]]+/ { print $2; exit }' /etc/resolv.conf || true)"
fi
if [ -z "${CONTAINER_DNS_RESOLVER:-}" ]; then
  CONTAINER_DNS_RESOLVER="127.0.0.11"
fi
export CONTAINER_DNS_RESOLVER

# Option 1: plain user/pass from env (BASIC_AUTH_USER / BASIC_AUTH_PASS)
if [ -n "${BASIC_AUTH_USER:-}" ] && [ -n "${BASIC_AUTH_PASS:-}" ]; then
  htpasswd -bc /etc/nginx/.htpasswd "$BASIC_AUTH_USER" "$BASIC_AUTH_PASS"
# Option 2: full htpasswd lines from env (supports multiple users)
elif [ -n "${BASIC_AUTH_HTPASSWD:-}" ]; then
  # e.g. "alice:$apr1$hash...\nbob:$apr1$hash..."
  printf '%s\n' "$BASIC_AUTH_HTPASSWD" > /etc/nginx/.htpasswd
else
  echo "No BASIC_AUTH_USER/BASIC_AUTH_PASS or BASIC_AUTH_HTPASSWD provided." >&2
  exit 1
fi

# ── SAML Service Provider (shibd) ────────────────────────────────────────────
# router/shibboleth is mounted at /etc/sead-shibboleth, the SP keys at
# /etc/shibboleth/keys. A missing piece disables shibd; nginx and everything
# but SAML login keep working.
SHIB_SRC=/etc/sead-shibboleth
SHIB_KEYS=/etc/shibboleth/keys

# local: the dev IdP (sead_idp). swamid: SWAMID through SeamlessAccess.
if [ -z "${SAML_FEDERATION:-}" ]; then
  if [ "${DEPLOY_MODE:-dev}" = "prod" ]; then SAML_FEDERATION=swamid; else SAML_FEDERATION=local; fi
fi
# On super and browser this names an inert server block nobody resolves
SAML_DEV_IDP_HOST="${SAML_DEV_IDP_HOST:-sead-idp.local}"
SEAD_SP_HANDOFF_SECRET="${SEAD_SP_HANDOFF_SECRET:-}"
if [ "$SAML_FEDERATION" = "local" ]; then SHIB_SHOW_ATTRIBUTE_VALUES=true; else SHIB_SHOW_ATTRIBUTE_VALUES=false; fi
export SAML_FEDERATION SAML_DEV_IDP_HOST SEAD_SP_HANDOFF_SECRET SHIB_SHOW_ATTRIBUTE_VALUES

SHIBD_AUTOSTART=true
shib_template="${SHIB_SRC}/shibboleth2.${SAML_FEDERATION}.xml.template"
if [ ! -f "$shib_template" ]; then
  echo "SAML disabled: no Shibboleth template ${shib_template}" >&2
  SHIBD_AUTOSTART=false
fi
for key in sp-signing-key.pem sp-signing-cert.pem sp-encrypt-key.pem sp-encrypt-cert.pem; do
  if [ ! -f "${SHIB_KEYS}/${key}" ]; then
    echo "SAML disabled: SP key ${SHIB_KEYS}/${key} is missing (generate them with router/scripts/generate-sp-keys.sh)" >&2
    SHIBD_AUTOSTART=false
  fi
done
if [ -z "$SEAD_SP_HANDOFF_SECRET" ]; then
  echo "SAML disabled: SEAD_SP_HANDOFF_SECRET is not set" >&2
  SHIBD_AUTOSTART=false
fi
export SHIBD_AUTOSTART

# Every attribute header shibd can produce is one of the ids in attribute-map.xml.
# nginx clears all of them from the client's request before shib_request runs, so
# json_api_server only ever sees the ones shibd set. Deriving the list from the map
# means an attribute added there is cleared without a second edit.
SHIB_ATTRIBUTE_HEADERS=""
if [ -f "${SHIB_SRC}/attribute-map.xml" ]; then
  SHIB_ATTRIBUTE_HEADERS="$(grep -o 'id="[^"]*"' "${SHIB_SRC}/attribute-map.xml" \
    | sed -E 's/^id="(.*)"$/\1/' | sort -u | tr '\n' ' ')"
fi
export SHIB_ATTRIBUTE_HEADERS

mkdir -p /run/shibboleth /var/cache/shibboleth
if [ "$SHIBD_AUTOSTART" = "true" ]; then
  envsubst '$DOMAIN $SAML_DEV_IDP_HOST $SHIB_SHOW_ATTRIBUTE_VALUES' <"$shib_template" >/etc/shibboleth/shibboleth2.xml
  cp "${SHIB_SRC}/attribute-map.xml" "${SHIB_SRC}/md-signer2.crt" /etc/shibboleth/
  echo "SAML enabled: federation ${SAML_FEDERATION}, SP https://${DOMAIN}/shibboleth"
fi

# Render the nginx conf
envsubst '$DOMAIN $CONTAINER_DNS_RESOLVER $SAML_DEV_IDP_HOST $SEAD_SP_HANDOFF_SECRET $SHIB_ATTRIBUTE_HEADERS' \
  </etc/nginx/templates/default.conf.template >/etc/nginx/conf.d/default.conf

exec "$@"
