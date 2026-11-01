# Holding Pattern Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fifth cost class "holding" for aircraft circling / hovering and ships queueing for a berth, with the number of aborted approaches in the row label (Running Cost Breakdown 0.4.0).

**Architecture:** A pure module `holding.lua` turns per-sample observations of an air/water vehicle into holding yes/no plus go-around events (episode memory in two flat state tables); the sampler feeds it from `MOVE_PATH_AIRCRAFT`/`AIRCRAFT` reads for air/water vehicles only (carrier cached per vehicle), classifies with a new `holding` flag and counts go-arounds as a weighted bucket field `g`; the class list, row builder and GUI pick the new class up automatically, the label adds the count.

**Tech Stack:** Lua 5.1 (game), luajit tests in `test/`.

**Spec:** `docs/superpowers/specs/2026-11-01-holding-pattern-design.md` (measurements: `docs/probes/holding_probe/README.md`).

## Global Constraints

- No `_` as loop variable in GUI code; `luajit -bl` on every changed Lua file; all four existing test files stay green.
- Texts EN + DE in `strings.json`; mod-hub description (`modinfo.json`) is NOT touched (user maintains it); technical `CHANGELOG.md` gets the entry.
- STATE_VERSION stays 7; new state tables are flat (`statC`, `airF`, `airH`) and appear in the perf line's size list.
- Version string `0.4.0` in the three scripts, `revision` 6 in `mod.json`.

## Review Focus

- An aircraft whose `MOVE_PATH_AIRCRAFT` read fails mid-episode must fall back to the plain classification (no stuck holding).
- A vehicle sold while holding leaves no `airF/airH/statC` entries behind (gone-vehicle cleanup).
- A train or truck never gets the holding class even if `statC` is unknown (carrier 0 → no extra reads).
- The live line shows "holding" only when the sampler's summary says so and the vehicle is en route and moving.
- The go-around count survives the window weighting (pro rata of the oldest bucket) and shows as an integer (rounded).

---

### Task 1: `holding.lua` — episode logic as a pure function

**Files:** Create `kampfmoehre_running_costs_1/content/running_costs/holding.lua`, Test `test/holding_test.lua`.

**Produces:** `holding.step(prev, obs) -> next, isHolding, goAround` with
`prev = { f = flightState|nil, h = 0|1, stop = stopIndex|nil } | nil`,
`obs = { carrier = "AIR"|"WATER"|other, enRoute = boolean, flight = integer|nil (0 Taxi0 … 5 Taxi1), landRes = boolean|nil, alt = number|nil, cruise = number|nil, speed = number, stop = integer|nil, approaching = boolean|nil }`;
constants `holding.HOVER_SPEED = 5`, `holding.BERTH_SPEED = 1`, `holding.FLIGHT = 2, APPROACH = 3, LANDING = 4`.
Rules (spec): AIR + enRoute: drop (prev.f ∈ {3,4} and flight == 2, or prev.f == 4 and flight == 3) → goAround, h = 1; h ends when flight == 4 and (landRes or alt < 0.5·cruise), flight ∈ {0,1,5}, not enRoute, or stop ~= prev.stop; hover = flight == 2 and speed < HOVER_SPEED → isHolding (no episode). WATER + enRoute: approaching and speed < BERTH_SPEED → isHolding. Other carriers: next = nil, false, false. next always carries f, h, stop for AIR; nil for others.

- [ ] Step 1: write `test/holding_test.lua` (probe sequences: go-around at 44 m: prev f=4 → obs f=2 alt 44 cruise 525 → goAround, holding; stays holding at f=4 alt 400 (above half cruise), ends at f=4 alt 214 (below half) ; cruise loop 3→4→2 counts one go-around per drop; landing with reservation ends; taxi ends; stop change ends without goAround; helicopter f=2 speed 3 → holding, speed 20 → not; aircraft f=2 speed 90 no; ship approaching speed 0.5 → holding, speed 6 → not, not approaching speed 0 → not; truck → nil,false,false; nil prev tolerated; missing flight → no holding).
- [ ] Step 2: run `luajit test/holding_test.lua` → FAIL (module not found).
- [ ] Step 3: implement `holding.lua`.
- [ ] Step 4: run → all ok.

### Task 2: class list and classify flag

**Files:** Modify `cost_classes.lua`, `test/cost_classes_test.lua`.

**Produces:** `CLASSES[3] = { key = "holding", factor = 1.0, labelKey = "running_costs_class_holding", shortKey = "running_costs_short_holding", colour = "warn" }` (after waiting, before terminal); `classify(stateName, speedMps, standingSpeed, holding)` returns "holding" for EN_ROUTE/GOING_TO_DEPOT when `holding == true`, before the standing test.

