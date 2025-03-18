# SEAD DEPLOYMENT

## Installation

1. Run `generate_env.sh`
1. Run `docker compose up -d`. Wait until everything is built and running.
1. Run `run_database_import.sh`
1. Run `preload_jas.sh` to build the MongoDB server cache. This will take a while.