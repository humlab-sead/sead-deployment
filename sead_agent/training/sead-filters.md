# SEAD filters (facets) available in this client

Generated from `https://sead.local/query/api/facets` on 2026-09-08. This is the authoritative list of what the
`add_filter`, `set_filter_selections` and `remove_filter` tools accept: the **filter id**
column is the exact string those tools want. Filter ids are not guessable from the title,
and the titles users say out loud rarely match them.

This document is authoritative for **which filters exist and where**. The facet catalogue
in the system context document explains **what each filter acts on** in the database; where
the two disagree about availability, this one is right, because it was read from the running
system. `list_filters` is more current still - it reports the domain the user is actually in.


## Which filters exist where

A **domain** decides which filters are offered. `general` offers all of them; every other
domain offers a subset, because a domain already restricts the data to its own methods.
Asking for a filter the active domain does not list will fail - switch to `general` first,
or pick a filter that domain has.


| Domain | Filters offered |
|---|---|
| `general` | 39 |
| `palaeoentomology` | 22 |
| `archaeobotany` | 22 |
| `pollen` | 21 |
| `geoarchaeology` | 16 |
| `dendrochronology` | 18 |
| `ceramic` | 12 |
| `isotope` | 11 |

Only available in the `general` domain: `abundance_classification`, `analysis_entity_ages`, `constructions`, `dataset_methods`, `dataset_provider`, `record_types`, `region`, `tbl_biblio_sample_groups`, `tbl_biblio_sites`.

This matters when combining ideas. Switching domain **removes** these filters, so a
request like "dendro data in Småland" is best served by staying in `general` and
adding `dataset_methods` (pick the dendrochronology method) alongside `region` - not by
switching to the `dendrochronology` domain, which would leave you no way to filter by
region at all. Switch domain only when the user asks for a domain, or when every filter
you need exists inside it.


## The filters

### Ecology

**abundance classification** - filter id `abundance_classification`

: Type of quantification or classification system used to record presence or abundance of organisms or material properties.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general` only.

**Abundances** - filter id `abundances_all`

: Quantification of the amount (number, presence etc.) of an organism (taxon, species etc.)
: Type `range` - selections are exactly two numbers, [lower, upper].
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`.

**Eco code** - filter id `ecocode`

: Ecological category (trait) or cultural relevance of organisms based on a classification system
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`.

**Eco code system** - filter id `ecocode_system`

: Ecological or cultural organism classification system (which groups items in the ecological/cultural category filter)
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`.


### Measured values

**Loss on Ignition** - filter id `tbl_denormalized_measured_values_32`

: Organic content in % from weight lost when heated to a high temperature (e.g. 550°C)
: Type `range` - selections are exactly two numbers, [lower, upper].
: Domains: `general`, `geoarchaeology`.

**Magnetic sus.** - filter id `tbl_denormalized_measured_values_33_0`

: Measure of the degree to which a material can be magnetized in the presence of an external magnetic field.
: Type `range` - selections are exactly two numbers, [lower, upper].
: Domains: `general`, `geoarchaeology`.

**MS Heating 550** - filter id `tbl_denormalized_measured_values_33_82`

: Measurement of the magnetic susceptibility of a sample after heating at a temperature of 550°C.
: Type `range` - selections are exactly two numbers, [lower, upper].
: Domains: `general`, `geoarchaeology`.

**Phosphates** - filter id `tbl_denormalized_measured_values_37`

: Concentration of phosphate compounds in a sample, often used as an indicator of past human activity.
: Type `range` - selections are exactly two numbers, [lower, upper].
: Domains: `general`, `geoarchaeology`.


### Others

**Abundance Elements** - filter id `abundance_elements`

: The part (element) of the organism (plant or animal) that was counted.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `archaeobotany`, `pollen`.

**Bibliography modern** - filter id `tbl_biblio_modern`

: Published references associated with species descriptions or taxonomic identification literature
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Bibliography sites** - filter id `tbl_biblio_sites`

