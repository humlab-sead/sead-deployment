# SEAD 2026-11.1

MongoDB moves from 4.4 to 7.0, and releases can now carry upgrade steps of their own
(`releases/<release>/upgrade.sh`, see [the README](../README.md#upgrade-steps)). This is
the first release that does. The previous release is 2026-11.0.

MongoDB 4.4 has been end of life since February 2024. Dependency-Track flags the 4.4.30
image for CVE-2026-46595 (golang.org/x/crypto/ssh), through the `x/crypto` v0.25.0
built into its bundled database tools (mongodump and the others). The tools do not
include the vulnerable SSH server code, so the finding is not exploitable, but it cannot
be fixed on 4.4 either. The tools in 7.0.45 are built with v0.58.0, past the fix in v0.52.0.

## Components

| Component | Version |
| --- | --- |
| Browser client | v1.6.0 (was v1.5.0) |
| JSON API server | v1.65.0 (was v1.64.0) |
| Query API | v1.5.0 (was v1.5.0-multi-polygon.2) |
| Database schema | @2026.10 (unchanged) |
| MongoDB | 7.0.45 (was 4.4.30) |

7.0 and not 8.0: MongoDB 8.0.x refuses to start on Linux 6.19 and newer (SERVER-121912).
7.0.45 is also what VISP runs. The JSON API server's driver (mongodb 6.12) supports 7.0.

## Other changes

- **The query API is back on `main`.** Since 2026-10.0, releases ran a build from the
  feature branch `feature/multi-polygon-geofacet`. That branch is now merged
  ([#180](https://github.com/humlab-sead/sead_query_api/pull/180)), and v1.5.0 is a
  tag on `main`; its code is the same as v1.5.0-multi-polygon.2. The dataset methods
  facet fix in the test fixture ([#171](https://github.com/humlab-sead/sead_query_api/pull/171))
  came after the tag; it changes tests only, as the database side has been in the schema
  since @2026.04.
- **Browser client v1.6.0** carries the redesign from the `new-design` branch: a cookie
  notice of SEAD's own, folder tabs on the site report, the "when the evidence comes
  from" overview, result map sites colored by their main kind of evidence, and the SEAD
  agent's progress and streamed replies. The sites export gets a site list option, a
  progress bar and a cancel button for the XLSX export, and the map facet's country
  borders layer is gone.
- **JSON API server v1.65.0** builds the XLSX export as a job the client follows, with
  no fixed site limit and a streamed workbook, and adds a site list export. It also
  serves each site's main domain for the map and the dating overview.
- **Database builds check out the sead_change_control tag** that the release pins
  instead of pulling `main` (deploy.sh, a3dc53b and follow-ups). Before this, a rebuild
  "at @2026.10" deployed whatever `main` held.

## What the upgrade does

[`upgrade.sh`](upgrade.sh), on each server deployed from an earlier release:

1. **preflight** - MongoDB runs 4.4 or later, the CPU has AVX (5.0 and later need it),
   and there is room for a dump and a copy of the data directory.
2. **pre_apply** - dumps MongoDB into `backups/`, pulls `mongo:5.0.32`, `6.0.28` and
   `7.0.45`, and makes sure the featureCompatibilityVersion is 4.4.
3. **post_build** - stops `json_api_server` and mongo-express, counts the documents of
   every collection, stops mongo, copies the data directory aside, and steps it through
   5.0, 6.0 and 7.0 in temporary containers. The 7.0 container checks every collection
   holds as many documents as before.
4. **post_apply** - the release's `mongo:7.0.45` runs at featureCompatibilityVersion 7.0.

The compose healthcheck uses `mongosh`, since the `mongo` shell is gone from 6.0 on.

## Validation

On a copy of the local MongoDB data (4.4.30, 24 collections, 1.1 GB): the whole path,
with a failure forced before the 6.0 step and a second run resuming there, without
recounting or copying again. Every collection held as many documents afterwards; the
compose healthcheck passes on 7.0.45. The upgrade-step framework was tested with fake
releases: phase order, skipped releases, `UPGRADE_MIN_FROM`, malformed files, dry run,
resume and done-checks.

The local development stack has run on 7.0.45 since 2026-11-20, with the JSON API server
and mongo-express working against it.

The components: the client's production build passes (webpack, 2 warnings, as before);
the JSON API server's 108 tests pass; the query API's test suite gives 789 passed, 2
failed and 1 skipped both before and after #171, the 2 failures being tests that write to
a hard-coded path on another machine.

## Deployment

The schema stays at @2026.10, so this is a services-only deployment for the database:
start `release deploy` with `SEAD_RELEASE_NO_DB_REBUILD=1`. No new `.env` variables.

Super (checked 2026-11-25) runs 2026-11.0 on MongoDB 4.4.30, has AVX, and has 434 GB
free on `/data` against about 1 GB of MongoDB data.

Before deploying, on every server: `grep -c avx /proc/cpuinfo` must be above 0 (the
preflight checks this as well), and there has to be free space for twice MongoDB's data
directory. `./deploy.sh release deploy 2026-11.1 --dry-run` shows the steps and runs the
checks.

The JSON API server is down from the `mongo-to-7.0` step until the release starts.
Afterwards, once the release is known to be good, remove the dump in `backups/` and
the `mongodb-data-volume.mongo4.4.<timestamp>` directory (`podman unshare rm -rf`).
Going back to 2026-11.0 means stopping mongo, putting that directory back as
`mongodb/mounts/mongodb-data-volume`, and deploying 2026-11.0.