- [ ] Step 1: tests: order has five classes with holding third; `classify("EN_ROUTE", 80, nil, true) == "holding"`, `classify("EN_ROUTE", 0, nil, true) == "holding"`, `classify("AT_TERMINAL", 0, nil, true) == "terminal"`, `classify("EN_ROUTE", 80, nil, false) == "driving"`.
- [ ] Step 2: run → FAIL. Step 3: implement. Step 4: run all four tests → ok (cost_rows_test may reference class count: fix expectations if they assume four).

### Task 3: go-around count in the history

**Files:** Modify `cost_history.lua`, `test/cost_history_test.lua`.

**Produces:** `M.addCount(h, nowMs, field, n)` adds `n` to bucket field `field` (string, e.g. "g") of the bucket for nowMs (head bucket, in place); `window()` returns `out.g = Σ weight × b.g` (0 when absent); `deflateSummary`/`inflateSummary` pass `g` through unchanged (plain field).

- [ ] Step 1: tests: addCount twice → window g == 2; pro rata: bucket fully outside → 0; half-weighted oldest bucket → 1 for g=2; summary round trip keeps g.
- [ ] Step 2: run → FAIL. Step 3: implement. Step 4: run → ok.

### Task 4: sampler

**Files:** Modify `running_costs.script.lua` (sampler).

**Consumes:** Tasks 1-3. **Produces:** state tables `statC[v]` (1 AIR, 2 WATER, 0 other; filled in `staticOf` from `tv.carrier` compared with `api.type["enum"].Carrier.AIR/WATER`, also when the static rate is refreshed), `airF[v]`, `airH[v]`, `airS[v]` (stop) — flat; `summary.g` via window; `summary.key == "holding"` when classified so.

- [ ] Step 1: in the per-vehicle loop, for `statC[v] == 1 or 2` and state EN_ROUTE/GOING_TO_DEPOT read `MOVE_PATH_AIRCRAFT` (+ `AIRCRAFT` for AIR) inside pcall, build `obs`, call `holding.step(prev, obs)`, store next into airF/airH/airS, pass `isHolding` to `classify`, on goAround `history.addCount(h, now, "g", 1)` (after `history.add`). Note `tv.stopIndex` is needed for `stop`: read it from the TRANSPORT_VEHICLE only for AIR vehicles (one component read per aircraft per sample; acceptable, aircraft are few) — or drop the stop rule if the read costs too much; keep it.
- [ ] Step 2: gone-vehicle cleanup removes statC/airF/airH/airS; `stateSizes` lists them; fresh state creates them; `VERSION = "0.4.0"`; header comment.
- [ ] Step 3: `luajit -bl`; `./sync.sh`; in-game: test save, Flugzeug rows show holding with count (user verifies).

### Task 5: rows and GUI

**Files:** Modify `cost_rows.lua`, `test/cost_rows_test.lua`, GUI `running_costs.script.lua`, `strings.json`.

**Produces:** `cost_rows.build` sums `w.g` into `out.goArounds` (rounded integer) and sets `row.count = out.goArounds` on the holding row; GUI `classLabel(r)`: for `r.key == "holding"` and `r.count > 0` use `running_costs_class_holding_n` ("holding pattern ({n} go-arounds)") or `_one` ("… (1 go-around)"); the holding row label cell gets `meta.tooltip = _("running_costs_class_holding_tooltip")`; `liveData` promotes key "driving" to "holding" when `summaryOf(gs, v).key == "holding"`; strings EN/DE: `running_costs_class_holding` "holding pattern" / "Warteschleife", `_n`, `_one`, `_tooltip` ("Aircraft circling for a free runway or hovering in the landing queue, ships waiting for a free berth; charged at 100 % like driving." / DE), `running_costs_short_holding` "holding" / "Warteschleife". GUI `VERSION = "0.4.0"`; signature of the table includes the count.

- [ ] Step 1: tests for build: summaries with g → goArounds and row.count; without → 0/nil.
- [ ] Step 2: run → FAIL. Step 3: implement rows + GUI + strings. Step 4: run all tests; `luajit -bl` GUI; sync; in-game look (user).

### Task 6: docs and version

**Files:** `README.md` (new section "Holding pattern (0.4.0)" after Maintenance fee + "How it works" bullet), `CHANGELOG.md` (0.4.0 entry, technical), `mod.json` revision 6, `income.script.lua` VERSION "0.4.0", CLAUDE.md mod row (0.4.0 in progress, rules, probe pointer).

- [ ] Step 1: write; Step 2: `python3 -I -c json.load` on mod.json/strings.json; `./sync.sh`.
