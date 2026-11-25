-- SUPERSEDED on 2026-11-25 by build_mapping.sql (D-18, D-19): this version counted a site within 2 km
-- of a boundary as inside it, which linked towns to their neighbouring parishes. Kept as a record.
-- Builds table mapping(location_id, location_name, source, boundary_key, key_label, match_type, n_in, n_coord, note)
-- in the workbench. Inputs: region_cls, region_names, region_site, site_socken, sl_final, landskap_f, gadm1, gadm2,
-- cand_foreign, wd_socken, result (for the not-a-region list).

drop table if exists mapping;
create table mapping(location_id int, location_name text, source text, boundary_key text, key_label text,
                     match_type text, n_in int, n_coord int, note text);

-- Locations that name a building, farm, village or similar rather than a socken, even though
-- the socken they lie in is known. They go to the manual list, not here.
drop table if exists not_region_extra;
create table not_region_extra as
select location_id from region_cls where cls = 'kyrka'
union select unnest(array[4917, 5072, 5082, 5045, 5108, 5121, 5016]);  -- prästgårdar, Stockholms slott, Orkestaby, Vadsbroby, Vänge-Ekeby, Köpinge

-- every name a socken goes by: Lantmäteriet's, and Wikidata's label without "socken" and disambiguators
drop table if exists socken_names;
create table socken_names as
select kod, norm(namn) nm from sl_final
union select code, norm(regexp_replace(label, 's?\s+socken(,.*)?$', '')) from wd_socken where code is not null
union select code, norm(regexp_replace(label, '\s+socken(,.*)?$', '')) from wd_socken where code is not null;

-- ------------------------------------------------------------ 1. Swedish socken
with r as (
    select * from region_cls
    where country = 'Sweden' and cls in ('socken', 'bare')
      and base not in (select norm(landskap) from landskap_f)
      and location_id not in (select location_id from not_region_extra)
      and location_id not in (select location_id from result where status = 'E:not_region')
      and location_id not in (4032, 4124, 4254)   -- Gamla Uppsala (absorbed); the two "X & Y" locations are added by hand below
),
pts as (select location_id, site_id, st_setsrid(st_point(lon, lat), 4326) p from region_site where lat is not null),
cand as (
    select distinct r.location_id, s.kod, s.namn, true exact
    from r join region_names rn using (location_id) join socken_names sn on sn.nm = rn.nm join sl_final s on s.kod = sn.kod
    union
    select distinct r.location_id, s.kod, s.namn, false
    from r join site_socken ss using (location_id) join sl_final s on s.kod = ss.kod
    where similarity(un(s.namn), un(r.base)) >= 0.45
      and not exists (select 1 from region_names rn join socken_names sn on sn.nm = rn.nm where rn.location_id = r.location_id and sn.kod = s.kod)
),
scored as (
    select c.*,
           (select count(*) from pts where pts.location_id = c.location_id) n_coord,
           (select count(*) from pts join sl_final s on s.kod = c.kod
             where pts.location_id = c.location_id and st_dwithin(s.geom::geography, pts.p::geography, 2000)) n_in
    from cand c
),
hit as (select * from scored where n_in > 0),
nhit as (select location_id, count(*) k from hit group by 1),
-- no candidate holds any of the sites: keep the name match when it is unique
fallback as (
    select s.location_id, min(s.kod) kod, min(s.namn) namn, max(s.n_coord) n_coord
    from scored s
    where s.exact and not exists (select 1 from hit h where h.location_id = s.location_id)
    group by 1 having count(*) = 1
)
insert into mapping
select h.location_id, r.name, 'lm_socken_stad', h.kod, h.namn,
       case when nh.k > 1 then 'shared_name'
            when not h.exact then 'name_variant'
            when h.n_in = h.n_coord then 'confirmed'
            when h.n_in * 2 >= h.n_coord then 'majority'
            else 'sites_disagree' end,
       h.n_in, h.n_coord, null
from hit h join nhit nh using (location_id) join r using (location_id)
union all
select f.location_id, r.name, 'lm_socken_stad', f.kod, f.namn,
       case when f.n_coord = 0 then 'name_only' else 'sites_disagree' end, 0, f.n_coord, null
