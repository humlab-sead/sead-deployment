import { tool, jsonSchema } from 'ai';

/*
* The tools the agent uses to operate the SEAD web client.
*
* None of them run here. Each one hands a command to the browser that asked the
* question, waits for it to run it against its own `window.sqs`, and returns whatever
* the browser reports back. The service never evaluates model-written JavaScript - the
* command names below are the entire vocabulary, and the client refuses anything else.
*
* The corresponding executor is SeadAgentActions in the sead_browser_client.
*/

const DOMAINS = ["general", "palaeoentomology", "archaeobotany", "pollen", "geoarchaeology", "dendrochronology", "ceramic"];
const RESULT_VIEWS = ["map", "table", "mosaic"];

//A discrete facet is picked by integer id, a range facet by exactly two numbers
const SELECTIONS_SCHEMA = {
    type: "array",
    description: "For a discrete filter: the integer ids to select. For a range or timeline filter: exactly two numbers, [lower, upper].",
    items: { type: "number" }
};

function noArgs(description) {
    return jsonSchema({ type: "object", properties: {}, additionalProperties: false, description: description });
}

export function createClientTools(runCommand) {
    return {
        list_filters: tool({
            description: "List the filters (facets) this client offers, with their id, title, type and description, and which ones the user currently has open. Call this before adding a filter, so you use a real filter id rather than guessing one.",
            inputSchema: noArgs("No arguments."),
            execute: async () => runCommand("list_filters", {})
        }),

        get_state: tool({
            description: "Read what the user is currently looking at, as a snapshot of the whole interface: which page they are on, the active domain, every open filter with its selections, whether it is minimised and anything typed into its text search, the active result view with its site count and which mosaic tiles are rendered, the open site report and which of its sections are expanded, any dialog covering the screen, and which menus are open. Call this before answering any question about 'the current results', 'my filters' or what is on screen, and after making changes to see their effect.",
            inputSchema: noArgs("No arguments."),
            execute: async () => runCommand("get_state", {})
        }),

        get_filter_options: tool({
            description: "List the values that can be selected in one discrete filter, as {id, name} pairs. This is how you turn a name the user said ('pollen', 'Sweden', 'oak') into the id that a selection needs. Results are capped, so pass 'search' to narrow them. For a filter that list_filters marks with `stages`, pass a stage id rather than the filter id - a later stage has no values until the stage before it has a selection, and the reply says which one is in the way.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    filter: { type: "string", description: "The filter id, as given by list_filters - or one of its stage ids, for a filter that has stages." },
                    search: { type: "string", description: "Optional case-insensitive substring to match against option names." }
                },
                required: ["filter"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("get_filter_options", args)
        }),

        add_filter: tool({
            description: "Open a filter in the client, optionally with values already selected. This is what the user means by 'add', 'apply', 'deploy' or 'show me' a filter. Adding a filter with no selections is useful on its own - it shows the user the available values. A stage id opens the one facet its stages share.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    filter: { type: "string", description: "The filter id, as given by list_filters." },
                    selections: SELECTIONS_SCHEMA
                },
                required: ["filter"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("add_filter", args)
        }),

        set_filter_selections: tool({
            description: "Replace what is selected in a filter that is already open. Use this rather than removing and re-adding a filter. For a staged filter (see `stages` in list_filters) pass the stage id, e.g. `ecocode_system` to pick the classification system and then `ecocode` to pick codes within it - the filter id alone cannot say which stage you mean.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    filter: { type: "string", description: "The filter id." },
                    selections: SELECTIONS_SCHEMA
                },
                required: ["filter", "selections"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("set_filter_selections", args)
        }),

        remove_filter: tool({
            description: "Close one filter and drop its selections.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    filter: { type: "string", description: "The filter id." }
                },
                required: ["filter"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("remove_filter", args)
        }),

        clear_filters: tool({
            description: "Remove every filter the user has open and go back to an unfiltered result. This throws away the user's work, so only do it when they clearly asked to start over.",
            inputSchema: noArgs("No arguments."),
            execute: async () => runCommand("clear_filters", {})
        }),

        set_domain: tool({
            description: "Switch the active domain. A domain scopes the whole interface - it changes which filters are offered and adds a hidden method filter to every query. Changing it rebuilds the filters and the results, so prefer a filter when the user only wants to narrow results.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    domain: { type: "string", enum: DOMAINS, description: "The domain to switch to." }
                },
                required: ["domain"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("set_domain", args)
        }),

        open_site_report: tool({
            description: "Open a site's report page - the full record for one site, with its sample groups, analyses and datasets. This is what the user means by 'take me to', 'go to', 'show me' or 'open' a named site, as opposed to filtering the result list down to it. Filtering to a site and opening its report are different things: prefer this one when they name a single site.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    siteId: { type: "integer", description: "The site's database id. Resolve a name to an id with get_filter_options on the 'sites' filter." }
                },
                required: ["siteId"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("open_site_report", args)
        }),

        close_site_report: tool({
            description: "Leave the site report and go back to the filters and result list.",
            inputSchema: noArgs("No arguments."),
            execute: async () => runCommand("close_site_report", {})
        }),

        list_site_report_sections: tool({
            description: "List the sections of the site report that is currently open - their id, title, whether they are expanded, and their subsections. An expanded section also lists its expandableRows: table rows, such as sample groups, that open onto the rows inside them. Call this before expanding or collapsing anything, since section ids differ from site to site (each analysis method gets its own section).",
            inputSchema: noArgs("No arguments."),
            execute: async () => runCommand("list_site_report_sections", {})
        }),

        set_site_report_section: tool({
            description: "Expand or collapse one section of the open site report - an analysis, a dataset, the sample groups. Expanding also scrolls the section into view and loads its contents.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    section: { type: "string", description: "The section id, as given by list_site_report_sections." },
                    expanded: { type: "boolean", description: "true to expand and reveal it, false to collapse it." }
                },
                required: ["section", "expanded"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("set_site_report_section", args)
        }),

        set_site_report_rows: tool({
            description: "Open or close rows inside a site report table - a sample group in the 'samples' section, to show its samples, say. This is what the user means by expanding or opening a sample group; set_site_report_section only opens whole sections. Row ids come from expandableRows in list_site_report_sections. The reply gives each row's state afterwards - report that, not what you asked for.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    section: { type: "string", description: "The id of the section the rows are in, as given by list_site_report_sections, e.g. 'samples'." },
                    rows: {
                        type: "array",
                        items: { type: "string" },
                        description: "Row ids from expandableRows, e.g. sample group ids ['12724']."
                    },
                    expanded: { type: "boolean", description: "true to open the rows, false to close them." }
                },
                required: ["section", "rows", "expanded"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("set_site_report_rows", args)
        }),

        export_site_report: tool({
            description: "Open the export dialog for the site report, so the user can download the data. Offers the formats available for what is being exported. This opens the chooser - it does not download anything on its own, the user picks the format.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    section: { type: "string", description: "Optional section id to export just that section; omit to export the whole site." }
                },
                additionalProperties: false
            }),
            execute: async (args) => runCommand("export_site_report", args)
        }),

        set_result_view: tool({
            description: "Switch how results are displayed. 'mosaic' is the overview with charts, 'table' is the site list, 'map' is the geographic view.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    view: { type: "string", enum: RESULT_VIEWS, description: "The result view to activate." }
                },
                required: ["view"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("set_result_view", args)
        }),

        find_areas: tool({
            description: "Look up an administrative area - a country, region or municipality - by name, in the GADM boundary data held alongside SEAD. Returns candidates with the id that set_map_polygons takes. Names repeat all over the world (there are eight Yorks), so read the country and region on each candidate before choosing, and say which one you used. This is a lookup only: it does not change anything on screen.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    name: { type: "string", description: "The area name to look for, e.g. 'Skåne', 'Sweden', 'Umeå'. Matched case-insensitively anywhere in the name." },
                    level: { type: "number", enum: [0, 1, 2], description: "Optional: 0 country, 1 region, 2 municipality. Omit to search all three." },
                    country: { type: "string", description: "Optional country name to restrict the search to, e.g. 'Sweden'." }
                },
                required: ["name"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("find_areas", args)
        }),

        set_map_polygons: tool({
            description: "Draw one or more polygons on the map filter, which then narrows the results to the sites inside them, and move the map so the user can see what was selected. This is the default way to filter by a place - any level, any number of areas at once, since a site matches if it falls within ANY of the polygons. Pass 'areas' with ids from find_areas - the boundary is fetched and simplified for you - or 'polygons' with explicit rings for a shape that is not an administrative area. This replaces whatever the filter held unless you pass append. The boundary is a simplified outline: small islands may be left out, and the reply says how many rings were omitted, so prefer the country filter when an exact whole-country count is what is being asked for.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    areas: {
                        type: "array",
                        description: "Area ids from find_areas, e.g. ['SWE.13_1']. At most 6.",
                        items: { type: "string" }
                    },
                    polygons: {
                        type: "array",
                        description: "Explicit polygons, each a list of [latitude, longitude] pairs in order around the shape. At least 3 points per polygon; do not repeat the first point at the end.",
                        items: { type: "array", items: { type: "array", items: { type: "number" } } }
                    },
                    append: { type: "boolean", description: "Add to the polygons already on the filter instead of replacing them. Defaults to false." }
                },
                additionalProperties: false
            }),
            execute: async (args) => runCommand("set_map_polygons", args)
        }),

        //The general layer: anything a person can see and use, for what the commands above
        //don't cover. The model names a ref from the outline and one of these actions; the
        //client decides what that ref is and whether it may be touched.
        read_screen: tool({
            description: "Read what is on screen as text: every visible element the user could click or fill in, each with a ref (e.g. 'e14'), a role, a label and its state (expanded, collapsed, checked, value, disabled), grouped under the dialog, site report section, filter or menu it is in. Use it for anything the dedicated tools don't cover - a button, a tab, a table row, an option in a dialog - and to see what a click changed. Narrow it with 'region' or 'section' when you know where to look; the whole page is long. Pass text: true to also get that part's visible text, when you need to read content rather than act on it.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    region: { type: "string", enum: ["all", "dialog", "site_report", "filters", "results", "menus", "page"], description: "Which part of the interface to read. Defaults to all." },
                    section: { type: "string", description: "Optional site report section id (from list_site_report_sections) to read just that section." },
                    text: { type: "boolean", description: "Also return the visible text of the region or section. Defaults to false." }
                },
                additionalProperties: false
            }),
            execute: async (args) => runCommand("read_screen", args)
        }),

        click: tool({
            description: "Click an element from read_screen, by its ref, exactly as the user would. The reply is the outline of the part of the screen it was in afterwards, plus any dialog it opened - read it to see what actually happened before telling the user. Refs stay valid while the element is on the page; if one is gone, read the screen again. Prefer the dedicated tools for filters, domains, views, site reports and the map when they do what is asked.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    ref: { type: "string", description: "The element's ref from read_screen, e.g. 'e14'." }
                },
                required: ["ref"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("click", args)
        }),

        set_value: tool({
            description: "Fill in a text field, tick or untick a checkbox (true/false), or pick an option in a select (by its value or its text), by ref from read_screen. The reply is the outline of that part of the screen afterwards. For a filter's selections use set_filter_selections instead.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    ref: { type: "string", description: "The element's ref from read_screen." },
                    value: { type: ["string", "number", "boolean"], description: "The text to enter, true/false for a checkbox, or the option to pick." }
                },
                required: ["ref", "value"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("set_value", args)
        })
    };
}

export const CLIENT_COMMANDS = [
    "list_filters", "get_state", "get_filter_options", "add_filter",
    "set_filter_selections", "remove_filter", "clear_filters", "set_domain", "set_result_view",
    "open_site_report", "close_site_report", "list_site_report_sections",
    "set_site_report_section", "set_site_report_rows", "export_site_report",
    "find_areas", "set_map_polygons",
    "read_screen", "click", "set_value"
];
