# SEAD DEPLOYMENT

## Installation

1. `git clone https://github.com/humlab-sead/sead-deployment.git`
1. `cd sead-deployment`
1. `./generate_env.sh` to copy .env-example to .env and fill it out with auto-generated passwords.
1. `docker compose up -d` Wait until everything is built and running.
1. `./run_database_import.sh` This builds the database via the sead_change_control system.
1. `./preload_jas.sh` to build the Json Api Server MongoDB database from the Postgres database. This will take a while.