# SEAD DEPLOYMENT

## Installation

1. `git clone https://github.com/humlab-sead/sead-deployment.git`
1. `./generate_env.sh`
1. `docker compose up -d`. Wait until everything is built and running.
1. `./run_database_import.sh`
1. `./preload_jas.sh` to build the MongoDB server cache. This will take a while.