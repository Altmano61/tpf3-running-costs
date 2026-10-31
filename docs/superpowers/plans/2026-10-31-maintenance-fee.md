# Maintenance Fee Breakdown (0.3.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the window of a depot or maintenance building, a collapsible card showing the "Maintenance Vehicles" fee of the rolling window, how much of it was charged for vehicles already in very good condition, how much of that for vehicles also covered by other buildings, and per vehicle its minutes in the pool, fee share, condition and other buildings.

**Architecture:** The cost sampler (already iterating every 3 s of game time) additionally reads each building's pool list and accumulates per building a ring (`cost_history` ring with bucket field `pool`) of seconds, fee, seconds-at-≥0.8, seconds-at-1.0 and entry condition per vehicle, plus a per-vehicle set of buildings seen in the window. A pure module `fee_rows.lua` turns a building's window entries into the card's figures and rows; a new plugin at `::MaintenanceStationEowExtensionPoint` renders it, reading the building's ring via `state_native:findPath`.

**Tech Stack:** Lua 5.1 / LuaJIT, TF3 game scripts and react-like GUI, luajit tests. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-31-maintenance-fee-design.md` (this repo); mechanics in `/home/satan/dev/tpf3-modding/CLAUDE.md` backlog entry "Maintenance Vehicles"; conventions in that CLAUDE.md.

## Global Constraints

- Same repo and modId `kampfmoehre_running_costs_1`; `VERSION = "0.3.0"` in all three scripts; `mod.json` `revision` 4; `cosmetic: true`; no params. Work on a branch `feat/maintenance-fee` off `main` (last commit `fa8c1ee`).
- **No commits by the implementer** unless the user asks; each task ends with the changed files and a suggested conventional commit message.
- Fee rule (verbatim from the measurements): fee per maintained vehicle per minute = `0.25 × getRunningCost(v) × 60 / 1461`; a vehicle is in a building's pool when `transportVehicleSystem.getVehiclesForMaintenanceStation(d)` lists it; "Very good" = condition ≥ 0.8; condition from `api.engine.util.vehicle.getVehicleMaintenanceState(v)`.
- Buildings = entities from `api.engine.getEntitiesWithComponent(api.type.ComponentType.VEHICLE_DEPOT)` with `maintenancePool > 0`; the window's `entityId` is that entity; its account is `api.engine.system.streetConnectorSystem.getConstructionEntityForDepot(d)` (fallback: `d`).
- Window = `api.util.getDefaultYearDuration()` ms; ring geometry `cost_history.BUCKET_MS`/`BUCKETS`; weighting via `cost_history.bucketWeight` with the building ring's own `first`.
- Game scripts: `update()` runs on arbitrary pool threads; everything persistent in `state:get()/set()`; `STATE_VERSION` 4 rebuilds old states. GUI: no `_` loop variables, no globals, `pcall` around engine calls, `builtin.Component{ layout = <layout> }`, amounts right-aligned (`kampfmoehre-rc-money`), counts (`kampfmoehre-rc-num`).
- Budget: the pool reads add ≤ 1 ms per sample on the 364-vehicle save; the perf line reports buildings and pool entries.
- Texts EN first in `strings.json` (keys and EN copy pinned in Task 4), DE by the implementer, user reviews; `luajit -bl` every Lua file; `luajit test/<name>_test.lua` from the repo root.

## Review Focus

- A building demolished while in the state: its ring is dropped on the next sweep, no error in a window that was open (Task 2 cleanup; Task 4 shows "no vehicles maintained yet" when the ring is gone).
- A vehicle sold while in a pool: its row disappears with the next window refresh, the building's fee keeps the past seconds (ring data is per bucket, no live lookup needed); `cNow` read returns nil → "–" (Task 3 test "row without current condition", Task 4 pcall).
- A vehicle maintained by two buildings in the same 3 s sample (overlapping circles): both rings count it, both charge in the game too (measured: the fee is per listing); `elsewhere` lists the other building (Task 3 test "elsewhere from maintainedBy").
- Coverage below the window (building just built, mod just installed): header says "last N min" with the real N; shares computed on whatever exists; empty ring → empty card text (Task 3 tests "empty", "young ring").
- A pool vehicle whose running cost is 0 or unknown (modded vehicle without metadata): fee 0, seconds still counted, no division by zero in the shares (Task 3 test "zero fee vehicle").

---

## File structure

```
kampfmoehre_running_costs_1/
  content/running_costs/cost_history.lua        + addPool, windowPool                                   (Task 1)
  content/running_costs/running_costs.script.lua  pool sampling into s.pool / s.maintainedBy, STATE_VERSION 4, perf (Task 2)
  content/gui/kampfmoehre_running_costs/fee_rows.lua          pure: entries → figures + rows              (Task 3)
  content/gui/kampfmoehre_running_costs/station.res.lua       react-plugin ::MaintenanceStationEowExtensionPoint, order 35 (Task 4)
  content/gui/kampfmoehre_running_costs/running_costs.script.lua  reader + MaintenanceFeePlugin + FeeTable  (Task 4)
  content/gui/kampfmoehre_running_costs/running_costs.css.lua     (no change expected; reuse rc-money/rc-num)
  strings.json                                   + fee keys EN/DE                                          (Task 4)
  mod.json, _metadata/modinfo.json, README.md, CHANGELOG.md                                                (Task 5)
