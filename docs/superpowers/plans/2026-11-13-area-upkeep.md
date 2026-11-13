# Infrastructure Upkeep per Town Area Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Running Cost Breakdown 0.6.0 adds a card "Infrastructure upkeep" to the town window that breaks the player's yearly infrastructure upkeep inside that town's area down by category (stations, depots, maintenance buildings, warehouses, other buildings, tracks, roads, signals), computed from live data on the GUI thread in frame slices.

**Architecture:** Two pure Lua modules under `content/running_costs/` (luajit-tested like `cost_history.lua`): `area_upkeep.lua` holds the formulas, the classification and the row builder; `area_scan.lua` is a resumable, budgeted scan over an injected environment table (phases: towns + constructions, edge list, edges + edge objects, finish). The GUI side adds `area_env.lua` (the environment built from the engine API, mirrors the verified probe) and, in `running_costs.script.lua`, a card recipe, a `::TownEowExtensionPoint` plugin and an `onStep` driver in the existing entry plugin. No game-script state, no `calculateBalance`.

**Tech Stack:** Transport Fever 3 GUI Lua (LuaJIT / Lua 5.1), the game's React-like framework (`react.lua`, `builtin.lua`, `content_card.tl`), luajit for unit tests, `luajit -bl` for syntax checks.

**Spec:** `docs/superpowers/specs/2026-11-13-area-upkeep-design.md` (read it first; the probe findings behind every formula are in `docs/probes/area_probe/README.md`).

## Global Constraints

