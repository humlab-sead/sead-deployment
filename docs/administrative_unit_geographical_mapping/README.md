# Mapping SEAD regions to administrative boundaries

This folder documents how the locations in SEAD's **Region** filter were matched to boundary polygons from external sources (Lantmäteriet, GADM, Wikidata and others), so that a selected region can be drawn on the map. It is the record of what was done, why, and what is still open.

The work started on 2026-11-24. It was carried out by Claude Code (an AI assistant) working with Johan von Boer, who made the decisions marked as his in the [decision log](05-decision-log.md). Decisions marked as proposed by Claude Code have not been reviewed by anyone else.

## Status (2026-11-25)

- **874 of the 1,156 Region-filter locations** are linked to at least one boundary (900 links in all).
- **226 locations** are not administrative regions at all (farms, churches, streets, city blocks, natural features) and are left for manual handling.
- **56 locations** are administrative units that still lack a boundary. They need sources not yet available, or a decision. See [open issues](07-open-issues-and-next-steps.md).
- **An open correction:** for bare names that are both a landskap and a län ("Norrbotten", "Västerbotten", "Östergötland"), the current mapping chose the landskap, while the sites show that SEAD often means the län. A rule has been proposed but not yet decided; see [D-17](05-decision-log.md#d-17-landskap-or-län-for-bare-names-open).
- **Matching rule changed on 2026-11-25** ([D-18](05-decision-log.md#d-18-the-2-km-tolerance-wrongly-links-a-town-and-its-neighbouring-parish), [D-19](05-decision-log.md#d-19-the-2-km-tolerance-is-a-fallback-that-needs-a-persons-sign-off)): sites must lie strictly inside a boundary, and the 2 km tolerance is only a fallback that a person must sign off. 112 sites whose coordinates don't fit one of their regions, and 71 regions, wait for review on the [review page](review/index.html). Its answers can also correct sites' regions in SEAD, through a separate change request ([08](08-sead-data-corrections.md)). The figures above, the change request and the interactive brief still show version 1 until the review is done and the mapping is regenerated.
- Nothing is committed or deployed. The work exists on local branches and in a local database copy, `sead_staging_region_mapping`. See [implementation](04-data-model-and-implementation.md).

## Documents

| Document | Contents |
|---|---|
| [human-brief.md](human-brief.md) | **Start here.** A one-page overview with charts and tables |
| [review/index.html](review/index.html) | **Review page**, in two tabs. 1 · Sites: every site whose coordinates don't fit one of its regions, with all its regions listed; keep, replace (same level) or flag. 2 · Regions: link each region to its boundary, with the evidence from step 1. Open the file in a browser ([D-24](05-decision-log.md#d-24-the-review-is-site-based-in-two-steps-sites-then-regions)) |
| [human-brief/index.html](human-brief/index.html) | The same overview as an interactive page (an experiment): click a number to list the regions behind it, with their boundaries, sites and a small map. Open the file in a browser; it needs no server or network |
| [01-background-and-scope.md](01-background-and-scope.md) | What the Region filter is, what is in it, and what the goal is |
| [02-sources.md](02-sources.md) | Every source considered, what it offers, its licence, and whether it was used |
| [03-method.md](03-method.md) | How locations were matched to boundaries, step by step |
| [04-data-model-and-implementation.md](04-data-model-and-implementation.md) | The `lookup` schema, the two new tables, the change requests, scripts and where everything lives |
| [05-decision-log.md](05-decision-log.md) | Every decision, with its justification, the alternatives and who made it |
| [06-results.md](06-results.md) | Counts, match types, and the SEAD data problems the matching uncovered |
| [07-open-issues-and-next-steps.md](07-open-issues-and-next-steps.md) | What remains to be done or decided |
| [08-sead-data-corrections.md](08-sead-data-corrections.md) | Plan for correcting sites' regions in SEAD from the review's answers (not done yet) |

## Supporting files

In [supporting/](supporting/):

| File | What it is |
|---|---|
| `build_mapping.sql` | The matching, version 2 (strict containment, reviewed near sites), run in the matching workbench (see [03-method.md](03-method.md)) |
| `run_build_mapping.sh` | Runs the whole thing: loads the review decisions, runs `build_mapping.sql`, writes `mapping.csv` and `review/data.js` |
| `mapping.csv` | The links from version 2, with sites inside each boundary and near sites still pending review. Not yet in the change request |
| `near_boundary_review.csv` | The reviewers' yes/no decisions on near sites, downloaded from the review page. Does not exist until the first review |
| `site_region_corrections.csv` | Corrections of sites' regions in SEAD from step 1 of the review (replace, add) and sites flagged for a look by hand (wrong region, wrong coordinates). Written by `run_build_mapping.sh`; empty until the review is back |
| `export_site_review.sql`, `build_review_data.py` | Export the review data (sites, their regions and checks, suggestions, regions for step 2) and write `review/data.js` |
| `build_mapping_v1.sql`, `mapping_v1.csv` | Version 1 of the matching and its 900 links, which the current change request inserts. Superseded, kept as a record |
| `region_polygon_matches.csv` | The first matching pass, with a status for every one of the 1,156 locations. Superseded by `mapping.csv`, kept as a record |
| `non_regions.json` | The 226 locations that are not regions, with their sites. The same data as the review page |
| `socken_landskap_overrides.csv` | The hand-made province assignments for ten border parishes |
| `export_human_brief_data.sql`, `export_human_brief_context.sql` | Read-only queries against `sead_staging_region_mapping` that export the data behind `human-brief/index.html` |
| `build_human_brief_data.py` | Combines those exports with the files above into `human-brief/data.js` (generated, about 2 MB) |

The review page for the 226 non-regions is a private claude.ai artifact: <https://claude.ai/artifact/1e1xaQiZ5CmeBm1MYHBgtz>.

This folder is in `docs/` of the sead-deployment repository.
