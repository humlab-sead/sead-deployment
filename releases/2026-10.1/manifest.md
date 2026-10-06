# Release 2026-10.1 - manifest

**Status:** cut (2026-10-06).
**Target:** super.sead.se, as 2026-10.0 was. Production is not part of this release.

2026-10.1 is [2026-10.0](../2026-10.0/manifest.md) with a deploy that brings the
database along. It pins the same versions of every service and the same schema; only
this repository changes.

## Services

| Service | Repository | Pin | Same as 2026-10.0 |
| --- | --- | --- | --- |
| client | `humlab-sead/sead_browser_client` | `2026-10.0` (`c9c5b6d`) | yes |
| json_api_server | `humlab-sead/json_api_server` | `v1.59.0` (`cf7c5ce`) | yes |
| sead_query_api | `humlab-sead/sead_query_api` | `v1.5.0-multi-polygon.2` (`bc7bf09`) | yes |
| database schema | `humlab-sead/sead_change_control` | `@2026.10` | yes |

## What changes

All in this repository's `deploy.sh`; see [releases/README.md](../README.md):

- **The database comes with the release.** A deploy rebuilds the database at the
  pinned sqitch tag when it is not there, beside the one in use, and swaps it in. A new
  PostgreSQL major version starts on a fresh data directory, the old one kept.
- **A deploy stops on an incomplete `.env`** before changing anything, and
  `./deploy.sh generate-env --update [<release>]` adds the missing variables.
- **Remote deploys run detached on the server** and are followed from your end
  (`./deploy.sh remote deploy`, `./deploy.sh remote logs`).
- `router/scripts/generate-sp-keys.sh` and `sead_agent/scripts/` are in the repository;
  an ignore rule had kept them out, so `./deploy.sh sp-keys` failed on every server.

2026-10.0 cannot be deployed to super as it stands: it moves PostgreSQL from 16 to 18,
and its `deploy.sh` cannot start PG18 on super's PG16 data.

## Deploying it to super

super.sead.se ran a May build from branches, with a `deploy.sh` that predates releases.
Once, by hand: check out the tag in super's checkout (with `compose.override.yml.disabled`
moved back for the checkout), run `./deploy.sh generate-env --update` and
`./deploy.sh sp-keys` there, then from your own machine:

```bash
./deploy.sh remote deploy super 2026-10.1
```

The deploy moves super from PostgreSQL 16 to 18, so it sets the PG16 data directory
aside and rebuilds the database at `@2026.10` on an empty one; the site has no database
until that is done. The GADM boundaries are then imported in the background.

SAML and ORCID login need registrations that are not done yet: super with SWAMID
(its SP metadata is at `https://super.sead.se/Shibboleth.sso/Metadata` once the SP keys
exist), and an ORCID public API client with the redirect URI
`https://super.sead.se/jsonapi/auth/orcid/callback`.
