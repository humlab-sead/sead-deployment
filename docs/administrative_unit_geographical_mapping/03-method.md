# 3. Method

## Principle

A name match alone is not trustworthy. Swedish parish names repeat a lot: there are several parishes each called Dalby, Ekeby, Tuna, Bro, Gryt and Halla. So every candidate boundary was checked against the coordinates of the sites SEAD attaches to the location (`tbl_sites.latitude_dd` / `longitude_dd`). A boundary is accepted when the location's own sites lie inside it ([D-04](05-decision-log.md#d-04-a-name-match-must-be-confirmed-by-the-locations-sites)).

## Where the work was done

No matching was done in SEAD's database. A throwaway PostGIS container (`region-poly-wb`, image `postgis/postgis:18-3.6`) was loaded with read-only extracts:

- the 1,156 Region-filter locations, each with its type and country;
- the 4,057 links between those locations and their sites, with coordinates (11 sites have none);
- site names and their other locations, for review;
- GADM levels 0–2: all of level 0 and 1, and level 2 for the countries that occur;
- Lantmäteriet's Socken och stad, dissolved to one row per code;
- the Wikidata parish data.

The final mapping is produced by [supporting/build_mapping.sql](supporting/build_mapping.sql), run in that container.

## Steps

### 1. Classify and normalise names

Each location got a class from its name: `socken`, `kommun`, `lan` (län or fylke), `kyrka` (church), `kvarter` (city block) or `bare` (anything else). The base name was lower-cased, `?` removed, and the suffix stripped (" socken", " kommun", " kommune", " län", " fylke", " kyrka"). A genitive variant without a final "s" was added: "Leksbergs socken" → "leksbergs", "leksberg".

### 2. Swedish parishes (Lantmäteriet)

Candidates for a location of class `socken` or `bare`:

- **By name:** units whose name equals one of the location's base names. The names a unit goes by are Lantmäteriet's name plus its Wikidata label without "socken" and disambiguators. The Wikidata label catches renamings, such as Klippan = Gråmanstorp.
- **By site:** units that contain one of the location's sites and whose name is similar to the location's (trigram similarity ≥ 0.45). This catches spelling variants such as Bredsätra/Bredsättra and Torbjörnstorps/Torbjörntorp.

For each candidate, the script counts how many of the location's georeferenced sites lie within it. Candidates with no site inside are dropped. Then:

