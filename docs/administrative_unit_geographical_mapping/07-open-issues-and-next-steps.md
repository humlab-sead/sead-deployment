# 7. Open issues and next steps

Status as of 2026-11-25. Items needing a decision say whose.

## Decisions waiting

1. **Landskap or län for bare names** ([D-17](05-decision-log.md#d-17-landskap-or-län-for-bare-names-open)). Johan to decide. Proposed rule:
   - choose whichever unit contains all the sites;
   - for ties, keep the landskap and note it on the row;
   - soften the `majority` comment.

   Afterwards: regenerate the DML, re-run the change-request tests, re-apply to `sead_staging_region_mapping`, and update [06-results.md](06-results.md).
2. **The site and region review** ([D-24](05-decision-log.md#d-24-the-review-is-site-based-in-two-steps-sites-then-regions)): 112 sites, then 71 regions ([D-19](05-decision-log.md#d-19-the-2-km-tolerance-is-a-fallback-that-needs-a-persons-sign-off)). The fourth version of the page (two tabs, site-based) has to be sent to the reviewer; earlier answers carry over. Waiting for their CSV. When it arrives, save it as `supporting/near_boundary_review.csv` and run `supporting/run_build_mapping.sh`. Eight locations stay unlinked until this is done. Worth a look while there: Eksjö socken, which [D-18](05-decision-log.md#d-18-the-2-km-tolerance-wrongly-links-a-town-and-its-neighbouring-parish) moved from the town to the socken although 12 of its 13 sites are in the town.

   After items 1 and 2: regenerate the change-request DML from `mapping.csv` (now 882 links before review, against 900 in the current DML), re-run the change-request tests, re-apply to `sead_staging_region_mapping`, regenerate the interactive brief, and update [06-results.md](06-results.md) and the human brief. The `match_type` column comment in the DDL has already been updated for D-18 and D-19.
3. **SEAD data corrections from the review** ([D-21](05-decision-log.md#d-21-review-corrections-lead-to-sead-data-updates-planned-not-yet-done), [D-22](05-decision-log.md#d-22-how-sead-data-corrections-are-made)). Planned in [08-sead-data-corrections.md](08-sead-data-corrections.md); to be done after the review CSV is back. Q1–Q5 decided.
4. **Danish parish polygons.** Johan to choose:
   - **(a)** download DAGI's "Sogn" layer from Datafordeler with a Datafordeler login, into `local-work/`. Recommended: no credential passes through the assistant.
   - **(b)** provide a Datafordeler API key and explicit permission to send it to `wfs.datafordeler.dk`.
   - **(c)** use the third-party dagirlite snapshot.

   20 locations depend on it. Note that "Fyn" and the two "Sjælland" locations mean islands, not parishes.
5. **GitHub issues for the two change requests.** Johan to approve creation. The plan entries and SQL headers say `ISSUE_URL` until then. Issues must carry the AI-generated disclaimer from `AGENTS.md`.
6. **Committing the three branches** (sead_change_control, sead-deployment, json_api_server). Johan to approve, after review.

## Work remaining

### Boundaries still missing

- **Foreign locations (22),** mostly through OpenStreetMap: historical Finnish municipalities (Hauho, Kymi, Eura, Nousiainen, Pori, Rovaniemi), German and Italian communes (Blowatz, Grube, Murlo), Kortrijk, Norwegian areas and old kommuner (Eidanger, Sunnmøre, Torridal, Varanger peninsula, Sværholthalvøya, Kvitøya, Øvre Dividal National Park), Transilvania, Isle of Bazaruto, Oost Flevoland, and "Carunia" (not yet identified). Needs a new source `osm` with a `lookup.osm_boundaries` table and an import script, plus a decision on ODbL attribution.
- **Swedish parishes not separate in Socken och stad (13):**
  - **Absorbed into a town before 1976:** Almby, Eker (Örebro); Badelunda (Västerås); Fosie (Malmö); Gamla Uppsala (Uppsala); Landeryd (Linköping); Östra Eneby (Norrköping); Våmb (Skövde); Västra Frölunda (Göteborg); Lundby (its two sites are in Göteborg and Västerås, so two different Lundby parishes). Lantmäteriet's Distriktsindelning would cover them but is excluded by [D-03](05-decision-log.md#d-03-no-geotorget-account-use-the-cc0-copy-on-zenodo). Alternatives: OSM, or accept the town polygon with `match_type = 'manual'` and a note.
  - **Sandseryd:** renamed Norrahammar (code 0641, which has no Wikidata code). Candidate for a manual link.
  - **Vickelby:** a spelling variant of Vickleby (0879). Its site lies in Torslunda.
  - **Ydre:** a härad, not a parish. There is no härad layer.

### Uncertain province assignments ([D-05](05-decision-log.md#d-05-landskap-from-wikidata-kept-as-a-file-border-parishes-decided-by-hand))

- **Nysund:** placed in Värmland by shared border. It is split between Närke and Värmland.
- **Stockholm (town):** wholly in Uppland, though Södermalm is Södermanland.
- **Tryserum and Hannäs:** Småland according to Wikidata, though both are in Östergötlands län. Their codes sit in the Östergötland block of the ATA list. Needs checking against a historical source.
- **Hamra:** set to Hälsingland by override. Worth confirming.

### SEAD data curation (needs its own change requests)

- **The 226 non-regions:** decide per location whether to change its location type (settlement, institution, street address), merge it into its parish, or keep it. The review page: <https://claude.ai/artifact/1e1xaQiZ5CmeBm1MYHBgtz>.
- **The 11 locations used for different same-named parishes:** consider splitting them ([06-results.md](06-results.md)).
- **The 5 `sites_disagree` cases** and the larger `majority` gaps: check the site links.

### Technical follow-ups

- **Fix the flaw in `build_mapping.sql`:** locations with no georeferenced sites outside the parish step would be labelled `confirmed` instead of `name_only` ([03-method.md](03-method.md)).
- **A `lookup` view** that unions all sources into one (source, key, geometry) shape.
- **A JSON API server endpoint** that serves a location's boundaries, simplified like the GADM endpoint, and **client support** for drawing a selected region. The Region filter can then be reconsidered for production, where it is currently blacklisted.
- **A release that carries:**
  - the deploy.sh changes;
  - the JSON API server change;
  - a sead_change_control tag with the new scripts and change requests.

  The first deploy of that release moves existing `gadm` tables into `lookup` and imports the parish data. Consider recording the move in that release's `upgrade.sh` notes as well.
- **Clean-up:** remove the `region-poly-wb` and `lookup-test-db` containers when the mapping is final, and drop `sead_staging_region_mapping` when it has served its purpose.
