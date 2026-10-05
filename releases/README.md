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

This fetches the tag, checks it out (the checkout is left detached at the tag), checks
every pinned tag on GitHub, syncs the service checkouts to their pinned commits, writes
the pinned refs into `.env`, builds, and starts the stack. The images are built from
those checkouts, so what was checked is what gets built; nothing is cloned during a
build. Each image records the `git describe` of the checkout it was built from, which
`./deploy.sh versions` reports. It refuses to run on a checkout with uncommitted
changes. `.env` keeps its secrets and settings; only the version variables change.

**A release never touches the database.** `import-db` recreates the database from
scratch, so it is never run on its own. If the schema is not at the sqitch tag the
release pins, the deploy says so, and the import is yours to start:

```bash
./deploy.sh import-db @2026.10
```

`./deploy.sh release apply` builds and starts the release of the checkout as it
stands, for when you have checked out the tag yourself.

## Rolling back

`.env` records the release an instance runs (`SEAD_RELEASE`) and the one it ran
before (`SEAD_PREVIOUS_RELEASE`). Rolling back is deploying the previous release
again. The database is not rolled back with it.

## Seeing what runs

```bash
./deploy.sh versions
```

reports the release the checkout carries, the one last applied, and every service
running something other than what the release pins - for instance after
`./deploy.sh update json_api_server` put a branch on a dev instance.
