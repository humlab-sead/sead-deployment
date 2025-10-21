# SEAD DEPLOYMENT

## Installation

1. `git clone https://github.com/humlab-sead/sead-deployment.git`
1. `cd sead-deployment`
1. `git clone --recurse-submodules https://github.com/humlab-sead/sead_browser_client`
1. `git clone --recurse-submodules https://github.com/humlab-sead/json_api_server`
1. `./generate_env.sh` to copy .env-example to .env and fill it out with auto-generated passwords.
1. Edit `.env`. Check COMPOSE_PROJECT_NAME is not colliding with any other project. Set DOMAIN to whatever you want, but we use sead.local here.
1. `docker-compose build` Wait until everything is built.
1. While waiting; edit /etc/hosts in WSL and add `127.0.0.1 sead.local`. Then edit the Windows hosts file (C:\Windows\System32\drivers\etc) and do the same.
1. `docker compose up -d` To start everything.
1. `docker compose ps` To check that everything seems to be fine. The PostgREST service will be failing/restarting, this is fine at this stage since it's due to not having imported the database yet. Everything else should be running ok.
1. `./run_database_import.sh` This builds the database via the sead_change_control system.
1. `./preload_jas.sh` to build the Json Api Server MongoDB database from the Postgres database. This will take a while.
1. `docker compose down && docker compose up -d` To restart everything.

System should now be available at http://sead.local or whatever address you specified.

If you want to do development of the webclient:
1. Run VSCode and attach to the running container sead-client-1.

If you want to do development of the JAS:
1. Open the json_api_server directory in vscode. Server will automatically restart when code changes.

Note:
If you are deploying multiple instances on the same server, make sure to set the COMPOSE_PROJECT_NAME (in .env) to something unique for each instance.