- Repo root for every command below: `/home/satan/dev/tpf3-modding/tpf3-running-costs`. Mod directory: `kampfmoehre_running_costs_1/`.
- Lua 5.1 / LuaJIT only: no `goto`, no integer division, no `//` comments; syntax-check every changed script with `luajit -bl <file> > /dev/null`.
- GUI Lua state: never use `_` as a loop variable (shadows the translation function; use `__`, `___` like the existing code); `rawget`/`rawset` do not exist; module-level `local` state is fine, globals are not.
- All engine calls in the GUI go through `pcall`; a failed call yields "no data", never a Lua error (a red error screen in the player's game).
- Never call `api.engine.util.finance.calculateBalance` anywhere in this feature (caught engine assertion ≈ 1 s each on entities without an ACCOUNT).
- Amounts are per default game year (1461 s game time) exactly as the station windows show them; constructions: `round(mc.maintenanceCost × scale × yearMult) + round(Σ accumulatedCost)`; edges: `hermiteLength × (max(templateRate, 0) + bridgeOrTunnelRate)`, the template rate is already scaled.
- Stylesheet rule count after this plan ≤ 21 (count = number of comma-separated selector parts over all `a("…")` calls in `running_costs.css.lua`); no new CSS rules, only selector changes.
- Strings: EN first, DE mirrored with "ss" instead of "ß" (the game's own German), `uk` gets the EN text as placeholder for every new key. Keys are prefixed `running_costs_area_`.
- `strings.json` formatting: 4-space indent, `ensure_ascii=False`, plain apostrophes, trailing newline (`python3 -I` + `json.dump(d, f, indent=4, ensure_ascii=False)` reproduces the file byte-identically).
- Log lines start with `[kampfmoehre_running_costs] `; the version string is `local VERSION = "0.6.0"` in all three scripts (`content/running_costs/running_costs.script.lua`, `content/running_costs/income.script.lua`, `content/gui/kampfmoehre_running_costs/running_costs.script.lua`); `mod.json` `revision` 10.
- Commits in conventional style, English, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. The user normally commits himself: the commit steps below are only executed if he agreed to commits for this plan at the handoff; otherwise stage nothing and report what to commit.
- `./sync.sh` only in Task 7 and 8 (no upload of a previous version is pending: 0.5.1 is uploaded). Never run `changelog_to_modinfo.py` for this repo; the hub description changelog is written by hand (Task 8 provides the sentence).
- In-game verification is the user's; the plan's in-game steps describe what to ask him to check and are not "Expected" outputs the executor can see.

## Review Focus

Input classes the spec implies but the tests below do not fully exercise; each line names the task whose tests pin it.

1. A player construction without a `MAINTENANCE_COST` component (some assets, landmarks with 0 upkeep): it must contribute 0 and never raise; Task 5 `area_env` returns `upkeep = 0`, Task 3's row test hides zero rows (`test "zero rows hidden"`).
2. An edge whose midpoint has no town (`getClosestTown` returns nil or -1 on a map edge, or a map without towns): the edge is skipped, the scan finishes; Task 4 test "edge without town is skipped".
3. A station group with several carriers (rail station with bus module) must count once under rail; Task 2 test "multi-carrier station counts as rail".
4. The scan is re-triggered while it runs (second town window opened): no restart, no duplicate accumulation; Task 4 test "start while running is a no-op".
5. A town window opened before the first scan finished shows "calculating" and then updates without being reopened; Task 7 (manual) plus Task 4 test "result stays nil until the scan completes, old result survives a rescan".

---

### Task 1: Formulas and template grouping (`area_upkeep.lua`, part 1)

**Files:**
- Create: `kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua`
- Test: `test/area_upkeep_test.lua`

**Interfaces:**
- Produces (module table `M`, pure Lua, no `api`):
  - `M.hermiteLength(p0, t0, p1, t1) -> number` — points/tangents are `{x, y, z}` tables, 16 segments.
  - `M.midpoint(p0, t0, p1, t1) -> x, y, z` — `0.5 (p0 + p1) + 0.125 (t0 − t1)`.
  - `M.constructionUpkeep(maintenanceCost, accumulated, scale, yearMult, progression) -> integer` — `round(maintenanceCost × scale × (progression and yearMult or 1)) + round(accumulated)`; nil numbers count as 0.
  - `M.edgeUpkeep(meters, rate, extra) -> number` — `meters × (max(rate or 0, 0) + (extra or 0))`.
  - `M.templateGroup(path) -> string` — strips exactly one of the suffixes `_tram_electrified`, `_electrified`, `_tram`, `_catenary` that sits directly before `.street_template` (or at the end of the string); other variants (`_barriers`, `_bus`, `_trees`) stay their own group (builder's call: their upkeep may differ, electrification does not).
  - `M.templateBaseName(path) -> string` — the file name part of the group path without `.street_template` (fallback label, e.g. `town_new_small`).

- [ ] **Step 1: Write the failing tests**

Test runner pattern = `test/fee_rows_test.lua` (`check`, `near`, exit code 1 on failures). `package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path`, `local M = require "area_upkeep"`.

```lua
-- straight edge: chord 100 m along x, tangents of length 100 -> 100 m
near("hermite straight", M.hermiteLength({x=0,y=0,z=0}, {x=100,y=0,z=0}, {x=100,y=0,z=0}, {x=100,y=0,z=0}), 100, 1e-6)
-- quarter circle radius 100 (tangent length 3 × 0.5523 × r, the cubic-Bezier circle): arc 157.08
near("hermite curve", M.hermiteLength({x=100,y=0,z=0}, {x=0,y=165.69,z=0}, {x=0,y=100,z=0}, {x=-165.69,y=0,z=0}), 157.08, 0.3)
local mx, my, mz = M.midpoint({x=0,y=0,z=0}, {x=100,y=0,z=0}, {x=100,y=0,z=0}, {x=100,y=0,z=0})
near("midpoint x", mx, 50, 1e-9); near("midpoint y", my, 0, 1e-9)
check("construction upkeep with progression", M.constructionUpkeep(100000, 0, 1.25, 2.2, true) == 275000)
check("construction upkeep without progression", M.constructionUpkeep(100000, 0, 1.25, 2.2, false) == 125000)
check("construction upkeep adds accumulated", M.constructionUpkeep(100000, 1760, 1.0, 5.0, true) == 501760)
check("construction upkeep nil-safe", M.constructionUpkeep(nil, nil, 1.0, 1.0, false) == 0)
near("edge upkeep", M.edgeUpkeep(1000, 13, 0), 13000, 1e-9)
near("edge upkeep negative rate is free", M.edgeUpkeep(1000, -1, 0), 0, 1e-9)
near("edge upkeep bridge extra", M.edgeUpkeep(100, 38, 7), 4500, 1e-9)
local T = "::/infrastructure/track/simple/simple_catenary.street_template"
check("catenary folds into base", M.templateGroup(T) == "::/infrastructure/track/simple/simple.street_template")
check("tram_electrified folds into base", M.templateGroup("::/infrastructure/street/town/town_new_large_tram_electrified.street_template") == "::/infrastructure/street/town/town_new_large.street_template")
check("base template unchanged", M.templateGroup("::/infrastructure/track/simple/simple.street_template") == "::/infrastructure/track/simple/simple.street_template")
check("barriers stay separate", M.templateGroup("::/infrastructure/street/country/country_new_large_barriers.street_template") == "::/infrastructure/street/country/country_new_large_barriers.street_template")
check("template base name", M.templateBaseName("::/infrastructure/track/simple/simple.street_template") == "simple")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/area_upkeep_test.lua`
Expected: error `module 'area_upkeep' not found`

- [ ] **Step 3: Implement the five functions in `area_upkeep.lua`**

Header comment like `fee_rows.lua` (what the module is, "No game API, unit-tested with plain luajit"). Hermite as in `docs/probes/area_probe/area_probe.script.lua` `hermiteLength` (basis h00 = 2t³ − 3t² + 1, h10 = t³ − 2t² + t, h01 = −2t³ + 3t², h11 = t³ − t²), without the pcall.

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/area_upkeep_test.lua`
Expected: every line `ok   …`, exit code 0

- [ ] **Step 5: Commit**

```bash
git add kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua test/area_upkeep_test.lua
git commit -m "feat(area): upkeep formulas and template grouping"
```

---

### Task 2: Classification (`area_upkeep.lua`, part 2)

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua`
- Test: `test/area_upkeep_test.lua`

**Interfaces:**
- Produces (category and sub-row keys are the string ids used later for `running_costs_area_<key>`):
  - `M.CATEGORY_ORDER = { "stations", "depots", "maintenance", "warehouses", "other_buildings", "tracks", "roads", "signals" }`
  - `M.STATION_SUBS = { "roadside_stops", "road_terminals", "rail_stations", "harbours", "airports", "heliports", "other_stations" }`
  - `M.DEPOT_SUBS = { "road_depots", "rail_depots", "ship_depots", "hangars", "heli_hangars" }`
  - `M.classifyStation(carriers, modes) -> sub` — `carriers`, `modes` are lists of enum NAMES (strings); priority RAIL → `rail_stations`, AIR → `heliports` when `modes` contains `HELICOPTER` but neither `AIRCRAFT` nor `SMALL_AIRCRAFT`, else `airports`; WATER → `harbours`; ROAD or TRAM → `road_terminals`; none of these → `other_stations`.
  - `M.classifyDepot(carrier, modes) -> sub | nil` — ROAD/TRAM → `road_depots`, RAIL → `rail_depots`, WATER → `ship_depots`, AIR → `heli_hangars` (same helicopter rule on `modes`) or `hangars`; anything else → nil (counted in the Depots total only).
  - `M.classifyConstruction(info) -> cat | nil, sub | nil` — `info = { fileName, nStations, nDepots, nTownBuildings, carriers, modes, depotCarrier, depotModes, upkeep }`: `nTownBuildings > 0` → nil; `nStations > 0` → `"stations", classifyStation(...)`; `nDepots > 0` → `"maintenance", nil` when `fileName:lower()` contains `maint`, else `"depots", classifyDepot(depotCarrier, depotModes)`; `fileName:lower()` contains `warehouse` → `"warehouses", nil`; `upkeep > 0` → `"other_buildings", nil`; else nil.
  - `M.classifyEdgeObject(isStation) -> cat, sub` — `true` → `"stations", "roadside_stops"`; `false` → `"signals", nil`.

- [ ] **Step 1: Write the failing tests** (append to `test/area_upkeep_test.lua`)

```lua
check("rail station", M.classifyStation({ "RAIL" }, { "TRAIN", "ELECTRIC_TRAIN" }) == "rail_stations")
check("multi-carrier station counts as rail", M.classifyStation({ "ROAD", "RAIL" }, { "BUS", "TRAIN" }) == "rail_stations")
check("airport", M.classifyStation({ "AIR" }, { "AIRCRAFT", "HELICOPTER" }) == "airports")
check("heliport", M.classifyStation({ "AIR" }, { "HELICOPTER" }) == "heliports")
check("harbour before road", M.classifyStation({ "ROAD", "WATER" }, { "SHIP", "BUS" }) == "harbours")
check("tram stop is a road terminal", M.classifyStation({ "TRAM" }, { "TRAM" }) == "road_terminals")
check("no carrier", M.classifyStation({}, {}) == "other_stations")
check("road depot", M.classifyDepot("ROAD", { "BUS", "TRUCK" }) == "road_depots")
check("tram depot is a road depot", M.classifyDepot("TRAM", { "TRAM" }) == "road_depots")
check("ship depot", M.classifyDepot("WATER", { "SHIP" }) == "ship_depots")
check("helicopter hangar", M.classifyDepot("AIR", { "HELICOPTER" }) == "heli_hangars")
check("hangar", M.classifyDepot("AIR", { "AIRCRAFT", "HELICOPTER" }) == "hangars")
check("unknown depot carrier", M.classifyDepot("OTHER", {}) == nil)
local function con(t) return setmetatable(t, { __index = { fileName = "", nStations = 0, nDepots = 0, nTownBuildings = 0, carriers = {}, modes = {}, depotCarrier = nil, depotModes = {}, upkeep = 0 } }) end
local c, s = M.classifyConstruction(con{ nStations = 1, carriers = { "RAIL" }, modes = { "TRAIN" }, upkeep = 5 })
check("station construction", c == "stations" and s == "rail_stations")
c, s = M.classifyConstruction(con{ nDepots = 1, fileName = "depots/road/road_depot/road_depot.con", depotCarrier = "ROAD", depotModes = { "BUS" }, upkeep = 5 })
check("depot construction", c == "depots" and s == "road_depots")
c, s = M.classifyConstruction(con{ nDepots = 1, fileName = "depots/rail/rail_maint_station.con", depotCarrier = "RAIL", upkeep = 5 })
check("maintenance building", c == "maintenance" and s == nil)
c, s = M.classifyConstruction(con{ fileName = "::/warehouses/warehouse.con", upkeep = 5 })
check("warehouse", c == "warehouses" and s == nil)
c, s = M.classifyConstruction(con{ fileName = "landmark/x.con", upkeep = 7 })
check("other building with upkeep", c == "other_buildings")
check("zero-upkeep other building is dropped", M.classifyConstruction(con{ fileName = "landmark/x.con", upkeep = 0 }) == nil)
check("town building is dropped", M.classifyConstruction(con{ nTownBuildings = 2, upkeep = 9 }) == nil)
c, s = M.classifyEdgeObject(true); check("roadside stop", c == "stations" and s == "roadside_stops")
c, s = M.classifyEdgeObject(false); check("signal", c == "signals" and s == nil)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/area_upkeep_test.lua`
Expected: error `attempt to call field 'classifyStation' (a nil value)`

- [ ] **Step 3: Implement the constants and the four classify functions in `area_upkeep.lua`**

A local `has(list, name)` helper; `fileName` may be nil (treat as "").

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/area_upkeep_test.lua`
Expected: all `ok`, exit code 0

- [ ] **Step 5: Commit**

```bash
git add kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua test/area_upkeep_test.lua
git commit -m "feat(area): classify constructions, depots, stations and edge objects"
```

---

### Task 3: Accumulator and rows (`area_upkeep.lua`, part 3)

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua`
- Test: `test/area_upkeep_test.lua`

**Interfaces:**
- Produces:
  - `M.newAcc() -> acc` — `acc.towns = {}` keyed by town entity.
  - `M.addBuilding(acc, town, cat, sub, amount)` — adds `amount` to the town's category (and sub when non-nil).
  - `M.addEdge(acc, town, kind, group, meters, amount, etype, extraAmount)` — `kind` `"TRACK"` → category `tracks`, `"STREET"` → `roads` (anything else ignored); adds `meters`/`amount` to the category and to the template group `group` (string key); `etype` `"BRIDGE"` / `"TUNNEL"` additionally adds `meters` and `extraAmount` (the surcharge part only) to the category's `bridges` / `tunnels` `{ meters, extra }`.
  - `M.rows(acc, town, labelOf) -> { total = number, rows = { row… } }` — `labelOf(groupPath) -> string` names a template group. `row = { key = <category>, amount, meters?, children?, bridges?, tunnels? }`; `children` entries are `{ key = <sub> }` for stations/depots (fixed order `STATION_SUBS` / `DEPOT_SUBS`) or `{ label = labelOf(group), group = group, meters }` for tracks/roads (sorted by amount descending, ties by label), each with `amount`. Rows and children with `amount < 0.5` are omitted; a category with no children keeps `children = nil`. Rows follow `CATEGORY_ORDER`. Unknown town → `{ total = 0, rows = {} }`. `total` = sum of category amounts.

- [ ] **Step 1: Write the failing tests** (append)

```lua
local acc = M.newAcc()
M.addBuilding(acc, 1, "stations", "rail_stations", 275000)
M.addBuilding(acc, 1, "stations", "roadside_stops", 5000)
M.addBuilding(acc, 1, "stations", "roadside_stops", 5000)
M.addBuilding(acc, 1, "depots", nil, 40000)             -- unknown carrier: total only
M.addBuilding(acc, 1, "signals", nil, 4125)
M.addBuilding(acc, 1, "other_buildings", nil, 0)        -- zero: hidden
M.addEdge(acc, 1, "TRACK", "simple", 1000, 13000, "NORMAL", 0)
M.addEdge(acc, 1, "TRACK", "standard", 200, 7600 + 1400, "BRIDGE", 1400)
M.addEdge(acc, 1, "STREET", "town_new_small", 500, 2500, "TUNNEL", 300)
M.addEdge(acc, 2, "TRACK", "simple", 100, 1300, "NORMAL", 0)
local R = M.rows(acc, 1, function(g) return "L:" .. g end)
near("total", R.total, 275000 + 10000 + 40000 + 4125 + 13000 + 9000 + 2500, 1e-6)
local keys = {}
for __, r in ipairs(R.rows) do keys[#keys + 1] = r.key end
check("row order, zero rows hidden", table.concat(keys, ",") == "stations,depots,tracks,roads,signals")
check("stations children in fixed order", R.rows[1].children[1].key == "roadside_stops" and R.rows[1].children[1].amount == 10000 and R.rows[1].children[2].key == "rail_stations")
check("depots without sub has no children", R.rows[2].children == nil and R.rows[2].amount == 40000)
local tracks = R.rows[3]
near("tracks meters", tracks.meters, 1200, 1e-9)
check("templates sorted by amount", tracks.children[1].label == "L:simple" and tracks.children[1].meters == 1000 and tracks.children[2].label == "L:standard")
check("bridge surcharge", tracks.bridges.meters == 200 and tracks.bridges.extra == 1400 and tracks.tunnels == nil)
check("tunnel surcharge on roads", R.rows[4].tunnels.meters == 500 and R.rows[4].tunnels.extra == 300)
check("other town", M.rows(acc, 2, tostring).total == 1300 and #M.rows(acc, 2, tostring).rows == 1)
check("unknown town", M.rows(acc, 99, tostring).total == 0 and #M.rows(acc, 99, tostring).rows == 0)
check("unknown kind ignored", (function() M.addEdge(acc, 1, "AIR", "x", 1, 1, "NORMAL", 0); return M.rows(acc, 1, tostring).total end)() == R.total)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/area_upkeep_test.lua`
Expected: error `attempt to call field 'newAcc' (a nil value)`

- [ ] **Step 3: Implement `newAcc`, `addBuilding`, `addEdge`, `rows`**

Per-town structure (builder's choice as long as `rows` meets the contract), e.g. `towns[t] = { cats = { [cat] = { amount, meters, subs = { [sub] = amount }, groups = { [group] = { amount, meters } }, bridges, tunnels } } }`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/area_upkeep_test.lua`
Expected: all `ok`, exit code 0

- [ ] **Step 5: Commit**

```bash
git add kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua test/area_upkeep_test.lua
git commit -m "feat(area): per-town accumulator and row builder"
```

---

### Task 4: Sliced scan over an environment (`area_scan.lua`)

**Files:**
- Create: `kampfmoehre_running_costs_1/content/running_costs/area_scan.lua`
- Test: `test/area_scan_test.lua`

**Interfaces:**
- Consumes: `area_upkeep` (`hermiteLength`, `midpoint`, `edgeUpkeep`, `classifyConstruction`, `classifyEdgeObject`, `newAcc`, `addBuilding`, `addEdge`, `rows`).
- Consumes an environment table `env` (built by Task 5 in the game, faked in the test):
  - `env.now() -> number` microseconds (monotonic).
  - `env.towns() -> { entity }`.
  - `env.constructionsOf(town) -> { entity }`.
  - `env.construction(e) -> info | nil` — nil when not player-owned or no CONSTRUCTION component; `info` as `classifyConstruction` expects, `upkeep` already computed.
  - `env.edges() -> { entity }` (deduped).
  - `env.edge(e) -> info | nil` — nil when not player-owned or inside a construction; `info = { p0, t0, p1, t1 ({x,y,z} tables), kind = "TRACK"|"STREET", etype = "NORMAL"|"BRIDGE"|"TUNNEL", rate, extra, group (template group path), objects = { entity… } }`.
  - `env.townAt(x, y, z) -> entity | nil` (nil also for -1).
  - `env.edgeObject(e) -> info | nil` — nil when not player-owned or no MAINTENANCE_COST; `info = { upkeep, isStation }`.
  - `env.templateLabel(group) -> string`.
  - `env.begin()` (optional): called by `S.start()` when present, before any other call of the scan (Task 5 re-reads the year multiplier there).
- Produces: `M.new(env) -> S` with
  - `S.start()` — begins a scan unless one is running (then no-op); keeps the previous result until the new one completes.
  - `S.running() -> boolean`.
  - `S.step(budgetUs) -> boolean` — works until `env.now() − stepStart ≥ budgetUs` (checked after every item, and before the edge-list call which may overrun once) or the scan finishes; returns `true` exactly on the step that finished a scan. No-op returning `false` when not running.
  - `S.result() -> { at = <env.now() at finish>, acc } | nil`.
  - `S.rows(town) -> { total, rows } | nil` — nil without a result; otherwise `area_upkeep.rows(result.acc, town, env.templateLabel)`.
  - `S.ageUs(nowUs) -> number | nil` — `nowUs − result.at`, nil without a result.
  - `S.stats() -> { towns, constructions, edges, objects, steps, durationUs }` of the last completed scan (for the log line): `constructions` = constructions added to the accumulator, `edges` = edges whose `env.edge` returned an info table (also those later dropped for lack of a town), `objects` = edge objects added, `steps` = `step()` calls of that scan.

- [ ] **Step 1: Write the failing test** (`test/area_scan_test.lua`, same runner pattern; `package.path` adds `kampfmoehre_running_costs_1/content/running_costs/?.lua`)

Fake env: a clock `T` that advances by 10 µs on every `now()` call; towns `{ 1, 2 }`; constructions: town 1 → `{ 11, 12, 13 }` (11 rail station upkeep 1000, 12 depot ROAD upkeep 500, 13 town building), town 2 → `{ 21 }` (21 not owned → nil); edges `{ 31, 32, 33, 34 }`: 31 nil (inside construction), 32 TRACK straight 100 m rate 13 extra 0 group "simple" with objects `{ 41, 42 }` (41 signal upkeep 4125, 42 not owned → nil), midpoint in town 1; 33 STREET 100 m rate 20 BRIDGE extra 5 group "town_new_small", midpoint in town 2; 34 TRACK 100 m whose midpoint has no town (`townAt` returns nil for x == 9999). `townAt(x, …)`: x < 500 → 1, x < 5000 → 2, else nil. `templateLabel = function(g) return "L" .. g end`.

```lua
local S = M.new(env)
check("no result before start", S.result() == nil and S.rows(1) == nil and S.running() == false)
check("step without start is a no-op", S.step(1000) == false)
S.start()
check("running", S.running() == true)
local steps, finished = 0, false
while S.running() and steps < 1000 do
	steps = steps + 1
	if S.step(25) then finished = true end     -- 25 µs budget = 2-3 items per step
end
check("finished in several steps", finished and steps > 3)
local R1 = S.rows(1)
near("town 1 total", R1.total, 1000 + 500 + 100 * 13 + 4125, 1e-6)
local R2 = S.rows(2)
near("town 2 total", R2.total, 100 * (20 + 5), 1e-6)
check("edge without town is skipped", S.stats().edges == 3 and S.rows(1).total + S.rows(2).total == R1.total + R2.total)   -- 32, 33, 34 read; 34 dropped silently
check("stats", S.stats().towns == 2 and S.stats().constructions == 2 and S.stats().objects == 1 and S.stats().steps == steps)
check("bridge surcharge recorded", R2.rows[1].key == "roads" and R2.rows[1].bridges.extra == 500)
check("template label from env", R1.rows[3].children[1].label == "Lsimple")
-- a second scan: start while running is a no-op, old result survives until done
local at1 = S.result().at
S.start()
check("start while running is a no-op", (function() S.start(); return S.running() end)())
check("old result survives a rescan", S.result().at == at1 and S.rows(1).total == R1.total)
while S.running() do S.step(1e9) end
check("rescan replaces the result", S.result().at > at1 and S.rows(1).total == R1.total)
check("age", S.ageUs(S.result().at + 5) == 5)
-- a huge budget finishes in one step
local S2 = M.new(env); S2.start()
check("one step with a large budget", S2.step(1e9) == true and S2.running() == false)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/area_scan_test.lua`
Expected: error `module 'area_scan' not found`

- [ ] **Step 3: Implement `area_scan.lua`**

State machine with `phase` 1..4 and indices `(ti, ci)` for towns/constructions, `ei` for edges, `oi` for the current edge's objects; the edge list is fetched once at the start of phase 2. Per edge: `info = env.edge(e)`; if nil skip; `meters = hermiteLength(info.p0, info.t0, info.p1, info.t1)`; `town = env.townAt(midpoint(...))`; if town nil skip the edge AND its objects; else `addEdge(acc, town, info.kind, info.group, meters, edgeUpkeep(meters, info.rate, info.extra), info.etype, meters × info.extra)`; for each object `oinfo = env.edgeObject(o)`; if oinfo and `oinfo.upkeep > 0` → `addBuilding(acc, town, classifyEdgeObject(oinfo.isStation))`. Constructions: `info = env.construction(c)`; `cat, sub = classifyConstruction(info)`; if cat → `addBuilding(acc, town, cat, sub, info.upkeep)`. Budget check: `env.now() - t0 >= budgetUs` after each construction and each edge (objects belong to their edge). Every `env.*` call that may touch the engine is wrapped in `pcall` inside `area_env` (Task 5), not here.

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/area_scan_test.lua`
Expected: all `ok`, exit code 0

- [ ] **Step 5: Commit**

```bash
git add kampfmoehre_running_costs_1/content/running_costs/area_scan.lua test/area_scan_test.lua
git commit -m "feat(area): resumable budgeted scan over an environment"
```

---

### Task 5: Engine environment (`area_env.lua`)

**Files:**
- Create: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/area_env.lua`

**Interfaces:**
- Consumes: `area_upkeep.constructionUpkeep`, `area_upkeep.templateGroup`, `area_upkeep.templateBaseName`; the engine API; the GUI probe `docs/probes/area_probe/area_gui_probe.script.lua` and the engine probe `area_probe.script.lua` as the verified reference for every call.
- Produces: `M.new() -> env` implementing the Task 4 `env` contract. No unit test (engine-bound); `luajit -bl` and the in-game check of Task 7.

- [ ] **Step 1: Implement `area_env.lua`**

Module returns `{ new = function() … end }`. Details the executor cannot infer:

- `now`: `local clock = api.type.Clock.new()`; `return clock:getTime()` (µs).
- Enum names: resolve once with the probe's `enumNames(enumTable, members)` → `{ [tostring(value)] = name }`, trying `api.type["enum"].X` then `api.type.X`: `RoadType {STREET, TRACK}`, `BaseEdgeType {NORMAL, BRIDGE, TUNNEL}`, `Carrier {ROAD, RAIL, TRAM, OTHER, AIR, WATER}`, `TransportMode {AIRCRAFT, SMALL_AIRCRAFT, HELICOPTER}` (only these three matter; other mode values map to their `tostring`). Compare via `tostring(value)`; `api.type["enum"].X` tables cannot be iterated.
- `comp(e, "NAME")` = `pcall(api.engine.getComponent, e, api.type.ComponentType.NAME)` → component or nil (components are userdata-like; index fields directly, never `type(x) == "table"` guards).
- Player: `api.engine.util.getPlayer()` once per `new()`; owned = `comp(e, "PLAYER_OWNED")` with `.player == player`.
- Constants read once per `new()` (pcall each, defaults 1): `scale = api.res.getBaseConfig().costs["infrastructureMaintenanceScale"]`; `year = api.engine.util.getCalendarDate(api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime).year` (exactly `entity_window_util.tl` 189-190); `yearMult = api.engine.util.construction.getCostMultiplierForYear(baseConfig.treeCostYearMultipliers, year)`. Because `new()` runs once per loaded game, the year multiplier would go stale across a 20-year step: re-read `year`/`yearMult` at the start of every scan (an `env.begin()` hook the scanner calls from `start()`; the fake env in Task 4 may omit it, the scanner calls it only when present).
- `progression(fileName)` cached per name: `api.res.constructionRep.get(api.res.constructionRep.find(fileName)).costsYearProgression` (pcall, default false).
- `towns`: `api.engine.getEntitiesWithComponent(api.type.ComponentType.TOWN)`; `constructionsOf`: `api.engine.system.streetConnectorSystem.getTownClosestConstructions(town)`; both return `{}` on failure.
- `construction(e)`: owned check; `con = comp(e, "CONSTRUCTION")` (nil → nil); `mc = comp(e, "MAINTENANCE_COST")`; accumulated = Σ over `pairs(mc.accumulatedCost)` (pcall; 0 without mc); `upkeep = constructionUpkeep(mc and mc.maintenanceCost, accumulated, scale, yearMult, progression(con.fileName))`; `nStations/nDepots/nTownBuildings` via a `listLen` helper (pcall `#t`); carriers/modes for `nStations > 0`: `g = stationGroupSystem.getStationGroup(con.stations[1])`, `car = stationGroupSystem.getCarriers(g, -1, -1)` → names of `car[1]` (carriers) and `car[2]` (modes) through the enum maps; depot: `vd = comp(con.depots[1], "VEHICLE_DEPOT")` → `depotCarrier = carrierName(vd.carrier)`, `depotModes` = names of `vd.transportModes`.
- `edges`: `map = api.engine.system.streetSystem.getNode2SegmentMap()`; dedupe with a set over `pairs(map)` / `pairs(segs)` exactly like the probe.
- `edge(e)`: `be = comp(e, "BASE_EDGE")` (nil → nil); owned check; `getConstructionEntityForEdge(e)` non-nil and ≠ -1 → nil; `p0/t0/p1/t1` copied into `{x, y, z}` tables from `be.position0/tangent0/position1/tangent1`; `kind = roadTypeName(be.roadType)`, `etype = edgeTypeName(be.type)`; `rate` from a per-template cache: `api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(be.roadTemplate)).maintenanceCost` (pcall; failure → 0); `extra` for BRIDGE/TUNNEL: `(api.res.bridgeTypeRep | tunnelTypeRep).get(be.typeIndex).maintenanceCost` cached per `(etype, typeIndex)` (pcall; 0 on failure); `group = templateGroup(tostring(be.roadTemplate))`; `objects` = list of `objs[j][1]` for `j = 1, listLen(be.objects)` (pcall per entry, numbers only).
- `townAt(x, y, z)`: `api.engine.util.town.getClosestTown(api.type.Vec3f.new(x, y, z))` (the `town` sub-table!), pcall; nil or -1 → nil.
- `edgeObject(e)`: owned check; `mc = comp(e, "MAINTENANCE_COST")` (nil → nil); `eo = comp(e, "EDGE_OBJECT")`; `fileName = eo and tostring(eo.edgeObjectConstruction)`; `upkeep = constructionUpkeep(mc.maintenanceCost, Σ accumulatedCost, scale, yearMult, progression(fileName))`; `isStation = comp(e, "STATION") ~= nil`.
- `templateLabel(group)` cached: `api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(group)).name` (the probe read `t.name`; the tealdef comment "Localized display name" belongs to it); empty or failure → `templateBaseName(group)`.

- [ ] **Step 2: Syntax check**

Run: `luajit -bl kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/area_env.lua > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/area_env.lua
git commit -m "feat(area): engine environment for the area scan"
```

---

### Task 6: Strings

**Files:**
- Modify: `kampfmoehre_running_costs_1/strings.json`

**Interfaces:**
- Produces string keys used by Task 7 (`running_costs_area_` + key): `title`, `total`, `total_tooltip`, `calculating`, `km`, `bridges`, `tunnels`, `inside_note`, and one key per category and sub-row: `stations`, `roadside_stops`, `road_terminals`, `rail_stations`, `harbours`, `airports`, `heliports`, `other_stations`, `depots`, `road_depots`, `rail_depots`, `ship_depots`, `hangars`, `heli_hangars`, `maintenance`, `warehouses`, `other_buildings`, `tracks`, `roads`, `signals`.

- [ ] **Step 1: Add the keys with a `python3 -I` script** (load, add to `en`, `de`, `uk`, dump with `indent=4, ensure_ascii=False`, trailing newline)

| key | en | de |
|---|---|---|
| title | Infrastructure upkeep | Infrastruktur-Unterhalt |
| total | Total | Gesamt |
| total_tooltip | Player-owned infrastructure in this town's area (the area shown around the town), per game year as in the station windows. Vehicles are not included. | Infrastruktur des Spielers im Gebiet dieser Stadt (die um die Stadt angezeigte Fläche), pro Spieljahr wie in den Stationsfenstern. Fahrzeuge sind nicht enthalten. |
| calculating | calculating … | wird berechnet … |
| km | {label} · {km} km | {label} · {km} km |
| bridges | Bridges: {km} km, +{amount}/year | Brücken: {km} km, +{amount}/Jahr |
| tunnels | Tunnels: {km} km, +{amount}/year | Tunnel: {km} km, +{amount}/Jahr |
| inside_note | Tracks and roads inside stations and depots count under the station or depot. | Gleise und Strassen innerhalb von Stationen und Depots zählen zur Station bzw. zum Depot. |
| stations | Stations | Stationen |
| roadside_stops | Roadside stops | Haltestellen |
| road_terminals | Road terminals | Terminals |
| rail_stations | Rail stations | Bahnhöfe |
| harbours | Harbours | Häfen |
| airports | Airports | Flughäfen |
| heliports | Heliports | Heliports |
| other_stations | Other stations | Sonstige Stationen |
| depots | Depots | Depots |
| road_depots | Road depots | Strassendepots |
| rail_depots | Rail depots | Zugdepots |
| ship_depots | Ship depots | Schiffsdepots |
| hangars | Hangars | Hangars |
| heli_hangars | Helicopter hangars | Helikopterhangars |
| maintenance | Maintenance buildings | Wartungsgebäude |
| warehouses | Warehouses | Lagerhäuser |
| other_buildings | Other buildings | Sonstige Gebäude |
| tracks | Tracks | Gleise |
| roads | Roads | Strassen |
| signals | Signals | Signale |

`uk` = the `en` text for every key. (The Tracks/Roads tooltip is assembled in Task 7 from `bridges`, `tunnels` and `inside_note`.)

- [ ] **Step 2: Verify**

Run: `python3 -I -c "import json; d=json.load(open('kampfmoehre_running_costs_1/strings.json')); print(len(d['en']), len(d['de']), len(d['uk']), all(k in d['de'] and k in d['uk'] for k in d['en']))"`
Expected: `91 91 91 True` (63 + 28), and `git diff --stat` shows only added lines in `strings.json` (indentation unchanged).

- [ ] **Step 3: Commit**

```bash
git add kampfmoehre_running_costs_1/strings.json
git commit -m "feat(area): strings for the infrastructure upkeep card (EN/DE, uk placeholders)"
```

---

### Task 7: Town card, plugin, scan driver, stylesheet

**Files:**
- Create: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/town.res.lua`
- Modify: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.script.lua` (requires near line 41, new section before `M.EntryPlugin` ≈ line 1152, the entry plugin itself, the load-log line)
- Modify: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.css.lua` (three selectors)

**Interfaces:**
- Consumes: `area_scan.new(env)` (Task 4), `area_env.new()` (Task 5), strings (Task 6), `area_upkeep.rows` row shape (Task 3).
- Produces: `M.TownPlugin` (plugin recipe at `::TownEowExtensionPoint`), recipe name `KampfmoehreRunningCostsAreaTable` (used in the CSS selector).

- [ ] **Step 1: Resource file `town.res.lua`** (same shape as `station.res.lua`): `type = "react-plugin ::TownEowExtensionPoint"`, `filePath = "kampfmoehre_running_costs_1::/gui/kampfmoehre_running_costs/running_costs.script@TownPlugin"`, `order = 70`.

- [ ] **Step 2: Stylesheet** — change exactly these selectors (rule count 21 → 20, verify with the regex below):
  - `R::KampfmoehreRunningCostsTable TextView, R::KampfmoehreRunningCostsFeeTable TextView` → append `, R::KampfmoehreRunningCostsAreaTable TextView` (+1)
  - `R::KampfmoehreRunningCostsTable TextView!kampfmoehre-rc-money, R::KampfmoehreRunningCostsFeeTable TextView!kampfmoehre-rc-money` → `TextView!kampfmoehre-rc-money` (−1; the class is namespaced, nothing else uses it)
  - `R::KampfmoehreRunningCostsTable TextView!kampfmoehre-rc-num, R::KampfmoehreRunningCostsFeeTable TextView!kampfmoehre-rc-num` → `TextView!kampfmoehre-rc-num` (−1)
  - `R::KampfmoehreRunningCostsFeeTable Button!kampfmoehre-rc-namebutton` → `Button!kampfmoehre-rc-namebutton` (±0; the area table's expand toggles reuse it)

Run: `grep -o 'a("[^"]*"' kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.css.lua | tr ',' '\n' | wc -l`
Expected: `20`

- [ ] **Step 3: Script additions** in `running_costs.script.lua`:

Requires (after line 41): `area_scan = ug_require "kampfmoehre_running_costs_1::/running_costs/area_scan.lua"`, `area_env = ug_require "kampfmoehre_running_costs_1::/gui/kampfmoehre_running_costs/area_env.lua"`.

New section "Infrastructure upkeep per town area (0.6.0)" before the entry plugin:

```lua
local AREA_EVENT = "kampfmoehreRunningCostsAreaUpkeep"
local AREA_CARD_KEY = "kampfmoehreRunningCostsAreaUpkeep"
local AREA_TTL_US = 30 * 1000000
local AREA_BUDGET_US = 4000
local areaScanner = nil          -- created on first use (area_env.new needs the engine)
local areaCards = 0              -- mounted card instances
local function areaScannerGet() … pcall(area_env.new) → area_scan.new(env); nil and a log line on failure … end
local function areaWant()        -- start a scan if there is none or the cache is older than TTL
local function areaStep()        -- called from the entry plugin's onStep: if running, step(AREA_BUDGET_US); on true fire api.gui.fireReactEvent(AREA_EVENT, {}) and log one line "area scan: N towns, N constructions, N edges, N objects in N steps, X ms"
```

`AreaTable = react.RegisterRecipe("KampfmoehreRunningCostsAreaTable", function(p) … end)` with `p.town`:
- `react.onMount(function() areaCards = areaCards + 1; areaWant() end)`, `react.onUnmount(function() areaCards = areaCards - 1 end)`.
- `local version = react.useState(0)`; `react.onEvent(AREA_EVENT, function() version:set(version:old() + 1) end)` (re-render when a scan finished); `react.onStepTimer(function() if areaCards > 0 then areaWant() end end, 1)` (TTL re-scan while a card is open).
- `local expanded = react.useState({})` keyed by row key; toggling copies the table (`react` state must be replaced, not mutated).
- Data: `local R = areaScanner and areaScanner.rows(p.town)`; nil → `builtin.BoxLayout{ children = { cell(_("running_costs_area_calculating")) } }`.
- Table: `builtin.TableLayout{ rows = rows, columnWeights = { 10, -1 } }`; first row `meta.localKey = "total"`: label `_("running_costs_area_total")` bold with `meta.tooltip = _("running_costs_area_total_tooltip")`, amount bold; then per row `r` (`localKey = r.key`): label cell = `builtin.BoxLayout{ orientation = Horizontal, children = { toggle?, TextView } }` where `toggle` exists only when `r.children` and is `builtin.Button{ meta = { class = "kampfmoehre-rc-namebutton" }, content = builtin.BoxLayout{ children = { builtin.ImageView{ path = isOpen and "::/gui/builtin/combobox/arrow_down.tga" or "::/gui/builtin/combobox/arrow_right.tga" } } }, onClick = toggle(r.key) }` (the pattern of `gui/main/collapsible_checkbox_list.tl` ~157); label text = `_("running_costs_area_" .. r.key)`, for `tracks`/`roads` `fmt("running_costs_area_km", { label = …, km = km(r.meters) })` with `km(m) = string.format("%.1f", m / 1000)` and `meta.tooltip` = lines joined by `"\n"`: `bridges` line (if `r.bridges`), `tunnels` line (if `r.tunnels`), `_("running_costs_area_inside_note")`; amount cell = `yearly(r.amount)` with class `"font-scale-body, negative, kampfmoehre-rc-money"` where `yearly(x) = fmt("{maintenanceCost}/{maintenancePeriod}", { maintenanceCost = money(x), maintenancePeriod = _("Year") })` (both are base-game keys, `entity_window_util.tl` ~220 and `maintenance_station.tl` ~195); when `isOpen` append one row per child (`localKey = r.key .. ":" .. (c.key or c.group)`): label `"    " .. (c.key and _("running_costs_area_" .. c.key) or c.label)`, for template children with the km format, class `font-scale-annotation`; amount `yearly(c.amount)` in `font-scale-annotation, kampfmoehre-rc-money`.
- `money`, `fmt`, `round` are script-level helpers (top of `data()`); `cell(text, class)` is local to `FeeTable`'s body, so define the same one-liner inside `AreaTable`.

`M.TownPlugin = react.RegisterPluginRecipe({ id = "::TownEowExtensionPoint" }, "KampfmoehreRunningCostsTown", function(params) … end)`: returns `builtin.BoxLayout{ meta = { class = "box-plugin-vertical-space" }, orientation = Vertical, children = { content_card.ContentCard{ meta = { localKey = AREA_CARD_KEY }, title = _("running_costs_area_title"), initialCalloutTextPermanent = "", recipeAndParamPermanent = content_card.makeRecipeAndParam(AreaTable, { town = params.entityId }), gameCtx = params.gameCtx, showOnRightSide = params.showCalloutOnRightSide } } }` (the statistics card in `town.tl` ~1250 is the template; `ContentCard` has no title tooltip, hence the tooltip on the Total row). No ownership check: towns are not player-owned.

Entry plugin: add `react.onStep(function() areaStep() end)` inside `M.EntryPlugin`'s body (before the `return`); one boolean check per frame while idle. Extend the load-log line with `, town area card`.

- [ ] **Step 4: Syntax check and tests**

Run: `for f in kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/*.lua kampfmoehre_running_costs_1/content/running_costs/*.lua; do luajit -bl "$f" > /dev/null || echo "FAIL $f"; done; echo checked; for t in test/*_test.lua; do luajit "$t" > /dev/null || echo "FAIL $t"; done; echo tests done`
Expected: `checked` and `tests done` with no `FAIL` line.

- [ ] **Step 5: Sync and in-game check (user)**

Run: `./sync.sh`
Expected: `synced -> …/staging_area/kampfmoehre_running_costs_1`

Ask the user to reload the big save and check, in this order (reporting exact log lines helps): (1) `stdout.txt` has `v0.6.0 GUI loaded (… town area card)` and, after opening a town window, one `area scan: …` line with no Lua error; (2) the town window shows the card below "Statistics" with Total first, "calculating …" at most for a second; (3) the Vänersborg (or any) card total against the probe's per-town line in `docs/probes/area_probe/README.md` log excerpt; (4) expanding Stations and Tracks, the arrow flips, sub-rows indented; (5) hover Tracks: bridges/tunnels lines; (6) sum of all towns' totals ≈ the finance table's Upkeep rows (±2 %); (7) no visible stutter when opening the town window; (8) a newly built bus stop appears within 30 s and equals the stop window's figure; (9) on the test save the border depot appears under Filderstadt. Fix what fails (TDD for anything in the pure modules), re-sync, repeat.

- [ ] **Step 6: Commit**

```bash
git add kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/town.res.lua kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.script.lua kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.css.lua
git commit -m "feat(area): infrastructure upkeep card in the town window"
```

---

### Task 8: Version, revision, changelog, README, hub description, project notes

**Files:**
- Modify: `kampfmoehre_running_costs_1/mod.json` (`revision` 9 → 10)
- Modify: the three scripts' `VERSION` (`"0.5.1"` → `"0.6.0"`): `kampfmoehre_running_costs_1/content/running_costs/running_costs.script.lua`, `kampfmoehre_running_costs_1/content/running_costs/income.script.lua`, `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.script.lua`
- Modify: `CHANGELOG.md` (new top entry `## 0.6.0 (unreleased)`), `README.md` (feature section after "Holding pattern and station queue (0.4.0)" and before "Installation"; a bullet in "How it works"; the test list in "Development" gets `luajit test/area_upkeep_test.lua` and `luajit test/area_scan_test.lua`)
- Modify (outside the repo, project notes): `/home/satan/dev/tpf3-modding/CLAUDE.md` Running Cost Breakdown row: append a 0.6.0 note (town card, GUI-side sliced scan, files, rule count 20, "probe removed from the mod 2026-11-13").

- [ ] **Step 1: Bump version and revision**

Run: `grep -n 'VERSION = ' kampfmoehre_running_costs_1/content/running_costs/*.script.lua kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.script.lua; grep -n revision kampfmoehre_running_costs_1/mod.json`
Expected: three lines with `"0.6.0"`, `"revision": 10`

- [ ] **Step 2: CHANGELOG entry** (technical, GitHub readers), covering: the town card and its rows; the formulas (construction `maintenanceCost × infrastructureMaintenanceScale × year multiplier + accumulated`, edges Hermite length × template rate (+ bridge/tunnel rate), edge objects = signals and roadside stops); attribution by the game's own town area (Voronoi, `getClosestTown`); GUI-side scan in 4 ms slices (≈ 100 ms on a 13k-edge save), cache 30 s, no saved state; catenary not split (no extra upkeep); bridges/tunnels in the tooltip; CSS selectors widened (20 rules); Ukrainian strings are English placeholders until translated.

- [ ] **Step 3: README section "Infrastructure upkeep per town area (0.6.0)"** — what the card shows (screenshot placeholder line for the user's gallery image), how the area is defined (the light area around the town), what counts and what not (vehicles, one-off construction costs, catenary), the two tooltips, the 30 s refresh; "How it works" bullet: the three modules and the slice driver; the probe reference `docs/probes/area_probe/README.md`.

- [ ] **Step 4: Hub description sentence** (the user pastes it into `modinfo.json` himself; give it in the final message, EN and DE):

EN: `<p><strong>0.6.0 (date)</strong></p><ul><li>Town windows get a card "Infrastructure upkeep": the yearly upkeep of your stations, depots, maintenance buildings, warehouses, tracks, roads and signals inside that town's area, by category, with track and road length. Expand stations and depots by carrier and tracks and roads by type. Computed from live data, no saved state.</li></ul>`

DE: `Stadtfenster erhalten eine Karte "Infrastruktur-Unterhalt": der jährliche Unterhalt deiner Stationen, Depots, Wartungsgebäude, Lagerhäuser, Gleise, Strassen und Signale im Gebiet dieser Stadt, nach Kategorie, mit Gleis- und Strassenlänge. Stationen und Depots lassen sich nach Verkehrsträger aufklappen, Gleise und Strassen nach Typ.`

- [ ] **Step 5: Final checks**

Run: `for t in test/*_test.lua; do luajit "$t" > /dev/null || echo "FAIL $t"; done; echo tests done; git status --short`
Expected: `tests done` without `FAIL`; status lists only the files of this task (plus untracked `docs/` from the design phase, which the user commits).

- [ ] **Step 6: Sync (so the staging copy carries the version bump) and commit**

Run: `./sync.sh`

```bash
git add kampfmoehre_running_costs_1/mod.json kampfmoehre_running_costs_1/content CHANGELOG.md README.md
git commit -m "chore: release 0.6.0 (infrastructure upkeep per town area)"
```

Report to the user: what to upload (revision 10), the hub description sentences, and that `docs/superpowers/specs/2026-11-13-area-upkeep-design.md`, `docs/superpowers/plans/2026-11-13-area-upkeep.md` and `docs/probes/area_probe/` are still uncommitted from the design phase.
