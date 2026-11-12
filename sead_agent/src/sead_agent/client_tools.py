"""
The tools the agent uses to operate the SEAD web client.

None of them run here. Each one checks its arguments and then defers: the model's run ends,
the command goes to the browser that asked the question, and the next run picks up with
whatever the browser reported back (see agent_service.py). The service never evaluates
model-written JavaScript - the tool names below are the entire vocabulary, and the client
refuses anything else.

The corresponding executor is SeadAgentActions in the sead_browser_client.

The descriptions are part of what the model is told, so they say how each tool behaves;
when and why to use it belongs in training/02_instructions.md.
"""
from dataclasses import replace
from typing import Annotated, Literal

from pydantic import Field
from pydantic_ai import CallDeferred, ModelRetry, Tool

Domain = Literal["general", "palaeoentomology", "archaeobotany", "pollen", "geoarchaeology", "dendrochronology", "ceramic"]
ResultView = Literal["map", "table", "mosaic"]

#The client's own limit on areas in one call - SeadAgentActions.MAX_AREAS
MAX_AREAS = 6

#A discrete facet is picked by integer id, a range facet by exactly two numbers. Which one a
#filter is, only the client knows, so the shape is checked there.
Selections = Annotated[list[float], Field(description="For a discrete filter: the integer ids to select. For a range or timeline filter: exactly two numbers, [lower, upper].")]
FilterId = Annotated[str, Field(description="The filter id.")]

Point = Annotated[list[float], Field(min_length=2, max_length=2)]
Polygon = Annotated[list[Point], Field(min_length=3)]


def defer(**args):
    """
    Hands the call to the browser. The arguments go with it as they came out of validation,
    and an argument the model left out is left out here too, so the client sees exactly the
    shape it always has.
    """
    raise CallDeferred(metadata={"args": {name: value for name, value in args.items() if value is not None}})


#The tools that take no arguments. Asked to call one, the local model tends to invent a
#placeholder anyway - {"raw": "true"}, {"_noargs": "unused"} - and keeps doing so however
#often it is told not to, so refusing those would only spend its retries. They accept and
#drop whatever they are given (the **placeholders), while the schema the model is shown
#still says there is nothing to give.
NO_ARGUMENTS_SCHEMA = {"type": "object", "properties": {}, "additionalProperties": False, "description": "No arguments."}


async def no_arguments_schema(ctx, tool_def):
    return replace(tool_def, parameters_json_schema=NO_ARGUMENTS_SCHEMA)


async def list_filters(**placeholders):
    """List the filters (facets) this client offers, with their id, title, type and description, and which ones the user currently has open. Call this before adding a filter, so you use a real filter id rather than guessing one."""
    defer()


async def get_state(**placeholders):
    """Read what the user is currently looking at, as a snapshot of the whole interface: which page they are on, the active domain, every open filter with its selections, whether it is minimised and anything typed into its text search, the active result view with its site count and which mosaic tiles are rendered, the open site report and which of its sections are expanded, any dialog covering the screen, which menus are open, and the quick search results if they are showing. Call this before answering any question about 'the current results', 'my filters' or what is on screen, and after making changes to see their effect."""
    defer()


async def get_filter_options(
    filter: Annotated[str, Field(description="The filter id, as given by list_filters - or one of its stage ids, for a filter that has stages.")],
    search: Annotated[str | None, Field(description="Optional case-insensitive substring to match against option names.")] = None,
):
    """List the values that can be selected in one discrete filter, as {id, name} pairs. This is how you turn a name the user said ('pollen', 'Sweden', 'oak') into the id that a selection needs. Results are capped, so pass 'search' to narrow them. For a filter that list_filters marks with `stages`, pass a stage id rather than the filter id - a later stage has no values until the stage before it has a selection, and the reply says which one is in the way."""
    defer(filter=filter, search=search)


async def add_filter(
    filter: Annotated[str, Field(description="The filter id, as given by list_filters.")],
    selections: Selections | None = None,
):
    """Open a filter in the client, optionally with values already selected. This is what the user means by 'add', 'apply', 'deploy' or 'show me' a filter. Adding a filter with no selections is useful on its own - it shows the user the available values. A stage id opens the one facet its stages share."""
    defer(filter=filter, selections=selections)


