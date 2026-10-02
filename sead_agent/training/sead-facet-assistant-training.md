# SEAD Facet Assistant — System & Data Context

Context document for the in-app SEAD assistant. It covers what the data is, what the
filters (facets) do, how they become SQL, and which HTTP APIs to call for lookups.

Verified against the live staging stack on 2026-09-07 (client `sead_browser_client`,
API `sead_query_api`, `json_api_server`, PostgREST, PostgreSQL `sead_staging`).

---

## 1. What SEAD is

SEAD (Strategic Environmental Archaeology Database) holds environmental &
archaeological proxy data — insects, plants, pollen, tree rings, soil chemistry,
ceramics, isotopes, aDNA — from excavation and sampling sites, mostly in Europe
(especially Sweden and the UK), plus scattered global sites.

**The spine of the data model.** Almost every query walks this chain:

```
tbl_sites ──< tbl_sample_groups ──< tbl_physical_samples ──< tbl_analysis_entities >── tbl_datasets >── tbl_methods
     │                                        │                        │
     └─< tbl_site_locations >── tbl_locations │                        └─< tbl_abundances >── tbl_taxa_tree_master
                                              └─< tbl_physical_sample_features >── tbl_feature_types
```

- **Site** — an excavation / sampling location. Has one or more locations (country,
  region, settlement…) via `tbl_site_locations`.
- **Sample group** — a set of samples defined by the excavator (e.g. one profile/trench).
- **Physical sample** — an individual sample.
- **Analysis entity** — one sample analysed by one dataset/method. This is the atomic
  "record" that filters ultimately count.
- **Dataset** — a body of results produced by one **method**. `tbl_datasets.method_id`
  is what defines a record's scientific domain.
- **Abundance** — a count/presence of a taxon in an analysis entity.

Approximate live volumes: 3.5k sites, 6.5k sample groups, 43k physical samples,
163k analysis entities, 59k datasets, 234k abundances, 24k taxa, 3.4k locations,
7.3k dendro dates, 1.5k geochronology dates, 135 methods.

**Rule that matters constantly:** sites and sample groups have *no* domain of their own.
A site belongs to a domain only because it has a linked dataset in that domain, reached
via `site → sample_group → physical_sample → analysis_entity → dataset → method_id`.

### 1.1 What the user's words mean

Users say very few of these names the way the database spells them. The mappings that
come up constantly:

| What they say | What they mean |
|---|---|
| site, sites, locality, place | an archaeological site record — `tbl_sites`, the `sites` filter. **Never a website, web page, URL or internet domain**, unless they explicitly say so |
| sample, samples | a physical sample (`tbl_physical_samples`) — not a sample group, and not an analysis entity |
| group, context group, profile, trench, core | a sample group (`tbl_sample_groups`, the `sample_groups` filter) |
| analysis, analyses | usually an analysis entity: one sample analysed by one dataset. It is also the unit the result counts are in (§8) |
| measurement, measurements, observation, value | a measured value (`tbl_measured_values`) — read in a site report, or narrowed with the geoarchaeology measured-value filters (§3.3) |
| species, taxon, taxa, and any bug, plant or pollen name | the `species` filter (taxa actually observed in abundances), narrowed by `family` and `genus` |
| period, era, age, "the Bronze Age" | normally a named period in `relative_age_name`, not one of the numeric age filters |
| proxy, proxy type, kind of data | `record_types` or `data_types` — though what they usually want is a domain (§2) |

Two words worth resolving rather than guessing at:

- **"location"** — either the site itself or the administrative place it sits in. When
  they name a country or a region, it is the latter (`country`, `region`).
- **"dataset"** — in ordinary speech usually "the data I would get from these sites",
  not a row in `tbl_datasets`. Only reach for the `datasets` filter when they mean one
  particular dataset.

Answer in their vocabulary, not the schema's: say sites and samples, and keep `tbl_*`
names out of the reply unless the question was about the database itself.

---

## 2. Domains

