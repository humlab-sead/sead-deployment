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
            description: "List the values that can be selected in one discrete filter, as {id, name} pairs. This is how you turn a name the user said ('pollen', 'Sweden', 'oak') into the id that a selection needs. Results are capped, so pass 'search' to narrow them.",
            inputSchema: jsonSchema({
                type: "object",
                properties: {
                    filter: { type: "string", description: "The filter id, as given by list_filters." },
                    search: { type: "string", description: "Optional case-insensitive substring to match against option names." }
                },
                required: ["filter"],
                additionalProperties: false
            }),
            execute: async (args) => runCommand("get_filter_options", args)
        }),

        add_filter: tool({
            description: "Open a filter in the client, optionally with values already selected. This is what the user means by 'add', 'apply', 'deploy' or 'show me' a filter. Adding a filter with no selections is useful on its own - it shows the user the available values.",
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
            description: "Replace what is selected in a filter that is already open. Use this rather than removing and re-adding a filter.",
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
            description: "List the sections of the site report that is currently open - their id, title, whether they are expanded, and their subsections. Call this before expanding or collapsing anything, since section ids differ from site to site (each analysis method gets its own section).",
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
        })
    };
}

export const CLIENT_COMMANDS = [
    "list_filters", "get_state", "get_filter_options", "add_filter",
    "set_filter_selections", "remove_filter", "clear_filters", "set_domain", "set_result_view",
    "open_site_report", "close_site_report", "list_site_report_sections",
    "set_site_report_section", "export_site_report"
];
