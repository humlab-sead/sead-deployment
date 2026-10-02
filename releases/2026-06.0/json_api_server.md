# Release 2026-06.0

Changes since `v1.55.0`, compiled from the GitHub comparison `v1.55.0...main`.

Current `main` is 7 commits ahead of `v1.55.0` and is tagged `v1.57.1` at `95c38e0`.

## Added

- Added `POST /graphs/countries`, returning a country summary for a list of site IDs.
- Added graph-cache support for the country summary endpoint, using a stable cache key derived from the requested site IDs.
- Added experimental image support:
  - `GET /images` lists available bundled test images with filename, size, type, and modification date.
  - `GET /image/*` serves individual bundled image files with path traversal protection.
- Added bundled thin-section and ceramic image test data under `assets/images/test_data/all/`.
- Added a `do-release` npm script pointing to `scripts/do-release.mjs`.

## Changed

- Updated the API server version from `1.55.0` to `1.57.1`.
- Renamed the package from `seaddataserver` to `json_api_server` and bumped `package.json` to version `1.57.0`.
- Added `server_version` to site and taxon API responses alongside the existing `api_source` value.
- Tightened taxon ecocode output to include only ecocode groups `2` and `3`.
- Updated alternative site fetching so `/site/:siteId/:noCache?/:alternativeFetchMethod?` now treats the alternative fetch method flag explicitly as `"true"`.
- Normalized analysis entity field ordering in the consolidated Postgres site fetch path, prioritizing dataset, date, analysis entity, physical sample, preparation method, measured value, and abundance fields.

## Operations

- Improved graceful shutdown handling for `SIGTERM` and `SIGINT`.
- Shutdown now closes the HTTP server, WebSocket server, Postgres pool, and MongoDB client before exiting.
- Added a forced shutdown timeout to stay within Docker stop timing.
- Updated the Docker production command to `exec node ...`, allowing Node to receive container signals directly.

## Commits Included

- `5f1ed5e` - Updates to alternatives site fetching method
- `98d2731` - Thin section analysis test data
- `876312b` - Experimental support for images
- `d1cb38a` - `/graphs/countries` endpoint
- `98b6467` - Merge branch `main`
- `13d8945` - Graceful SIGTERM shutdown + bump version to 1.57.0
- `95c38e0` - Narrowing down ecocode groups to just 2 and 3, for now