test/cost_history_test.lua, test/fee_rows_test.lua
```

---

### Task 1: Pool accumulation in the shared ring (pure)

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/running_costs/cost_history.lua`
- Test: `test/cost_history_test.lua` (append)

**Interfaces:**
- Produces:
  - `M.addPool(ring, nowMs, dtMs, v, rcPerYear, cond, yearMs)` — in the bucket for `nowMs`, `bucket.pool[v] = { s, fee, good, full, c0 }`: `s += dtMs/1000`, `fee += 0.25 × rcPerYear × dtMs / yearMs`, `good += dtMs/1000` if `cond ≥ 0.8`, `full += dtMs/1000` if `cond ≥ 1 − 1e-6`, `c0 = cond` the first time `v` appears in this bucket (nil `cond` counts as not good, not full, `c0` stays nil).
  - `M.windowPool(ring, nowMs, windowMs) : { [v] = { s, fee, good, full, c0 } }` — weighted with `bucketWeight(t0, nowMs, windowMs, ring.first)`; `c0` = the entry condition of the oldest counted bucket that has one; also returns a second value `coverageMs` computed like `window()` does (oldest counted bucket, cut at `from` and `first`).

- [ ] **Step 1: Append the failing tests** to `test/cost_history_test.lua` (reuse `check`/`near`, `Y`):

```lua
-- pool rings (0.3.0): seconds, fee, good/full seconds and entry condition per vehicle
local pr = M.new(0)                                      -- ring with first (building first seen at 0)
M.addPool(pr, 3000, 3000, 7, 1461000, 0.5, Y)            -- 3 s at 1 461 000/yr -> fee 0.25 × 3000 = 750
M.addPool(pr, 6000, 3000, 7, 1461000, 0.85, Y)           -- good
M.addPool(pr, 9000, 3000, 7, 1461000, 1.0, Y)            -- full
M.addPool(pr, 9000, 3000, 8, 0, nil, Y)                  -- unknown rc / condition
local P, cov = M.windowPool(pr, 9000, Y)
near("pool seconds", P[7].s, 9, 1e-9); near("pool fee", P[7].fee, 2250, 1e-6)
near("good seconds (>= 0.8)", P[7].good, 6, 1e-9); near("full seconds (1.0)", P[7].full, 3, 1e-9)
near("entry condition", P[7].c0, 0.5, 1e-9)
check("zero fee vehicle counted", P[8].s == 3 and P[8].fee == 0 and P[8].good == 0 and P[8].c0 == nil)
near("pool coverage", cov, 9000, 1e-9)
-- pro rata and c0 from the oldest counted bucket
local pr2 = M.new(0)
M.addPool(pr2, 1000, 1000, 7, Y, 0.3, Y)                              -- bucket 0, c0 = 0.3
M.addPool(pr2, M.BUCKET_MS + 1000, 1000, 7, Y, 0.9, Y)                -- bucket 1, c0 = 0.9
local P2 = M.windowPool(pr2, M.BUCKET_MS + 1000, 2 * M.BUCKET_MS)
near("c0 from the oldest bucket", P2[7].c0, 0.3, 1e-9)
local P3 = M.windowPool(pr2, M.BUCKET_MS + 1000, M.BUCKET_MS / 2)   -- cut inside bucket 1
near("c0 from the oldest counted bucket", P3[7].c0, 0.9, 1e-9)
check("empty pool ring", next(M.windowPool(M.new(0), 0, Y)) == nil and select(2, M.windowPool(nil, 0, Y)) == 0)
```

