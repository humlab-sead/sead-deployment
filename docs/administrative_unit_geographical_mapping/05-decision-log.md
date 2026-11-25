# 5. Decision log

Every decision made in this work, in the order it was made. Each records who made it:

- **Johan:** decided by Johan von Boer.
- **Claude Code (accepted):** proposed by Claude Code and accepted by Johan without objection, or confirmed later.
- **Claude Code (unreviewed):** made by Claude Code during the work and not yet reviewed by anyone.

Later decisions can supersede earlier ones; a superseded decision says so rather than being removed.

---

## D-01. A lookup schema for external reference geodata

- **Date / by:** 2026-11-24, Johan
- **Decision:** boundary polygons from external sources live in a schema of their own, `lookup`, together with the GADM tables that used to be in the `gadm` schema. GADM's tables become `lookup.gadm_adm_0..2`.
- **Justification:** one place for external reference data, kept apart from SEAD's own model. The table prefix (`gadm_`, `lm_`) keeps sources apart within the schema.
- **Consequences:**
  - deploy.sh, `import_gadm_data.sh`, `fix_gadm_names.sql` and the JSON API server's GADM endpoint all change.
  - Existing servers need their `gadm` tables moved; deploy.sh does that on the next release deploy.
- **Alternatives:** keep `gadm` and add one schema per source; put everything in `public`. The second would mix sqitch-managed and script-loaded tables.

## D-02. Lantmäteriet is the primary source for Sweden

- **Date / by:** 2026-11-24, Johan
- **Decision:** Swedish parishes and towns come from Lantmäteriet's *Socken och stad*, and the provinces are built from it. RAÄ's parish boundaries and OSM are not used for Sweden.
- **Justification:**
  - Lantmäteriet is the authoritative Swedish source.
  - The data is CC0, covers the whole country without overlaps, and uses the established ATA parish numbering, which Wikidata also uses.
  - Building provinces from it makes province borders agree exactly with parish borders.

## D-03. No Geotorget account; use the CC0 copy on Zenodo

- **Date / by:** 2026-11-24, Johan (no account); Claude Code (use Zenodo), accepted
- **Decision:** no account is created at Lantmäteriet's Geotorget. Socken och stad is taken from the CC0 copy on Zenodo (record 15021532). `import_socken_data.sh` also accepts an official GeoPackage with `--file`.
- **Justification:**
  - The Zenodo copy is the same data, under the same CC0 licence, as GeoJSON.
  - Its attribute names match Lantmäteriet's product description exactly.
- **Cost:** Lantmäteriet's Distriktsindelning, also Geotorget-only, is unavailable. It would have covered most of the 13 Swedish parishes still without a boundary.
- **Risk:** the Zenodo copy may lag behind Lantmäteriet's yearly corrections.

## D-04. A name match must be confirmed by the location's sites

- **Date / by:** 2026-11-24, Claude Code (accepted)
- **Decision:** a candidate boundary is accepted only if sites attached to the location lie within it, unless the name is unique and nothing contradicts it.
- **Justification:** Swedish parish names repeat (Dalby, Ekeby, Tuna). In the first pass, name-only matching picked the wrong Karaby. The sites are the only evidence of which place SEAD means.

## D-05. Landskap from Wikidata, kept as a file; border parishes decided by hand

- **Date / by:** 2026-11-24, Claude Code (accepted)
- **Decision:**
  - A Swedish parish's province is taken from Wikidata's P361.
  - The Wikidata result is stored as a file in the repository (`bin/resources/lookup/socken_wikidata.csv`) and refreshed by script.
  - The ten parishes that Wikidata places in two provinces (plus Hamra, which has no code there) are decided in `socken_landskap_overrides.csv`, each with a reason.
  - Towns, which are not parish items, take the province of the neighbour they share the longest border with.
- **Justification:**
  - Lantmäteriet has no province attribute. Wikidata links its parishes to Lantmäteriet by the same code (P777), and covers 2,348 of 2,473 units.
  - A file makes imports reproducible and independent of the Wikidata service, and refreshes show up as reviewable diffs.
  - Explicit overrides with reasons are auditable.
