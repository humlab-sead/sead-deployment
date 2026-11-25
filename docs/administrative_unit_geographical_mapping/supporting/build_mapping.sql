-- Builds the location → boundary mapping in the matching workbench (version 2, 2026-11-25).
--
-- Outputs:
--   mapping(location_id, location_name, source, boundary_key, key_label, match_type, n_in, n_coord, n_near_pending, note)
--     the links the change request inserts.
--   near_review(location_id, location_name, source, boundary_key, key_label, site_id, dist_m, decision, ...)
--     every site that lies outside all of its location's candidate boundaries but within 2 km of one,
--     with the reviewer's sign-off (decision 'yes') when there is one.
--
-- Inputs: region_cls, region_names, region_site, site_socken, sl_final, landskap_f, gadm0, gadm1, gadm2,
-- cand_foreign, wd_socken, socken_names, result, and site_review_decisions (loaded from
-- near_boundary_review.csv; may be empty).
--
-- Rules (decision log):
--   D-04  a name match must be confirmed by the location's sites.
--   D-18  a site belongs to the candidate boundary that strictly contains it. "X socken" prefers the
--         socken (sockenstadtyp 1) over the town of the same name.
--   D-19  only a site outside every candidate may fall back to the nearest candidate within 2 km, and
--         such a site counts as inside only after a person has said yes to it in the review.
--         A link that rests only on unreviewed near sites is left out.
-- The superseded version 1 is build_mapping_v1.sql.

-- site_review_decisions is loaded from near_boundary_review.csv by run_build_mapping.sh (D-24). One row per
-- question on the site review page:
--   question = 'check': the site's coordinates do not fit its region location_id. decision:
--     keep    the region is right. For a near site (within 2 km) this counts in favour of the region's boundary
--             link, i.e. it is the sign-off of D-19.
--     no      (first versions of the page) keep the region, but the site does not support the boundary link.
--     replace the site's link to location_id is to be replaced by a region for target_source/target_key.
--     other   the region is wrong; the comment says more.
--     coords  the site's coordinates look wrong.
--   question = 'add': a suggested additional region for the site (target_source/target_key); decision 'add'.
--   question = 'link' (tab 2): a decision on the link of region location_id to the boundary target_source/target_key:
--     link    link it; sites kept in tab 1 that lie within 2 km outside count in its favour (the D-19 sign-off).
--     nolink  do not link it, whatever the sites say.
-- Effect on the mapping: a site whose region tab 1 replaces or flags (replace, other, coords) no longer counts as evidence
-- for that region (region_site_eff). A near site counts in favour of a link when tab 1 keeps it and tab 2 has not said
-- nolink; a link that rests only on near sites needs tab 2's link. Replacements and additions themselves are applied in
-- SEAD through a change request (08-sead-data-corrections.md), not here.
create table if not exists site_review_decisions(site_id int, location_id int, question text, decision text,
    target_source text, target_key text, reviewed_by text, reviewed_on date, comment text);


-- The site–region links the matching uses: as in SEAD, minus the ones tab 1 has replaced or flagged.
drop table if exists region_site_eff;
create table region_site_eff as
select rs.* from region_site rs
where not exists (select 1 from site_review_decisions d
                  where d.question = 'check' and d.site_id = rs.site_id and d.location_id = rs.location_id
                    and d.decision in ('replace', 'other', 'coords'));

-- Locations that name a building, farm, village or similar rather than a socken, even though
-- the socken they lie in is known. They go to the manual list, not here.
drop table if exists not_region_extra;
create table not_region_extra as
select location_id from region_cls where cls = 'kyrka'
union select unnest(array[4917, 5072, 5082, 5045, 5108, 5121, 5016]);  -- prästgårdar, Stockholms slott, Orkestaby, Vadsbroby, Vänge-Ekeby, Köpinge

-- ================================================================ candidates
-- cand(section, location_id, source, key, label, exact, geom): every boundary a location might mean,
-- by name. section: 1 socken, 2 landskap, 3 Swedish kommun/län, 4 foreign.
drop table if exists cand;
create table cand(section int, location_id int, source text, boundary_key text, key_label text, exact bool,
                  geom geometry(MultiPolygon, 4326));

