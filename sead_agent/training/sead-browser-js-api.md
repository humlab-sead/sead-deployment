# How the SEAD browser client works underneath

**You do not write or run JavaScript.** You act on the client through your tools
(`add_filter`, `set_filter_selections`, `remove_filter`, `clear_filters`, `set_domain`,
`set_result_view`, and the read-only `list_filters`, `get_state`, `get_filter_options`).

This document describes what those tools do on the other side, because its constraints are
real and they explain failures you may see - a range filter rejecting one value, a duplicate
filter being refused, a domain change resetting everything.

The website exposes one application instance as `window.sqs`.

## Supported facet operations

- Add a facet: `sqs.facetManager.spawnFacet(facetName, selections, triggerResultLoad)`.
- Find a facet: `sqs.facetManager.getFacetByName(facetName)`; a miss returns `null`.
- Replace selections: `facet.setSelections(selections, false)`.
- Remove a facet safely: `facet.destroy()`.
- Clear all facets: `sqs.facetManager.reset()`.
- Read state: `sqs.facetManager.getFacetState()` or `getFacetState(true)` for Data Exchange Format.
- Refresh results: `sqs.resultManager.updateResultView()`; use `fetchData()` only for a full render cycle.
- Switch result view: `await sqs.resultManager.setActiveModule("table" | "map" | "mosaic")`; mosaic becomes table on mobile.
- Active results: inspect the active module. Mosaic exposes `sqs.resultManager.getModule("mosaic").sites`.

## Selection types

- Discrete facets: integer ID arrays.
- Range facets: exactly `[lower, upper]` floats.
- Timeline selections: `[lowerBP, upperBP]`, always stored in years BP.
- Geographic polygon facets: arrays of polygon/feature pick values.
- Multistage facets operate on the current stage; their state flattens to one entry per sub-filter.

## Safe batching

For several changes, suspend both facet and result fetching, apply all mutations, then resume facet fetching followed by result fetching:

```js
const fm = sqs.facetManager;
fm.setFacetDataFetchingSuspended(true);
sqs.resultManager.setResultDataFetchingSuspended(true);
// apply facet changes
fm.setFacetDataFetchingSuspended(false);
sqs.resultManager.setResultDataFetchingSuspended(false);
```

## Important constraints

- Validate facet names with `getFacetTemplateByFacetId()` before creating them.
- `spawnFacet` refuses duplicates.
- Chain order is defined by `facetManager.links`, not insertion order.
- Use `facet.destroy()` rather than calling `removeFacet()` directly.
- Do not mutate discrete selections with `addSelection`, `removeSelection`, or `clearSelections` unless a selection broadcast is also performed; prefer `setSelections()`.
- Range facets require exactly two values.
- Result and facet requests discard stale responses using request IDs.
- Domain changes rebuild facets and results. Valid domains are `general`, `dendrochronology`, `palaeoentomology`, `archaeobotany`, `pollen`, `geoarchaeology`, `isotope`, and `ceramic`.
