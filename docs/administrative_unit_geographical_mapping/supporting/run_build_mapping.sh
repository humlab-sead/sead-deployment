#!/usr/bin/env bash
# Rebuilds the location → boundary mapping in the matching workbench and refreshes the review page.
#
#   1. loads site names from SEAD, and the reviewer's decisions (near_boundary_review.csv, if present)
#      into the workbench; decisions from the first, region-based versions of the page are converted
#   2. runs build_mapping.sql
#   3. writes mapping.csv and site_region_corrections.csv
#   4. exports the review data and writes ../review/data.js
#
# Needs the workbench container (WB_CONTAINER, default region-poly-wb, database wb) with the input
# tables described in 03-method.md, and read access to the SEAD database
# (SEAD_CONTAINER, default sead-postgresql-1; SEAD_DB, default sead_staging_region_mapping).
# Nothing is written to the SEAD database.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
wb_container="${WB_CONTAINER:-region-poly-wb}"
sead_container="${SEAD_CONTAINER:-sead-postgresql-1}"
sead_db="${SEAD_DB:-sead_staging_region_mapping}"
decisions="$here/near_boundary_review.csv"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

wb() { podman exec -i "$wb_container" psql -U postgres -d wb -v ON_ERROR_STOP=1 "$@"; }
sead() { podman exec -i "$sead_container" psql -U sead_master -d "$sead_db" -v ON_ERROR_STOP=1 "$@"; }

# ---- site names (for "X Raä NN" sites) --------------------------------------------------------------
{
    echo "drop table if exists site_names; create table site_names(site_id int primary key, site_name text);"
    echo "copy site_names from stdin with (format csv);"
    sead -q -c "\\copy (select site_id, site_name from tbl_sites) to stdout with (format csv)"
    echo '\.'
} | wb -q

# ---- decisions ----------------------------------------------------------------------------------------
wb -q -c "drop table if exists site_review_decisions;
          create table site_review_decisions(site_id int, location_id int, question text, decision text,
            target_source text, target_key text, reviewed_by text, reviewed_on date, comment text);"
if [[ -f "$decisions" ]]; then
    # Site-based CSVs (column "question") are taken as they are. Region-based ones from the first versions of the
    # page are converted: yes → keep, move → replace (move_* → target_*); no, other and coords stay.
    python3 -I - "$decisions" > "$tmp/decisions.csv" <<'PY'
import csv, sys
out = csv.writer(sys.stdout)
for row in csv.DictReader(open(sys.argv[1], encoding="utf-8", newline="")):
    d = row.get("decision") or ""
    if "question" in row:
        if not d:
            continue
        out.writerow([row["site_id"], row.get("location_id") or None, row["question"], d,
                      row.get("target_source") or None, row.get("target_key") or None,
                      row.get("reviewed_by") or None, row.get("reviewed_on") or None, row.get("comment") or None])
    elif d in ("yes", "no", "move", "other", "coords"):
        d = {"yes": "keep", "move": "replace"}.get(d, d)
        out.writerow([row["site_id"], row["location_id"], "check", d,
                      row.get("move_source") or None, row.get("move_key") or None,
                      row.get("reviewed_by") or None, row.get("reviewed_on") or None, row.get("comment") or None])
PY
    {
        echo "copy site_review_decisions from stdin with (format csv);"
        cat "$tmp/decisions.csv"
        echo '\.'
    } | wb -q
    echo "Loaded $(wb -At -c 'select count(*) from site_review_decisions') decisions from near_boundary_review.csv"
fi

# ---- matching -------------------------------------------------------------------------------------------
wb < "$here/build_mapping.sql"

wb -q -c "\\copy (select location_id, location_name, source, boundary_key, key_label, match_type, n_in, n_coord, n_near_pending, note
                   from mapping order by location_name, location_id, source, boundary_key) to stdout with (format csv, header)" \
    > "$here/mapping.csv"
echo "Wrote mapping.csv ($(($(wc -l < "$here/mapping.csv") - 1)) links)"

# Corrections of sites' regions in SEAD (replace, add), and sites flagged for a look by hand (other: wrong region;
# coords: wrong coordinates), for 08-sead-data-corrections.md. Nothing is applied here.
wb -q -c "\\copy (select d.site_id, n.site_name, d.question, d.location_id, r.name location_name, d.decision,
                           d.target_source, d.target_key, d.reviewed_by, d.reviewed_on, d.comment
                    from site_review_decisions d
                    left join region_cls r using (location_id)
                    left join site_names n using (site_id)
                    where d.decision in ('replace', 'other', 'coords', 'add') order by d.site_id, d.question, r.name)
                   to stdout with (format csv, header)" \
    > "$here/site_region_corrections.csv"
echo "Wrote site_region_corrections.csv ($(($(wc -l < "$here/site_region_corrections.csv") - 1)) rows)"

# ---- review page ----------------------------------------------------------------------------------------
wb -At < "$here/export_site_review.sql" > "$tmp/review.json"
sead -At -c "select json_object_agg(site_id, json_build_object('name', site_name, 'regions', regions))
             from (select s.site_id, s.site_name,
                          json_agg(json_build_array(l.location_id, l.location_name, l.location_type_id, t.location_type)
                                   order by l.location_type_id, l.location_name) regions
                   from tbl_sites s
                   join tbl_site_locations sl using (site_id)
                   join tbl_locations l using (location_id)
                   join tbl_location_types t using (location_type_id)
                   group by 1, 2) x" > "$tmp/site_regions.json"
python3 -I "$here/build_review_data.py" "$tmp/review.json" "$tmp/site_regions.json" "$here/../review/data.js"