-- ---------------------------------------------------------------- 1. Swedish socken
drop table if exists r_socken;
create table r_socken as
select * from region_cls
where country = 'Sweden' and cls in ('socken', 'bare')
  and base not in (select norm(landskap) from landskap_f)
  and location_id not in (select location_id from not_region_extra)
  and location_id not in (select location_id from result where status = 'E:not_region')
  and location_id not in (4032, 4124, 4254);   -- Gamla Uppsala (absorbed; D-12); the two "X & Y" locations are manual

insert into cand
select distinct 1, r.location_id, 'lm_socken_stad', s.kod, s.namn, true, s.geom
from r_socken r join region_names rn using (location_id) join socken_names sn on sn.nm = rn.nm join sl_final s on s.kod = sn.kod;

insert into cand
select distinct 1, r.location_id, 'lm_socken_stad', s.kod, s.namn, false, s.geom
from r_socken r join site_socken ss using (location_id) join sl_final s on s.kod = ss.kod
where similarity(un(s.namn), un(r.base)) >= 0.45
  and not exists (select 1 from cand c where c.location_id = r.location_id and c.boundary_key = s.kod);

-- D-18: a location named "X socken" means the socken, not the town, when the town has a rural socken
-- candidate as its neighbour (within 2 km). A same-named socken far away (Kalmar socken in Uppland
-- for "Kalmar socken") does not count: then the town stays a candidate and the sites decide.
delete from cand c
using r_socken r
where c.section = 1 and c.location_id = r.location_id and r.cls = 'socken'
  and (select typ from sl_final where kod = c.boundary_key) = 2
  and exists (select 1 from cand c2 join sl_final s2 on s2.kod = c2.boundary_key
              where c2.location_id = c.location_id and c2.section = 1 and s2.typ = 1
                and st_dwithin(c2.geom::geography, c.geom::geography, 2000));

-- ---------------------------------------------------------------- 2. landskap (only locations named as a bare landskap)
insert into cand
select 2, r.location_id, 'lm_landskap', l.landskap, l.landskap, true, l.geom
from region_cls r join landskap_f l on norm(l.landskap) = r.base
where r.country in ('Sweden', 'Finland|Sweden') and r.cls = 'bare';

-- ---------------------------------------------------------------- 3. Swedish kommun and län against GADM
insert into cand
select distinct 3, r.location_id, case g.lvl when 1 then 'gadm_adm_1' else 'gadm_adm_2' end, g.gid, g.name, true, g.geom
from region_cls r
join (select gid, name, 1 lvl, geom from gadm1 where gid_0 = 'SWE' union all select gid, name, 2, geom from gadm2 where gid_0 = 'SWE') g
  on regexp_replace(un(g.name), '[- ]', '', 'g') in (select regexp_replace(un(nm), '[- ]', '', 'g') from region_names n where n.location_id = r.location_id)
 and g.lvl = case r.cls when 'kommun' then 2 else 1 end
where r.country = 'Sweden' and r.cls in ('kommun', 'lan');

-- ---------------------------------------------------------------- 4. foreign names GADM has as they are (best name similarity only)
insert into cand
select 4, c.location_id, case c.lvl when 1 then 'gadm_adm_1' else 'gadm_adm_2' end, c.gid, c.gname, c.sim >= 0.99, g.geom
from (select *, max(sim) over (partition by location_id) best from cand_foreign
      where sim >= 0.69 and country not like '%|%' and country not like '%?%'
        and location_id not in (3952, 1197)) c   -- Sjælland means the island (D-12)
join (select gid, 1 lvl, geom from gadm1 union all select gid, 2, geom from gadm2) g on g.gid = c.gid and g.lvl = c.lvl
where c.sim = c.best;

