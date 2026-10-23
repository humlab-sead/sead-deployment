# SEAD 2026-10.9

RAÄ and MCF map overlays use the SEAD Nginx router for WMS catalogues, map tiles
and legends. This fixes browser CORS failures on the five RAÄ Metria services and
the redirect from MCF's former hostname.

## Components

| Component | Version |
| --- | --- |
| Browser client | v1.3.3 |
| JSON API server | v1.63.1 |
| Query API | v1.5.0-multi-polygon.2 |
| Database schema | @2026.10 |

The release builds on 2026-10.8. Only the client and router change; the other
component pins are retained. The schema tag is unchanged.

## Map proxy

- `/maps/raa/visning/` serves the four configured public RAÄ datasets, including
  their `/wms` catalogues and `/ows` legends.
- `/maps/raa/inspire/` serves the five configured Metria datasets.
- `/maps/mcf/flooding` serves MCF's flooding service at `gis-tjanster.mcf.se`.
- Routes allow only the configured provider paths and GET/HEAD requests. The
  router verifies upstream HTTPS certificates and forwards no browser credentials.
- Nginx caches successful responses when provider cache headers permit it, with
  a bounded 256 MB cache and a ten-minute default lifetime.
- The client routes advertised legend URLs through the proxy and repairs MCF's
  incorrectly encoded legend query separators. RAÄ layer identifiers are retained.

## Validation

Client development build, Playwright overlay regression, Nginx configuration
validation, and real-provider catalogue, tile and legend requests through the proxy.

## Deployment

Target: staging.sead.se.

```bash
./deploy.sh remote deploy staging 2026-10.9
```
