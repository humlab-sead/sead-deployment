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

echo "All password fields have been updated in '$ENV_FILE'. ✅"