A **domain** scopes the whole UI: it changes which filters are offered, which result
tiles are shown, and adds a hidden `WHERE tbl_datasets.method_id IN (...)` to every query.
The user switches domain from the top menu; the URL is `/<domainname>` (`/` = general).

| Domain code | Title | Method filter (the actual SQL clause) | Client-enabled |
|---|---|---|---|
| `general` | General | *none* | yes |
| `palaeoentomology` | Palaeoentomology | `method_id IN (3, 6)` | yes |
| `archaeobotany` | Archaeobotany | `method_id IN (4, 8)` | yes |
| `pollen` | Pollen | `method_id IN (14, 15, 21)` | yes |
| `geoarchaeology` | Geoarchaeology | `method_id IN (32,33,35,36,37,94,106)` | yes |
| `dendrochronology` | Dendrochronology | `method_id IN (10)` | yes |
| `ceramic` | Ceramic | `method_id IN (172, 171)` | yes |
| `isotope` | Isotope | `method_id IN (175)` | **no** (disabled in client config) |
| `adna` | aDNA | methods whose `tbl_record_types.record_type_name = 'DNA'` | not in client config |

Caveats worth knowing:
- Method 175 is *"Ancient DNA analysis (Sample Extraction/Analysis)"*, record type `DNA`
  — so the `isotope` domain clause actually points at aDNA data. This is a known
  inconsistency; `isotope` is disabled in the client. Don't offer it.
- By dataset volume the data is heavily skewed: dendrochronology (~31.7k datasets) and
  ceramic petrography (~10.2k) dominate; pollen (~69) and archaeobotany (~392) are small.
