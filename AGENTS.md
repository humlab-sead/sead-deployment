This is the deployment repository for the Strategic Environmental Archaeology Database (SEAD). It is the repository which ties together everything.

All services within SEAD are being run in user space as a podman compose cluster.

The most central part of SEAD is the PostgreSQL database where the core data lies in the `public` schema. There is also a `facet` schema that is used internally by the sead_query_api.

There is also a MongoDB that is used by the JSON Api Server for faster data access.

When working with this repository and the services/repositories in it, take great care to note and respect existing conventions regarding naming, directory structure, code style and general architechture of each system.

There is an MCP server called "postgres" which gives you full read access to the database. Make free use of it to gain understanding whenever needed.

Never perform write operations against databases unless specifically told to do so. You may read from them freely.

The services in this system are:

router - An Nginx server acting as the single entrypoint to all of the services in the system. Everything, all web requests performed to any service in the system, is routed through this.

postgresql - The central database acting as the single souce of truth.

postgrest - A REST API interface that exposes the public schema of the database to be read from the internet.

mongo - A MongoDB used by the json_api_server. The MongoDB largely contains the same data as the PostgreSQL database, but formatted as JSON documents, which makes access easier in some circumstances, such as when delivering data to the webclient.

mongo-express - An admin interface for MongoDB.

client - This is the webclient, the frontend. The production build of this is being run at browser.sead.se.

sead_query_api - This is a .NET server mainly responsible for handling the facetted filtering experience provided by the webclient.

redis_cache - Used by the sead_query_api.

json_api_server - Delivers charts, site reports/landing pages and other things to the webclient.

maria-db - Used by Matomo.

matomo - Used for webstats.

ontop - API

postgresql_mcp - An MCP server for allowing AI agents to interface with the PostgreSQL database.

