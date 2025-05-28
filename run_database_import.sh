#!/bin/bash

# Load .env
export $(grep -v '^#' .env | xargs)

DEPLOY_TAG="@2025.04"
TARGET_DB="sead_staging"
DB_USER="sead_master"

# Define the docker service name to run this in
SERVICE_NAME="postgresql"

# Define the command to execute inside the container
COMMAND="./bin/deploy-staging --port 5432 --user $DB_USER --create-database --on-conflict drop --source-type empty --target-db-name $TARGET_DB --deploy-to-tag $DEPLOY_TAG --ignore-git-tags --host postgresql"

# Execute the command inside the specified service
docker compose exec "$SERVICE_NAME" bash -c "$COMMAND"

# Finally, set the password for the postgrest_anon user
docker compose exec -T "$SERVICE_NAME" psql -h postgresql -U "$DB_USER" -d "$TARGET_DB" -v ON_ERROR_STOP=1 <<-EOSQL
    -- Enable PostGIS extension
    CREATE EXTENSION IF NOT EXISTS postgis;

    -- Set passwords for users
    ALTER USER postgrest_anon WITH PASSWORD '${DATABASE_READ_ONLY_PASSWORD}';
    ALTER USER sead_ro WITH PASSWORD '${DATABASE_READ_ONLY_PASSWORD}';
    ALTER USER sead_master WITH PASSWORD '${DATABASE_PASSWORD}';
    ALTER USER humlab_admin WITH PASSWORD '${DATABASE_PASSWORD}';

    -- Grant USAGE on schemas (public & facet) to read-only users
    GRANT USAGE ON SCHEMA audit TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA bugs_import TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA clearing_house TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA clearing_house_commit TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA facet TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA postgrest_api TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA postgrest_default_api TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA public TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA sead_utility TO sead_ro, postgrest_anon;
    GRANT USAGE ON SCHEMA sqitch TO sead_ro, postgrest_anon;

    -- Grant SELECT on all existing tables in public & facet schemas
    GRANT SELECT ON ALL TABLES IN SCHEMA audit TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA bugs_import TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA clearing_house TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA clearing_house_commit TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA facet TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA postgrest_api TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA postgrest_default_api TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA sead_utility TO sead_ro, postgrest_anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA sqitch TO sead_ro, postgrest_anon;

    -- Ensure SELECT permission applies to future tables in public & facet schemas
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT ON TABLES TO sead_ro, postgrest_anon;

    ALTER DEFAULT PRIVILEGES IN SCHEMA facet 
    GRANT SELECT ON TABLES TO sead_ro, postgrest_anon;

    -- Grant SELECT on all existing sequences (IDs, etc.) in public & facet schemas
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA bugs_import TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA clearing_house TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA clearing_house_commit TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA facet TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA postgrest_api TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA postgrest_default_api TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA sead_utility TO sead_ro, postgrest_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA sqitch TO sead_ro, postgrest_anon;

    -- Ensure SELECT permission applies to future sequences in public & facet schemas
    ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT USAGE, SELECT ON SEQUENCES TO sead_ro, postgrest_anon;

    ALTER DEFAULT PRIVILEGES IN SCHEMA facet 
    GRANT USAGE, SELECT ON SEQUENCES TO sead_ro, postgrest_anon;
EOSQL



