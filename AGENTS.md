This is the deployment repository for the Strategic Environmental Archaeology Database (SEAD). It is the repository which ties together everything.

All services within SEAD are being run in user space as a podman compose cluster.

The most central part of SEAD is the PostgreSQL database where the core data lies in the `public` schema. There is also a `facet` schema that is used internally by the sead_query_api.

There is also a MongoDB that is used by the JSON Api Server for faster data access.

When working with this repository and the services/repositories in it, take great care to note and respect existing conventions regarding naming, directory structure, code style and general architechture of each system.

Never perform write operations against databases unless specifically told to do so. You may read from them freely.

Whenever you create a GitHub issue or post a comment on an existing issue, in any repository, end its body with this disclaimer, separated from the rest by a horizontal rule. This includes issues and comments created indirectly through scripts you run, such as `bin/add-change-request` in sead_change_control. Use "issue" or "comment" to match what you are posting:

```markdown
---

> [!NOTE]
> **AI-generated <issue|comment>.** This <issue|comment> was written by an AI assistant (<name of the assistant, e.g. Claude Code>), based on <what the content is based on, e.g. queries against the local `sead_staging` database and the query API>. Its findings and proposed solutions have not yet been reviewed by a person, so please verify them before acting on them.
```

## Documenting major changes

Every major change to SEAD is documented in a directory of its own under `docs/` in this repository, named in snake_case after the change (e.g. `docs/administrative_unit_geographical_mapping/`). A change is major when it does any of these: adds or changes database schema or data sources, spans several repositories, takes more than one session, or involves design decisions that someone will later need to understand. The point is a paper trail: anyone should later be able to see what was done, why, and who decided.

Create the directory at the start of the work and keep it up to date as the work goes on, not only at the end. Use `docs/administrative_unit_geographical_mapping/` as the model. It should contain:

- `human-brief.md`: a one-page overview for people in a hurry. Very short, and visual wherever possible (tables, Mermaid charts and diagrams). It covers the goal, the status, what was done, the decisions waiting and what remains.
- `README.md`: the current status, an index of the documents and a description of the supporting files.
- A decision log (e.g. `05-decision-log.md`) with numbered entries (`D-01`, `D-02`, …). Each entry gives the date, who decided, the decision, its justification, and the alternatives considered. Mark who decided as one of:
  - the person by name;
  - the AI assistant, accepted by that person;
  - the AI assistant, not yet reviewed.

  Open questions get an entry marked as open. Superseded decisions say so; they are not deleted.
- Further numbered documents as the work needs them, such as background and scope, sources, method, data model and implementation, results, and open issues and next steps.
- A `supporting/` directory for the scripts, data extracts and other files the documents rely on.

Record mistakes and corrections where they happened, rather than quietly rewriting history.

This repository is public. Never put credentials, tokens or other secrets in `docs/`. Avoid local absolute paths and links that only one person can open. Point out anything that should be reviewed before it is committed.

## Services

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

postgresql_mcp - An MCP server for allowing AI agents to interface with the PostgreSQL database.

