# 4. Data model and implementation

## The `lookup` schema

External reference geodata lives in a schema of its own, `lookup` ([D-01](05-decision-log.md#d-01-a-lookup-schema-for-external-reference-geodata)). It is loaded by import scripts in `sead_change_control/bin`, not by sqitch, in the same way GADM always was. Each source's tables carry a prefix for the source.

| Table | Source | Key | Rows | Loaded by |
|---|---|---|---|---|
| `lookup.gadm_adm_0` | GADM 4.1 | `gid` | 263 | `import_gadm_data.sh` |
| `lookup.gadm_adm_1` | GADM 4.1 | `gid` | 3,661 | `import_gadm_data.sh` |
| `lookup.gadm_adm_2` | GADM 4.1 | `gid` | 47,217 | `import_gadm_data.sh` |
| `lookup.lm_socken_stad` | Lantmäteriet + Wikidata | `sockenstadkod` | 2,473 | `import_socken_data.sh` |
| `lookup.lm_landskap` | built from `lm_socken_stad` | `landskap` | 25 | `import_socken_data.sh` |

`lookup.lm_socken_stad` has one row per code, with all of a unit's areas (main area and enclaves) dissolved into one MultiPolygon. Its columns:

| Column | Contents |
|---|---|
| `sockenstadkod` | the code, zero-padded to four digits (primary key) |
| `sockenstadnamn` | name |
| `sockenstadtyp` | 1 = socken, 2 = town |
| `landskap` | province |
| `landskap_basis` | how the province was decided: `wikidata`, `override` or `shared_border` |
| `wikidata_id` | Wikidata item |
| `geonames_id` | GeoNames id |
| `n_areas` | number of areas dissolved into the geometry |
| `geom` | full resolution, EPSG:4326 |

The read-only roles `sead_ro` and `postgrest_anon` are granted read access by the import scripts. `humlab_read` and `querysead_worker` have none, the same as for the old `gadm` schema.

## Tables in `public`

Two tables, created by a change request ([D-09](05-decision-log.md#d-09-the-link-is-stored-in-a-sqitch-managed-table-the-polygons-are-not)).

**`tbl_boundary_sources`**: one row per source.

| Column | Meaning |
|---|---|
| `boundary_source_id` | serial primary key |
| `boundary_source_code` | unique: `lm_socken_stad`, `lm_landskap`, `gadm_adm_0`, `gadm_adm_1`, `gadm_adm_2` |
| `boundary_source_name`, `description` | human-readable |
| `lookup_table`, `key_column` | where the boundaries are, e.g. `lookup.lm_socken_stad` / `sockenstadkod` |
| `source_url`, `license` | provenance |
| `date_updated` | standard SEAD column |

**`tbl_location_boundaries`**: one row per link between a location and a boundary.

| Column | Meaning |
|---|---|
| `location_boundary_id` | serial primary key |
| `location_id` | foreign key to `tbl_locations`, cascading |
| `boundary_source_id` | foreign key to `tbl_boundary_sources` |
| `boundary_key` | the boundary's key in its source, e.g. `1209` or `SWE.14_1`. Text, and not a foreign key ([D-10](05-decision-log.md#d-10-the-column-is-called-boundary_key)) |
| `match_type` | how the link was established. Checked against seven values, which are explained in the column comment ([D-11](05-decision-log.md#d-11-match_type-values-are-explained-in-the-column-comment)) |
| `notes` | free text, used for hand-picked links |
| `date_updated` | standard SEAD column |

A location can have several rows, so the table is unique on (`location_id`, `boundary_source_id`, `boundary_key`).

To get a location's polygons, join through `tbl_boundary_sources` to the table it names. For "Dalby socken" (location 4006) this returns two rows, `0215` and `1209`:

```sql
select l.location_name, s.boundary_source_code, b.boundary_key, b.match_type,
       coalesce(sk.geom, ls.geom, g0.geom, g1.geom, g2.geom) as geom
from tbl_location_boundaries b
join tbl_locations l using (location_id)
join tbl_boundary_sources s using (boundary_source_id)
left join lookup.lm_socken_stad sk on s.boundary_source_code = 'lm_socken_stad' and sk.sockenstadkod = b.boundary_key
left join lookup.lm_landskap   ls on s.boundary_source_code = 'lm_landskap'    and ls.landskap      = b.boundary_key
left join lookup.gadm_adm_0    g0 on s.boundary_source_code = 'gadm_adm_0'     and g0.gid           = b.boundary_key
left join lookup.gadm_adm_1    g1 on s.boundary_source_code = 'gadm_adm_1'     and g1.gid           = b.boundary_key
left join lookup.gadm_adm_2    g2 on s.boundary_source_code = 'gadm_adm_2'     and g2.gid           = b.boundary_key
where b.location_id = 4006;
```

Each new source adds another join. A view in `lookup` that unions all sources into one (source, key, geometry) shape would let consumers do a single join; it is a suggested follow-up.

## Change requests

Both are in sead_change_control, branch `feature/location-boundaries`, in a separate worktree, based on `origin/main` at `e8257f6`.

| Change | Project | What it does |
|---|---|---|
| `20261124_DDL_LOCATION_BOUNDARIES` | `sead_model` | Creates both tables and the five source rows. Skips itself if `tbl_location_boundaries` exists |
| `20261124_DML_LOCATION_BOUNDARIES` | `general` | Inserts the 900 links. Skips itself if the table has rows. Every row states the location name it expects, and the script aborts if any `location_id` has a different name |

Their plan entries and headers still read `ISSUE_URL`: the GitHub issues have not been created.

**Tested** in a throwaway PostGIS container (`lookup-test-db`, port 55432) holding copies of `tbl_locations`, `tbl_location_types` and `sead_utility.table_exists`:

- deploy, verify and re-deploy, where both scripts report "ALREADY EXECUTED";
- revert, then deploy again, giving 900 rows;
- renaming a location, which makes the DML abort as intended.

## Scripts (sead_change_control, same branch)

| File | Purpose |
|---|---|
| `bin/import_socken_data.sh` | New. Fetches Socken och stad (Zenodo by default, or `--file` for an official GeoPackage), builds `lookup.lm_socken_stad` and `lookup.lm_landskap`, grants read access. Takes about 6 seconds once the file is cached |
| `bin/fetch_socken_wikidata.sh` | New. Refreshes `bin/resources/lookup/socken_wikidata.csv` from Wikidata's SPARQL endpoint. Run by hand; review the diff before committing |
| `bin/resources/lookup/socken_wikidata.csv` | New. 2,419 rows: code, item, label, province, GeoNames id |
| `bin/resources/lookup/socken_landskap_overrides.csv` | New. Ten hand-decided provinces, with reasons |
| `bin/import_gadm_data.sh` | Changed. Defaults to schema `lookup` and table prefix `gadm_`, with a new `--table-prefix` option |
| `bin/fix_gadm_names.sql` | Changed. Points at `lookup.gadm_adm_<n>` |

## sead-deployment

Branch `feature/lookup-schema`, in a separate worktree, based on `master` at `89b77d5`.

- `deploy.sh`:
  - `move_legacy_gadm_schema` runs after PostgreSQL starts in every release deploy. It moves `gadm.adm_<n>` to `lookup.gadm_adm_<n>`, renames the indexes, gives `lookup` the owner `gadm` had, drops the empty `gadm` schema and grants read access. It does nothing once the tables have moved.
    - Tested on a fixture and on the real copy.
    - A first version created `lookup` owned by `postgres`, which would have stopped the imports (run as `sead_master`) from creating tables. Found and fixed while setting up the copy.
  - `copy_lookup_into_rebuild` replaces `copy_gadm_into_rebuild` and copies the whole `lookup` schema into a rebuilt database.
  - `ensure_lookup_data` starts a background import of any lookup tables that are missing.
  - `start_lookup_import_background` replaces the GADM-only job. It runs the parish import first (seconds), then GADM, and skips a source whose import script the change-control checkout does not have yet.
  - A new `import-socken` command, a parish row in `versions`, and an untangled usage text.
- `compose.yml`: mounts `postgresql/mounts/lookup` at `/var/lib/lookup` for the cached parish file. `.gitignore` and `.gitkeep` follow the GADM pattern.

**Release coupling:** these changes, the JAS change and the import scripts must ship together, in a release whose change-control tag contains the new scripts.

## JSON API server

Branch `feature/lookup-schema`, in a separate worktree, based on `origin/main` at `d764a2e`. `src/EndpointModules/Gadm.class.js` reads `lookup.gadm_adm_<n>` instead of `gadm.adm_<n>`. Nothing else changes.

## The local database copy

`sead_staging_region_mapping`, on the local PostgreSQL server (created 2026-11-24 at Johan's request):

1. A `pg_dump | pg_restore` of `sead_staging`, owned by `sead_master`, with the same database privileges. Verified to have the same number of comments, tables, sites, locations and sqitch changes as the original.
2. GADM moved into `lookup` by `move_legacy_gadm_schema`.
3. Parishes and provinces loaded by `import_socken_data.sh`, run as `sead_master`.
4. Both change requests run with psql, not sqitch ([D-14](05-decision-log.md#d-14-change-requests-applied-to-the-copy-with-psql-not-sqitch)). Its sqitch registry therefore still lists them as undeployed.
5. The improved table and `match_type` comments applied directly.

## Containers

| Container | Purpose | Keep? |
|---|---|---|
| `region-poly-wb` | Matching workbench; holds every intermediate table | Until the mapping is final |
| `lookup-test-db` | Testing the change requests and deploy.sh functions | Disposable |

Remove both with `podman rm -f region-poly-wb lookup-test-db`.
