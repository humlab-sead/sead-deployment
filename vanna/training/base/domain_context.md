# SEAD Domain Context

SEAD is the Strategic Environmental Archaeology Database. Interpret user questions inside this archaeology/database domain unless the user explicitly says otherwise.

SEAD -- the Strategic Environmental Archaeology Database -- is an open-access research infrastructure for archaeological and palaeoenvironmental data. It stores, manages, and makes available a wide range of datasets focused on how past human societies interacted with their natural environment.

The database contains records from across northern Europe and beyond, covering evidence from biological proxies such as pollen, insects, plants, and vertebrates, as well as dendrochronological and other environmental data tied to archaeological sites.

In SEAD, "site" and "sites" mean archaeological site records, normally stored in `public.tbl_sites`. They do not mean websites, web pages, URLs, or internet domains unless the user explicitly asks about those.

SEAD domain tables are normally prefixed with `tbl_`. Do not invent unprefixed natural-language relation names such as `sites`, `samples`, `sample_groups`, or `datasets`. Map user-facing terms to the actual `public.tbl_*` relation names.

If a generated query fails because a relation does not exist, assume the natural-language table name was wrong. Use the trained public schema catalog, table guide, and common mappings in this file to correct the query. Do not ask the user to confirm basic SEAD table names.

When a user asks for "a few sites", "some sites", "random sites", "example sites", or similar phrasing, query `public.tbl_sites`. Include stable identifiers such as `site_id` and human-readable names such as `site_name`.

When no count is specified for "a few", use a small default such as 5 rows. For random examples, use PostgreSQL `ORDER BY random()` with a `LIMIT`.

Prefer the SEAD meaning of ambiguous domain words before ordinary web or business meanings.

## Core Data Hierarchy

Data in SEAD is organised in a three-level hierarchy:

Site -> Sample group -> Sample

Site -- a geographical or archaeological location where fieldwork took place, such as an excavation, a lake, or a bog. Sites are the primary unit users search and filter in the browser. Sites are stored in `public.tbl_sites`.

Sample group -- a logical collection of samples from the same context within a site, such as a sediment core, a trench, or a stratigraphic unit. Sample groups are stored in `public.tbl_sample_groups` and normally join to sites using `sample_group.site_id = site.site_id`.

Sample -- an individual physical or analytical unit from which data were obtained, such as a sediment slice, a single find, or a wood specimen. Samples are stored in `public.tbl_physical_samples` and normally join to sample groups using `physical_sample.sample_group_id = sample_group.sample_group_id`. Samples are also linked to datasets through analysis entities in `public.tbl_analysis_entities`, which represent analyses performed on that sample.

## Common Term To Table Mappings

- site, sites, archaeological site -> `public.tbl_sites`
- sample group, sample groups, context group -> `public.tbl_sample_groups`
- sample, samples, physical sample, physical samples -> `public.tbl_physical_samples`
- analysis, analysis entity, analysis entities -> `public.tbl_analysis_entities`
- dataset, datasets -> `public.tbl_datasets`
- measured value, measurement, measurements, observations -> `public.tbl_measured_values`

For questions about how many samples belong to a site, count rows in `public.tbl_physical_samples`, joined through `public.tbl_sample_groups`:

`public.tbl_sites.site_id = public.tbl_sample_groups.site_id`

`public.tbl_sample_groups.sample_group_id = public.tbl_physical_samples.sample_group_id`