- Domain method IDs are duplicated in three places (DB `facet.facet_clause`, the query
  API, and `json_api_server`'s search). The DB clause is authoritative.

---

## 3. Facets (filters)

### 3.1 How the facet system is configured

All facet behaviour is **data**, in the `facet` schema of the SEAD database — not code:

| Table | Role |
|---|---|
| `facet.facet` | One row per filter: code, title, description, type, group, `category_id_expr` (the value column), `category_name_expr` (the label column), sort |
| `facet.facet_table` | The tables/UDFs a facet needs, in order — the facet's own join path |
| `facet.facet_clause` | A permanent extra `WHERE` predicate always applied for that facet |
| `facet.facet_children` | Which facets a **domain** offers, and in what order |
| `facet.table` / `facet.table_relation` | A weighted graph of tables and join columns. The API runs shortest-path over this to build JOINs automatically |
| `facet.result_field`, `facet.result_specification*`, `facet.result_view_type` | Result table/map column definitions |

### 3.2 Facet types

| Type | Pick payload | Compiles to |
|---|---|---|
| `discrete` | list of category ids | `category_id_expr IN (v1, v2, …)` |
| `range` | exactly 2 numbers `[lo, hi]` | `category_id_expr BETWEEN lo AND hi` |
| `rangesintersect` | exactly 2 numbers `[lo, hi]` | range-overlap test against a `int4range` column |
| `geopolygon` | flat lat/long list, ≥3 points (auto-closed) | point-in-polygon on `latitude_dd` / `longitude_dd` |

### 3.3 Facet catalogue

This table explains **what each filter acts on** in the database. For **which filters exist
and which domains offer them**, the generated filter reference is authoritative - it is read
from the running system, and the `Dom` column here can drift from it. Use `list_filters` to
see what the user's current domain actually offers.

`Grp` = facet group shown in the UI sidebar. `Dom` = domains offering it:
**A** = all domains + general, **G** = general only, or a list.

**Space / Time**

| Code | Title | Type | Dom | Filters on |
|---|---|---|---|---|
| `country` | Countries | discrete | A | `tbl_locations` via `tbl_site_locations`, restricted to `location_type_id = 1` |
| `region` | Region | discrete | G | same view, `location_type_id IN (2,7,14,16,18)` — admin regions, aggregate regions, historical units, geographical areas, islands |
| `location_types` | Location type | discrete | A | `tbl_location_types` — the admin level itself |
| `sites` | Site | discrete | A | `tbl_sites.site_id` (label `site_name`) |
| `sites_polygon` | Sites (map) | geopolygon | A | one or more polygons over site lat/long. Several are OR:ed - a site inside any one matches. `set_map_polygons` fills it from GADM boundaries (§3.5) |
| `sample_groups` | Sample groups | discrete | A | `tbl_sample_groups` (label = `site_name + ' ' + sample_group_name`) |
| `datasets` | Datasets | discrete | A | `tbl_datasets.dataset_id` |
| `dataset_methods` | Dataset methods | discrete | G | `tbl_methods.method_id` — the analysis method |
| `dataset_provider` | Dataset provider | discrete | G | `tbl_dataset_masters` — contributing institution |
| `relative_age_name` | Time periods | discrete | A | `tbl_relative_ages` — named cultural/geological periods (Bronze Age, Neolithic…) |
| `analysis_entity_ages` | Analysis entity ages | rangesintersect | G (default on) | `tbl_analysis_entity_ages.age_range` — **years BP**, plain (§3.4) |
| `dendro_age_contained_by` | Dendrochronology ages | rangesintersect | dendro, G | `tbl_dendro_dates.age_range` — **calendar AD years**, plain |
| `geochronology` | Geochronology | range | all except dendro-blacklisted | `tbl_geochronology.age` — absolute dates in method years BP (e.g. uncalibrated ¹⁴C) |
| `activeseason` | Insect activity seasons | discrete | palaeoent., archaeobot., pollen, adna | `tbl_seasons` |

**Taxonomy** (a strict hierarchy — narrow family → genus → species in that order)

| Code | Title | Type | Dom | Filters on |
|---|---|---|---|---|
| `family` | Family | discrete | palaeoent., archaeobot., pollen, dendro | `tbl_taxa_tree_families` |
| `genus` | Genus | discrete | same | `tbl_taxa_tree_genera` |
| `species` | Taxa | discrete | same + adna | `facet.abundance_taxon_shortcut` (taxon actually observed in abundances) |
| `species_author` | Author | discrete | same | `tbl_taxa_tree_authors` — taxonomic authority, not a publication author |

**Ecology**

| Code | Title | Type | Dom | Filters on |
|---|---|---|---|---|
| `ecocode_system` | Eco code system | discrete | palaeoent., archaeobot., pollen | `tbl_ecocode_systems` — **stage 1 of the client's Eco code filter**, not a filter of its own |
| `ecocode` | Eco code | discrete | same | `tbl_ecocode_definitions` — ecological/cultural trait of the organism. **Stage 2**: no values until a system is picked |
| `abundances_all` | Abundances | range | same | `facet.view_abundance.abundance` — count per record |
| `abundance_classification` | Abundance classification | discrete | G | quantification scheme (presence/absence, classes, counts) |

**Measured values** (geoarchaeology; each is a range over one method's values)

| Code | Title | Dom |
|---|---|---|
| `tbl_denormalized_measured_values_32` | Loss on Ignition (organic %) | geoarch., G |
| `tbl_denormalized_measured_values_33_0` | Magnetic susceptibility | geoarch., G |
| `tbl_denormalized_measured_values_33_82` | MS Heating 550 | geoarch., G |
| `tbl_denormalized_measured_values_37` | Phosphates | geoarch., G |

**Others**

| Code | Title | Type | Dom | Filters on |
|---|---|---|---|---|
| `feature_type` | Feature type | discrete | A | `tbl_feature_types` via `tbl_physical_sample_features` |
| `data_types` | Data types | discrete | A | `tbl_data_types` |
| `record_types` | Proxy types | discrete | G, adna | `tbl_record_types` — e.g. Dating, Insects & similar, Plants & pollen, DNA |
| `sample_group_sampling_contexts` | Sampling contexts | discrete | A | `tbl_sample_group_sampling_contexts` |
| `modification_types` | Modification types | discrete | archaeobot. | e.g. carbonised, fragment |
| `abundance_elements` | Abundance elements | discrete | archaeobot., pollen | body/plant part counted |
| `rdb_systems` / `rdb_codes` | Red Data Book system / code | discrete | palaeoent. | species conservation status |
| `constructions` | Constructions | discrete | G, adna | `tbl_sample_group_descriptions` where `sample_group_description_type_id = 60` — dated timber constructions |
| `construction_purpose` | Construction purpose | discrete | dendro, G | intended function of a dated construction |
| `tbl_biblio_sites` | Bibliography sites | discrete | G | publications tied to sites |
| `tbl_biblio_sample_groups` | Bibliography sites/sample groups | discrete | G | publications tied to sample groups |
| `tbl_biblio_modern` | Bibliography modern | discrete | all except dendro/ceramic | taxonomic literature |

**Internal — never expose to the user:** `result_facet`, `map_result`, `result_datasets`,
`sites_helper`, `abundances_all_helper`, and the eight domain facets
(`palaeoentomology`, `pollen`, …) which are applied implicitly by `domainCode`.

**Domain filter counts (what the API offers before client blacklists):** general 39,
palaeoentomology 22, archaeobotany 21, pollen 22, geoarchaeology 17, dendrochronology 18,
ceramic 12, adna 17.

**Client-side blacklists on top of that:** dendrochronology hides `species`, `family`,
`species_author`, `tbl_biblio_modern`, `geochronology`; ceramic hides `tbl_biblio_modern`,
`sample_group_sampling_contexts`. Production additionally hides `construction_type`,
`abundance_classification`, `region` globally — **check the running config before
promising the `region` filter**; if it is hidden, resolve regions via PostgREST and
narrow with `sites` instead.

### 3.4 Age scales — the biggest trap

Three age filters, three different number scales:

- **`analysis_entity_ages`** — category expression is plain `age_range`, so picks are
  **conventional years BP** (positive = older), `[younger, older]`. 4000–6000 BP is
  `[4000, 6000]`; the last 500 years is `[-76, 424]`, since "now" (2026) is −76 BP.
  The lower number is the *more recent* end. This is also what the Timeline slider shows.
- **`dendro_age_contained_by`** — plain **calendar AD years**. Picks `[1700, 1750]`
  mean AD 1700–1750. Verified: 95 sites.
- **`geochronology`** — raw method years BP as measured (uncalibrated ¹⁴C etc.), no offset.

Never hand-compute bounds. Load the facet with no picks first and read the returned
`Extent` / outer bounds, then pick inside them.

### 3.5 The map filter and administrative boundaries

`sites_polygon` is the only filter that selects by shape instead of by value, and since the
multi-polygon change it holds **a list of polygons rather than one**. A site matches if its
coordinates fall inside any of them, so "Skåne and Gotland" is one filter, and so is a country
whose islands are separate rings.

**On the wire.** A facet config for it accepts three forms, all equivalent for one polygon:

```jsonc
"picks":  [{"pickValue": "63.87"}, {"pickValue": "20.09"}, ...]   // flat, latitude first
"coordinates": [[63.87, 20.09], [63.94, 20.50], ...]              // one polygon
"polygons": [ [[63.87, 20.09], ...], [[55.60, 12.90], ...] ]      // several
```

Coordinates are **[latitude, longitude]** — the reverse of GeoJSON — and rings need not be
closed; the API closes them. Replies echo the picks back grouped under `Polygons`, with a
`PolygonIndex` on each pick saying which ring it belongs to. Multi-polygon needs the query API
from the `feature/multi-polygon-geofacet` work; an older build ignores `polygons` silently and
returns everything, so a filter that suddenly matches every site is the symptom to recognise.

**Where the shapes come from.** The deployment loads GADM administrative boundaries into the
`gadm` schema (levels 0/1/2: country, region, municipality; roughly 263, 3.6k and 47k areas).
They are not reachable through PostgREST, which exposes `public` only, and the raw geometry is
far too detailed for a filter anyway — Sweden alone is 3338 rings and 14k points. The JSON API
server serves them ready for use instead:

| Endpoint | Returns |
|---|---|
| `GET /jsonapi/gadm/areas?q=<name>[&level=][&country=]` | candidates: `gid`, level, name, region, country |
| `GET /jsonapi/gadm/area/<gid>/polygons` | `polygons` as [latitude, longitude] rings, plus a count of rings omitted |

Each boundary is cut to its largest few rings and simplified to a point budget, so what you get
is a recognisable outline, not the legal border: small islands drop out, and the edge is off by
around a kilometre. The `find_areas` and `set_map_polygons` tools wrap these two endpoints.

---

## 4. How a facet configuration becomes SQL

`sead_query_api` (`QuerySetupBuilder.Build`) is the core. For a given **target facet**
(the one being populated or counted) and the ordered chain of facet configs:

1. Take all facet configs **preceding** the target in the chain (`GetFacetConfigsAffectedBy`).
2. If `domainCode` is set, prepend the domain facet's config (this injects the
   `tbl_datasets.method_id IN (...)` clause).
3. Compile each config's picks into a criterion, by facet type:
   - **discrete** — skipped if it *is* the target facet (so a facet never filters itself,
     which is why counts stay visible for unselected options), else `expr IN (...)`.
   - **range** — `BETWEEN lo AND hi`; with no picks, the facet's permanent clause is used.
   - **rangesintersect** — range-overlap; requires ≥2 pick values.
   - **geopolygon** — point-in-polygon on the site coordinates. A config can carry several
     polygons, in which case the `ST_Within` expressions are OR:ed inside one parenthesised
     criterion; one polygon compiles exactly as it always did.
4. Union the tables required by every involved facet (`facet.facet_table`) plus any tables
   needed by the requested result fields.
5. **Shortest-path over `facet.table_relation`** from the target facet's table to every
   involved table, then reduce/dedupe the edges → the JOIN list. This is why you never
   specify joins: the graph resolves them.
6. Append each involved facet's permanent `facet.facet_clause` predicate.

The resulting shape for populating a discrete facet:

```sql
SELECT CAST(<category_id_expr> AS varchar) AS category, <category_name_expr> AS name
FROM   <target facet's table>
       <joins resolved from the table graph>
WHERE  1 = 1
  AND  <optional name LIKE filter>
  AND  <pick criteria from preceding facets>
  AND  <domain clause>
  AND  <permanent facet clauses>
GROUP BY 1, 2
ORDER BY <sort_expr>
```

Counts per category come from the same query aggregated; result tables/maps use the same
setup with `result_facet` / `map_result` as target and the result fields as extra tables.

**Practical consequences to reason with:**
- Filters combine as **AND** across facets, **OR** (IN) within one facet's picks.
- Order in the chain matters: a facet is only constrained by facets *before* it.
- Adding a facet late in the chain never changes earlier facets' counts.
- Counts shown next to a discrete option = matching analysis entities (or datasets for
  domain facets), not sites.

---

## 5. APIs available to the assistant

All paths below are relative to the site root (nginx router). Client config names them:
`serverAddress` → `/query`, `dataServerAddress` → `/jsonapi`,
`siteReportServerAddress` → `/postgrest`.

### 5.1 Query API — `/query` (the facet engine)

| Endpoint | Purpose |
|---|---|
| `GET /query/api/facets` | All facet definitions |
| `GET /query/api/facets/domain` | The domain facets |
| `GET /query/api/facets/domain/{domainCode}` | Facet codes available in a domain — **use this to check a filter exists before suggesting it** |
| `POST /query/api/facets/load` | Populate a facet: returns its selectable categories + counts |
| `POST /query/api/result/load` | Load the result table / map for a facet configuration |
| `GET /query/api/result/definition` | Result specifications (`site_level`, `aggregate_all`, `sample_group_level`, `map_result`) |
| `GET /query/api/meta/facet`, `/meta/facet/group`, `/meta/facet/type` | Metadata |
| `GET /query/api/version` | API version |

**Facet load request:**

```json
{
  "requestId": 1,
  "requestType": "populate",
  "targetCode": "sites",
  "triggerCode": "region",
  "domainCode": "dendrochronology",
  "facetConfigs": [
    { "facetCode": "region", "position": 1, "picks": [ { "pickValue": 781, "text": "Småland" } ] },
    { "facetCode": "sites",  "position": 2, "picks": [] }
  ]
}
```

- `targetCode` — the facet you want populated.
- `position` — 1-based order in the chain; determines which filters constrain which.
- `picks` — `[]` means "no selection, show me everything available".
- Range/intersect facets take two bare values: `"picks": [{"pickValue": 1700}, {"pickValue": 1750}]`.
- `domainCode` — `""` for general.
- Optional `textFilter` on a config restricts a discrete facet's category names.

**Facet load response:** `{ "FacetsConfig": {…echo…}, "Items": [ { "Category": "3831",
"Count": 48, "Extent": [0.0], "Name": "75246 Eksjö", "DisplayName": "75246 Eksjö" }, … ] }`.
`Category` is the value to feed back as a `pickValue`.

**Result load request** wraps the same config:

```json
{
  "facetsConfig": { "...as above...", "targetCode": "sites", "triggerCode": "sites" },
  "resultConfig": {
    "requestId": "10", "sessionId": "1",
    "viewTypeId": "tabular",            // "tabular" or "map"
    "aggregateKeys": ["site_level"]     // site_level | aggregate_all | sample_group_level
  }
}
```

Response: `{ "RequestId", "Meta": { "Columns": [{FieldKey, DisplayText, Type}, …] },
"Data": { "DataCollection": [ [row values], … ] } }`.

### 5.2 PostgREST — `/postgrest` (direct database lookups)

Exposes the **public schema read-only**: every `tbl_*` table as a REST resource. Use this
to *resolve names to IDs* and to sanity-check a request **before** touching the UI.

```
GET /postgrest/tbl_locations?location_name=ilike.*småland*&limit=5
GET /postgrest/tbl_locations?location_type_id=eq.1&location_name=eq.Sweden
GET /postgrest/tbl_methods?method_name=ilike.*dendro*
GET /postgrest/tbl_taxa_tree_genera?genus_name=eq.Quercus
GET /postgrest/tbl_sites?site_name=ilike.*uppsala*&select=site_id,site_name&limit=20
```

Operators: `eq.`, `neq.`, `lt.`, `gte.`, `like.`, `ilike.`, `in.(a,b)`, `is.null`.
Also `select=`, `order=`, `limit=`, `offset=`, and `Prefer: count=exact` for totals.

**There is no `tbl_regions`.** Regions, countries, settlements, islands and historical
units all live in `tbl_locations`, discriminated by `location_type_id`:

| id | Type | rows |
|---|---|---|
| 1 | Country | 266 |
| 2 | Sub-country administrative region (county, län, socken, parish) | 2002 |
| 4 | Settlement | 534 |
| 5 | Continent | — |
| 7 | Aggregate / non-admin geographical region (e.g. Småland, Central Europe) | 74 |
| 8 | Institution | 13 |
| 9 | Water body | 32 |
| 10 | Street address | 1 |
| 14 | Historical administrative unit (e.g. Yugoslavia, Roman Britannia) | 12 |
| 16 | Geographical area | 6 |
| 17 | Archaeological site | 1 |
| 18 | Island | 7 |
| 19 | Historical settlement | — |
| 20 | Unprocessed Bugs Transfer (needs cleaning — low quality) | 456 |

Name lookups often return **several rows for the same name at different types** — e.g.
"Småland" is both `location_id 781` (type 7, the real region) and `location_id 5294`
(type 20, an unprocessed import artefact). The `region` facet only accepts types
2, 7, 14, 16, 18, so pick accordingly; prefer the lowest-numbered non-20 type.

### 5.3 JSON API server — `/jsonapi` (search, reports, graphs)

| Endpoint | Purpose |
|---|---|
| `GET /jsonapi/search/{category}/{term}?domainCode=&page=&limit=` | Ranked search. `category` ∈ `sites`, `sample_groups`, `datasets`, `methods`. `domainCode` optional, validated against the nine codes in §2 |
| `GET /jsonapi/freesearch/{term}` | Cross-category free search |
| `GET /jsonapi/site/{siteId}` | Full site report data |
| `GET /jsonapi/sample/{sampleId}`, `/jsonapi/taxon/{taxonId}` | Entity details |
| `GET /jsonapi/taxon_distribution/{taxon_id}`, `/taxon_references/{taxon_id}` | Taxon extras |
| `GET /jsonapi/graphs/...` | Aggregate stats behind the mosaic tiles (`countries`, `analysis_methods`, `sample_methods`, `feature_types`, `ecocodes`, `datings`, `temporal_distributon`, `dating_overview`, …) |
| `GET /jsonapi/dendro/...`, `/mcr/...`, `/ecocodes/...` | Domain-specific data services |
| `GET /jsonapi/viewstate/{id}`, `POST /jsonapi/viewstate` | Saved view states |

Search response: `{ query, algorithm, category, domain: {code, enabled},
pagination: {page, limit, total, total_pages, has_more}, items: [...] }`, items ranked by
`score` with `is_exact` / `is_prefix` / `is_contains` flags. This is usually the fastest
way to answer "does SEAD have anything about X?".

---

## 6. The user interface

**Filter chain.** Filters live in ordered *slots* in the left panel. Each filter shows its
options with counts; the user picks values; downstream filters and the result refresh.
Adding a filter appends it to the chain.

**Result modules** (right panel, switchable by the user):

| Module | Name | Notes |
|---|---|---|
| Mosaic | `mosaic` | Default. Grid of summary tiles; tile set is per-domain |
| Map | `map` | Sites on a map; supports polygon selection feeding `sites_polygon` |
| Table | `table` | Tabular result rows |
| Globe | `globe` | 3-D globe |
| Lab | `lab` | Data lab / exploratory |

Mosaic tiles by domain: general — `mosaic-map`, `mosaic-sample-methods`,
`mosaic-analysis-methods`, `mosaic-feature-types`, `mosaic-domain-samples`,
`mosaic-taxa-list`. Dendrochronology — tree age, tree species, sample types, sapwood,
pith, tree rings, analysed radii, waney edge, bark, EW/LW measurements, building types.
Palaeoentomology — map, mutual climatic range, taxa list, ecocodes.
Archaeobotany — archaeobotany taxa list, sample methods, analysis methods, feature types, map.
Pollen — map, analysis methods. Geoarchaeology / ceramic — map (+ feature types,
analysis methods for ceramic).

**Routes.** `/` general, `/<domain>` domain landing, `/site/<siteId>` site report,
`/species/<id>` or `/taxon/<id>` taxon page, `/viewstate/<id>` a saved state.

**View states.** A complete snapshot the user can save and share:

```json
{ "id", "name", "apiVersion", "clientVersion", "saved",
  "layout": {…},
  "facets": [ { "name": "region", "position": 1, "selections": [781] }, … ],
  "result": {…}, "siteReport": {…},
  "domain": "dendrochronology" }
```

Constructing a view state is the cleanest way to hand the user a reproducible search.

**The assistant surface** is `AIAssistant.class.js` — a draggable chatbox that opens a
WebSocket to `copilotServerAddress` (`wss://<host>/ai-assistant`) and exchanges
`{ threadId, message }` frames. Replies render as Markdown. It is gated by
`config.copilotEnabled`. It currently has **no UI-action tool interface**: it can explain,
link, and hand over URLs / view states, but cannot yet click filters itself. Say what to
do and give a link rather than claiming to have done it.

---

## 7. Playbooks

**Always resolve names to IDs before proposing filters.** Facet picks are IDs, and user
wording rarely matches the stored name.

### "Sites with dendro data in Småland, Sweden"

1. Resolve the place — do **not** assume a table called `tbl_regions`:
   `GET /postgrest/tbl_locations?location_name=ilike.*småland*`
   → `location_id 781` (type 7, real region) and `5294` (type 20, junk). Use 781.
2. Confirm the domain has data there — populate `sites` with the region pick under
   `domainCode=dendrochronology`. Verified live: returns 75246 Eksjö (48), 75519 Småland
   (12), 75521 Småland (12), 75523 Småland (6), …
3. Tell the user: switch to the **Dendrochronology** domain, add the **Region** filter,
   select *Småland*, and read the sites from the result. Mention the region filter may be
   hidden in production — fall back to selecting the sites directly.

Sanity check before answering: `GET /jsonapi/search/sites/småland?domainCode=dendrochronology`
returned 5 sites, agreeing with the facet load.

### "What insect species are found in Roman-period Britain?"

Domain `palaeoentomology` → `country` = United Kingdom → `relative_age_name` = the Roman
period entry (resolve via `tbl_relative_ages`) → read the **taxa list** mosaic tile, or
populate the `species` facet with those picks to list taxa with counts.

### "Show me pollen data between 4000 and 6000 BP"

Domain `pollen` → `analysis_entity_ages` with picks `[4000, 6000]`
(plain years BP). Load with no picks first to confirm the bounds. Warn that
pollen is a small part of SEAD (~69 datasets).

### "Oak timbers felled in the 18th century"

Domain `dendrochronology` → `genus` = Quercus (resolve via
`/postgrest/tbl_taxa_tree_genera?genus_name=eq.Quercus`) → `dendro_age_contained_by`
picks `[1700, 1799]` (calendar AD, no offset). Note `genus`/`species` are blacklisted in
the dendrochronology UI in the shipped config — if so, use the dendro tree-species
mosaic tile instead of a filter.

### "Sites in Skåne" / "anything from Umeå municipality"

1. `find_areas` with the name; read the candidates and pick by country and level - name
   collisions are the norm, not the exception.
2. `set_map_polygons` with that area's id. Several areas in one call are OR:ed together.
3. `get_state` for the resulting site count.

This is the default route for any place, at any level. The `country` filter is the exception
worth taking: it selects on the location recorded for a site rather than on its coordinates,
so it is exact where an outline is not - measured against full-resolution boundaries, the
Skåne outline matches its 301 sites exactly, while Sweden's gets 1913 of 1990 because the rest
sit on islands too small to keep. Use it for a whole-country count; draw the area otherwise.

### "Which sites have phosphate measurements above X?"

Domain `geoarchaeology` → `tbl_denormalized_measured_values_37` (Phosphates), a range
filter. Load with no picks to get the real value range before suggesting a threshold.

---

## 8. Things to get right
- **Age scales differ per filter** (§3.4). `analysis_entity_ages` is plain years BP, `[younger, older]`.
- **Filters never filter themselves**, so a facet's own counts reflect everything else
  in the chain but not its own selection.
- **Chain order matters** — only preceding filters constrain a facet.
- **Sites/sample groups have no method.** Never filter them by their own method column;
  go through linked datasets.
- **Check availability before suggesting a filter:** `GET /query/api/facets/domain/{code}`,
  then subtract the client `filterBlacklist` for that domain and the global one.
- **`isotope` is disabled and mis-mapped** (method 175 is aDNA). Don't offer it.
- **Data volumes are lopsided** — a "no results" answer is often correct for pollen or
  archaeobotany queries. Verify with a search or facet load before saying SEAD lacks
  something, and say which domain you checked.
- **Counts are analysis entities**, not sites. Say which unit you are quoting.
- **The assistant drives the UI.** The client tools apply filters, switch domain and view,
  open site reports and draw map polygons in the user's own browser - so act rather than
  describe the menu path (see the operating instructions at the top of the prompt).
- **Map polygons are approximate outlines.** They are simplified administrative boundaries,
  not the border itself, and they select on site coordinates only - a site with no coordinates
  is in no polygon. Accurate enough to be the default way into a place; not the thing to quote
  a whole-country total from.

---
