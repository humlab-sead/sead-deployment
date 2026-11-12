# SEAD 2026-11.0

The SEAD agent runs on Pydantic AI and streams its replies to the browser chatbox.
The browser shows progress while the agent uses its tools. The previous release is
2026-10.12; super.sead.se is the deployment target.

## Components

| Component | Version |
| --- | --- |
| Browser client | v1.5.0 |
| JSON API server | v1.64.0 |
| Query API | v1.5.0-multi-polygon.2 |
| Database schema | @2026.10 |

The agent is built from this repository. Its rewrite retains the browser tool protocol,
adds limits on model requests and total output per turn, and streams filtered replies as
newline-delimited JSON. Clients and services that do not support streaming continue to
use complete JSON responses. The router passes streamed data through without buffering.
The client reports its current activity and displays streamed text in the chatbox.

## Validation

The agent's 64 scripted-model tests pass. The client development build and checks of
stream parsing, progress, UTF-8, actions, errors and interrupted responses pass.

## Deployment

Super's PostgreSQL 18 and schema @2026.10 match the release. This is a services-only
deployment: start `release deploy` with `SEAD_RELEASE_NO_DB_REBUILD=1` so it stops if
the database cannot be verified at the pinned version. Super needs the new
`SEAD_AGENT_MAX_MODEL_REQUESTS` and `SEAD_AGENT_MAX_TURN_OUTPUT_TOKENS` settings added
from `.env-example` before deployment.
