# 6. Results

Figures as of 2026-11-24, from the change request `20261124_DML_LOCATION_BOUNDARIES` (equal to [supporting/mapping.csv](supporting/mapping.csv)). They do not yet reflect the landskap/län correction proposed in [D-17](05-decision-log.md#d-17-landskap-or-län-for-bare-names-open).

## Coverage

| Outcome | Locations |
|---|---|
| Linked to at least one boundary | 874 |
| Not a region; handled manually ([D-07](05-decision-log.md#d-07-locations-that-are-not-regions-are-handled-manually)) | 226 |
| Danish, needs DAGI parish polygons | 20 |
| Foreign, needs OSM or another source | 22 |
| Swedish parish not separate in Socken och stad, or not a parish | 13 |
| "Mellannorrlands län", which is not a real län | 1 |
| **Total** | **1,156** |

## Links by source

| Source | Links | Locations |
|---|---|---|
| `lm_socken_stad` (Lantmäteriet parishes and towns) | 638 | 613 |
| `gadm_adm_2` (kommuner and similar) | 188 | 187 |
| `gadm_adm_1` (län, fylker and similar) | 49 | 49 |
| `lm_landskap` (provinces) | 24 | 24 |
| `gadm_adm_0` (Åland) | 1 | 1 |
| **Total** | **900** | **874** |

## Links by match type

| `match_type` | Links | Locations |
|---|---|---|
| `confirmed` | 784 | 784 |
| `shared_name` | 46 | 23 |
| `majority` | 34 | 34 |
| `manual` | 18 | 15 |
| `name_variant` | 13 | 13 |
| `sites_disagree` | 5 | 5 |
| `name_only` | 0 | 0 |

## What the matching found in SEAD's data

These are observations, not corrections ([D-16](05-decision-log.md#d-16-no-sead-data-is-corrected-as-part-of-this-work)).

A site outside its location's boundary has three possible causes:

1. The site is attached to the wrong location.
2. SEAD means the name in a different sense, such as the län rather than the landskap ([D-17](05-decision-log.md#d-17-landskap-or-län-for-bare-names-open)).
3. The boundary is an approximation: the 2 km tolerance on simplified coastlines, or Stockholm assigned wholly to Uppland.

Each case below needs a look before anything is changed.

### Locations used for several places (`shared_name`)

23 locations. Each is attached to sites in more than one unit of that name. They fall into two groups:

- **Different places with the same name:**
  - Bro (0902, 1540)
  - Dalby (0215, 1209)
  - Ekeby (0414, 0909)
  - Gryt (0326, 0425)
  - Halla (0328, 0930)
  - Herrestad socken (0432, 1552)
  - Nora (2308, 2482)
  - Österåker (0125, 0395)
  - Övraby (1172, 1529)
  - Tuna (0380, 2505)
  - Vallby (0384, 1135)

  These locations could be split in SEAD, one per parish.
- **A town and the rural parish of the same name:**
  - Arboga, Eksjö, Laholm, Nybro, Skellefteå, Sölvesborg, Strängnäs, Umeå, Vetlanda, Vimmerby

  These probably mean the whole area, and the two rows together represent it well.

  **Corrected 2026-11-25:** that reading was wrong for nine of the ten. The pairs are mostly an artefact of the 2 km tolerance: the sites lie strictly inside one of the two, and the neighbouring unit was counted because it is within 2 km. Only Eksjö is a real split. See [D-18](05-decision-log.md#d-18-the-2-km-tolerance-wrongly-links-a-town-and-its-neighbouring-parish).
- **Bare names matching a parish and a similarly named one:**
  - "Herrestad": Herrestad and Stora Herrestad
  - "Mellby": Mellby and Norra Mellby

### Sites far from their location (`sites_disagree`)

| Location | Boundary | Sites inside | Observation |
|---|---|---|---|
| Ljungby kommun | Ljungby (Kronoberg) | 0 / 2 | The sites are in Ljung and Ljungby parishes near Kalmar, 171 km away. Probably meant Ljungby parish, not the kommun |
| Storuman kommun | Storuman | 0 / 1 | The site is in Norsjö parish, 51 km away |
| Husby-Sjuhundra socken | Husby-Sjuhundra | 0 / 1 | The site is in Riala |
| Los socken | Los | 0 / 1 | The site is in Hamra, which was split off from Los |
| Uddevalla socken | Uddevalla (town) | 0 / 2 | The sites are in Bäve, next to the town |

### Most but not all sites inside (`majority`)

34 locations. In most of them a single site falls outside. The larger gaps:

| Location | Inside | Note |
|---|---|---|
| Norrbotten (landskap) | 13 / 18 | All 18 are inside Norrbottens län. See D-17 |
| Västerbotten (landskap) | 39 / 47 | All 47 are inside Västerbottens län. See D-17 |
| Uppsala län | 27 / 31 | |
| Södermanland (landskap) | 77 / 80 | Two misses are in Stockholm, assigned to Uppland |
| Ålem, Roslags-Kulla, Sandby, Vänge socken | 1 / 2 each | One site in a neighbouring or same-named parish. Ålem's other site is in Ål, 412 km away |

The full list is in [supporting/mapping.csv](supporting/mapping.csv) (`match_type = majority`, with `n_in` and `n_coord`).

### Locations that are not regions

226 locations with 271 site links, by kind:

| Kind | Locations |
|---|---|
| Other place names (mostly farms and villages) | 71 |
| Farms, estates and hamlets | 52 |
| Churches, churchyards, vicarages, castles and buildings | 43 |
| City blocks (kvarter) | 37 |
| Natural features and reserves | 10 |
| Streets and addresses | 8 |
| Town districts | 5 |

The kinds were assigned from the names by pattern, and are a guide for review, not a classification. Notable cases:

- "Kyrkogården" ("the churchyard") is attached to 34 sites in different Gotland parishes.
- "Stallbacksvägen 8" is a street address.

### Other observations

- "Mellannorrlands län" is not a Swedish län (Mellannorrland is a statistical region). It has one site, in Borgsjö.
- "Ydre socken": Ydre is a härad, not a parish.
- "Lappland" is attached to sites in both Sweden and Finland. It is linked to the Swedish province, which holds 19 of its 20 sites.
- "Nordrhein-Westfalen or Belgium" records an uncertainty about the place rather than naming one region.
