# 2. Sources

Every source that was considered, what it offers, and what became of it. Checked on 2026-11-24 unless stated otherwise.

## Used

### Lantmäteriet: Socken och stad (Swedish parishes and towns)

- **What:** a nationwide, non-overlapping division into socknar and towns. The socknar are the *jordregistersocknar* that applied when the new property register was introduced in 1976–1995. The towns are those that had town privileges at the 1971 municipal reform. The division is "frozen" and does not change over time.
- **Attributes:** `sockenstadkod` (four-digit code), `sockenstadnamn`, `sockenstadtyp` (1 = socken, 2 = town), `omradesnummer` and `huvudomrade` (a parish can consist of a main area and enclaves), `objektidentitet` (UUID).
- **Codes:** taken mainly from Riksantikvarieämbetet/ATA's list *Städer och socknar*. Parishes not in that list are numbered in the 3500 series, towns in the 4000 series.
- **Licence:** open data, CC0.
- **Access:** officially only through Lantmäteriet's Geotorget, which requires an account. We used the CC0 copy on Zenodo, record [15021532](https://zenodo.org/records/15021532), file `socken-lantmateriet.geojson` (89 MB, CRS84). See [D-03](05-decision-log.md#d-03-no-geotorget-account-use-the-cc0-copy-on-zenodo).
- **Documentation:** [product description, version 1.2, 2022-04-20](https://www.lantmateriet.se/globalassets/geodata/geodatatjanster/pb-socken-och-stad-nedladdning-vektor.pdf).
- **Limitation:** parishes absorbed into a town before 1976–1995 are not separate units (e.g. Fosie in Malmö, Badelunda in Västerås). Lantmäteriet notes this itself.
- **Used for:** Swedish parishes (`lookup.lm_socken_stad`) and, merged, the 25 Swedish provinces (`lookup.lm_landskap`).

### GADM 4.1

- **What:** global administrative boundaries. SEAD has levels 0–2 loaded: countries; län, fylker, Länder and similar; kommuner and similar.
- **Already in SEAD:** loaded by `sead_change_control/bin/import_gadm_data.sh` into a `gadm` schema, and served by the JSON API server at `/gadm/area/:gid/polygons`. This work moved it into the `lookup` schema ([D-01](05-decision-log.md#d-01-a-lookup-schema-for-external-reference-geodata)).
- **Geometry:** dissolved from GADM's leaf units and simplified at 0.001° (about 110 m). This is why sites on the coast can fall just outside a polygon, and why a 2 km tolerance is used ([D-08](05-decision-log.md#d-08-a-site-within-2-km-of-a-boundary-counts-as-inside)).
- **Vintage:** Norway is at its pre-2020 fylker (Hedmark, Telemark, Vest-Agder, Hordaland), which happens to match the names SEAD uses.
- **Licence:** free for academic and other non-commercial use; redistribution needs permission. SEAD already serves GADM-derived polygons, so this is not new, but it should be kept in mind for anything public.
- **Used for:** Swedish kommuner and län, and most foreign regions.

### Wikidata

- **What:** every Swedish parish item (instance of Q1523821, *socken i Sverige*) carries:
  - P777: the parish code. It is the same number as Lantmäteriet's `sockenstadkod`.
  - P361: the province (landskap) it is part of.
  - P1566: its GeoNames id.
  - P131: its härad.
- **Coverage:** 2,348 of Lantmäteriet's 2,473 units join to a Wikidata parish by code. The ones that don't are almost all towns, which are not parish items.
- **Licence:** CC0.
- **Access:** SPARQL, via `bin/fetch_socken_wikidata.sh`. The result is kept as a file in the repository (`bin/resources/lookup/socken_wikidata.csv`, 2,419 rows) so that imports never depend on Wikidata being up ([D-05](05-decision-log.md#d-05-landskap-from-wikidata-kept-as-a-file-border-parishes-decided-by-hand)).
- **Used for:** the province of each Swedish parish, alternative parish names (catching renamings), and the GeoNames ids stored with each parish.

### OpenStreetMap (Nominatim)

- **What:** administrative boundary relations. Probing showed good polygons for foreign communes (Blowatz, Murlo) and for historical Finnish municipalities (Hauho). There are `boundary=historic` relations for 15 of the 25 Swedish provinces.
- **Not usable for:** Swedish parishes (Fosie and Badelunda exist only as a suburb and a nature reserve) or Danish parishes (only village points).
- **Licence:** ODbL.
- **Status:** not yet imported. It is the intended source for most of the 22 remaining foreign locations ([07](07-open-issues-and-next-steps.md)).

## Considered, not used

### GeoNames

GeoNames publishes polygons only for countries. Below that level it has points, names and hierarchy. Its value here is as a cross-reference: the GeoNames id of each Swedish parish is stored from Wikidata. The GeoNames import script in sead_change_control (`bin/import-geonames`) has not been run locally.

### Lantmäteriet: Distriktsindelning

2,523 *distrikt*, following the parish (*församling*) division of 31 December 1999. It would separate several of the parishes that Socken och stad merges into towns (Fosie, Badelunda, Västra Frölunda). Like Socken och stad it is open data, but available only through Geotorget. Johan decided against creating an account ([D-03](05-decision-log.md#d-03-no-geotorget-account-use-the-cc0-copy-on-zenodo)).

### Riksantikvarieämbetet: sockengränser

RAÄ's parish boundaries, frozen as of 1995 and used to describe find spots. They largely duplicate Lantmäteriet's, and Johan chose Lantmäteriet as the primary source ([D-02](05-decision-log.md#d-02-lantmäteriet-is-the-primary-source-for-sweden)). RAÄ is retiring shapefile downloads during 2026.

### bygdeband.se/socknar

Suggested by Johan. A guide to Swedish parishes with about 250 parish pages listed by län and kommun, with no codes, coordinates, boundaries or download. It cites Uppsala University's *Svenska socknar* database (socknar with härad, län and coordinates) as a resource. Not used.

### Danish parishes (sogne): DAWA, Dataforsyningen, Datafordeler

- **DAWA** (`api.dataforsyningen.dk/sogne`) used to serve Danish parish polygons. It is shut down (HTTP 410 Gone).
- **Dataforsyningen** (Johan's account; the token is in `local-work/.secrets`):
  - The DAGI service `dagi_DAF` offers the parish layer `Sogneinddeling` only as a WMS, which serves map images.
  - The WFS no longer exists ("Service WFS:dagi_DAF does not exist").
  - WMS GetFeatureInfo, which would identify the parish at a point, fails with a server-side Java error.
- **Datafordeler** (`wfs.datafordeler.dk`) now serves DAGI as WFS and file downloads, but requires its own API key or login. Sending the Dataforsyningen token there was blocked, correctly, as it is a different service ([D-15](05-decision-log.md#d-15-danish-parishes-the-dataforsyningen-token-is-not-sent-to-datafordeler)).
- **dagirlite** (an R package on CRAN) bundles a 2,141-parish snapshot taken from DAWA. It is a third-party copy that would need an R container to convert.

Status: undecided, see [07](07-open-issues-and-next-steps.md).

## Licence summary

| Source | Licence | Stored in SEAD as |
|---|---|---|
| Lantmäteriet Socken och stad | CC0 1.0 | `lookup.lm_socken_stad`, `lookup.lm_landskap` (geometry) |
| Wikidata | CC0 1.0 | province, Wikidata and GeoNames ids in `lookup.lm_socken_stad` |
| GADM 4.1 | non-commercial, no redistribution without permission | `lookup.gadm_adm_0..2` |
| OpenStreetMap (planned) | ODbL | not yet |