- **Rejected:** deriving provinces from parish-code ranges, which proved unreliable (see [03-method.md](03-method.md)).
- **Uncertain assignments** (see [07](07-open-issues-and-next-steps.md)):
  - Nysund: shared border, ended up in Värmland.
  - Stockholm: the whole town is assigned to Uppland, though Södermalm is historically Södermanland.
  - Tryserum: Wikidata says Småland, though it lies in Östergötlands län.

## D-06. One location may link to several boundaries

- **Date / by:** 2026-11-24, Claude Code (accepted)
- **Decision:** `tbl_location_boundaries` allows several rows per location.
  - When SEAD uses one location for sites in several same-named units ("Dalby socken" for sites in two different Dalby parishes, or "Eksjö socken" for both the town and the rural parish), it gets one row per unit that holds any of its sites, with `match_type = 'shared_name'`.
  - "X & Y" locations get one row per unit.
- **Justification:**
  - Choosing one unit would hide the others' sites from the map.
  - Shared names are recorded as such, so the locations can later be split in SEAD if that is wanted.

## D-07. Locations that are not regions are handled manually

- **Date / by:** 2026-11-24, Johan (handle manually); Claude Code (where to draw the line), accepted
- **Decision:**
  - Farms, estates, villages, churches, vicarages, castles, streets, city blocks and natural features get no boundary, even when the parish they lie in is known.
  - They are listed, with their sites, for manual handling: 226 locations, 271 site links. The list is in `supporting/non_regions.json` and on the review page.
- **Justification:**
  - Mapping "Ryssby kyrka" to Ryssby parish would present a building as a region.
  - Most of these probably need a different location type in SEAD (settlement, institution, street address) rather than a polygon, and that is a curation decision.

## D-08. A site within 2 km of a boundary counts as inside

