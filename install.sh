#!/bin/bash
set -e  # Exit on error

echo "🚀 Starting installation..."

# Step 1: Run generate_env.sh
if [[ -f "./generate_env.sh" ]]; then
    echo "🔧 Generating .env file..."
    chmod +x generate_env.sh
    ./generate_env.sh
else
    echo "❌ Error: generate_env.sh not found!"
    exit 1
fi

# Step 2: Start Docker services
echo "🐳 Starting Docker containers..."
docker compose up -d

sleep 5  # Wait for Docker containers to start

# Step 3: Wait for PostgreSQL to be available
echo "⏳ Waiting for PostgreSQL to be available at localhost:5432..."
while ! nc -z localhost 5432; do
  sleep 1
  echo "🔄 Still waiting for PostgreSQL..."
done
echo "✅ PostgreSQL is up!"

# Alternative method (if `pg_isready` is available)
# while ! pg_isready -h localhost -p 5432; do
#   sleep 1
#   echo "🔄 Still waiting for PostgreSQL..."
# done

# Step 4: Run database import
if [[ -f "./run_database_import.sh" ]]; then
    echo "📦 Importing database..."
    chmod +x run_database_import.sh
    ./run_database_import.sh
else
    echo "❌ Error: run_database_import.sh not found!"
    exit 1
fi

# Step 5: Preload JAS (MongoDB cache build)
if [[ -f "./preload_jas.sh" ]]; then
    echo "🗄️ Preloading JAS (MongoDB cache build)... This may take a while."
    chmod +x preload_jas.sh
    ./preload_jas.sh
else
    echo "❌ Error: preload_jas.sh not found!"
    exit 1
fi

echo "✅ Installation complete!"
