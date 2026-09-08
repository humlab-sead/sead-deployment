# Release 2026-06.0 changelog

Scope: changes reviewed from the `@2025.02` Sqitch release marker to the
`@2026.04` release tag.

Source used: GitHub comparison for
`humlab-sead/sead_change_control` from commit
`c79c077982304e0cd62683b1841a28b563f98ade` to
`82424da0f79a9464766fb21cb23248fcd65c2682`.

Note: `@2025.02` is present as a Sqitch release marker in project plans, but
is not present as a Git tag on `origin`. The lower bound above is the commit
that completed the February 2025 Sqitch plan tagging. `@2026.04` is present as
a Git tag and points at `82424da`.

## Summary

The repository advanced from the February 2025 Sqitch release marker to the
April 2026 release tag with 341 GitHub commits in the comparison range. The
release-positioned Sqitch changes are concentrated in `adna`, `facet`,
`sead_model`, `utility`, and the newly added `radiocarbon` project. The same
period also introduced a much larger operator tooling surface around staging
deploys, clearinghouse submissions, generated documentation, semantic release
automation, and agent/repository guidance.

## Release-positioned database changes

### aDNA

- Added `20250402_DML_ADNA_EXPLODE_ANALYSIS_VALUES`
  ([#372](https://github.com/humlab-sead/sead_change_control/issues/372)):
  explodes untyped aDNA analysis values into typed tables.
- Added `20260201_DML_ADNA_ACCESSION_LINK`
  ([#395](https://github.com/humlab-sead/sead_change_control/issues/395)):
  adds an aDNA accession type and accession link handling.

### Facet

- Added `20250402_DML_ADNA_DOMAIN_FACET`
  ([#369](https://github.com/humlab-sead/sead_change_control/issues/369)):
  adds the domain facet for aDNA.
- Added `20260323_DML_FACET_DESCRIPTIONS`: improves 26 facet descriptions
  where descriptions were missing or only repeated the filter name.
- Added `20260327_DML_FIX_DATASET_METHODS_FACET`
  ([#423](https://github.com/humlab-sead/sead_change_control/issues/423)):
  fixes the `dataset_methods` facet by removing the deprecated
  `tbl_dataset_methods` entry and promoting `tbl_methods` as the target table.
- Added `20260331_DML_DATASETS_FACET`: adds a datasets facet backed by
  `tbl_datasets` as a domain filter.
- Added `20260402_DML_ANALYSIS_ENTITY_AGES_BP_OVERLAP_FIX`: aligns the
  `analysis_entity_ages` facet range semantics with BP overlap expectations.

### SEAD model

- Added `20251120_DDL_SITE_TYPES`
  ([#403](https://github.com/humlab-sead/sead_change_control/issues/403)):
  creates tables and initial data for storing site types.
- Added `SEAD_MODEL_COMMENTS`
  ([#411](https://github.com/humlab-sead/sead_change_control/issues/411)):
  moves table and column comments into a dedicated model comments change.
- Added `20260212_DDL_PROPERTY_VALUE_TABLES`
  ([#412](https://github.com/humlab-sead/sead_change_control/issues/412)):
  adds generic key-value property tables.

### Utility

- Added `20250526_COUNTRY_CODES`
  ([#383](https://github.com/humlab-sead/sead_change_control/issues/383)):
  adds country-code data to the utility project.

### Radiocarbon

- Added `radiocarbon` as a new Sqitch project and inserted it into
  `projects.txt`.
- Added `20250401_RADIOCARBON_PILOT__COMMIT`
  ([#370](https://github.com/humlab-sead/sead_change_control/issues/370)):
  introduces radiocarbon pilot data with deploy, revert, verify, and plan
  files.

## Other database-history changes in the GitHub range

- Renamed and reshaped the aDNA pilot submission CR from
  `20250108_DML_SUBMISSION_ADNA_001_COMMIT` to
  `20250108_DML_SUBMISSION_ADNA_PILOT_COMMIT`, including updated deploy,
  revert, verify, data, and post-deploy hook files.
- Added `20240925_DDL_SAMPLE_DIMENSION_QUALIFIER`
  ([#356](https://github.com/humlab-sead/sead_change_control/issues/356)):
  adds qualifier support to sample dimension values. In the final plan it is
  positioned before the older release markers, so it is treated here as
  history/backport work rather than a new CR between `@2025.02` and
  `@2026.04`.
- Backported and corrected existing SEAD model changes, including
  bibliographic UUID handling, `date_submitted` typing, measured-value refactor
  scripts, lookup data, foreign keys, and model comments.
- Backported UUID support into `20190401_DDL_UTILITY_SCHEMA` and updated
  utility helpers for dropping tables/views, allocating system IDs, storing
  view definitions, result chronology import, and schema/documentation support.
- Updated several older facet scripts for consistency, including category
  operator handling, construction/taxa/geochronology facets, and sample-group
  facet behavior.
- Reworked clearinghouse submission handling around submission names rather
  than serial IDs.
- Added or updated clearinghouse transport data under `subsystem`, including
  copied `copy_in.sql` and `copy_out.sql` material for isotope, ceramics,
  dendrochronology living trees, and aDNA pilot submissions.
- Updated the clearinghouse system and transport system scripts for stronger
  utility use, role handling, resilience, and post-deploy hook support.
- Renamed historical submission CRs for ceramics and dendrochronology to remove
  embedded submission-number naming, with matching deploy, revert, verify, and
  data-folder updates.
- Updated aDNA, ceramics, dendrochronology, isotope, MAL, Bugs, SEAD API, and
  archived scripts where commit history shows corrections to old deploy files,
  copy scripts, lookup data, comments, or formatting.
- Archived several obsolete or no-op general/utility change files rather than
  leaving them in active deploy paths.

## Tooling, workflow, and documentation

- Added semantic-release configuration and GitHub Actions release automation,
  with repository versions moving through `v1.1.0` to `v1.15.1` in this range.
- Expanded `bin/deploy-staging` with deploy-from-tag support, stricter option
  handling, empty-status handling, clearer output, and supporting
  `bin/deploy-staging.md` documentation.
- Added and improved clearinghouse/submission tooling:
  `bin/commit-submission`, `bin/submission`, `bin/deploy-clearinghouse`,
  `bin/deploy-clearinghouse-commit`, and related development reset/update
  helpers.
- Added utility scripts including `bin/_db_utils.sh`, `bin/ls-cr`,
  `bin/ls-columns`, `bin/dump-table-data`, `bin/import-geonames`,
  `bin/tbls.sh`, and `bin/add-topic-to-repository`.
- Replaced the older `bin/isql` path with `bin/psql.sh`, improving environment
  variable handling and `.pgpass`-based password behavior.
- Added generated documentation support through `bin/create-docs`, SchemaSpy
  resources, `.tbls.yml`, `.sqlfluff`, `resources/tables_and_columns.csv`,
  `resources/tables_and_columns_old.xlsx`, and `resources/sead_model.png`.
- Added repository guidance and release material: `AGENTS.md`,
  `.github/copilot-instructions.md`, `docs/RELEASE-NOTES.md`,
  `docs/project-review-2026-01-20.md`, and updates to `README.md` and
  `CHANGELOG.md`.

## Release-boundary notes

- The final `@2026.04` Git tag points at commit `82424da`, which moves the
  dendrochronology `@2026.04` marker before
  `20241213_DML_LUND_LIVING_TREES_COMMIT`. That living-trees CR is present in
  the GitHub commit history, but the final plan position means it is not inside
  the dendrochronology `@2026.04` deployment scope.
- `general/deploy/20260318_DML_METHODS_UPDATE.sql` is present in the GitHub
  history, but it is not present in the final `general/sqitch.plan`, so it is
  not counted as `@2026.04` release-positioned content.
- Several project plans place `@2026.02` after `@2026.04`. This changelog uses
  the final `@2026.04` positions as the release boundary and calls out
  substantive CRs that are positioned between `@2025.02` and `@2026.04` or are
  part of new projects introduced during the range.
- This is a changelog compiled from GitHub commit history and local Sqitch plan
  state. It does not record a fresh staging validation run.
