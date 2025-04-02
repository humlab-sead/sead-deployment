#!/bin/bash
set -e

PGUSER=postgres

echo "🔑 Applying password to write-access users..."

# Create superusers with the password
psql -v ON_ERROR_STOP=1 --username "$PGUSER" <<-EOSQL
    CREATE ROLE sead_master WITH SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD '${DATABASE_PASSWORD}';
    CREATE ROLE humlab_admin WITH SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD '${DATABASE_PASSWORD}';
    CREATE ROLE sead_write WITH SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD '${DATABASE_PASSWORD}';
    CREATE ROLE seadwrite WITH SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD '${DATABASE_PASSWORD}';
EOSQL

# Create read-only roles (these still have empty passwords)
psql -v ON_ERROR_STOP=1 --username "$PGUSER" <<-EOSQL
    CREATE ROLE humlab_read WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE sead_read WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE phil WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE mattias WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE postgrest_anon WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE querysead_worker WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE querysead_owner WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE sead_ro WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE clearinghouse_worker WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE johan WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE postgrest WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
    CREATE ROLE anonymous_rest_user WITH LOGIN PASSWORD '${POSTGREST_DB_PASSWORD}';
EOSQL

echo "✅ User setup complete."

# Create the sead_staging database if it does not exist
DB_EXISTS=$(psql -U "$PGUSER" -tAc "SELECT 1 FROM pg_database WHERE datname='sead_staging'")
if [ "$DB_EXISTS" != "1" ]; then
    echo "🚀 Creating database sead_staging..."
    psql -v ON_ERROR_STOP=1 --username "$PGUSER" <<-EOSQL
        CREATE DATABASE sead_staging OWNER sead_master;
        GRANT ALL PRIVILEGES ON DATABASE sead_staging TO sead_master;
        GRANT CONNECT ON DATABASE sead_staging TO sead_write, sead_ro, humlab_read, sead_read, querysead_worker, querysead_owner;
        -- Grant USAGE on the public schema
        GRANT USAGE ON SCHEMA public TO sead_ro;

        -- Grant SELECT on all existing tables in the public schema
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO sead_ro;

        -- Ensure sead_ro gets SELECT permission on future tables
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO sead_ro;
EOSQL
    echo "✅ Database sead_staging created."
else
    echo "⚠️ Database sead_staging already exists. Skipping creation."
fi

echo "✅ Setup complete."
