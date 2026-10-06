#!/usr/bin/env python3
"""
Regenerates training/03_sead-filters.md, the agent's reference to the filters this
deployment actually offers.

The filter list is data, not code: it lives in the SEAD database and reaches the browser
from the query API, so it changes without anything here changing. Rerun this whenever the
facet definitions change, then restart the agent to pick the document up.

  ./scripts/generate-filters-doc.py [--base-url https://sead.local] [--out <path>]
"""
import argparse, datetime, json, os, re, ssl, sys, urllib.request

DOMAINS = ["general", "palaeoentomology", "archaeobotany", "pollen",
           "geoarchaeology", "dendrochronology", "ceramic", "isotope"]

#The client renames a few filters on screen (FacetManager.importFacetDefinitions), and the
#agent should know them by the title the user sees
TITLE_OVERRIDES = {
    "analysis_entity_ages": "Timeline",
    "sites_polygon": "Map polygon",
}


def fetch(url):
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(url, timeout=30, context=context) as response:
        return json.loads(response.read())


def client_custom_descriptions(client_source):
    """The client replaces some database descriptions with friendlier wording. Those are
    what the user sees in the interface, so they are what the agent should know."""
    try:
        source = open(client_source, encoding="utf-8").read()
    except OSError as error:
        print("warning: could not read client source (%s); using database descriptions only" % error, file=sys.stderr)
        return {}
    start = source.index("const customDescriptions = [")
    depth, begin = 0, source.index("[", start)
    end = begin
    for i in range(begin, len(source)):
        if source[i] == "[":
            depth += 1
        elif source[i] == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    pairs = re.findall(r'\{\s*facetCode:\s*"([^"]+)",\s*description:\s*"((?:[^"\\]|\\.)*)"\s*\}', source[begin:end])
    return {code: text.replace('\\"', '"').replace("\\'", "'") for code, text in pairs}


def client_staged_filters(client_source):
    """The client folds some filters into one facet that asks for them in order - the eco
    code system and its codes are one "Eco code" filter on screen, and the second stage
    cannot be picked until the first one is. The query API knows nothing about this, so it
    is read from the client, where the pairing is declared."""
    try:
        source = open(client_source, encoding="utf-8").read()
    except OSError:
        return {}
    staged = {}
    for parent, stages in re.findall(
            r'filter\.FacetCode\s*==\s*"([^"]+)"[^}]*?filter\.stagedFilters\s*=\s*\[([^\]]*)\]', source, re.S):
        staged[parent] = [name.strip().strip('"\'') for name in stages.split(",") if name.strip()]
    return staged


