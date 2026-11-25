-- Exports the data behind the site review page (review/index.html), as one JSON document (D-24).
-- Run in the matching workbench after build_mapping.sql. Read-only. Needs site_names(site_id, site_name)
-- loaded by run_build_mapping.sh.
--
-- For every georeferenced site that has at least one region whose boundary does not contain the site's
-- coordinates (a mismatch), it exports:
--   checks   every region of the site that has a boundary to check against: the linked boundaries
--            (mapping), or for regions not linked yet, their pending candidates (near_review); whether the
--            coordinates lie inside, and how far outside they are.
--   lies_in  the units the coordinates actually lie in, with where that comes from: the Lantmäteriet parish or
--            town, its landskap and the basis of that (wikidata / override / shared_border), and the GADM
--            level 1 and level 2 units. When the point lies in none, the nearest within 10 km.
--   name_parish  for "X Raä NN" sites, the parish named X nearest to the coordinates (RAÄ numbers are per parish).
-- regions: for tab 2, every region with a site in the review, its links and all its sites;
-- plus, for every boundary shown, the SEAD regions already linked to it (so a suggested replacement can
-- reuse an existing region row), and its simplified geometry.
-- A site's full list of regions (including those without a boundary) is added from SEAD by build_review_data.py.
with geo as (
    select 'lm_socken_stad' src, kod k, namn label, typ, geom from sl_final
    union all select 'lm_landskap', landskap, landskap, null, geom from landskap_f
    union all select 'gadm_adm_0', gid, name, null, geom from gadm0
    union all select 'gadm_adm_1', gid, name || ', ' || name_0, null, geom from gadm1
    union all select 'gadm_adm_2', gid, name || ', ' || name_1 || ', ' || name_0, null, geom from gadm2
),
reg_bound as (
    select location_id, source, boundary_key, 'linked' status from mapping
    union
    select distinct location_id, source, boundary_key, 'pending' from near_review
    where location_id not in (select location_id from mapping)
),
pts as (
    select distinct site_id, lat, lon, st_setsrid(st_point(lon, lat), 4326) p from region_site where lat is not null
),
checks as (
    select rs.site_id, rs.location_id,
           json_agg(json_build_array(b.source, b.boundary_key, b.status) order by b.source, b.boundary_key) links,
           bool_or(st_covers(g.geom, pts.p)) inside,
           round(min(st_distance(g.geom::geography, pts.p::geography))::numeric) dist_m,
           exists (select 1 from near_review n where n.location_id = rs.location_id and n.site_id = rs.site_id) near_pair
    from region_site rs
    join pts using (site_id)
    join reg_bound b on b.location_id = rs.location_id
    join geo g on g.src = b.source and g.k = b.boundary_key
    group by rs.site_id, rs.location_id
),
q_sites as (select site_id from checks group by 1 having bool_or(not inside)),
lies as (
    select pts.site_id, pts.lat, pts.lon,
           lm.kod in_lm, lm.landskap lm_landskap, lm.landskap_basis lm_basis,
           (select g.gid from gadm1 g where st_covers(g.geom, pts.p) limit 1) in_g1,
           (select g.gid from gadm2 g where st_covers(g.geom, pts.p) limit 1) in_g2,
           pts.p
    from pts
    left join lateral (select s.kod, s.landskap, s.landskap_basis from sl_final s where st_covers(s.geom, pts.p) limit 1) lm on true
    where pts.site_id in (select site_id from q_sites)
),
nearest as (
    select l.site_id,
           case when l.in_lm is null then (select json_build_array(s.kod, round(st_distance(s.geom::geography, l.p::geography)::numeric))
                from sl_final s where st_dwithin(s.geom::geography, l.p::geography, 10000)
                order by s.geom <-> l.p limit 1) end lm,
           case when l.in_g2 is null then (select json_build_array(g.gid, round(st_distance(g.geom::geography, l.p::geography)::numeric))
                from gadm2 g where st_dwithin(g.geom::geography, l.p::geography, 10000)
                order by g.geom <-> l.p limit 1) end g2,
           case when l.in_g1 is null then (select json_build_array(g.gid, round(st_distance(g.geom::geography, l.p::geography)::numeric))
                from gadm1 g where st_dwithin(g.geom::geography, l.p::geography, 10000)
                order by g.geom <-> l.p limit 1) end g1
    from lies l
),
name_parish as (
    select l.site_id, np.kod, np.dist_m
    from lies l
    join site_names sn using (site_id)
    cross join lateral (
        select s.kod, round(st_distance(s.geom::geography, l.p::geography)::numeric) dist_m
        from socken_names x join sl_final s on s.kod = x.kod
        where x.nm = norm((regexp_match(sn.site_name, '^(.+?)\s+ra[aä]\s', 'i'))[1])
        order by s.geom <-> l.p limit 1) np
),
shown as (
    select b.source src, b.boundary_key k from reg_bound b
    where exists (select 1 from checks c where c.location_id = b.location_id and c.site_id in (select site_id from q_sites))
    union select 'lm_socken_stad', in_lm from lies where in_lm is not null
    union select 'lm_landskap', lm_landskap from lies where lm_landskap is not null
    union select 'gadm_adm_1', in_g1 from lies where in_g1 is not null
    union select 'gadm_adm_2', in_g2 from lies where in_g2 is not null
    union select 'lm_socken_stad', lm->>0 from nearest where lm is not null
    union select 'gadm_adm_2', g2->>0 from nearest where g2 is not null
    union select 'gadm_adm_1', g1->>0 from nearest where g1 is not null
    union select 'lm_socken_stad', kod from name_parish
),
simp as (
    select g.src, g.k, g.label, g.typ,
           st_asgeojson(st_simplifypreservetopology(g.geom, greatest(0.0002, sqrt(st_area(g.geom)) / 400)), 4)::json gj
    from geo g join shown s on s.src = g.src and s.k = g.k
)
select json_build_object(
  'generated', now()::date,
  'decisions', (select coalesce(json_agg(d), '[]') from site_review_decisions d),
  'sites', (select json_agg(json_build_object(
      'site_id', l.site_id, 'lat', l.lat, 'lon', l.lon,
      'checks', (select json_agg(json_build_object('location_id', c.location_id, 'links', c.links, 'inside', c.inside,
                                                   'dist_m', c.dist_m, 'near_pair', c.near_pair) order by c.inside, c.location_id)
                 from checks c where c.site_id = l.site_id),
      'in_lm', l.in_lm, 'lm_landskap', l.lm_landskap, 'lm_basis', l.lm_basis, 'in_g1', l.in_g1, 'in_g2', l.in_g2,
      'nearest', (select json_build_object('lm_socken_stad', n.lm, 'gadm_adm_2', n.g2, 'gadm_adm_1', n.g1) from nearest n where n.site_id = l.site_id),
      'name_parish', (select json_build_array(np.kod, np.dist_m) from name_parish np where np.site_id = l.site_id)
    ) order by l.site_id) from lies l),
  -- tab 2: every region with at least one site in the review, its boundary links (or pending candidates),
  -- and all its georeferenced sites, inside any of its boundaries or not
  'regions', (select json_agg(json_build_object(
      'location_id', r.location_id, 'name', rc.name,
      'links', (select json_agg(json_build_object('source', b.source, 'key', b.boundary_key, 'status', b.status,
                                                  'match_type', m.match_type) order by b.source, b.boundary_key)
                from reg_bound b left join mapping m using (location_id, source, boundary_key)
                where b.location_id = r.location_id),
      'sites', (select json_agg(json_build_array(c.site_id, pts.lat, pts.lon, c.inside, c.dist_m, c.near_pair) order by c.inside, c.dist_m)
                from checks c join pts using (site_id) where c.location_id = r.location_id))
    order by rc.name) from (select distinct location_id from checks where not inside) r join region_cls rc using (location_id)),
  'linked_regions', (select json_object_agg(src_key, regions) from (
      select m.source || ':' || m.boundary_key src_key,
             json_agg(distinct jsonb_build_array(m.location_id, m.location_name)) regions
      from mapping m group by 1) x),
  'boundaries', (select json_object_agg(s.src || ':' || s.k, json_build_object('label', s.label, 'typ', s.typ, 'geom', s.gj)) from simp s)
);
