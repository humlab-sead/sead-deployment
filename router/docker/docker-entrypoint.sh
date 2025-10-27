#!/bin/sh
set -eu

# Require DOMAIN, others optional depending on how you pass the creds
: "${DOMAIN:?Set DOMAIN in env}"

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

# Render the nginx conf with ${DOMAIN}
envsubst '$DOMAIN' </etc/nginx/templates/default.conf.template \
  >/etc/nginx/conf.d/default.conf

exec "$@"
