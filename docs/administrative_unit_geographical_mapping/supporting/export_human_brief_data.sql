-- Exports the data behind human-brief/index.html as one JSON document:
-- the Region-filter locations and their sites, the boundary links and which sites
-- fall within each linked boundary (2 km tolerance, as in build_mapping.sql),
-- and simplified boundary geometries. Read-only. Run against sead_staging_region_mapping;
-- build_human_brief_data.py turns the output into human-brief/data.js.
with region as (
    select l.location_id, l.location_name, l.location_type_id
    from tbl_locations l
    where l.location_type_id in (2, 7, 14, 16, 18)
      and exists (select 1 from tbl_site_locations sl where sl.location_id = l.location_id)
),
loc_sites as (
    select r.location_id, array_agg(distinct sl.site_id order by sl.site_id) site_ids
    from region r join tbl_site_locations sl using (location_id)
    group by r.location_id
),
sites as (
    select s.site_id, s.site_name,
           round(s.latitude_dd::numeric, 4) lat, round(s.longitude_dd::numeric, 4) lon
    from tbl_sites s
    where s.site_id in (select unnest(site_ids) from loc_sites)
),
bnd as (
    select 'lm_socken_stad' src, sockenstadkod k, sockenstadnamn::text label, geom from lookup.lm_socken_stad
    union all select 'lm_landskap', landskap, landskap, geom from lookup.lm_landskap
    union all select 'gadm_adm_0', gid, name_0, geom from lookup.gadm_adm_0
    union all select 'gadm_adm_1', gid, name_1 || ', ' || name_0, geom from lookup.gadm_adm_1
    union all select 'gadm_adm_2', gid, name_2 || ', ' || name_1 || ', ' || name_0, geom from lookup.gadm_adm_2
),
links as (
    select lb.location_id, bs.boundary_source_code src, lb.boundary_key k, lb.match_type, lb.notes
    from tbl_location_boundaries lb join tbl_boundary_sources bs using (boundary_source_id)
),
used as (
    select b.src, b.k, b.label, b.geom from bnd b
    where exists (select 1 from links l where l.src = b.src and l.k = b.k)
),
link_inside as (
    select l.*, (
        select coalesce(array_agg(s.site_id order by s.site_id), '{}')
        from loc_sites ls, unnest(ls.site_ids) sid join sites s on s.site_id = sid
        where ls.location_id = l.location_id and s.lat is not null
          and st_dwithin(u.geom::geography, st_setsrid(st_point(s.lon, s.lat), 4326)::geography, 2000)
    ) inside
    from links l join used u on u.src = l.src and u.k = l.k
)
select json_build_object(
    'locations', (select json_agg(json_build_object('id', r.location_id, 'name', r.location_name,
                    'type', r.location_type_id, 'sites', ls.site_ids) order by r.location_id)
                  from region r join loc_sites ls using (location_id)),
    'sites', (select json_object_agg(site_id, json_build_array(site_name, lat, lon)) from sites),
    'links', (select json_agg(json_build_object('loc', location_id, 'src', src, 'key', k,
                    'mt', match_type, 'note', notes, 'inside', inside)) from link_inside),
    'boundaries', (select json_object_agg(src || ':' || k, json_build_object('label', label,
                    'geom', st_asgeojson(st_simplifypreservetopology(geom,
                              greatest(0.0005, sqrt(st_area(geom)) / 70)), 3)::json))
                   from used)
);