-- ---------------------------------------------------------------- 5. chosen by hand (not scored; not reviewed for nearness)
drop table if exists manual;
create table manual(location_id int, source text, boundary_key text, note text);
insert into manual values
    (4124, 'lm_socken_stad', '1295', 'Lilla Slågarp & Västra Alstad: one row per socken'),
    (4124, 'lm_socken_stad', '1401', 'Lilla Slågarp & Västra Alstad: one row per socken'),
    (4254, 'lm_socken_stad', '0529', 'Vårdsberg & Linköping: one row per unit'),
    (4254, 'lm_socken_stad', '0461', 'Vårdsberg & Linköping: one row per unit'),
    (997,  'lm_socken_stad', '0155', 'Umeå stads socken = Umeå stad'),
    (3951, 'gadm_adm_1', 'ITA.15_1',  'Sicilia = Sicily'),
    (736,  'gadm_adm_1', 'RUS.49_1',  'Novgorodskaya Oblast = Novgorod oblast'),
    (4189, 'gadm_adm_1', 'IRL.21_1',  'Sligeach is the Irish name of County Sligo'),
    (967,  'gadm_adm_2', 'DNK.1.4_1', 'Bornholms Regionskommune = Bornholm kommune'),
    (3919, 'gadm_adm_2', 'FIN.5.3_1', 'Varsinais-Suomi = Finland Proper'),
    (3939, 'gadm_adm_2', 'FIN.4.5_1', 'Uusimaa; Eastern Uusimaa merged into Uusimaa in 2011, so both GADM units'),
    (3939, 'gadm_adm_2', 'FIN.4.1_1', 'Uusimaa; Eastern Uusimaa merged into Uusimaa in 2011, so both GADM units'),
    (3968, 'gadm_adm_0', 'ALA',       'Åland is a level-0 unit in GADM'),
    (4117, 'gadm_adm_2', 'ALA.1.3_2', 'Kökar'),
    (4169, 'gadm_adm_2', 'ALA.2.7_2', 'Saltvik'),
    (1198, 'gadm_adm_2', 'NOR.17.16_1', 'Målselvs kommune = Målselv'),
    (4064, 'gadm_adm_2', 'NOR.8.11_1',  'Haram'),
    (3913, 'gadm_adm_1', 'GRC.3_1',     'Attica');

delete from cand where location_id in (select location_id from manual);
create index on cand using gist (geom);

-- ================================================================ sites → candidates
-- Each georeferenced site goes to every candidate that strictly contains it. Only a site that no
-- candidate contains falls back to the nearest candidate within 2 km, as a "near" site (D-19).
drop table if exists site_assign;
create table site_assign as
with pts as (
    select location_id, site_id, st_setsrid(st_point(lon, lat), 4326) p
    from region_site_eff where lat is not null and location_id in (select location_id from cand)
),
strict as (
    select c.section, c.location_id, c.source, c.boundary_key, pts.site_id, 0::numeric dist_m, false near
    from pts join cand c on c.location_id = pts.location_id and st_covers(c.geom, pts.p)
),
near as (
    select n.*, true near from pts
    cross join lateral (
        select c.section, c.location_id, c.source, c.boundary_key, pts.site_id,
               round(st_distance(c.geom::geography, pts.p::geography)::numeric) dist_m
        from cand c
        where c.location_id = pts.location_id and st_dwithin(c.geom::geography, pts.p::geography, 2000)
        order by st_distance(c.geom::geography, pts.p::geography) limit 1) n
    where not exists (select 1 from strict s where s.location_id = pts.location_id and s.site_id = pts.site_id)
)
select * from strict union all select * from near;

-- ================================================================ review
drop table if exists near_review;
create table near_review as
select a.location_id, r.name location_name, a.source, a.boundary_key, c.key_label, a.site_id, a.dist_m,
       (select count(*) from site_assign s where s.location_id = a.location_id and s.source = a.source
           and s.boundary_key = a.boundary_key and not s.near) n_strict,
       case when d.decision = 'keep' and coalesce(ld.decision, '') <> 'nolink' then 'yes'
            when d.decision is not null then 'no' end decision,
       d.reviewed_by, d.reviewed_on, d.comment
from site_assign a
join region_cls r using (location_id)
join cand c using (location_id, source, boundary_key)
left join site_review_decisions d on d.location_id = a.location_id and d.site_id = a.site_id and d.question = 'check'
left join site_review_decisions ld on ld.question = 'link' and ld.location_id = a.location_id
                                  and ld.target_source = a.source and ld.target_key = a.boundary_key
where a.near;

-- ================================================================ links
drop table if exists mapping;
create table mapping(location_id int, location_name text, source text, boundary_key text, key_label text,
                     match_type text, n_in int, n_coord int, n_near_pending int, note text);

