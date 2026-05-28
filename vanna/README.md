# Vanna Service

This service hosts a Vanna v2 FastAPI SQL agent configured for SEAD.

## Endpoints

- UI: `/vanna/`
- API: `/api/vanna/v2/chat_sse`, `/api/vanna/v2/chat_websocket`, `/api/vanna/v2/chat_poll`
- Health: `/health` (proxied via `/vanna/health` and `/api/vanna/health`)

## Training workflow

Use `deploy.sh` helper commands:

- `./deploy.sh vanna-train baseline`
- `./deploy.sh vanna-train schema-refresh`
- `./deploy.sh vanna-train apply`
- `./deploy.sh vanna-train-ops "Always exclude test records where applicable"`

## Memory snapshots

- Export: `./deploy.sh vanna-memory-export my_snapshot`
- Import: `./deploy.sh vanna-memory-import my_snapshot`

## Data locations

- Chroma live data: `./vanna/mounts/chroma`
- Snapshots: `./vanna/mounts/snapshots`
- Ops logs + ledger: `./vanna/mounts/ops`
- Versioned training assets: `./vanna/training/base`
- Generated schema catalog: `./vanna/training/generated/schema_catalog.json`