: Publications and reports directly associated with excavation sites
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general` only.

**Bibliography sites/Samplegroups** - filter id `tbl_biblio_sample_groups`

: Publications and reports associated with specific excavation sites or sample groups
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general` only.

**Construction purpose** - filter id `construction_purpose`

: The intended function of a dated timber construction (e.g. residential, religious, infrastructure, naval)
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `dendrochronology`.

**Constructions** - filter id `constructions`

: Dated timber constructions identified through dendrochronological analysis (e.g. buildings, bridges, ships)
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general` only.

**Data types** - filter id `data_types`

: Types of data generated by an analysis or observation.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Feature type** - filter id `feature_type`

: Archaeological, geological, environmental, or cultural features associated with the excavation and samples
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Modification Types** - filter id `modification_types`

: Types of modification to an organism (insect, seed, bone etc.), such as it being a fragment or carbonised.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `archaeobotany`.

**Proxy types** - filter id `record_types`

: General type of proxy measurement (e.g. pollen, dating) used to infer aspects of the past.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general` only.

**RDB Code** - filter id `rdb_codes`

: Red Data Book codes provide an description of the conservation status of a species in a particular geographical area.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`.

**RDB system** - filter id `rdb_systems`

: Red Data Book systems are used to classify and document the conservation status of species and ecosystems.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`.

**Sampling Contexts** - filter id `sample_group_sampling_contexts`

: The context in which the sample was collected.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.


### Space/Time

**Analysis entity ages** - filter id `analysis_entity_ages`

: Age range assigned to analysis entities based on dating evidence; uses range-intersection matching
: Type `rangesintersect` - selections are exactly two numbers, [lower, upper].
: Domains: `general` only.

**Countries** - filter id `country`

: The name of the country, at the time of collection, in which the samples were collected
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Dataset methods** - filter id `dataset_methods`

: The various methods and techniques used for creating, collecting or analyzing the data
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general` only.

**Dataset provider** - filter id `dataset_provider`

: The institution or individual responsible for contributing a dataset to SEAD
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general` only.

**Datasets** - filter id `datasets`

: Datasets
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Dendrochronology ages** - filter id `dendro_age_contained_by`

: Age range filter for dendrochronology, covering both estimated felling year and outermost tree ring date
: Type `rangesintersect` - selections are exactly two numbers, [lower, upper].
: Domains: `general`, `dendrochronology`.

**Geochronology** - filter id `geochronology`

: Sample ages as retrieved through absolute methods such as radiocarbon dating or other radiometric methods (in method based years before present - e.g. 14C years)
: Type `range` - selections are exactly two numbers, [lower, upper].
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`.

**Insect activity seasons** - filter id `activeseason`

: Season in which an adult insect has been observed to be active.
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`.

**Location type** - filter id `location_types`

: Administrative level of a geographic location entry (e.g. country, region, municipality)
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Region** - filter id `region`

: Modern or historical geographical or administrative region
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general` only.

**Sample groups** - filter id `sample_groups`

: A collection of samples, usually defined by the excavator or collector
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Site** - filter id `sites`

: General name for the excavation or sampling location
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Sites (map)** - filter id `sites_polygon`

: General name for the excavation or sampling location
: Type `geopolygon` - selections are polygon coordinates - not settable by the agent.
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.

**Time periods** - filter id `relative_age_name`

: Age of sample as defined by association with a (often regionally specific) cultural or geological period (in years before present)
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `dendrochronology`, `ceramic`, `isotope`.


### Taxonomy

**Author** - filter id `species_author`

: Authority of the taxonomic name (not used for all species)
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `dendrochronology`.

**Family** - filter id `family`

: Taxonomic family
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `dendrochronology`.

**Genus** - filter id `genus`

: Taxonomic genus (under family)
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `dendrochronology`.

**Taxa** - filter id `species`

: Taxonomic species (under genus)
: Type `discrete` - selections are array of integer ids (use get_filter_options to resolve names).
: Domains: `general`, `palaeoentomology`, `archaeobotany`, `pollen`, `dendrochronology`.