with counts as (
    select c.section, c.location_id, c.source, c.boundary_key, c.key_label, c.exact,
           count(a.site_id) filter (where not a.near) n_strict,
           count(a.site_id) filter (where a.near and nr.decision = 'yes') n_yes,
           count(a.site_id) filter (where a.near and nr.decision is null) n_pending,
           string_agg(distinct nr.reviewed_by || ' on ' || nr.reviewed_on, '; ') filter (where a.near and nr.decision = 'yes') signed_off,
           (select count(*) from region_site_eff rs where rs.location_id = c.location_id and rs.lat is not null) n_coord,
           (select ld.decision from site_review_decisions ld where ld.question = 'link' and ld.location_id = c.location_id
               and ld.target_source = c.source and ld.target_key = c.boundary_key limit 1) link_decision
    from cand c
    left join site_assign a using (location_id, source, boundary_key)
    left join near_review nr using (location_id, source, boundary_key, site_id)
    group by 1, 2, 3, 4, 5, 6
),
hit as (
    -- sections 2-4 take one boundary per location: the one holding most sites, then the higher level
    select * from (
        select c.*, row_number() over (partition by location_id order by n_strict + n_yes desc, source, boundary_key) rn
        from counts c
        where n_strict + n_yes > 0
          and coalesce(link_decision, '') <> 'nolink'                    -- tab 2 said no
          and (n_strict > 0 or link_decision = 'link')) x                -- resting on near sites only: needs tab 2's yes
    where section = 1 or rn = 1
),
nhit as (select location_id, count(*) k from hit group by 1),
-- sections 1-3: no candidate holds any site, not even after review: keep a unique exact name match
-- (Swedish kommun and län names are unique, so the link is sure even when the sites are elsewhere)
fallback as (
    select c.location_id, min(c.source) source, min(c.boundary_key) boundary_key, min(c.key_label) key_label, max(c.n_coord) n_coord
    from counts c
    where c.section in (1, 2, 3) and c.exact and not exists (select 1 from hit h where h.location_id = c.location_id)
      and coalesce(c.link_decision, '') <> 'nolink'
      and not exists (select 1 from counts p where p.location_id = c.location_id and p.n_pending > 0)
    group by 1 having count(*) = 1
)
insert into mapping
select h.location_id, r.name, h.source, h.boundary_key, h.key_label,
       case when nh.k > 1 and h.section = 1 then 'shared_name'
            when not h.exact then 'name_variant'
            when h.n_strict + h.n_yes = h.n_coord then 'confirmed'
            when (h.n_strict + h.n_yes) * 2 >= h.n_coord then 'majority'
            else 'sites_disagree' end,
       h.n_strict + h.n_yes, h.n_coord, h.n_pending,
       case when h.n_yes > 0 then format('%s site(s) up to 2 km outside the boundary; linked anyway, signed off by %s',
                                         h.n_yes, h.signed_off) end
from hit h join nhit nh using (location_id) join region_cls r using (location_id)
union all
select f.location_id, r.name, f.source, f.boundary_key, f.key_label,
       case when f.n_coord = 0 then 'name_only' else 'sites_disagree' end, 0, f.n_coord, 0, null
from fallback f join region_cls r using (location_id);

-- ---------------------------------------------------------------- manual links
insert into mapping
select m.location_id, r.name, m.source, m.boundary_key, g.name, 'manual',
       (select count(*) from region_site_eff rs where rs.location_id = m.location_id and rs.lat is not null
           and st_covers(g.geom, st_setsrid(st_point(rs.lon, rs.lat), 4326))),
       (select count(*) from region_site_eff rs where rs.location_id = m.location_id and rs.lat is not null),
       0, m.note
from manual m
join region_cls r using (location_id)
join (select kod key, namn name, geom, 'lm_socken_stad' src from sl_final
      union all select gid, name, geom, 'gadm_adm_1' from gadm1
      union all select gid, name, geom, 'gadm_adm_2' from gadm2
      union all select gid, name, geom, 'gadm_adm_0' from gadm0) g on g.key = m.boundary_key and g.src = m.source;

select source, match_type, count(distinct location_id) locs, count(*) rows from mapping group by rollup (1, 2) order by 1, 2;
select count(*) near_sites, count(distinct (location_id, source, boundary_key)) near_links,
       count(*) filter (where decision is null) pending from near_review;