> **Superseded on 2026-11-25 by [D-19](#d-19-the-2-km-tolerance-is-a-fallback-that-needs-a-persons-sign-off).** The tolerance linked towns to their neighbouring parishes ([D-18](#d-18-the-2-km-tolerance-wrongly-links-a-town-and-its-neighbouring-parish)). It is now only a fallback, and needs a person's sign-off.

- **Date / by:** 2026-11-24, Claude Code (unreviewed)
- **Decision:** a site counts as inside a boundary if it lies no more than 2 km outside it.
- **Justification:**
  - GADM is simplified to about 110 m, so coastal sites (Västervik, Norrtälje, Tanum) fell just outside their kommun.
  - 2 km absorbs that and small coordinate imprecision, while still separating same-named parishes, which are typically tens to hundreds of kilometres apart.

## D-09. The link is stored in a sqitch-managed table; the polygons are not

- **Date / by:** 2026-11-24, Johan
- **Decision:** the links go in `public.tbl_location_boundaries`, created and filled by change requests in sead_change_control. The polygons stay in `lookup`, loaded by import scripts.
- **Justification:**
  - The links are curated SEAD data and belong in its change history.
  - The polygons are bulky third-party data (GADM's source alone is 1.4 GB) that is refreshed from its sources, as GADM already was.

## D-10. The column is called `boundary_key`

- **Date / by:** 2026-11-24, Claude Code (proposed); Johan (decided to keep)
- **Decision:** the external key column is `boundary_key`, not `boundary_id`.
- **Justification:**
  - In SEAD, `_id` denotes an integer key of a SEAD table, either a serial or a foreign key.
  - This value is the source's own natural key: text (`SWE.14_1`, `0215`, `Skåne`), pointing outside sqitch's model, and not a foreign key.
  - It pairs with `tbl_boundary_sources.key_column`.
- **Alternatives considered:** `boundary_identifier` (after `tbl_sites.national_site_identifier`), `external_key`, `source_key`.

## D-11. `match_type` values are explained in the column comment

- **Date / by:** 2026-11-24, Johan (document the values in the schema); Claude Code (column comment plus a pointer from the table comment), accepted
- **Decision:** the meaning of each `match_type` value, and the 2 km rule, are in the comment on `tbl_location_boundaries.match_type`. The table comment points to it. A check constraint limits the column to the seven documented values.
- **Justification:** database tools and SEAD's generated documentation show a column comment next to the column, where a reader of the values will look.

## D-12. Exclusions: Gamla Uppsala and Sjælland

- **Date / by:** 2026-11-24, Claude Code (unreviewed)
- **Decision:** "Gamla Uppsala socken" and the two "Sjælland" locations are not linked.
- **Justification:**
  - Gamla Uppsala was absorbed into Uppsala before 1976, so the only candidate is the town of Uppsala, which would misrepresent it.
  - SEAD's Sjælland means the island; GADM's Sjælland is the administrative region, which leaves out Copenhagen and North Zealand. Only 1 of 3 sites fell inside.
  - Both wait for better sources (a district boundary; an island polygon from OSM).

## D-13. A local copy of sead_staging for the mapping

- **Date / by:** 2026-11-24, Johan
- **Decision:** the complete setup (lookup schema with data, both change requests) is built in a separate local database, `sead_staging_region_mapping`, copied from `sead_staging`. `sead_staging` is not changed.
- **Justification:** see the result in a real database without touching the one the local services use.

## D-14. Change requests applied to the copy with psql, not sqitch

- **Date / by:** 2026-11-24, Claude Code (unreviewed)
- **Decision:** the two change requests were run against the copy with psql, so its sqitch registry does not record them.
- **Justification:**
  - Local `sead_staging` does not have the `sead_model` changes `20260830_DDL_SUBMISSION_MODEL_REFACTOR` and `20260830_DML_SUBMISSION_MODEL_MIGRATE`, which are planned before ours.
  - A sqitch deploy would have applied them too, making the copy differ from `sead_staging` in unrelated ways.
  - Both scripts guard themselves, so a later sqitch deploy will skip them.

## D-15. Danish parishes: the Dataforsyningen token is not sent to Datafordeler

- **Date / by:** 2026-11-24, blocked by Claude Code's permission system; Claude Code then stayed within it
- **Decision:** Johan's Dataforsyningen token was used only against Dataforsyningen. An attempt to also try it against Datafordeler was blocked, and was not repeated.
- **Justification:** the token was issued for Dataforsyningen. Sending a credential to a different service needs the owner's explicit permission.
- **Outcome:** Dataforsyningen offers Danish parishes only as map images. The polygons are at Datafordeler. Options are listed in [07](07-open-issues-and-next-steps.md).

## D-16. No SEAD data is corrected as part of this work

- **Date / by:** 2026-11-24, Claude Code (unreviewed), following the repository rule not to write to databases unless asked
- **Decision:**
  - Problems found in SEAD's data (sites apparently attached to the wrong location, locations used for several places, buildings typed as regions) are reported in [06-results.md](06-results.md), not fixed.
  - The mapping links SEAD's locations as they are.
- **Justification:** corrections are curation decisions that need their own change requests and review.

## D-17. Landskap or län for bare names (open)

- **Date / by:** 2026-11-24, raised by Johan; rule proposed by Claude Code; **not decided**
- **Problem:**
  - Bare names such as "Norrbotten", "Västerbotten" and "Östergötland" can mean either the landskap or the län.
  - The current mapping (in the change request and the copy) links all bare province names to the landskap.
  - Johan pointed out that Arvidsjaur, whose five sites fell outside landskap Norrbotten, is in Norrbottens län.
- **Evidence:**

  | Location | Sites in landskap | Sites in län | Sites also carrying an explicit "… län" location |
  |---|---|---|---|
  | Norrbotten | 13 / 18 | 18 / 18 | 0 of 19 |
  | Västerbotten | 39 / 47 | 47 / 47 | 43 of 47 |
  | Östergötland | 77 / 78 | 78 / 78 | 62 of 78 |
  | Södermanland | 77 / 80 | 46 / 80 | 53 of 80 (Södermanlands or Stockholms län) |
  | Halland | 50 / 51 | 50 / 51 | 37 of 51 |
  | Skåne, Blekinge, Dalarna, Jämtland, Värmland, Västmanland | all | all | varies |

  The one Östergötland site outside the landskap is Skrickerum, in Tryserum. Wikidata places Tryserum in Småland, but it lies in Östergötlands län.

  Two of Södermanland's three misses are an artefact of [D-05](#d-05-landskap-from-wikidata-kept-as-a-file-border-parishes-decided-by-hand): the town of Stockholm is assigned wholly to Uppland.
- **Consequence already noted:** the earlier claim that Norrbotten's five Arvidsjaur sites are "probably linked wrong" was unfounded. The `majority` description in the column comment ("the others are likely linked to the wrong location") is too strong and should be softened.
- **Proposed rule:**
  1. For a bare name that is both a landskap and a län, choose the one that contains all the sites. Norrbotten, Västerbotten and Östergötland → län; Södermanland → landskap.
  2. Where both fit equally, keep the landskap, the usual sense in archaeology, and note on the row that the län fits as well.
  3. Soften the `majority` comment.
- **Alternatives:** map ties to the län, or to both units.
- **Status:** awaiting Johan's decision. The DML will then be regenerated and re-applied to the copy.

## D-18. The 2 km tolerance wrongly links a town and its neighbouring parish

- **Date / by:** 2026-11-25, raised by Johan (looking at Arboga in the interactive brief); analysis and rule proposed by Claude Code; **rule accepted by Johan, 2026-11-25**; sub-question decided by Johan
- **Problem:**
  - "Arboga socken" is linked to both 2273 (Arboga **stad**, the town, `sockenstadtyp` 2) and 3077 (Arboga **socken**, the rural parish, type 1) as `shared_name`.
  - Its only site, Arboga Raä 65, lies inside the socken and 1.6 km outside the town. The 2 km tolerance of [D-08](#d-08-a-site-within-2-km-of-a-boundary-counts-as-inside) counted it as inside both.
  - D-08 assumed that same-named units lie far apart. A town and the rural parish of the same name are neighbours, so that assumption fails for them.
  - The interactive brief labelled both rows "Lantmäteriet parish or town", hiding the type that tells them apart. Lantmäteriet does record the difference.
- **Evidence:** the ten town/parish pairs among the `shared_name` links, with sites strictly inside each polygon:

  | Location | Sites | In socken | In stad | Strictly, the location is |
  |---|---|---|---|---|
  | Arboga socken | 1 | 1 | 0 | socken |
  | Laholms socken | 1 | 1 | 0 | socken |
  | Skellefteå socken | 2 | 2 | 0 | socken |
  | Sölvesborg socken | 1 | 1 | 0 | socken |
  | Umeå socken | 20 | 20 | 0 | socken |
  | Vetlanda socken | 1 | 1 | 0 | socken |
  | Nybro socken | 1 | 0 | 1 | stad |
  | Vimmerby socken | 1 | 0 | 1 | stad |
  | Strängnäs socken | 3 | 0 | 3 | stad |
  | Eksjö socken | 13 | 1 | 12 | both: a real split |

  The other 13 `shared_name` locations (different parishes far apart, such as the two Dalby) are unaffected: their strict and 2 km counts are the same.
- **Earlier conclusion that this corrects:** [06-results.md](06-results.md) said these town/parish pairs "probably mean the whole area". For nine of the ten, that is not what the sites show.
- **Proposed rule:**
  1. Assign each site to the candidate that strictly contains it. Only when no candidate contains it, fall back to the nearest candidate within 2 km.
  2. `shared_name` only when sites end up in more than one candidate after step 1.
  3. Show `sockenstadtyp` (socken or stad) wherever a Lantmäteriet boundary is shown.
- **Effect:** nine locations get a single link (six socken, three stad), and the number of links drops by nine. Eksjö keeps both.
- **Sub-question:** for "X socken" whose sites are all in the town (Nybro, Vimmerby, Strängnäs), link to the town as the sites say, or to the socken as the name says?
- **Decision (Johan):** the socken, "since that would be more true to the original data". The rule is applied generally: a location named "X socken" means the socken whenever a socken of that name borders the town of the same name.
- **Implementation notes (Claude Code, unreviewed):**
  - "Borders" is tested as within 2 km. Without that test, "Kalmar socken" and "Halmstads socken" switched from their towns to unrelated same-named parishes far away (Kalmar socken in Uppland), which the first run of the new script did. Most of the 46 "X socken" locations linked to a town have no such socken ("Stockholm socken", "Lund socken") and keep the town.
  - **Eksjö socken** follows the rule too, although 12 of its 13 sites are in the town: it is now linked to the socken only, with 1 site inside and 3 near sites waiting for review. Johan may want to look at it.
  - Nybro, Vimmerby and Strängnäs socken now have no site strictly inside the socken. Their sites are near sites, so these locations stay unlinked until the review ([D-19](#d-19-the-2-km-tolerance-is-a-fallback-that-needs-a-persons-sign-off)). One of Strängnäs's three sites is more than 2 km from the socken.
- **Status:** implemented in `supporting/build_mapping.sql` (version 2). The version 1 script and its output are kept as `build_mapping_v1.sql` and `mapping_v1.csv`. The change request DML has not been regenerated yet.

## D-19. The 2 km tolerance is a fallback that needs a person's sign-off

- **Date / by:** 2026-11-25, Johan
- **Decision:**
  - A site belongs to the candidate boundary that strictly contains it.
  - Only a site that no candidate contains may fall back to the nearest candidate within 2 km (a *near site*).
  - A near site supports a link to that boundary only after a person has said yes, i.e. chosen to link the region to it anyway. Until then it counts against the link, and a link that rests only on near sites is left out.
  - The sign-off is recorded with the reviewer's name and date, and ends up in the link's `notes`.
  - There must be a user interface where a person can go through the near sites, see them on a map, and tick yes or no for each.
- **Justification (Johan):** "There's nothing inherently wrong with the 2km rule, but it should only be applied when a matching polygon can not be found and even then we should require manual sign-off on it."
- **Supersedes:** [D-08](#d-08-a-site-within-2-km-of-a-boundary-counts-as-inside).
- **Effect before any review** (`supporting/mapping.csv` compared with `mapping_v1.csv`):
  - 66 near sites on 35 links wait for review.
  - 8 locations are unlinked until then, because all their sites are near sites: Enslöv, Skånela, Valleberga, Nybro, Vimmerby and Strängnäs socken, Kragerø? and Schleswig-Flensburg.
  - 23 links drop from `confirmed` to `majority` or `sites_disagree` until their near sites are reviewed, mostly coastal kommuner (Norrtälje, Västervik, Kalmar).
  - 866 locations are linked by 882 links. Before: 874 locations, 900 links.
- **Alternatives considered:** keep the 2 km tolerance as it was (rejected, see D-18); drop it entirely (rejected by Johan: it is right for coarse coastlines).

## D-20. How the near-site review is done

- **Date / by:** 2026-11-25, Claude Code (unreviewed)
- **Decision:**
  - The review page is a self-contained HTML page in this folder, `review/index.html`, with generated data `review/data.js`. It opens from disk, with no server.
  - For each near site it shows:
    - the candidate boundary;
    - the Lantmäteriet unit and the GADM unit the site actually lies in;
    - the distance;
    - a link to the site in the SEAD browser and in OpenStreetMap;
    - "Yes, link" and "No" checkboxes and a comment field. The question is whether to link the region to the boundary anyway, not whether the site is inside (it is not). Wording changed from "Yes, inside" at Johan's request, 2026-11-25.
  - Decisions are saved in the browser as the reviewer works and downloaded as `supporting/near_boundary_review.csv`, which is committed. The reviewer must enter a name before deciding.
  - `supporting/run_build_mapping.sh` loads that CSV into the matching workbench, rebuilds the mapping and refreshes the review page.
- **Justification:**
  - Johan asked for a visual yes/no interface (D-19).
  - A CSV in the repository is the paper trail: who decided what, when, and in which commit.
  - A local page needs no accounts, server or database writes.
- **Alternatives considered:**
  - a shared web page with stored state (decisions would live outside the repository);
  - an admin view in the SEAD client writing to the database (far more work, and writes to the database before the design is settled).
- **Limitation:** the map has no background map, only boundary outlines. For coastal cases the "Open in OpenStreetMap" link shows the terrain.
- **Later wording changes (Johan, 2026-11-25):** each card asks "Which of these sites support linking the SEAD region "X" to the boundary "Y"?", to remind the reviewer that a site's answer is evidence for the region's link, not a change to the site's own region.
- **Considered and not done (2026-11-25):** splitting the page into 8 *decisive* regions (9 sites, no other site inside, so the answer decides whether the region is linked at all) and 27 *label-only* regions (57 sites, linked anyway, where the answer only moves the match type between `confirmed` and `majority`). Johan kept the page as it was, because it had already been sent to the reviewer.
- **Second version of the page (2026-11-25, at the reviewer's and Johan's request):**
  - each site shows the name and kind of the unit it lies in (for example "Eksjö stad (Lantmäteriet town, code 4044)");
  - besides "Yes, supports the link", the reviewer can choose "No, it belongs in X" for the unit the site lies in, or "No, other reason" with a comment;
  - the region's sites more than 2 km outside are listed too, as optional, with the same "belongs in" choices;
  - the legend names the boundary in question and the units the outside sites lie in.
- **Two outcomes made explicit (Johan, 2026-11-25):** the page now says that an answer can decide two things, and each choice states its effect on both:
  - 🔗 **the boundary link:** is the SEAD region linked to this boundary?
  - 📍 **the site's region:** which SEAD region is the site attached to?

  The plain "No" was split into "No, but keep the site's region" (`no`: against the link, site unchanged) and "No, the site is in the wrong region" (`other`: against the link, flagged for correction by hand, with a comment).
  **Caveat:** a "No" given with the first version of the page now shows as "No, but keep the site's region". Its comment, if any, should be checked when the CSV comes back.
  The "belongs in" answers become proposed SEAD corrections ([D-21](#d-21-review-corrections-lead-to-sead-data-updates-planned-not-yet-done)), written to `supporting/site_region_corrections.csv`. Decisions made with the first version carry over.
- **Third version (Johan, 2026-11-25), "Region review":**
  - **Part 1:** the 35 near-boundary cards. 🔗 and 📍, as before.
  - **Part 2:** 36 new cards for sites more than 2 km outside every boundary their region is linked to. 📍 only.
  - **"Belongs in" choices:** they offer the unit of the same kind as the region's link (a län for a län, a landskap for a landskap) and the Lantmäteriet parish or town; abroad, the GADM municipality.
  - **New choice, "The site's coordinates look wrong" (`coords`):** proposed by Claude Code (unreviewed), because many part 2 sites lie at sea or hundreds of kilometres away. The site's region stays as it is, and the site is flagged for a coordinate check rather than a region correction.
  - **Names of GADM units** are shown in a neutral form ("Eksjö (kommun in Jönköping)", "Östergötland (län)"), to avoid guessing Swedish genitives.
  - **Previously given "No" answers** now mean "keep the site's region".
- **What a "no" does:** the site keeps its region in SEAD (no data is changed, [D-16](#d-16-no-sead-data-is-corrected-as-part-of-this-work)); it only counts against the link. A "no" is a flag that the site may be attached to the wrong region, or that the region row is used for two places.

## D-21. Review corrections lead to SEAD data updates (planned, not yet done)

- **Date / by:** 2026-11-25, Johan
- **Decision:** when the reviewer decides that a site belongs in another unit than its current region (for example Eksjö stad rather than Eksjö socken), that should result in an update of the site's region in the SEAD database. This is to be **planned now and done after the review's CSV has come back**, not before. No new rows are created and nothing in the database is changed until then.
- **Supersedes in part:** [D-16](#d-16-no-sead-data-is-corrected-as-part-of-this-work). SEAD data is still not corrected by the mapping itself, but corrections from the review are now in scope, through their own change request.
- **Plan:** [08-sead-data-corrections.md](08-sead-data-corrections.md).

## D-22. How SEAD data corrections are made

- **Date / by:** 2026-11-25, proposed by Claude Code; Q1–Q5 **decided by Johan**, 2026-11-25
- **Proposal:**
  - The approved corrections become one change request in sead_change_control, deployed before the regenerated location-boundaries change request.
  - Each correction moves the site's link from the old region row to the target row.
  - A target row that does not exist yet is created, with a boundary link.
  - The mapping is rebuilt on the corrected data.
- **Open questions:** see the table in [08-sead-data-corrections.md](08-sead-data-corrections.md#open-questions-d-22):
  - replace or add the link;
  - naming of new region rows;
  - who approves each correction;
  - scope beyond the 35 reviewed regions;
  - who else must agree.
- **Decisions (Johan, 2026-11-25):**
  - **Q1:** replace. The site's link to the old region row is replaced by a link to the new one.
  - **Q2:** new region rows are named after the unit and its kind ("Eksjö stad", "Eksjö socken", "Laholm kommun").
  - **Q3:** the reviewer decides. A "belongs in" answer is applied without a further approval step.
  - **Q5:** anyone else who needs to agree does so in the pull request for the change request.
- **Q4:** Johan asked why sites further outside their region's boundary are not all on the review page. Answer: the page was built for D-19, which only concerns sites within 2 km. Sites further out count against the link automatically, with no sign-off needed, so they were left out. Only with D-21 did the question of a site's region come in, and it applies to them too. On 2026-11-25:
  - 45 sites in 36 linked regions lie more than 2 km outside every boundary of their region and are not on the page (33 in `majority` links, 7 in `sites_disagree`, 5 in `manual`; 22 of them 2–20 km out, 23 more than 20 km);
  - another 26 such sites are on the page as optional far sites, because their region has a near site.

  **Decision (Johan):** add all of them. The review page got a part 2, "Sites far outside their region": 36 regions, 45 sites, one card per region, asking only which region each site should be attached to. Johan also approved the interface changes proposed with it (third version of the page, see [D-20](#d-20-how-the-near-site-review-is-done)).

## D-23. The review page must not present derived units as facts; "belongs in" offers the same kind of unit only

- **Date / by:** 2026-11-25. Raised by Johan; the mistake was Claude Code's.
- **What happened:**
  - On the "Södermanland" card, the page said that Kvarteret Ormen "lies in Uppland (landskap)" and offered "The site belongs in Uppland (landskap)".
  - Nothing in SEAD links the site to Uppland. Its regions are Sweden, Södermanland, Stockholm kommun, Stockholm socken, Stockholm and Kvarteret Ormen.
  - "Uppland" came from our own `lookup.lm_landskap` polygon. That polygon assigns the whole town of Stockholm (Lantmäteriet 0091) to Uppland, by the shared-border fill of the import script (`landskap_basis = 'shared_border'`): there is no Wikidata or other source for it, and it is known to be wrong for Södermalm ([D-05](#d-05-landskap-from-wikidata-kept-as-a-file-border-parishes-decided-by-hand)).
  - The site is on Södermalm (59.319 N, 18.071 E), which is historically Södermanland. "Belongs in Uppland" would have put an error into SEAD.
- **Decisions:**
  1. **Johan:** a "belongs in" correction replaces a region with a unit of the **same kind (level)**: a landskap with a landskap, a parish with a parish. The page offered the Lantmäteriet parish or town as a second option everywhere, which mixed levels; that is to be removed.
  2. **Johan:** the page must not present units it has inferred itself as if they were facts. **Proposed (Claude Code, unreviewed):**
     - every "lies in" statement says where it comes from (Lantmäteriet, GADM, or "our own landskap boundary, built from parishes");
     - a derived unit is not offered as a correction where its basis is weak (`landskap_basis = 'shared_border'`, or a town that spans two landskap, such as Stockholm).
- **Status:** not yet implemented. The current page is with the reviewer, and its answers for landskap cards need checking against this.

## D-24. The review is site-based, in two steps: sites, then regions

- **Date / by:** 2026-11-25, Johan. Implementation details by Claude Code, unreviewed.
- **Decision (Johan):**
  - For each site, show **all** the regions it is currently linked to in SEAD. Only where one of them does not add up with the site's coordinates is the reviewer asked anything.
  - A replacement may be suggested, preferably of the **same level**.
  - Regions are **never added to a site automatically**. Additions may only be suggested to the reviewer.
  - The page has two tabs:
    1. **Sites:** make sure each site has the right regions.
    2. **Regions:** decide the region→boundary links, with the evidence from step 1 applied.
- **Supersedes:** the region-based page of [D-20](#d-20-how-the-near-site-review-is-done), whose "lies in" landskap offers were the error recorded in [D-23](#d-23-the-review-page-must-not-present-derived-units-as-facts-belongs-in-offers-the-same-kind-of-unit-only).
- **How it works (Claude Code):**
  - **Step 1 (112 sites, 138 questions):** every site with at least one region whose boundary does not contain its coordinates (strictly; no 2 km tolerance).
    - Each region of the site is shown as ✓ (inside), ✗ (outside, with the distance) or "no boundary to check".
    - For a ✗ region the choices are: keep; replace with a suggested unit of the same level; "wrong, none of these" (comment); coordinates wrong.
    - Suggestions, each with its source:
      - parish: the Lantmäteriet parish or town containing the point, the nearest one within 10 km, and the parish named in "X Raä NN" site names;
      - kommun and län: the GADM unit containing the point, or the nearest;
      - landskap: only when the parish's landskap comes from Wikidata or a hand-made assignment, never from the shared-border guess (D-23).
    - Hints: when none of the site's regions fit (the coordinates are probably wrong); when the point lies at sea; when the site's name points to another parish.
    - "Possible additions" are offered, unticked, for levels the site has no region of.
  - **Step 2 (71 regions):** every region with a site in step 1.
    - The evidence is recalculated live from step 1: sites replaced or flagged no longer count, and sites kept within 2 km count in favour.
    - The reviewer chooses "Link" or "Don't link" for each boundary.
    - Regions whose link rests only on near sites (8) come first, marked "not linked yet".
  - **In the mapping** (`build_mapping.sql`):
    - a site whose region is replaced or flagged no longer counts as evidence for it (`region_site_eff`);
    - a near site counts in favour when step 1 keeps it and step 2 has not said "don't link";
    - a link resting only on near sites needs step 2's "link";
    - "don't link" removes a link.
  - **Answers from the earlier versions are converted:** yes → keep, move → replace. A plain "no" stays as "keep, but doesn't support the link".
  - **Output files:** answers go to `supporting/near_boundary_review.csv`; corrections and flags (replace, other, coords, add) to `supporting/site_region_corrections.csv`.
- **Map layers (Johan, 2026-11-25):**
  - Each site map has a toggle per region of the site, each in its own colour, plus one for the suggested replacements, so that for example Österåker kommun and Stockholms län can be compared.
  - The map starts with the first ✗ region and fits whatever is switched on.
  - Clicking a region's name in the list shows just that region.
- **Tested** with a scripted round trip (2026-11-25):
  - "coordinates wrong" on Skrea Raä 194 made Halland, Hallands län, Falkenbergs kommun and Skrea socken `confirmed`;
  - "keep" + "link" linked Nybro socken;
  - a replacement took 75246 Eksjö out of Eksjö socken's evidence.
