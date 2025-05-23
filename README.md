# SEAD DEPLOYMENT

## Installation

1. `git clone https://github.com/humlab-sead/sead-deployment.git`
1. `cd sead-deployment`
1. `git clone --recurse-submodules https://github.com/humlab-sead/sead_browser_client`
1. `git clone --recurse-submodules https://github.com/humlab-sead/json_api_server`
1. `./generate_env.sh` to copy .env-example to .env and fill it out with auto-generated passwords.
1. Edit `.env`. Check COMPOSE_PROJECT_NAME is not colliding with any other project. Set DOMAIN to whatever you have. Check that there are no port conflicts.
1. `docker-compose build` Wait until everything is built.
1. `docker compose up -d` To start everything.
1. `docker compose ps` To check that everything seems to be fine. The PostgREST service will be failing/restarting, this is fine at this stage since it's due to not having imported the databas yet. Everything else should be running ok.
1. `./run_database_import.sh` This builds the database via the sead_change_control system.
1. `./preload_jas.sh` to build the Json Api Server MongoDB database from the Postgres database. This will take a while.
1. `docker compose down && docker compose up -d` To restart everything.

System should now be available at http://localhost:8080 or whatever address and port you specified.

If you want to do development of the webclient:
1. Run `npm run dev` in the sead_browser_client repo.
1. The development version of the webclient is now available at http://localhost:8081 (note! different from port 8080 - which is used for non-dev locally hosted webclient).
1. Open the sead_browser_client in vscode. Browser should automatically refresh upon code changes.


If you want to do development of the JAS:
1. Open the json_api_server directory in vscode. Server will automatically restart when code changes.


Note:
If you are deploying multiple instances on the same server, make sure to set the COMPOSE_PROJECT_NAME (in .env) to something unique for each instance.
