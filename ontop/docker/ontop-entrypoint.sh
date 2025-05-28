#!/bin/bash

set -e

: "${DATABASE_NAME:?Need to set DATABASE_NAME}"
: "${DOMAIN:?Need to set DOMAIN}"
: "${ONTOP_DB_USER:?Need to set ONTOP_DB_USER}"
: "${ONTOP_DB_PASSWORD:?Need to set ONTOP_DB_PASSWORD}"

MAPPING_FILE="/opt/ontop/models/${DATABASE_NAME}_mapping.obda"
ONTOLOGY_FILE="/opt/ontop/models/${DATABASE_NAME}_ontology.owl"

if [[ ! -f "$MAPPING_FILE" || ! -f "$ONTOLOGY_FILE" ]]; then
  echo "Generating mapping and ontology files, because they were not found."
  ./ontop bootstrap \
    -m $MAPPING_FILE \
    -t $ONTOLOGY_FILE \
    -b https://${DOMAIN}/
fi

echo "Starting Ontop endpoint..."
exec ./ontop endpoint -m $MAPPING_FILE -t $ONTOLOGY_FILE
