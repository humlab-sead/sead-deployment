#!/bin/bash

# Load .env
export $(grep -v '^#' .env | xargs)

# Define the base URL using WEB_PORT from .env
BASE_URL="http://localhost:${WEB_PORT}"

TIMEOUT=10

# Call /flush/graphcache
echo "Calling ${BASE_URL}/jsonapi/flush/graphcache..."
curl -m "$TIMEOUT" -u "$JAS_PROTECTED_ENDPOINTS_USER:$JAS_PROTECTED_ENDPOINTS_PASS" "${BASE_URL}/jsonapi/flush/graphcache"

echo -e "\nDone."