def method_abbreviations(postgrest):
    """The short forms the client shows for the methods that are actually in use - by a
    dataset (analysis methods) or a sample group (sampling methods) - leaving out the ones
    that already say what they are ("Dendro" for Dendrochronology)."""
    try:
        methods = fetch(postgrest + "/tbl_methods?select=method_id,method_name,method_abbrev_or_alt_name")
        used = {row["method_id"] for row in fetch(postgrest + "/tbl_datasets?select=method_id")}
        used |= {row["method_id"] for row in fetch(postgrest + "/tbl_sample_groups?select=method_id")}
    except Exception as error:
        print("warning: method abbreviations: %s" % error, file=sys.stderr)
        return []
    abbreviations = {}
    for method in methods:
        abbrev = (method.get("method_abbrev_or_alt_name") or "").strip()
        name = (method.get("method_name") or "").strip()
        if method["method_id"] not in used or not abbrev or not name:
            continue
        #Spacing and punctuation aside, "0,6 mm (%)" is its own name
        if re.sub(r"\W", "", name.lower()).startswith(re.sub(r"\W", "", abbrev.lower())):
            continue
        abbreviations.setdefault(abbrev, name)
    return sorted(abbreviations.items(), key=lambda pair: pair[0].lower())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.environ.get("SEAD_BASE_URL", "https://sead.local"))
    parser.add_argument("--client-source", default=os.path.join(os.path.dirname(__file__), "..", "..",
                                                                "sead_browser_client", "src", "js", "SeadQuerySystem.class.js"))
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "training", "03_sead-filters.md"))
    args = parser.parse_args()

    query_api = args.base_url.rstrip("/") + "/query/api/facets"
    facets = fetch(query_api)
    custom = client_custom_descriptions(args.client_source)
    staged = client_staged_filters(args.client_source)
    #Which parent facet each stage id belongs to
    stage_parent = {stage: parent for parent, stages in staged.items() for stage in stages if stage != parent}

    #Which filters each domain offers. A filter the active domain doesn't list cannot be
    #added while that domain is active.
    by_domain = {}
    for domain in DOMAINS:
        try:
            by_domain[domain] = sorted(f["FacetCode"] for f in fetch(query_api + "/domain/" + domain))
        except Exception as error:
            print("warning: domain %s: %s" % (domain, error), file=sys.stderr)

    groups = {}
    for facet in facets:
        groups.setdefault((facet["FacetGroupKey"], facet["FacetGroup"]["DisplayTitle"]), []).append(facet)

    general = set(by_domain.get("general", []))
    general_only = sorted(code for code in general
                          if not any(code in by_domain.get(d, []) for d in DOMAINS if d != "general"))

    #The document is in the prompt on every turn, so it holds only what the agent cannot get
    #from list_filters: that tool describes the active domain's filters and nothing else, so
    #this is the one place that says which filters the other domains have
    out = []
    out.append("# SEAD filters\n")
    out.append("Every filter this deployment offers, generated from `%s` on %s. The id is what\n"
               "`add_filter`, `set_filter_selections` and `remove_filter` take; it is not guessable from the\n"
               "title. `list_filters` is more current, but covers only the active domain - this list is the\n"
               "only place that says what the other domains offer.\n"
               % (query_api, datetime.date.today().isoformat()))

    out.append("## Domains\n")
    out.append("`general` offers every filter; each other domain offers a subset, and asking for a filter\n"
               "the active domain lacks fails.")
    if general_only:
        out.append("Switching domain **removes** the filters it lacks, so \"dendro data in Sm\u00e5land\" is best\n"
                   "served by staying in `general` and adding `dataset_methods` (pick the dendrochronology\n"
                   "method) alongside `region` - the `dendrochronology` domain has no way to filter by region.\n"
                   "Switch domain only when the user asks for one, or when every filter you need exists in it.")
    out.append("")

    out.append("## The filters\n")
    out.append("One line each: id, title, type, description, and the domains beyond `general` that offer it.\n"
               "A filter with no type is `discrete`: its selections are integer ids from `get_filter_options`.\n"
               "`range` and `rangesintersect` take `[lower, upper]`.\n")
    for (group_key, group_title) in sorted(groups, key=lambda g: g[1]):
        lines = []
        for facet in sorted(groups[(group_key, group_title)], key=lambda f: f["DisplayTitle"].lower()):
            code = facet["FacetCode"]
            #A stage is described on the filter it belongs to
            if code in stage_parent:
                continue
            title = TITLE_OVERRIDES.get(code, facet["DisplayTitle"])
            description = (custom.get(code) or facet.get("Description") or "").strip().rstrip(".")
            if description.lower() == title.lower():
                description = ""
            if code in staged:
                kind = "staged: %s" % " then ".join("`%s`" % stage for stage in staged[code])
            elif facet["FacetTypeKey"] == "geopolygon":
                #Its database description is the site filter's, which only misleads
                kind = "polygons, set with `set_map_polygons`"
                description = ""
            elif facet["FacetTypeKey"] != "discrete":
                kind = facet["FacetTypeKey"]
            else:
                kind = ""
            elsewhere = [d for d in DOMAINS if d != "general" and code in by_domain.get(d, [])]
            if code in general_only:
                where = "`general` only"
            elif len(elsewhere) == len([d for d in DOMAINS if d != "general" and d in by_domain]):
                where = "all domains"
            else:
                where = "also " + ", ".join(elsewhere)

            line = "- `%s` %s" % (code, title)
            if kind:
                line += " (%s)" % kind
            if description:
                line += " - %s" % description
            line += ". *%s*" % where
            lines.append(line)
        if lines:
            out.append("### %s\n" % group_title)
            out.extend(lines)
            out.append("")

    abbreviations = method_abbreviations(args.base_url.rstrip("/") + "/postgrest")
    if abbreviations:
        out.append("## Method abbreviations\n")
        out.append("The site report's Samples table, the overview charts and the Table view's Analyses column\n"
                   "name methods by these short forms, with the full name only in a tooltip you cannot read:\n")
        out.append("; ".join("`%s` %s" % (abbrev, name) for abbrev, name in abbreviations) + ".\n")

    path = os.path.abspath(args.out)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out).rstrip() + "\n")
    print("Wrote %s (%d filters, %d domains)" % (path, len(facets), len(by_domain)))


if __name__ == "__main__":
    main()