- [ ] **Step 2: Run `luajit test/cost_history_test.lua`** — Expected: FAIL (`addPool` nil).
- [ ] **Step 3: Implement `addPool` and `windowPool`** (reuse `bucketFor`, `bucketWeight`; coverage like `window()`).
- [ ] **Step 4: Run the suite** (all three test files) — Expected: all `ok`. `luajit -bl` the module.
- [ ] **Step 5: Report** files + `feat: pool rings in cost_history`.

---

### Task 2: Sampler reads the pools

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/running_costs/running_costs.script.lua`

**Interfaces:**
- Consumes: Task 1 `addPool`; existing `sample()` locals `rc` per vehicle (collect them in a table `rcOf[v]` during the vehicle loop).
- Produces in the saved state (read by Task 4):

```lua
s.pool        = { [building] = Ring (cost_history.new, with first) }
s.maintainedBy = { [vehicle] = { [building] = lastSeenMs } }   -- buildings that listed v, pruned older than the window
s.poolInfo    = { buildings = n, entries = m }                  -- for the perf line
```

- [ ] **Step 1: In `sample()`, after the vehicle loop:** `local okD, depots = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.VEHICLE_DEPOT)`; for each `d`: `local okP, dep = pcall(api.engine.getComponent, d, VEHICLE_DEPOT)`; skip unless `dep.maintenancePool > 0`; `local okL, list = pcall(transportVehicleSystem.getVehiclesForMaintenanceStation, d)`; for each `v` in `list`: `cond = pcall(getVehicleMaintenanceState, v)` (nil on failure), `rc = rcOf[v] or 0`, `history.addPool(ring, now, dtMs, v, rc, cond, yearMs)` with `ring = s.pool[d] or history.new(now)`; `s.maintainedBy[v][d] = now`. Count buildings and entries into `s.poolInfo`.
- [ ] **Step 2: Sweeps** (in the existing 60 s sweep): drop `s.pool[d]` when `d` no longer exists; drop `maintainedBy[v][d]` entries older than `yearMs`, then empty `maintainedBy[v]` tables. Vehicles inside the pool rings need no sweep: their buckets age out with the ring.
- [ ] **Step 3: `STATE_VERSION = 4`, `VERSION = "0.3.0"`**; initialise `pool = {}`, `maintainedBy = {}` in the fresh state; extend the perf line with `"%d buildings, %d pool entries"`.
- [ ] **Step 4: `luajit -bl`; run the suite; `./sync.sh`.**
- [ ] **Step 5: In-game check (user, together with Task 4):** perf line shows buildings/entries and stays within ~1 ms more than before; no `error` lines.
- [ ] **Step 6: Report** files + `feat: sampler records maintenance pools per building`.

---

### Task 3: Fee rows (pure)

**Files:**
- Create: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/fee_rows.lua`
- Test: `test/fee_rows_test.lua`

