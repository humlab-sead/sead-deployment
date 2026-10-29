# SEAD 2026-10.11

The redesigned browser interface, and site reports and taxa that search engines can
find: sitemaps of them, schema.org descriptions on the pages, and a 404 for a site,
taxon or page that does not exist in place of an empty page with status 200.

## Components

| Component | Version |
| --- | --- |
| Browser client | v1.4.0 |
| JSON API server | v1.64.0 |
| Query API | v1.5.0-multi-polygon.2 |
| Database schema | @2026.10 |

The release builds on 2026-10.10. The client, the JSON API server and the router
change; the query API pin and the schema tag are unchanged.

The router and client changes depend on each other's components: the router asks
JSON API server v1.64.0 whether a page exists, and the client's vhost needs the
`clientPagePaths` index.html files that client v1.4.0 builds. Neither works with the
pins of 2026-10.10.

## Browser client

- A redesigned interface, mosaic views and site reports.
- Site reports: the summary is the tabs, which follow along at the top; samples open
  in a dialog; sample datasets are drawn with Plotly, as bars or a depth profile; the
  sample map can colour samples by depth or elevation; the site map shows the other
  sites around the site; the dendrochronology graph is a timeline of the dated
  samples; the dating tab opens on the graph.
- A site that doesn't exist leads back to the main page.
- Filters: a breadcrumb of every filter in the chain above the filters.
- Domains: SEAD's own domain icons, and switching domain asks first when it would
  remove filters.
- Site reports and taxa are described as schema.org datasets and taxa.
- Abundance exports no longer fail on sites without abundance elements.

## JSON API server

- `/sitemap/sites.xml` and `/sitemap/taxa.xml`: sitemaps of the sites with at least
  one analysed sample and the taxa with at least one abundance.
- `/page-exists`: whether the site or taxon of a client page is in the database,
  for the router.

## Router and client vhost

- `/sitemap-sites.xml` and `/sitemap-taxa.xml` are served at the root, from the JSON
  API server, since a sitemap may only list URLs under the path it is served from.
- `/site/`, `/taxon/` and `/species/` pages are checked against `/page-exists` with
  `auth_request`. A missing one gets the client with status 404. If the JSON API
  server cannot be asked, the page is served as before.
- The client's vhost serves index.html only for its own pages (the front page, the
  domains, the privacy policy) and the site, taxon, species and viewstate patterns.
  Anything else is a 404, still with the client.

## Validation

`nginx -t` of the router configuration in the router image and of the client vhost in
Debian's nginx-extras; `node --check` of the new JSON API server modules.

## Deployment

Target: super.sead.se.

```bash
./deploy.sh remote deploy super 2026-10.11
```
