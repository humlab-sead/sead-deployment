# SEAD Public Schema Join Patterns

Use only `public` schema relations. These are common starting points for natural-language questions:

- Site context normally starts from `public.tbl_sites`.
- The main sample spine is `public.tbl_sites.site_id = public.tbl_sample_groups.site_id`, then `public.tbl_sample_groups.sample_group_id = public.tbl_physical_samples.sample_group_id`, then `public.tbl_physical_samples.physical_sample_id = public.tbl_analysis_entities.physical_sample_id`.
- Numeric measurements normally continue from analysis entities to `public.tbl_measured_values` using `analysis_entity_id`.
- Biological abundance/species-list questions normally continue from analysis entities to `public.tbl_abundances` using `analysis_entity_id`, then to `public.tbl_taxa_tree_master` using `taxon_id`.
- Dataset and method context for an analysis entity normally joins through `public.tbl_analysis_entities.dataset_id = public.tbl_datasets.dataset_id`; datasets link onward to methods, projects, contacts, and bibliography through their foreign keys.
- Physical sample context, sample locations, sample dimensions, sample descriptions, and sample notes normally join through `physical_sample_id`.
- Sample group context, group descriptions, group dimensions, group coordinates, images, notes, sampling contexts, and references normally join through `sample_group_id`.
- Site location, images, natural grid references, preservation status, other records, and site references normally join through `site_id`.
- Chronology and dating questions usually involve analysis entities, `public.tbl_analysis_entity_ages`, chronologies, relative dates, radiocarbon dates, tephras, age types, and dating uncertainty tables. Follow the public foreign keys in the generated table guide.

Prefer ID-based joins over name-based joins because names can vary in spelling and granularity.
