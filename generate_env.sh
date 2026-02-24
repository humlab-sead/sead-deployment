#!/bin/bash

ENV_EXAMPLE=".env-example"
ENV_FILE=".env"

# Check if .env-example exists
if [ ! -f "$ENV_EXAMPLE" ]; then
  echo "Error: '$ENV_EXAMPLE' does not exist."
  exit 1
fi

# Copy .env-example to .env
cp "$ENV_EXAMPLE" "$ENV_FILE"
echo "Copied '$ENV_EXAMPLE' to '$ENV_FILE'."

# Generate random password without special characters that may break sed
generate_password() {
  # Generates a 16-character alphanumeric password
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

# Replace empty password fields with generated passwords
echo "Filling in password fields with generated passwords..."
while grep -qE '^.*PASSWORD=\s*$' "$ENV_FILE"; do
  password=$(generate_password)
  # Safely replace only the first empty PASSWORD occurrence each time
  sed -i '' -E "0,/^([A-Za-z0-9_]*PASSWORD)=\s*$/s//\1=${password}/" "$ENV_FILE" 2>/dev/null || \
  sed -i -E "0,/^([A-Za-z0-9_]*PASSWORD)=\s*$/s//\1=${password}/" "$ENV_FILE"
done

# Ensure JAS_MONGO_PASS is set if empty
if grep -qE '^JAS_MONGO_PASS=\s*$' "$ENV_FILE"; then
  mongo_pass=$(generate_password)
  sed -i '' -E "s/^JAS_MONGO_PASS=\s*$/JAS_MONGO_PASS=${mongo_pass}/" "$ENV_FILE" 2>/dev/null || \
  sed -i -E "s/^JAS_MONGO_PASS=\s*$/JAS_MONGO_PASS=${mongo_pass}/" "$ENV_FILE"
  echo "Generated random password for JAS_MONGO_PASS. ✅"
fi

# Set chmod permissions
chmod 600 "$ENV_FILE"

echo "All password fields have been updated in '$ENV_FILE'. ✅"

# Handle sead_authority_service/.env file
SAS_ENV_EXAMPLE="./sead_authority_service/.env.example"
SAS_ENV_FILE="./sead_authority_service/.env"

if [ -f "$SAS_ENV_EXAMPLE" ]; then
  cp "$SAS_ENV_EXAMPLE" "$SAS_ENV_FILE"
  echo "Copied '$SAS_ENV_EXAMPLE' to '$SAS_ENV_FILE'."
  
  # Clear OPENAI_API_KEY and GEONAMES_USERNAME to empty values
  sed -i '' -E 's/^OPENAI_API_KEY=.*/OPENAI_API_KEY=/' "$SAS_ENV_FILE" 2>/dev/null || \
  sed -i -E 's/^OPENAI_API_KEY=.*/OPENAI_API_KEY=/' "$SAS_ENV_FILE"
  
  sed -i '' -E 's/^GEONAMES_USERNAME=.*/GEONAMES_USERNAME=/' "$SAS_ENV_FILE" 2>/dev/null || \
  sed -i -E 's/^GEONAMES_USERNAME=.*/GEONAMES_USERNAME=/' "$SAS_ENV_FILE"
  
  chmod 600 "$SAS_ENV_FILE"
  echo "Cleared OPENAI_API_KEY and GEONAMES_USERNAME in '$SAS_ENV_FILE'. ✅"
else
  echo "Warning: '$SAS_ENV_EXAMPLE' not found, skipping sead_authority_service environment setup."
fi