**Interfaces:**
- Consumes: the `windowPool` entry shape `{ s, fee, good, full, c0 }` and `maintainedBy[v]`.
- Produces: `M.build(entries, building, maintainedBy) : Table` with
  `Table = { fee, goodShare | nil, fullShare | nil, elsewhereShare | nil, rows = { { v, seconds, fee, c0, elsewhere = { buildings except `building` } } }, empty }` where `goodShare = Σ fee × good/s over vehicles / Σ fee` (fee-weighted: each vehicle's fee attributed to good time by its share of good seconds), `fullShare` likewise with `full`, `elsewhereShare = (Σ over vehicles with ≥ 1 other building of fee × good/s) / (Σ fee × good/s)` (nil when the denominator is 0); shares nil when `fee == 0`; rows sorted by `fee` desc, ties by `v`; `empty = (#rows == 0)`; `M.minutes` reused from `cost_rows` (pass it in or duplicate: duplicate the 4-line function, keep modules independent).

- [ ] **Step 1: Write the failing test** `test/fee_rows_test.lua`:

```lua
local E = {
  [7] = { s = 600, fee = 6000, good = 300, full = 0, c0 = 0.5 },    -- half the time good
  [8] = { s = 300, fee = 3000, good = 300, full = 300, c0 = 1.0 },  -- always full
  [9] = { s = 100, fee = 0, good = 100, full = 100, c0 = nil },     -- zero fee vehicle
}
local MB = { [7] = { [1] = 1, [2] = 1 }, [8] = { [1] = 1 }, [9] = { [1] = 1 } }
local T = M.build(E, 1, MB)
near("fee", T.fee, 9000, 1e-9)
near("good share (fee-weighted)", T.goodShare, (6000 * 0.5 + 3000 * 1.0) / 9000, 1e-9)
near("full share", T.fullShare, 3000 / 9000, 1e-9)
near("elsewhere share of the good part", T.elsewhereShare, (6000 * 0.5) / (6000 * 0.5 + 3000 * 1.0), 1e-9)
check("rows sorted by fee, zero-fee vehicle last", #T.rows == 3 and T.rows[1].v == 7 and T.rows[3].v == 9)
check("elsewhere from maintainedBy", #T.rows[1].elsewhere == 1 and T.rows[1].elsewhere[1] == 2 and #T.rows[2].elsewhere == 0)
check("row without entry condition", T.rows[3].c0 == nil)
check("empty", M.build({}, 1, {}).empty == true and M.build({}, 1, {}).goodShare == nil)
check("zero fee only", M.build({ [9] = E[9] }, 1, MB).goodShare == nil and M.build({ [9] = E[9] }, 1, MB).empty == false)
check("young ring works like any", M.build({ [7] = { s = 3, fee = 30, good = 0, full = 0, c0 = 0.2 } }, 1, {}).goodShare == 0)
```

- [ ] **Step 2: Run `luajit test/fee_rows_test.lua`** — Expected: FAIL (module not found).
- [ ] **Step 3: Implement `fee_rows.lua`.**
- [ ] **Step 4: Run the suite** — Expected: all `ok`. `luajit -bl`.
- [ ] **Step 5: Report** files + `feat: fee rows for the maintenance card`.

---

### Task 4: GUI card in the depot / maintenance building window

**Files:**
- Create: `content/gui/kampfmoehre_running_costs/station.res.lua` — `type = "react-plugin ::MaintenanceStationEowExtensionPoint"`, `filePath = "kampfmoehre_running_costs_1::/gui/kampfmoehre_running_costs/running_costs.script@MaintenanceFeePlugin"`, `order = 35`.
- Modify: `content/gui/kampfmoehre_running_costs/running_costs.script.lua`, `strings.json`.
- Reference: the vehicle plugin's `makeRow`-style card and `CostTable` in the same file; `game-src/gui/entity_window/maintenance_station/maintenance_station_eow.script.tl` (params: `entityId`, `ownershipState`, `getCollapsibleExpanded`/`setCollapsibleExpanded`, `gameCtx`, `showCalloutOnRightSide`).

**Interfaces:**
- Consumes: Task 1 `windowPool(ring, now, windowMs)`; Task 2 state (`pool[d]`, `maintainedBy[v]`); Task 3 `fee_rows.build`; existing `gsComponent()`, `incomeRingOf`-style native read, `entityName`, `money`, `fmt`, `yearMs`, `gameTime`, `BOOKING_LUMP_MS`.
- Produces:
  - `poolRingOf(gs, d)` — `state_native:findPath({ "pool", d })` → `:asTable()`, same fallback pattern as `incomeRingOf` (copy of `gs.state.pool`).
  - `maintainedByOf(gs, v)` — `findPath({ "maintainedBy", v })`, fallback copy.
  - `bookedMaintenance(account, t0, t1)` — `calculateBalance({account}, t0, t1, true, api.type.JournalEntry.Maintenance.VEHICLE_MAINTENANCE)`, negated, nil below two lumps; `account = getConstructionEntityForDepot(d)` or `d`.
  - `feeData(d)` → `T = fee_rows.build(...)` plus `T.coverageMs`, `T.booked` (window), `T.year = bookedMaintenance(account, now − yearMs, now)`, `T.cNow[v]` from `getVehicleMaintenanceState` per row (pcall, nil → "–"), `T.names[b]` for buildings in `elsewhere` (entityName), `T.sig` for change detection; refreshed by `react.onStepTimer(…, SAMPLE_S)` in the recipe.
  - `FeeTable = react.RegisterRecipe("KampfmoehreRunningCostsFee", fn(p = { building }))`: header `running_costs_fee_header {minutes}`; `TableLayout{ columnWeights = { -1, -1, -1, -1, -1 } }` with header row (`running_costs_fee_col_vehicle`, `_minutes`, `_fee`, `_condition`, `_elsewhere`); per row: `entityName(v)`, `minutes(seconds×1000)` (`kampfmoehre-rc-num`), `money(fee)` (`negative, kampfmoehre-rc-money`), `string.format("%.2f → %s", c0, cNow and ("%.2f"):format(cNow) or "–")` (c0 nil → "–"), `#elsewhere` (`kampfmoehre-rc-num`) inside a `Component` whose tooltip lists `names`; footnote `running_costs_booked {amount}` when `T.booked`; empty → `running_costs_fee_none`.
  - `M.MaintenanceFeePlugin = react.RegisterPluginRecipe({ id = "::MaintenanceStationEowExtensionPoint" }, "KampfmoehreRunningCostsMaintenance", fn(params))`: returns an empty `BoxLayout` unless `params.ownershipState == "Player"`; otherwise a `content_card.ContentCard` like the vehicle row with `extraChildrenPermanent` = the collapsed line `fmt("running_costs_fee_line", { fee, pct = round(goodShare×100), elsewhere = round(elsewhereShare×100) })` (variants: `running_costs_fee_line_noelse` when `elsewhereShare == nil`, `running_costs_fee_line_raw` = just the fee when `goodShare == nil`), tooltip `running_costs_fee_tooltip` with `{full}` = round(fullShare×100) and `{year}` = money(T.year) ("–" when nil); `recipeAndParamCollapsible = makeRecipeAndParam(FeeTable, { building = params.entityId })`, `CARD_KEY = "kampfmoehreRunningCostsFee"`.
  - `strings.json` EN (exact): `running_costs_fee_header` "Maintenance fee of the last {minutes} min of game time", `running_costs_fee_line` "{fee} · {pct} % for vehicles already in very good condition, {elsewhere} % of that also covered elsewhere", `running_costs_fee_line_noelse` "{fee} · {pct} % for vehicles already in very good condition", `running_costs_fee_line_raw` "{fee}", `running_costs_fee_tooltip` "Every depot and maintenance building charges 25 % of the running costs of each vehicle inside its area that holds one of its slots, for as long as it stays, also at 100 % condition. {full} % of this fee went to vehicles at exactly 100 %. Booked by the game in the last year: {year}. Expand for the vehicles.", `running_costs_fee_col_vehicle` "Vehicle", `running_costs_fee_col_minutes` "min in pool", `running_costs_fee_col_fee` "Fee", `running_costs_fee_col_condition` "Condition", `running_costs_fee_col_elsewhere` "Elsewhere", `running_costs_fee_elsewhere_tooltip` "Also maintained in this window by:", `running_costs_fee_none` "no vehicles maintained yet".

- [ ] **Step 1: Write strings (EN + DE).**
- [ ] **Step 2: Implement reader, `feeData`, `FeeTable`, `MaintenanceFeePlugin`, `station.res.lua`; `VERSION = "0.3.0"`.**
- [ ] **Step 3: `luajit -bl`; suite; grep `for _,` in GUI files (none); `./sync.sh`.**
- [ ] **Step 4: In-game check (user):** single-truck save: open the depot window: the card sits under the pool bar; while the truck is repaired the line shows the fee and 0 % good, after 100 % the good share rises towards 100 %; expanded: one row "Strassenfahrzeug 1", minutes, fee, "0.xx → 1.00", elsewhere 0; footnote ≈ the finance window's "Maintenance Vehicles" for the span. Big save: Emmaboda Wartungsgebäude: good share ≈ 90 %+, several rows, elsewhere counts > 0 with names in the tooltip; on a train compare the row's condition with the game's "Zustand" column two cards below (report differences); perf line within budget; no `error`/"Global variable" lines. Report the row count of the busiest building (decides whether a cap is needed).
- [ ] **Step 5: Report** files, what the user confirmed, + `feat: maintenance fee card in depot and maintenance building windows`.

---

### Task 5: Docs and release preparation

**Files:**
- Modify: `README.md` (section "Maintenance fee" with the rule and the over-coverage reading), `CHANGELOG.md` (`## 0.3.0 (date)` incl. the depot bar colour fix), `mod.json` `revision` 4, `_metadata/modinfo.json` EN/DE (new paragraph + re-rendered changelog via `python3 -I ../changelog_to_modinfo.py tpf3-running-costs kampfmoehre_running_costs_1`), `/home/satan/dev/tpf3-modding/CLAUDE.md` mod-table row.

- [ ] **Step 1: Write the docs; bump the revision; render the description.**
- [ ] **Step 2: `./sync.sh`; Mod-Hub "reload" for strings/modinfo (user).**
- [ ] **Step 3: Report** files + `docs: 0.3.0 maintenance fee`. Gallery image of the card is the user's.
