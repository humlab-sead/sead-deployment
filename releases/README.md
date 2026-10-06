# SEAD releases

Every SEAD service keeps its own version number and its own versioning scheme. A
**SEAD release** says which version of each one belongs together, under one name of
the form `YYYY-MM.N` - `2026-10.0`, then `2026-10.1` for a fix to it.

## What a release is

A release is a git tag on this repository. The commit it points at pins:

- **Everything kept in this repository** - `compose.yml`, the router, `sead_idp`,
  the postgresql image, `sead_agent`, and the third-party images, which `compose.yml`
  names by exact version (`mongo:4.4.30`, never `mongo:4.4` or `latest`).
- **The services built from repositories of their own**, through
  [`sead-release.env`](../sead-release.env) at the root:

  | Service | Repository | Pinned by |
  | --- | --- | --- |
  | `client` | `humlab-sead/sead_browser_client` | `SBC_RELEASE`, `SBC_COMMIT` |
  | `json_api_server` | `humlab-sead/json_api_server` | `JAS_RELEASE`, `JAS_COMMIT` |
  | `sead_query_api` | `humlab-sead/sead_query_api` | `SEAD_QUERY_API_RELEASE`, `SEAD_QUERY_API_COMMIT` |
  | database schema | `humlab-sead/sead_change_control` | `SEAD_CHANGE_CONTROL_RELEASE` (a sqitch tag) |

  Each service is pinned to one of its own tags - never a branch, which moves - and
  to the commit that tag pointed at when the release was cut. A deploy checks every
  tag against its commit and refuses to build one that has been moved since.

The client shows the SEAD release, not its own version, as the release users are on:
on saved viewstates, in its exports, and in its About dialog, which also lists the
version of each component of the release. deploy.sh builds the client with them -
`git describe` of this checkout and of the services', which on a release are its
tags - so a new release rebuilds it even when its pin is unchanged. Outside a
release the version says how far past a release the checkout is, as in
`2026-10.1-11-gd4e5443`. The
client's own tags are semver from `v1.0.0` on, so that they cannot be mistaken for
a SEAD release; its earlier tags, up to `2026-10.0`, used the release form.

The notes for a release go in `releases/<release>/`, one file per service. A release
being planned starts there with a `manifest.md`: the version of each service
intended for it, the open decisions, and what has to happen before it can be cut.

## Making a release

Tag each service you want in it first, in its own repository. Then:

```bash
./deploy.sh release cut 2026-10.0
```

This asks for the tag of each service - the current release's pin is the default -
and the sqitch tag for the schema, writes `sead-release.env`, and on your say-so
commits it and tags the commit `2026-10.0`. It commits nothing but the manifest: other
uncommitted changes in the checkout are not part of the release. Nothing is pushed;
when the notes are written:

```bash
git push origin HEAD refs/tags/2026-10.0
```

## Deploying a release

On the server, in the instance's checkout:

```bash
./deploy.sh release deploy 2026-10.0
```

or from your own machine, through a target in `~/.config/sead-deployment/targets.conf`:

```bash
./deploy.sh remote deploy super 2026-10.0
```

The remote deploy runs detached on the server (`release deploy --background`, logging
to `logs/release-deploy-*.log`) and your end follows the log. Interrupting it, or losing
the connection, leaves the deploy running; `./deploy.sh remote logs super` picks the log
up again, and exits with the deploy's status when it ends.

This fetches the tag, checks that `.env` has every variable the release's `.env-example`
defines, checks it out (the checkout is left detached at the tag), checks every pinned
tag on GitHub, syncs the service checkouts to their pinned commits, writes the pinned
refs into `.env`, builds, brings the database to the release, and starts the stack. The
images are built from those checkouts, so what was checked is what gets built; nothing
is cloned during a build. Each image records the `git describe` of the checkout it was
built from, which `./deploy.sh versions` reports. It refuses to run on a checkout with
uncommitted changes. `.env` keeps its secrets and settings; only the version variables
change.

**A `.env` that lacks variables stops the deploy before anything changes.** A release
that adds services or settings adds them to `.env-example`; add them to the instance's
`.env`, on the server, with

```bash
./deploy.sh generate-env --update 2026-10.0
```

which adds only what is missing, with the example's values, generates new secrets and
asks for new host ports (those must be unique among the instances on the host). Review
the result, then deploy.

**The database comes with the release.** The schema is part of what a release is - it
holds the facet definitions, among other things - and everything in the database comes
from `sead_change_control`, so a deploy rebuilds the database at the sqitch tag the
release pins instead of migrating it:

- The rebuild is the import `import-db` runs, into `sead_staging_next`, while
  `sead_staging` keeps serving. The two are then swapped by renaming them, which takes
  seconds. The database it replaces is kept as `sead_staging_prev` (with connections
  refused) until the next rebuild.
- The GADM boundaries, which come from their own import, are copied over from the
  database being replaced, or imported in the background when it has none.
- The query API's Redis cache is flushed and the JSON API server's cache rebuilt in the
  background afterwards.
- A database already at the pinned tag is left alone, so a release that only changes
  services does not touch it.
- A release whose postgresql image is a new PostgreSQL major version cannot start on
  the old version's data directory. It is set aside as
  `postgresql/mounts/pg-data-volume.pg<old>.<timestamp>`, and the new version starts on
  an empty one; the site has no database until the rebuild is done. Remove the old
  directory once the release is known to be good.

This relies on nothing being written to the database except through
`sead_change_control` - data, including SDF submissions, arrives as change requests.

`./deploy.sh release apply` builds and starts the release of the checkout as it
stands, and brings the database to it, for when you have checked out the tag yourself.

## Rolling back

`.env` records the release an instance runs (`SEAD_RELEASE`) and the one it ran
before (`SEAD_PREVIOUS_RELEASE`). Rolling back is deploying the previous release
again. A deploy rebuilds the database at the tag the release pins, older or not, so the
database is rolled back with it. For an instant way back after a bad rebuild, the
replaced database is kept as `sead_staging_prev`: in psql as postgres,

```sql
ALTER DATABASE sead_staging RENAME TO sead_staging_bad;
ALTER DATABASE sead_staging_prev RENAME TO sead_staging;
ALTER DATABASE sead_staging WITH ALLOW_CONNECTIONS true;
```

After a PostgreSQL major version upgrade, going back means deploying the previous
release with the kept `pg-data-volume.pg<old>.<timestamp>` moved back into place.

## Seeing what runs

```bash
./deploy.sh versions
```

reports the release the checkout carries, the one last applied, and every service
running something other than what the release pins - for instance after
`./deploy.sh update json_api_server` put a branch on a dev instance.
