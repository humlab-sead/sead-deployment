# Release 2026-10.0 - manifest

**Status:** planning (2026-10-05). All service changes are pushed, and the schema and
sead_query_api are tagged; the client and json_api_server are not tagged yet.
**Target:** a dev release on super.sead.se. Production is not part of this release.

This document lists the version of each service intended for 2026-10.0 and what
has to happen before the release can be cut. When the release is cut,
`sead-release.env` becomes the authoritative pin list, and the per-service notes
go next to this file, as for [2026-06.0](../2026-06.0/).

## Services

| Service | Repository | 2026-06.0 pin | Planned for 2026-10.0 | State |
| --- | --- | --- | --- | --- |
| client | `humlab-sead/sead_browser_client` | `2026-04.2` | new tag from `master` (`2026-10.0`) | `master` pushed (`fc883e7`), not tagged |
| json_api_server | `humlab-sead/json_api_server` | `v1.57.1` | new tag from `main` (`v1.58.0`) | `main` pushed (`cf7c5ce`), not tagged |
| sead_query_api | `humlab-sead/sead_query_api` | `v1.4.0` | custom tag `v1.5.0-multi-polygon.2` on branch `feature/multi-polygon-geofacet` | tagged and pushed (`bc7bf09`); see [sead_query_api](#sead_query_api) |
| database schema | `humlab-sead/sead_change_control` | `@2026.04` | sqitch tag `@2026.10` | tagged and pushed (`8c89103`) |
| this repository | `humlab-sead/sead-deployment` | commit tagged `2026-06.0` | commit tagged `2026-10.0` | see [This repository](#this-repository) |

Third-party images are pinned by exact version in `compose.yml` and follow this
repository's commit.

## What goes in

### client

`master` past `2026-04.2`:

- SEAD login: sign-in from the account menu, and data import for sysadmins (`sead-login`)
- Timeline filter in plain years BP (`timeline-bp-alignment`)
- One colour-blind safe palette for domains and analysis methods (`method-colours`)
- Several polygons in the map filter (`7f87bc5`); needs the custom sead_query_api tag, see below
- SEAD agent: reads and works the whole screen, opens table rows
- UI scaled to the viewport for small laptop screens
- Range filters: select nothing until narrowed, and charts with a logarithmic y-axis
- SEAD agent chat redesign
- The image is built from the checkout it sits in (release tooling)

Left out: `backport/2025-05.2-dendro-export` and `thin-section-analysis`, which are
not merged.

### json_api_server

`main` past `v1.57.1`:

- SEAD login: SAML hand-off and ORCID, Mongo sessions, and a `sysadmin` role
- SDF import and export (`sdf-format`)
- Timeline BP alignment, plus a script that moves saved Timeline selections in
  viewstates into years BP
- The image is built from the checkout it sits in (release tooling)

### Database schema

`@2026.10` adds **only** the timeline change to `@2026.04`. Changes on `main` after
`@2026.04`:

- `facet/20261002_DML_ANALYSIS_ENTITY_AGES_PLAIN_BP` - **in**: the new client's
  Timeline sends plain years BP, and this change sets the facet up for it
- `sead_model/20260830_DDL_SUBMISSION_MODEL_REFACTOR` - out
  ([#440](https://github.com/humlab-sead/sead_change_control/issues/440) is open)
- `dendrochronology`: `20241213_DML_LUND_LIVING_TREES_COMMIT`,
  `20250107_DML_LUND_ARCHAELOGICAL_DATA_20200630_COMMIT`,
  `20260101_DML_GBG_STH_LIVING_TREES_COMMIT` - out. The last two are empty template stubs,
  and the related issues ([#332](https://github.com/humlab-sead/sead_change_control/issues/332), [#339](https://github.com/humlab-sead/sead_change_control/issues/339), [#341](https://github.com/humlab-sead/sead_change_control/issues/341)) are still open.
- `isotope`: `20260101_DML_GLYKOU_CARBON_COMMIT`, `20260101_DML_GLYKOU_RADIOCARBON_COMMIT`,
  `20260101_DML_GLYKOU_STRONTIUM_COMMIT` - out; empty template stubs

**Decided (2026-10-05):** in every project except `facet`, `@2026.10` tags the same
change as `@2026.04`, so a deploy to `@2026.10` adds nothing else. The stubs stay out
on purpose: deployed as no-ops, they would be recorded as done and skipped once they
get real content. `sdf` has no changes yet and gets no tag.

### This repository

The router as SAML Service Provider and the `sead_idp` dev IdP (`sead-login`), the
timeline alignment, the SEAD agent (`sead-agent`, merged into `master`), and the
release tooling: `deploy.sh release` and `deploy.sh remote`, `sead-release.env`, and
images built from the service checkouts.

## sead_query_api

The query API has three lines of development, and only one of them can go into
this release.

| Line | What it is | Usable for 2026-10.0 |
| --- | --- | --- |
| `main` | the current engine; `v1.4.0` is its newest tag | yes |
| `dev` | Roger Mähler's query engine overhaul, merged 2026-05-31 ([#177](https://github.com/humlab-sead/sead_query_api/pull/177), [#178](https://github.com/humlab-sead/sead_query_api/pull/178)); 124 commits past `main` | no |
| `query-engine-legacy-deprecation` | the newest overhaul work (2026-09-24), not merged anywhere; .NET 10 | no |

The overhaul is not ready to deploy:

- **Tests:** 107 of its 1521 tests fail on its last commit, and no CI runs them.
- **Filters on other filters:** a filter that isn't a plain list (polygon, range,
  timeline) can't narrow the other filters yet. Roger's `TODO.md` lists geopolygon
  support as the next step.

### Custom release: several polygons in the map filter

**Decided (2026-10-05):** this release runs a custom build of the current engine,
branch `feature/multi-polygon-geofacet`, until the overhaul is released.

The new client sends several polygons in a new `polygons` field. `v1.4.0` doesn't
know the field and drops it without an error, so a selection of two or more
polygons would be **silently ignored** there, with the map showing every site. The
branch adds the field.

The branch is `v1.4.0` plus three commits:

- `ca1b65d` - several polygons in the map filter. It was checked against local
  `sead_staging`: two boxes matching 374 and 530 sites give 904 together.
- `5814493` - a Dockerfile for the local `dotnet watch` dev container, which the
  production build doesn't use.
- `bc7bf09` - the image is built from the checkout it sits in, as the release
  tooling requires. A test build from a clean export of this commit succeeded.

The branch is not merged into `main`. Its PR,
[#180](https://github.com/humlab-sead/sead_query_api/pull/180), stays closed.

A release pins tags only, so the branch gets a tag of its own:
`v1.5.0-multi-polygon.2`. The first tag, `v1.5.0-multi-polygon.1` on `ca1b65d`, was
deleted: that commit's Dockerfile still cloned the repository at a `BRANCH` build
argument, which the release tooling no longer sets, so it couldn't be built.
- **Name:** a pre-release of `v1.5.0`, i.e. newer than `v1.4.0` but not a regular
  release.
- **No clash with automatic releases:** semantic-release only looks at tags
  reachable from `main`, so this tag doesn't affect the automatic releases there.

**Later:** the feature goes into the overhaul. It has already been ported there as
local branch `feature/multi-polygon-geofacet-composer` (not pushed yet), built on
`query-engine-legacy-deprecation`. All its geopolygon tests pass, with no new test
failures. The first release of the new engine then replaces this custom build.

### Known issue not fixed: map vs table site counts

[sead_query_api#172](https://github.com/humlab-sead/sead_query_api/issues/172): in
the general domain, the map counts every site (3462), while the table counts only
sites with analysed data (2554). 841 of the 908 data-less sites come from the 2024
dendro lookup import ([sead_change_control#317](https://github.com/humlab-sead/sead_change_control/issues/317)), ahead of dendro data that is not
imported yet.

- **On `main`:** not fixed, and the custom build doesn't fix it either.
- **On the overhaul:** already fixed, because the map is anchored on analysis
  entities there.

## Before the release can be cut

- [x] **sead_query_api:** tag `bc7bf09` as `v1.5.0-multi-polygon.2` and push the tag
- [x] **client:** push `master`
- [ ] **client:** tag `master`
- [x] **json_api_server:** push `main`
- [ ] **json_api_server:** tag `main`
- [x] **sead_change_control:** push `main`
- [x] **sead_change_control:** add the sqitch tag `@2026.10`, covering only the
      timeline change
- [x] **This repository:** commit the release tooling, merge `sead-agent` into
      `master`, and push `master`
- [ ] **This repository:** tag `2026-06.0`, which `sead-release.env` names but which
      doesn't exist yet
- [ ] `./deploy.sh release cut 2026-10.0`, then write the per-service notes here

## Deploying on super.sead.se

A release deploy never touches the database, and the timeline change has to land
together with the client, so the order matters:

1. **Database:** deploy `@2026.10` on super's database. Compared with `@2026.04` it
   adds only `20261002_DML_ANALYSIS_ENTITY_AGES_PLAIN_BP`.
2. **Services:** `./deploy.sh remote deploy super 2026-10.0`
3. **Cache:** flush the sead_query_api redis cache, since cached facet results
   predate the change.
4. **Saved viewstates:** run the viewstate migration script in json_api_server
   with `--saved-before <client deploy time>`. It's a dry run without `--apply`.
5. **Login:** check that super's `.env` has the router's SAML settings and the
   json_api_server login settings. The SWAMID and ORCID production registrations
   are not done yet.