from fallback f join r using (location_id);

-- ------------------------------------------------------------ 2. landskap (only locations named as a bare landskap)
insert into mapping
select r.location_id, r.name, 'lm_landskap', l.landskap, l.landskap,
       case when n_in = n_coord then 'confirmed' when n_in * 2 >= n_coord then 'majority' else 'sites_disagree' end, n_in, n_coord, null
from region_cls r
join landskap_f l on norm(l.landskap) = r.base
cross join lateral (
    select count(*) filter (where rs.lat is not null) n_coord,
           count(*) filter (where st_dwithin(l.geom::geography, st_setsrid(st_point(rs.lon, rs.lat), 4326)::geography, 2000)) n_in
    from region_site rs where rs.location_id = r.location_id) x
where r.country in ('Sweden', 'Finland|Sweden') and r.cls = 'bare';

-- ------------------------------------------------------------ 3. Swedish kommun and län against GADM
insert into mapping
select distinct on (r.location_id) r.location_id, r.name, case g.lvl when 1 then 'gadm_adm_1' else 'gadm_adm_2' end, g.gid, g.name,
       case when n_in = n_coord then 'confirmed' when n_in * 2 >= n_coord then 'majority' else 'sites_disagree' end, n_in, n_coord, null
from region_cls r
join (select gid, name, 1 lvl, geom from gadm1 where gid_0 = 'SWE' union all select gid, name, 2, geom from gadm2 where gid_0 = 'SWE') g
  on regexp_replace(un(g.name), '[- ]', '', 'g') in (select regexp_replace(un(nm), '[- ]', '', 'g') from region_names n where n.location_id = r.location_id)
 and g.lvl = case r.cls when 'kommun' then 2 else 1 end
cross join lateral (
    select count(*) filter (where rs.lat is not null) n_coord,
           count(*) filter (where st_dwithin(g.geom::geography, st_setsrid(st_point(rs.lon, rs.lat), 4326)::geography, 2000)) n_in
    from region_site rs where rs.location_id = r.location_id) x
where r.country = 'Sweden' and r.cls in ('kommun', 'lan')
order by r.location_id, n_in desc;

-- ------------------------------------------------------------ 4. foreign names GADM has as they are
insert into mapping
select distinct on (c.location_id) c.location_id, c.rname, case c.lvl when 1 then 'gadm_adm_1' else 'gadm_adm_2' end, c.gid, c.gname,
       case when c.sim < 0.99 then 'name_variant' when c.n_in = c.n_coord then 'confirmed' when c.n_in * 2 >= c.n_coord then 'majority' else 'sites_disagree' end,
       c.n_in, c.n_coord, null
from cand_foreign c
where c.sim >= 0.69 and c.n_in > 0 and c.country not like '%|%' and c.country not like '%?%'
  and c.location_id not in (3952, 1197)   -- Sjælland means the island; GADM's Sjælland is the region, which leaves out Copenhagen
order by c.location_id, c.sim desc, c.n_in desc, c.lvl;

-- ------------------------------------------------------------ 5. chosen by hand
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

delete from mapping where location_id in (select location_id from manual);

insert into mapping
select m.location_id, r.name, m.source, m.boundary_key, g.name, 'manual',
       (select count(*) from region_site rs where rs.location_id = m.location_id
           and st_dwithin(g.geom::geography, st_setsrid(st_point(rs.lon, rs.lat), 4326)::geography, 2000)),
       (select count(*) from region_site rs where rs.location_id = m.location_id and rs.lat is not null),
       m.note
from manual m
join region_cls r using (location_id)
join (select kod key, namn name, geom, 'lm_socken_stad' src from sl_final
      union all select gid, name, geom, 'gadm_adm_1' from gadm1
      union all select gid, name, geom, 'gadm_adm_2' from gadm2
      union all select gid, name, geom, 'gadm_adm_0' from gadm0) g on g.key = m.boundary_key and g.src = m.source;

select source, match_type, count(distinct location_id) locs, count(*) rows from mapping group by rollup (1, 2) order by 1, 2;