async def set_filter_selections(filter: FilterId, selections: Selections):
    """Replace what is selected in a filter that is already open. Use this rather than removing and re-adding a filter. For a staged filter (see `stages` in list_filters) pass the stage id, e.g. `ecocode_system` to pick the classification system and then `ecocode` to pick codes within it - the filter id alone cannot say which stage you mean."""
    defer(filter=filter, selections=selections)


async def remove_filter(filter: FilterId):
    """Close one filter and drop its selections."""
    defer(filter=filter)


async def clear_filters(**placeholders):
    """Remove every filter the user has open and go back to an unfiltered result. This throws away the user's work, so only do it when they clearly asked to start over."""
    defer()


async def set_domain(domain: Annotated[Domain, Field(description="The domain to switch to.")]):
    """Switch the active domain. A domain scopes the whole interface - it changes which filters are offered and adds a hidden method filter to every query. Changing it rebuilds the filters and the results, so prefer a filter when the user only wants to narrow results."""
    defer(domain=domain)


async def open_site_report(siteId: Annotated[int, Field(description="The site's database id. Resolve a name to an id with get_filter_options on the 'sites' filter.")]):
    """Open a site's report page - the full record for one site, with its sample groups, analyses and datasets. This is what the user means by 'take me to', 'go to', 'show me' or 'open' a named site, as opposed to filtering the result list down to it. Filtering to a site and opening its report are different things: prefer this one when they name a single site."""
    defer(siteId=siteId)


async def close_site_report(**placeholders):
    """Leave the site report and go back to the filters and result list."""
    defer()


async def list_site_report_sections(**placeholders):
    """List the sections of the site report that is currently open - their id, title, whether they are expanded, and their subsections. An expanded section also lists its expandableRows: table rows, such as sample groups, that open onto the rows inside them. Call this before expanding or collapsing anything, since section ids differ from site to site (each analysis method gets its own section)."""
    defer()


async def set_site_report_section(
    section: Annotated[str, Field(description="The section id, as given by list_site_report_sections.")],
    expanded: Annotated[bool, Field(description="true to expand and reveal it, false to collapse it.")],
):
    """Expand or collapse one section of the open site report - an analysis, a dataset, the sample groups. Expanding also scrolls the section into view and loads its contents."""
    defer(section=section, expanded=expanded)


async def set_site_report_rows(
    section: Annotated[str, Field(description="The id of the section the rows are in, as given by list_site_report_sections, e.g. 'samples'.")],
    rows: Annotated[list[str], Field(description="Row ids from expandableRows, e.g. sample group ids ['12724'].")],
    expanded: Annotated[bool, Field(description="true to open the rows, false to close them.")],
):
    """Open or close rows inside a site report table - a sample group in the 'samples' section, to show its samples, say. This is what the user means by expanding or opening a sample group; set_site_report_section only opens whole sections. Row ids come from expandableRows in list_site_report_sections. The reply gives each row's state afterwards - report that, not what you asked for."""
    defer(section=section, rows=rows, expanded=expanded)


async def export_site_report(
    section: Annotated[str | None, Field(description="Optional section id to export just that section; omit to export the whole site.")] = None,
):
    """Open the export dialog for the site report, so the user can download the data. Offers the formats available for what is being exported. This opens the chooser - it does not download anything on its own, the user picks the format."""
    defer(section=section)


async def set_result_view(view: Annotated[ResultView, Field(description="The result view to activate.")]):
    """Switch how results are displayed. 'mosaic' is the overview with charts, 'table' is the site list, 'map' is the geographic view."""
    defer(view=view)


async def find_areas(
    name: Annotated[str, Field(description="The area name to look for, e.g. 'Skåne', 'Sweden', 'Umeå'. Matched case-insensitively anywhere in the name.")],
    level: Annotated[Literal[0, 1, 2] | None, Field(description="Optional: 0 country, 1 region, 2 municipality. Omit to search all three.")] = None,
    country: Annotated[str | None, Field(description="Optional country name to restrict the search to, e.g. 'Sweden'.")] = None,
):
    """Look up an administrative area - a country, region or municipality - by name, in the GADM boundary data held alongside SEAD. Returns candidates with the id that set_map_polygons takes. Names repeat all over the world (there are eight Yorks), so read the country and region on each candidate before choosing, and say which one you used. This is a lookup only: it does not change anything on screen."""
    defer(name=name, level=level, country=country)


