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

Unchanged from 2026-11.0, unless pinned otherwise when the release is cut.

| Component | Version |
| --- | --- |
| MongoDB | 7.0.45 (was 4.4.30) |

7.0 and not 8.0: MongoDB 8.0.x refuses to start on Linux 6.19 and newer (SERVER-121912).
7.0.45 is also what VISP runs. The JSON API server's driver (mongodb 6.12) supports 7.0.

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

Not yet run: the JSON API server and mongo-express against 7.0 in a full stack.

## Deployment

Before deploying, on every server: `grep -c avx /proc/cpuinfo` must be above 0 (the
preflight checks this as well), and there has to be free space for twice MongoDB's data
directory. `./deploy.sh release deploy 2026-11.1 --dry-run` shows the steps and runs the
checks.

The JSON API server is down from the `mongo-to-7.0` step until the release starts.
Afterwards, once the release is known to be good, remove the dump in `backups/` and
the `mongodb-data-volume.mongo4.4.<timestamp>` directory (`podman unshare rm -rf`).
Going back to 2026-11.0 means stopping mongo, putting that directory back as
`mongodb/mounts/mongodb-data-volume`, and deploying 2026-11.0.
