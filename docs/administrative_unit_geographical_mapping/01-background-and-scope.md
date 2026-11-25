# 1. Background and scope

## The Region filter

The Region filter (`facet.facet`, `facet_code = 'region'`, `facet_id = 41`) lists locations from `tbl_locations` through the view `facet.site_location_shortcut`. Its clause limits it to five location types:

```sql
region.location_type_id in (2, 7, 14, 16, 18)
```

| `location_type_id` | Location type | Locations in the filter | Sites |
|---|---|---|---|
| 2 | Sub-country administrative region | 1,125 | 1,180 |
| 7 | Aggregate/non-admin geographical region | 17 | 124 |
| 14 | Historical administrative unit | 8 | 10 |
| 16 | Geographical area | 3 | 3 |
| 18 | Island | 3 | 51 |

Only locations that are linked to at least one site appear in the filter, and that is the set this work covers: **1,156 locations**. (`tbl_locations` holds 2,103 locations of these types in all.)

The filter is blacklisted on production at the time of writing (the client's production configuration blacklists `region`), so this work also prepares the ground for showing it again.

## What the locations are

Each location was assigned a country by looking at the country-type location (type 1) attached to the same sites. About 94% are Swedish:

| Country | Locations |
|---|---|
| Sweden | 1,052 |
| Norway | 33 |
| Denmark | 24 |
| Finland | 11 |
| Germany | 7 |
| Netherlands | 5 |
| Italy, Poland | 4 each |
| Romania | 3 |
| 13 others | 1 each |

The Swedish names were sorted by their form:

| Form | Locations | Example |
|---|---|---|
| "X socken" | 551 | "Linde socken" |
| Bare name, no suffix | 264 | "Visseltofta", "Uppland", "Harpsund" |
| "X kommun" | 157 | "Tranemo kommun" |
| "Kvarteret X" (city block) | 37 | "Kvarteret Kassamannen" |
| "X kyrka" (church) | 23 | "Ryssby kyrka" |
| "X län" | 20 | "Uppsala län" |

The bare names turned out to be a mix of parish names, the 25 Swedish provinces (landskap), and farms, estates, buildings and streets.

## Goal

Every Region-filter location that is an administrative unit should be linked to one or more boundary polygons, so that it can be drawn on the map and used in spatial queries. The link must be traceable: for each one it should be possible to see where the polygon came from and how confident the match is.

## Out of scope for now

- **Drawing the boundaries in the client, and a JSON API endpoint that serves them.** That is the next step once the data is settled.
- **Correcting SEAD's own data,** for example locations attached to the wrong sites, or locations that should be split. The matching found such problems and they are listed in [06-results.md](06-results.md), but no SEAD data has been changed.
- **Locations that are not regions** (farms, buildings, streets). Johan decided these are handled manually ([D-07](05-decision-log.md#d-07-locations-that-are-not-regions-are-handled-manually)).