async def set_map_polygons(
    areas: Annotated[list[str] | None, Field(max_length=MAX_AREAS, description="Area ids from find_areas, e.g. ['SWE.13_1']. At most 6.")] = None,
    polygons: Annotated[list[Polygon] | None, Field(description="Explicit polygons, each a list of [latitude, longitude] pairs in order around the shape. At least 3 points per polygon; do not repeat the first point at the end.")] = None,
    append: Annotated[bool | None, Field(description="Add to the polygons already on the filter instead of replacing them. Defaults to false.")] = None,
):
    """Draw one or more polygons on the map filter, which then narrows the results to the sites inside them, and move the map so the user can see what was selected. This is the default way to filter by a place - any level, any number of areas at once, since a site matches if it falls within ANY of the polygons. Pass 'areas' with ids from find_areas - the boundary is fetched and simplified for you - or 'polygons' with explicit rings for a shape that is not an administrative area. This replaces whatever the filter held unless you pass append. The boundary is a simplified outline: small islands may be left out, and the reply says how many rings were omitted, so prefer the country filter when an exact whole-country count is what is being asked for."""
    #The client would refuse this too, with the same words - saying so here saves the model
    #a round trip through the browser to find out
    if not areas and not polygons:
        raise ModelRetry("Nothing to draw: give 'areas' (ids from find_areas) or 'polygons' ([[lat, lon], ...] rings).")
    defer(areas=areas, polygons=polygons, append=append)


#The general layer: anything a person can see and use, for what the commands above don't
#cover. The model names a ref from the outline and one of these actions; the client decides
#what that ref is and whether it may be touched.
async def read_screen(
    region: Annotated[Literal["all", "dialog", "site_report", "filters", "results", "menus", "page"] | None, Field(description="Which part of the interface to read. Defaults to all.")] = None,
    section: Annotated[str | None, Field(description="Optional site report section id (from list_site_report_sections) to read just that section.")] = None,
    text: Annotated[bool | None, Field(description="Also return the visible text of the region or section. Defaults to false.")] = None,
):
    """Read what is on screen as text: every visible element the user could click or fill in, each with a ref (e.g. 'e14'), a role, a label and its state (expanded, collapsed, checked, value, disabled), grouped under the dialog, site report section, filter or menu it is in. Use it for anything the dedicated tools don't cover - a button, a tab, a table row, an option in a dialog - and to see what a click changed. Narrow it with 'region' or 'section' when you know where to look; the whole page is long. Pass text: true to also get that part's visible text, when you need to read content rather than act on it."""
    defer(region=region, section=section, text=text)


async def click(ref: Annotated[str, Field(description="The element's ref from read_screen, e.g. 'e14'.")]):
    """Click an element from read_screen, by its ref, exactly as the user would. The reply is the outline of the part of the screen it was in afterwards, plus any dialog it opened - read it to see what actually happened before telling the user. Refs stay valid while the element is on the page; if one is gone, read the screen again. Prefer the dedicated tools for filters, domains, views, site reports and the map when they do what is asked."""
    defer(ref=ref)


async def set_value(
    ref: Annotated[str, Field(description="The element's ref from read_screen.")],
    value: Annotated[bool | int | float | str, Field(description="The text to enter, true/false for a checkbox, or the option to pick.")],
):
    """Fill in a text field, tick or untick a checkbox (true/false), or pick an option in a select (by its value or its text), by ref from read_screen. The reply is the outline of that part of the screen afterwards. For a filter's selections use set_filter_selections instead."""
    defer(ref=ref, value=value)


def no_arguments(function):
    return Tool(function, prepare=no_arguments_schema)


CLIENT_TOOLS = [
    no_arguments(list_filters), no_arguments(get_state), get_filter_options, add_filter, set_filter_selections,
    remove_filter, no_arguments(clear_filters), set_domain, open_site_report, no_arguments(close_site_report),
    no_arguments(list_site_report_sections), set_site_report_section, set_site_report_rows,
    export_site_report, set_result_view, find_areas, set_map_polygons,
    read_screen, click, set_value,
]