- If one candidate is left, it is the match.
- If several are left, the location is used for sites in several same-named units, and it gets one row per unit ([D-06](05-decision-log.md#d-06-one-location-may-link-to-several-boundaries)).
- If none are left but the name matches exactly one unit, that unit is kept and marked as disagreeing with the sites.

Locations that name a building or a place within a parish ("X kyrka", "X prästgård", "Stockholms slott", villages like "Orkestaby") were excluded even when their parish was obvious ([D-07](05-decision-log.md#d-07-locations-that-are-not-regions-are-handled-manually)).

### 3. Provinces (landskap)

Lantmäteriet has no province attribute, so the provinces were built:

1. Each parish takes its province from Wikidata (P361) when Wikidata names exactly one. That covers 2,338 units.
2. Ten border parishes that Wikidata places in two provinces were decided by hand, each with a reason, in `socken_landskap_overrides.csv`. One of the ten is Hamra, which has no Wikidata code. ([D-05](05-decision-log.md#d-05-landskap-from-wikidata-kept-as-a-file-border-parishes-decided-by-hand).)
3. The remaining 125 units, almost all towns, take the province of the neighbour they share the longest border with.
4. Each province is the union of its parishes and towns, so province borders follow Lantmäteriet's parish borders exactly.

Bare location names equal to a province name were linked to the province, and checked against their sites the same way. This is where the landskap/län question arose ([D-17](05-decision-log.md#d-17-landskap-or-län-for-bare-names-open)).

A rejected first attempt: assigning provinces by ranges of the parish code (the ATA list is ordered roughly by province). The ranges have fuzzy edges, the 3500 and 4000 series sit outside them, and the rule got Nordmaling, Bjurholm and Hörnefors wrong.

### 4. Swedish kommuner and län (GADM)

"X kommun" was matched to GADM level 2 in Sweden and "X län" to level 1. The comparison ignores accents, hyphens and spaces: "Örebro län" matches GADM's "Orebro", and "Upplands Väsby" matches "Upplands-Väsby".

### 5. Foreign regions (GADM)

Names were compared to GADM levels 1 and 2 (accent-insensitive trigram similarity ≥ 0.69), accepting only candidates that contain at least one of the location's sites. A dozen more were matched by hand where the names differ by language or form: Sicilia → Sicily, Sligeach → Sligo, Varsinais-Suomi → Finland Proper, Novgorodskaya Oblast → Novgorod, Bornholms Regionskommune → Bornholm, and the Åland units, which are a GADM country of their own.

### 6. Hand-picked links

Some links were added by hand, with a note on each row:

- **The two "X & Y" locations get two rows each:** "Lilla Slågarp & Västra Alstad" and "Vårdsberg & Linköping".
- **"Uusimaa"** → Uusimaa and Eastern Uusimaa, which were merged in 2011.
- **"Umeå stads socken"** → the town of Umeå.

### 7. Exclusions

- **Gamla Uppsala socken:** absorbed into Uppsala before the property-register reform. The Uppsala town polygon would misrepresent it ([D-12](05-decision-log.md#d-12-exclusions-gamla-uppsala-and-sjælland)).
- **Sjælland (two locations):** SEAD means the island. GADM's Sjælland is the administrative region, which leaves out Copenhagen and North Zealand ([D-12](05-decision-log.md#d-12-exclusions-gamla-uppsala-and-sjælland)).

## How a site counts as inside

**Version 2 (from 2026-11-25, [D-19](05-decision-log.md#d-19-the-2-km-tolerance-is-a-fallback-that-needs-a-persons-sign-off)):**

1. Each georeferenced site goes to every candidate boundary that strictly contains it.
2. A site that no candidate contains, but that lies within 2 km of one (measured on the ellipsoid), is a **near site** of the nearest such candidate.
3. A near site supports the link only after a person has said "yes, link" on the [review page](review/index.html): the site stays outside, but the region is linked to that boundary anyway. Until then it counts against the link, and a link that rests only on near sites is left out.
4. A location named "X socken" drops the town candidate of the same name when a socken of that name borders it ([D-18](05-decision-log.md#d-18-the-2-km-tolerance-wrongly-links-a-town-and-its-neighbouring-parish)).

Matching is still by name first; the steps above only decide which of the name candidates hold the sites. Sections 2–4 (landskap, kommun/län, foreign) keep one boundary per location: the one holding most sites. When no candidate holds any site, a unique exact name match is kept as `sites_disagree` or `name_only` (for socken, landskap, kommun and län).

The whole run is `supporting/run_build_mapping.sh`. It loads `near_boundary_review.csv`, runs `build_mapping.sql`, writes `mapping.csv`, and refreshes `review/data.js`.

**Version 1 (2026-11-24, superseded):** a site counted as inside a boundary if it lay within it or no more than 2 km outside ([D-08](05-decision-log.md#d-08-a-site-within-2-km-of-a-boundary-counts-as-inside)). This linked towns to their neighbouring parishes ([D-18](05-decision-log.md#d-18-the-2-km-tolerance-wrongly-links-a-town-and-its-neighbouring-parish)). The script is kept as `supporting/build_mapping_v1.sql`, its output as `supporting/mapping_v1.csv`. The step descriptions above describe both versions, except where they mention the tolerance.

## Match types

Every link records how it was established in `match_type`:

| Value | Rule |
|---|---|
| `confirmed` | The name matches and every georeferenced site is inside |
| `majority` | The name matches and at least half the sites are inside |
| `name_variant` | A spelling or qualifier variant, accepted because the sites are inside |
| `shared_name` | The location is used for sites in several same-named units; one row per unit holding any of them |
| `sites_disagree` | The name matches exactly one unit, but fewer than half the sites are inside it |
| `name_only` | The name matches exactly one unit and no site has coordinates |
| `manual` | Chosen by hand; the `notes` column says why |

**Known flaw in version 1:** in steps 3–5, a location with no georeferenced sites would be labelled `confirmed` (0 of 0 inside) instead of `name_only`. No such location existed, so the output was correct. Version 2 fixes it: such a location gets no site-backed link and falls back to `name_only`.

## Validation

- Every `boundary_key` in the 900 links resolves to a polygon in `sead_staging_region_mapping`.
- The province polygons were checked against the sites SEAD files under each province, and their areas against the actual areas: Lappland 118,149 km², Skåne 11,730 km².
- Each match type was reviewed by reading through its rows. The first pass had a bug: for "Karaby socken" it picked Karaby in Västergötland, while the site is in Västra Karaby in Skåne. That led to the rule that site evidence decides between same-named units.
