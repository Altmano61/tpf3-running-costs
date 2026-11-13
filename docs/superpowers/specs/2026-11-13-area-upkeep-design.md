# Infrastructure upkeep per town area — design (2026-11-13)

Running Cost Breakdown 0.6.0: a card in the town window that breaks the player's
infrastructure upkeep inside that town's area down by category. A later version
adds an overview window over all towns (out of scope here, see "Later").

## Intent

Forum thread 4666 asked for infrastructure cost per line; UG.sam answered that a
breakdown "on a per municipal area basis" would be more useful. No mod does it
(Budget Check 6484875 is per carrier, Route Upkeep Inspector 6523165 per track
segment). The probe in `docs/probes/area_probe/README.md` showed that every item
of the "Upkeep …" finance rows can be computed from live data and attributed to
exactly one town with the game's own area notion. The user wants facts a player
draws conclusions from: how much the stations, depots, tracks and roads of this
area cost, so that oversized stations, superfluous maintenance buildings or a
track class that is faster than the trains need become visible. **No tips, no
recommendations** (the mod's principle).

## Goals

- Town window: a card "Infrastructure upkeep" below the "Statistics" card (the
  last card of the window).
- Rows by category with the amount per year, hidden when 0, expandable where a
  split helps; the total at the top.
- Track and road rows carry the length in km and expand into the track/road
  types (without catenary variants).
- Numbers match the game's station/depot windows and, summed over all towns,
  the finance table's "Upkeep" rows (verified by the probe: 1.1 %).
- No saved state, no sampler: the card is computed from live data on demand.
- No visible stall: the scan runs in slices over several frames.

## Non-goals (this version)

- No overview window over all towns, no ranking, no "next price step" line
  (goes into the overview later: "20 years are hours of play in which the
  information is irrelevant").
- No per-object list (the player clicks the building for that).
- No split by catenary (the probe showed catenary has no extra upkeep).
- No vehicles (not attributable to an area), no construction (one-off) costs.
- No change to the Ukrainian strings beyond EN placeholders (see Strings).

## Anti-goals

- A GUI stall when opening a town window (a full scan on the GUI thread is
  ~100 ms on the big save: 13k edges, 180 constructions, 800 edge objects;
  measured 2026-11-13 with the GUI probe, see `docs/probes/area_probe/`).
- `calculateBalance` on an entity without an `ACCOUNT` component: a caught
  engine assertion costing ~1 s each (the game froze for minutes during the
  probe). This design never calls `calculateBalance`.
- New stylesheet rules: the mod has 21, the shared budget is ~600 across all
  mods; reuse existing classes.

## What is counted, and how (verified formulas)

All amounts are per **default game year** (1461 s of game time, what the
station windows and the finance table columns use, regardless of the calendar
speed setting). Only entities whose `PLAYER_OWNED.player == api.engine.util.getPlayer()`
count.

**Constructions** (from `api.engine.system.streetConnectorSystem.getTownClosestConstructions(town)`;
skip entries without `PLAYER_OWNED` or whose `CONSTRUCTION.townBuildings` is
non-empty):

```
upkeep = round(mc.maintenanceCost × costs.infrastructureMaintenanceScale × yearMult) + round(Σ mc.accumulatedCost)
mc       = MAINTENANCE_COST component (absent → 0)
scale    = api.res.getBaseConfig().costs["infrastructureMaintenanceScale"]
yearMult = api.engine.util.construction.getCostMultiplierForYear(baseConfig.treeCostYearMultipliers, year)
           only if constructionRep.get(find(fileName)).costsYearProgression, else 1
```

(`entity_window_util.tl` `MaintenanceBar` does exactly this; equal to
`calcMaintenanceForStationGroup` for every station checked.)

**Edges** (`BASE_EDGE` entities; not loopable with `getEntitiesWithComponent`,
enumerate once per scan via `api.engine.system.streetSystem.getNode2SegmentMap()`
and dedupe the segment ids). Skip edges inside a construction
(`streetConnectorSystem.getConstructionEntityForEdge(e)` non-nil / ≠ -1) and
edges without `PLAYER_OWNED`.

```
length = Hermite length of (position0, tangent0, position1, tangent1), 16 segments
         (BaseEdge.distance is NOT a length: 5 for tracks, 0 for streets)
rate   = api.res.streetTemplateRep.get(streetTemplateRep.find(be.roadTemplate)).maintenanceCost
         (per metre per year, ALREADY scaled by infrastructureMaintenanceScale; negative = free)
extra  = bridgeTypeRep / tunnelTypeRep.get(be.typeIndex).maintenanceCost if be.type == BRIDGE / TUNNEL, else 0
upkeep = length × (max(rate, 0) + extra)
kind   = be.roadType (STREET or TRACK; compare via tostring with the resolved enum values, see probe)
town   = api.engine.util.town.getClosestTown(midpoint)   -- the `town` sub-table!
midpoint = 0.5 (p0 + p1) + 0.125 (t0 − t1)
```

**Edge objects** (`be.objects`, entries are `{entity, EdgeObjectType}` tables;
entity at `[1]`): skip without `PLAYER_OWNED`; same formula as constructions with
`EDGE_OBJECT.edgeObjectConstruction` as the construction file name. Attributed to
the edge's town. A two-sided roadside stop is two objects (one per side), their
sum equals the stop window's figure.

Cache the template rate per `roadTemplate` name and the `costsYearProgression`
flag per construction file name within a scan.

## Categories and rows

Top row: **Total** (bold), then rows in this order, each only when > 0:

| Row | Source | Expandable into |
|---|---|---|
| Stations | constructions with `CONSTRUCTION.stations` non-empty + roadside stop edge objects (object entity has a `STATION` component) | Roadside stops (edge objects); Road terminals / Rail stations / Harbours / Airports by the carriers of the construction's station group: `stationGroupSystem.getCarriers(stationGroupSystem.getStationGroup(con.stations[1]), -1, -1)[1]` → ROAD or TRAM = road terminal, RAIL = rail station, WATER = harbour, AIR = airport or heliport: heliport when the group's transport modes (`getCarriers(...)[2]`) contain HELICOPTER but neither AIRCRAFT nor SMALL_AIRCRAFT, else airport; several carriers → the construction counts once under the first carrier found in the order RAIL, AIR, WATER, ROAD/TRAM (a rail station with a bus module is a rail station); none → "Other stations" |
| Depots | constructions with `CONSTRUCTION.depots` non-empty whose file name does not mark a maintenance building | Road / Rail / Harbour / Hangar (AIR carrier, covers helicopter hangars too: `VEHICLE_DEPOT.transportModes` with HELICOPTER only → "Helicopter hangars") by `VEHICLE_DEPOT.carrier` of `depots[1]` |
| Maintenance buildings | depot constructions whose `fileName` contains `maint` (base: `depots/road/road_maint_station.con`, …); builder: verify the base file names for all carriers | none |
| Warehouses | `fileName` contains `warehouse` (base: `::/warehouses/warehouse.con`) | none |
| Other buildings | remaining player constructions with upkeep > 0 (landmarks cost 0 and vanish) | none |
| Tracks | edges with roadType TRACK; label carries the km | per template, grouped after stripping a `_catenary` suffix from the template path (`simple` + `simple_catenary` → "Simple track"); label = the base template's localized `description.name`, km and amount per group, sorted by amount |
| Roads | edges with roadType STREET; label carries the km | per template, same grouping (tram/electrified variants of a street template fold into the base template) |
| Signals | edge objects without a `STATION` component (path signals, waypoints; runway signs cost 0 and vanish) | none |

Bridges and tunnels stay inside the track/road amounts (they are a surcharge per
metre); the scan keeps per town and kind the bridge km + surcharge and tunnel
km + surcharge, and the Tracks / Roads row tooltip lists them: "Bridges: 1.2 km,
+{amount}/year · Tunnels: 0.3 km, +{amount}/year" (the surcharge only, i.e. what
the bridge costs on top of the same length of plain track). No extra table
rows for them. Edges inside constructions are never counted (their cost is in
the construction's `maintenanceCost`).

Format: `api.util.formatMoney(amount)` with the per-year suffix like the
station window ("{cost}/Year" → reuse the game's own string via
`_("{maintenanceCost}/{maintenancePeriod}")` + `_("Year")` if available, else
our own key); km with one decimal (`lang_util` or string.format), "12.3 km".
Expanded sub-rows are indented (a leading two-space or an indent cell), not
bold.

Rows of expandable categories render a toggle in front of the label (the same
pattern as the mod's existing collapsible tables, or a `builtin.Button` with
"▸"/"▾" is NOT acceptable: those glyphs render as boxes in the game font; use
the game's expander icons `::/gui/icons/…` or "+"/"−" text). Expansion state is
per card instance (`react.useState`), collapsed by default.

Tooltip on the card title: "Player-owned infrastructure in this town's area
(the area shown around the town), per game year as in the station windows.
Vehicles are not included." Tooltip on Tracks/Roads: the bridge/tunnel
line above, followed by "Tracks and roads inside stations and depots count under
the station or depot."

## Where the card lives

`::TownEowExtensionPoint` plugin with `order = 70` (the town information widget
is hard-coded at 30, the statistics card at 60; plugins are merged by order, so
70 renders below Statistics). Resource file
`content/gui/kampfmoehre_running_costs/town.res.lua`, plugin recipe in
`running_costs.script.lua` (the GUI script is already loaded at game start by
`entry.res.lua`). The plugin returns a `content_card.ContentCard{ meta = {
localKey = "kampfmoehreRunningCostsAreaUpkeep" }, title = _("…"),
recipeAndParamPermanent = content_card.makeRecipeAndParam(AreaUpkeepCard, {
entityId = params.entityId }), gameCtx = params.gameCtx, showOnRightSide =
params.showOnRightSide }` like the town statistics card (`town.tl` ~1250); the
plugin gets `params.entityId` = the town.

## Computation: the scan

New GUI-side module `content/gui/kampfmoehre_running_costs/area_scan.lua`
(engine access) + pure module `content/running_costs/area_upkeep.lua`
(classification, Hermite length, grouping, row building; unit-tested with
luajit like `cost_history.lua`, engine calls injected as functions).

- All engine calls the scan needs work in the GUI Lua state (verified with the
  GUI probe `area_gui_probe.script.lua`, 2026-11-13, big save): `getEntitiesWithComponent(TOWN)`,
  `streetConnectorSystem.getTownClosestConstructions`, `stationGroupSystem.getCarriers`,
  `streetSystem.getNode2SegmentMap`, `api.engine.util.town.getClosestTown`,
  `getConstructionEntityForEdge`, `streetTemplateRep`, component reads.
  Measured there: constructions 4.4 ms (11.8k listed, 180 ours),
  `getNode2SegmentMap` 4.5 ms + dedupe 4.1 ms (13 011 edges), edges 6 µs each
  incl. town lookup, template rate (cached) and edge objects → full pass ≈ 100 ms.
  No engine-side fallback is needed.
- One scan computes **all towns** (edges need the midpoint lookup anyway).
  Result: `{ at = <wall clock ms>, towns = { [townEntity] = { total, rows… } } }`.
- Trigger: a card instance mounts (`react.onMount`) and the cache is older than
  `TTL = 30 s` of wall clock, or there is none. While a scan runs, mounting cards
  show "…" / "calculating". The entry plugin's `react.onStep` drives the scan
  with a time budget of **4 ms per frame** (`api.type.Clock`), i.e. ≈ 25
  frames ≈ 0.5 s on the big save, then fires `api.gui.fireReactEvent(
  "kampfmoehreRunningCostsAreaUpkeep", {})` so mounted cards re-read the cache.
- Phases: 1 towns + their constructions (one `getTownClosestConstructions` per
  town, then per construction), 2 edge list (one `getNode2SegmentMap` call plus
  dedupe, ~9 ms, allowed to overrun the budget once), 3 edges + their objects,
  4 build rows per town and publish. Each phase keeps an index so a slice resumes.
- Scan cost grows with the map (edges dominate); the slice budget keeps the
  per-frame cost constant, only the number of frames grows. The TTL of 30 s is
  far above the scan length on any plausible save (builder's call: no adaptive TTL).
- A second mount while a scan runs does not restart it. After the scan, a
  mounted card re-triggers only when the cache is older than TTL (checked on
  `onStep` every ~1 s while a card is mounted), so a town window left open
  refreshes after a new station appears within half a minute.
- The scan touches only reads; no `api.cmd`, no state.

## Strings

New keys in `strings.json` EN + DE: card title, tooltip(s), the category rows
("Total", "Stations", "Roadside stops", "Road terminals", "Rail stations",
"Harbours", "Airports", "Heliports", "Other stations", "Depots", "Road depots",
"Rail depots", "Ship depots", "Hangars", "Helicopter hangars", "Maintenance
buildings", "Warehouses",
"Other buildings", "Tracks", "Roads", "Signals", "calculating"). DE mirrored
(Gesamt, Stationen, Haltestellen, Terminals, Bahnhöfe, Häfen, Flughäfen,
Heliports, Sonstige Stationen, Depots, Strassendepots, Zugdepots, Schiffsdepots,
Hangars, Helikopterhangars, Wartungsgebäude, Lagerhäuser, Sonstige Gebäude, Gleise, Strassen, Signale, wird
berechnet; the game's own German uses "ss"). The `uk` block gets the EN texts as
placeholders (a missing key would show the raw key id) and the contributor is
asked for the translation in the PR thread.

## Versioning and docs

VERSION 0.6.0 in all three scripts, `mod.json` revision 10, CHANGELOG entry
(technical), README feature paragraph + "How it works" section with the
formulas, hub description changelog entry (the user maintains the description;
provide the sentence), gallery image later from the user. Remove
`content/area_probe/` from the mod before syncing (probe stays in
`docs/probes/`).

## Testing

- luajit tests for `area_upkeep.lua`: Hermite length (straight edge = chord,
  tangents = length), category mapping incl. multi-carrier station and
  maintenance building, catenary grouping, zero rows hidden, totals.
- In game on the big save: the town totals summed over all towns within ~2 % of
  the finance table rows (the probe's `ESTIMATE` line gives the reference);
  Vänersborg card against the probe's per-town lines; the border depot on the
  test save appears under Filderstadt; no visible stutter on opening a town
  window (compare frame times with the benchmark procedure if in doubt); a
  newly built station shows within 30 s; bus stop sum equals the stop window.
- `luajit -bl` on all changed scripts; stylesheet rule count unchanged (21).

## Later (not in this version)

- Overview window (mod button in `::MainModButtonAreaExtension`, own
  `builtin.Window` via `game_react_globals.getDefaultWindowApi()` like Line
  Profit Auditor): one row per town, columns per category, sorted by total,
  name opens the town window, plus the next price step line ("1960: buildings
  +45 %") from `treeCostYearMultipliers`.
- Ukrainian strings from Altmano61.
