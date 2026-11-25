-- Coarse country outlines drawn faintly behind the boundary maps in human-brief/index.html.
-- Islands smaller than about 0.02 square degrees are left out. Read-only.
-- Run against sead_staging_region_mapping.
select json_object_agg(gid, st_asgeojson(g, 2)::json)
from (
    select gid, st_collect(st_simplifypreservetopology(d.geom, 0.03)) g
    from lookup.gadm_adm_0, st_dump(geom) d
    where gid in ('SWE', 'NOR', 'DNK', 'FIN', 'ALA', 'DEU', 'EST', 'POL')
      and st_area(d.geom) > 0.02
    group by gid
) c;
