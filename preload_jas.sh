#!/bin/bash

# Load .env
export $(grep -v '^#' .env | xargs)

# Define the endpoint
URL="http://localhost:8080/jsonapi/rebuild"

# Make the request with Basic Auth
curl -u "$JAS_PROTECTED_ENDPOINTS_USER:$JAS_PROTECTED_ENDPOINTS_PASS" "$URL"

