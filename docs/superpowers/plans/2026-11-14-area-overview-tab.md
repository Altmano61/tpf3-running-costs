# Infrastructure Upkeep Overview Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tab "Infrastructure" in the game's finance window listing every town's yearly infrastructure upkeep by category side by side, with a sum row and the next price step for buildings (Running Cost Breakdown 0.6.0, part 2).

**Architecture:** Two pure helpers in `area_upkeep.lua` (`overview`, `nextPriceStep`) and a one-line scanner change (`S.towns()` returns all scanned towns) carry the logic, luajit-tested. In `running_costs.script.lua` a wrapper pair around `builtin.TabWidgetChild` / `builtin.TabWidget` appends our `TabWidgetChild` to the finance window's tab list when it contains the game's `cargolifetime_tab`, mirrors the selected tab without hooks, and a new recipe `AreaOverview` renders the table from the part-1 scanner. A mod parameter `finance_tab` gates the wrappers.

**Tech Stack:** Lua 5.1 / LuaJIT, the game's React-like GUI (`react.lua`, `builtin.lua`, `content_card.tl`), luajit for tests, `luajit -bl` for syntax.

**Spec:** `docs/superpowers/specs/2026-11-14-area-overview-tab-design.md` (part 1: `docs/superpowers/specs/2026-11-13-area-upkeep-design.md`, already built in commits `afc2beb..494c8f1`).

## Global Constraints

- Repo root for every command: `/home/satan/dev/tpf3-modding/tpf3-running-costs`; mod directory `kampfmoehre_running_costs_1/`.
- Lua 5.1 / LuaJIT; `luajit -bl <file> > /dev/null` on every changed script. Never `_` as a loop variable in GUI code (use `__`, `___`). No `rawget`/`rawset`, no globals.
- Every engine call in GUI code is inside `pcall`; the builtin wrappers never throw and forward ALL arguments (`X{params}` and `X(ref, params)` forms: `local params = select(select('#', ...), ...)`), and use no react hooks.
- Stylesheet rule count after this plan ≤ 22 (count = comma-separated selector parts over all `a("…")` calls in `running_costs.css.lua`; today 20).
- Strings EN first, DE with "ss" (no "ß"), `uk` = EN placeholder; keys prefixed `running_costs_area_` (tab/overview) or `running_costs_param_` (parameter). `strings.json` rewritten only with `python3 -I` + `json.dump(d, f, indent=4, ensure_ascii=False)` + trailing newline (byte-identical format).
- Version stays `0.6.0` and `mod.json` `revision` 10 (unreleased); CHANGELOG 0.6.0 entry and README section of part 1 are extended, not duplicated.
- Scan only while our tab is selected (spec); the town card behaviour of part 1 is unchanged.
- The user commits himself unless he asked for commits for this plan at the handoff (he did for part 1); run `./sync.sh` after each GUI task so he can test; no upload.

## Review Focus

1. Finance window with the parameter Off, or a base tab list without `cargolifetime_tab`: the window renders exactly as without the mod (wrapper passes everything through). Task 4 has no unit test for the wrapper (GUI); the in-game step checks Off/On; the pure `tabInjectionIndex` helper (Task 4) is tested for "no cargolifetime key → nil".
2. A finance window opened on "Overview" and left open: no scan starts, no `area scan:` log line (Task 4 in-game step; `selected` is false until the wrapped `onValueChange` reports our value).
3. A town with total 0 (no player infrastructure): still a row, sorted last, cells "–" (Task 1 `overview` test; Task 2 `S.towns()` test).
4. Calendar year after the last multiplier step (2020+): the line reads "no further price step", no error (Task 1 `nextPriceStep` test returns nil).
5. `treeCostYearMultipliers` in an unexpected Lua shape (map vs list): the normaliser falls back to an empty list and the line is omitted instead of erroring (Task 3 `normaliseSteps` test for both shapes and garbage).

---

### Task 1: `overview` and `nextPriceStep` (pure, `area_upkeep.lua`)

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua` (append after `M.rows`)
- Test: `test/area_upkeep_test.lua` (append before the `if failures > 0` block)

**Interfaces:**
- Consumes: `M.rows(acc, town, labelOf)`, `M.CATEGORY_ORDER` (part 1).
- Produces:
  - `M.overview(acc, towns, labelOf) -> { rows = { { town, total, cats = { [cat] = amount }, meters = { tracks = m, roads = m } }… }, sum = { total, cats = { [cat] = amount } } }` — one entry per element of `towns` (also when the town has no data: total 0, empty `cats`, meters 0/0), sorted by `total` descending, ties by `town` ascending; `cats` holds only categories with a visible row (as `M.rows` returns them); `sum` adds over all rows for every key in `CATEGORY_ORDER` (0 when none).
  - `M.nextPriceStep(steps, year) -> { year = y, percent = p } | nil` — `steps` = sorted list `{ {year, factor}, … }`; current factor = factor of the last step with `step.year <= year` (1 when none); the first step with `step.year > year` is the next; `percent = round((next.factor / current − 1) × 100)`; nil when no later step or `steps` empty.

- [ ] **Step 1: Write the failing tests**

```lua
-- overview over all towns (acc from the rows block above: towns 1 and 2 have data)
local O = M.overview(acc, { 1, 2, 3 }, function(g) return g end)
check("overview sorted by total, empty town last", O.rows[1].town == 1 and O.rows[2].town == 2 and O.rows[3].town == 3 and O.rows[3].total == 0)
check("overview cats of a town", O.rows[1].cats.stations == 285000 and O.rows[1].cats.signals == 4125 and O.rows[1].cats.other_buildings == nil)
near("overview meters", O.rows[1].meters.tracks, 1200, 1e-9)
check("overview empty town shape", O.rows[3].meters.tracks == 0 and next(O.rows[3].cats) == nil)
near("overview sum total", O.sum.total, O.rows[1].total + O.rows[2].total, 1e-6)
near("overview sum tracks", O.sum.cats.tracks, 13000 + 9000 + 1300, 1e-6)
check("overview sum has every category", O.sum.cats.warehouses == 0 and O.sum.cats.roads == 2500)
check("overview without towns", #M.overview(acc, {}, tostring).rows == 0 and M.overview(acc, {}, tostring).sum.total == 0)
-- next price step (base game: 1900 1, 1920 1.5, 1940 2.2, 1960 3.2, 1980 4, 2000 5, 2020 6)
local STEPS = { { 1900, 1 }, { 1920, 1.5 }, { 1940, 2.2 }, { 1960, 3.2 }, { 1980, 4 }, { 2000, 5 }, { 2020, 6 } }
local st = M.nextPriceStep(STEPS, 1961)
check("next step 1961 -> 1980 +25 %", st.year == 1980 and st.percent == 25)
st = M.nextPriceStep(STEPS, 2010)
check("next step 2010 -> 2020 +20 %", st.year == 2020 and st.percent == 20)
st = M.nextPriceStep(STEPS, 1850)
check("before the first step: factor 1 -> 1900 +0 %", st.year == 1900 and st.percent == 0)
st = M.nextPriceStep(STEPS, 1960)
check("exact step year counts as reached", st.year == 1980 and st.percent == 25)
check("after the last step", M.nextPriceStep(STEPS, 2020) == nil and M.nextPriceStep(STEPS, 2075) == nil)
check("no steps", M.nextPriceStep({}, 1950) == nil)
```

(`acc` is the accumulator built in the rows block of the existing test file; town 1 stations = 275000 + 10000, its `other_buildings` entry was added with 0 and is hidden.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/area_upkeep_test.lua 2>&1 | grep -v '^ok'`
Expected: `attempt to call field 'overview' (a nil value)`

- [ ] **Step 3: Implement `M.overview` and `M.nextPriceStep` in `area_upkeep.lua`**

`overview` builds each row from `M.rows(acc, town, labelOf)` (`cats[r.key] = r.amount`, `meters.tracks/roads = r.meters` for those keys).

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/area_upkeep_test.lua | tail -1`
Expected: `all ok`

- [ ] **Step 5: Commit**

```bash
git add kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua test/area_upkeep_test.lua
git commit -m "feat(area): overview rows over all towns and the next price step"
```

---

### Task 2: `S.towns()` lists every scanned town (`area_scan.lua`)

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/running_costs/area_scan.lua` (`S.start` stores the town list, phase 4 copies it into `result`, `S.towns()` returns it)
- Test: `test/area_scan_test.lua`

**Interfaces:**
- Produces: `S.towns() -> { town… }` = the list `env.towns()` returned at `S.start()` (sorted ascending), nil without a result. `result = { at, acc, towns }`.

- [ ] **Step 1: Change the failing test** — in the fake env make `towns` return `{ 1, 2, 3 }` (town 3 has no constructions: `constructionsOf(3)` returns `{}`), and replace the existing check `#S.towns() == 2` with:

```lua
check("towns of the result incl. empty ones", #S.towns() == 3 and S.towns()[3] == 3 and M.new(env, U).towns() == nil)
check("empty town has zero rows", S.rows(3).total == 0 and #S.rows(3).rows == 0)
```

Also update the stats assertion `S.stats().towns == 2` to `== 3`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/area_scan_test.lua 2>&1 | grep -v '^ok'`
Expected: `FAIL towns of the result incl. empty ones`

- [ ] **Step 3: Implement** — keep `scan.towns` (already fetched in `S.start`), set `result = { at = now, acc = scan.acc, towns = scan.towns }` in phase 4; `S.towns()` returns a sorted copy of `result.towns`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `luajit test/area_scan_test.lua | tail -1 && luajit test/area_upkeep_test.lua | tail -1`
Expected: `all ok` twice

- [ ] **Step 5: Commit**

```bash
git add kampfmoehre_running_costs_1/content/running_costs/area_scan.lua test/area_scan_test.lua
git commit -m "feat(area): scanner result lists every scanned town"
```

---

### Task 3: Year-multiplier normaliser and tab-injection helper (pure, `area_upkeep.lua`)

**Files:**
- Modify: `kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua`
- Test: `test/area_upkeep_test.lua`

**Interfaces:**
- Produces:
  - `M.normaliseSteps(t) -> { {year, factor}… }` sorted by year; accepts a map `{ [year] = factor }` (number keys), a list of pairs `{ {year, factor}, … }`, a list of records `{ { year = y, multiplier|factor|value = f }, … }`; anything else (nil, non-table, entries without two numbers) → `{}`. Keys/values may be strings of numbers (`tonumber`).
  - `M.tabInjectionIndex(keys, marker) -> integer | nil` — `keys` = list of localKey strings (or nil entries) in tab order; returns `#keys + 1` (append position) when `marker` is present, nil otherwise. (Tiny, but it is the one piece of the wrapper's decision that can be unit-tested.)

- [ ] **Step 1: Write the failing tests**

```lua
local N = M.normaliseSteps({ [1940] = 2.2, [1900] = 1, [1920] = 1.5 })
check("normalise map", #N == 3 and N[1][1] == 1900 and N[3][2] == 2.2)
N = M.normaliseSteps({ { 1920, 1.5 }, { 1900, 1 } })
check("normalise list of pairs", #N == 2 and N[1][1] == 1900 and N[2][2] == 1.5)
N = M.normaliseSteps({ { year = 1960, multiplier = 3.2 }, { year = 1940, factor = 2.2 } })
check("normalise list of records", #N == 2 and N[1][1] == 1940 and N[2][2] == 3.2)
check("normalise garbage", #M.normaliseSteps(nil) == 0 and #M.normaliseSteps("x") == 0 and #M.normaliseSteps({ "a", {} }) == 0)
check("normalise string numbers", M.normaliseSteps({ ["2000"] = "5" })[1][1] == 2000)
check("injection after cargolifetime", M.tabInjectionIndex({ "overview_tab", "finances_tab", "cargolifetime_tab" }, "cargolifetime_tab") == 4)
check("no injection without the marker", M.tabInjectionIndex({ "a", nil, "b" }, "cargolifetime_tab") == nil and M.tabInjectionIndex({}, "x") == nil)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/area_upkeep_test.lua 2>&1 | grep -v '^ok'`
Expected: `attempt to call field 'normaliseSteps' (a nil value)`

- [ ] **Step 3: Implement both functions** (`tabInjectionIndex` iterates `1..table.maxn(keys)` so nil holes do not stop it).

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/area_upkeep_test.lua | tail -1`
Expected: `all ok`

- [ ] **Step 5: Commit**

```bash
git add kampfmoehre_running_costs_1/content/running_costs/area_upkeep.lua test/area_upkeep_test.lua
git commit -m "feat(area): year-step normaliser and tab injection helper"
```

---

### Task 4: Strings, mod parameter, tab wrappers and the overview recipe

**Files:**
- Modify: `kampfmoehre_running_costs_1/strings.json` (+10 keys × 3 languages)
- Modify: `kampfmoehre_running_costs_1/mod.json` (`params`)
- Modify: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.script.lua` (0.6.0 section, lines ≈ 1157-1343: after `AreaTable`, before `M.TownCondition`; `M.EntryPlugin`; load log line)
- Modify: `kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.css.lua` (two rules)

**Interfaces:**
- Consumes: `area_upkeep.overview/nextPriceStep/normaliseSteps/tabInjectionIndex` (Tasks 1, 3), `S.towns()` (Task 2), existing script locals `areaScanner`, `areaScannerFailed`, `areaCards`, `areaWant()`, `AREA_EVENT`, `money`, `fmt`, `entityName(e)` (line ≈ 355), `shorten(name)` (≈ 882), part-1 string keys `running_costs_area_<category>`, `running_costs_area_km`, `running_costs_area_calculating`, `running_costs_area_total`, `running_costs_sum`.
- Produces: recipe `KampfmoehreRunningCostsAreaOverview`; module locals `areaTabCurrent`, `AREA_TAB_VALUE = "KampfmoehreRunningCostsArea"`, `AREA_TAB_MARKER = "cargolifetime_tab"`; wrappers installed by `installFinanceTab()` called from `M.EntryPlugin`'s `react.onMount` after reading the parameter.

- [ ] **Step 1: Strings** (python3 -I script, same as part 1 Task 6)

| key | en | de |
|---|---|---|
| running_costs_area_tab | Infrastructure | Infrastruktur |
| running_costs_area_overview_title | Infrastructure upkeep per town area, per game year | Infrastruktur-Unterhalt pro Stadtgebiet, pro Spieljahr |
| running_costs_area_col_town | Town | Stadt |
| running_costs_area_next_step | Buildings and warehouses: next price step {year} (+{percent} %) | Gebäude und Lagerhäuser: nächste Preisstufe {year} (+{percent} %) |
| running_costs_area_no_step | Buildings and warehouses: no further price step | Gebäude und Lagerhäuser: keine weitere Preisstufe |
| running_costs_area_next_step_tooltip | The game raises the upkeep of buildings in steps every 20 years (1920, 1940, …, 2020). Tracks, roads and signals keep their rate. | Das Spiel erhöht den Unterhalt von Gebäuden alle 20 Jahre stufenweise (1920, 1940, …, 2020). Gleise, Strassen und Signale behalten ihren Satz. |
| running_costs_param_finance_tab_name | Finance window tab | Tab im Finanzfenster |
| running_costs_param_finance_tab_tooltip | Adds the tab 'Infrastructure' (upkeep per town area) to the finance window. Switch off if another mod changes that window's tabs. | Fügt dem Finanzfenster den Tab 'Infrastruktur' (Unterhalt pro Stadtgebiet) hinzu. Ausschalten, falls eine andere Mod die Tabs dieses Fensters verändert. |
| running_costs_param_off | Off | Aus |
| running_costs_param_on | On | Ein |

Run: `python3 -I -c "import json; d=json.load(open('kampfmoehre_running_costs_1/strings.json')); print(len(d['en']), len(d['de']), len(d['uk']))"`
Expected: `101 101 101`

- [ ] **Step 2: Mod parameter** in `mod.json` (`params` was `[]`), after Rate Preview's shape:

```json
"params": [
    {
        "defaultIndex": 1,
        "key": "finance_tab",
        "name": "running_costs_param_finance_tab_name",
        "tooltip": "running_costs_param_finance_tab_tooltip",
        "uiType": "Button",
        "values": ["running_costs_param_off", "running_costs_param_on"]
    }
],
```

(`defaultIndex` 1 = On; the read value is 1-based: 2 = On.)

- [ ] **Step 3: Stylesheet** — append `, R::KampfmoehreRunningCostsAreaOverview TextView` to the padding rule (the one listing `R::KampfmoehreRunningCostsAreaTable TextView`) and add

```lua
-- finance window tab (0.6.0): content block like the base finance tabs
a("R::KampfmoehreRunningCostsAreaOverview BoxLayout!content-layout", {
	gravity = { -1, -1 },
	innerSpacing = { 8, 8 },
})
```

Run: `grep -o 'a("[^"]*"' kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.css.lua | tr ',' '\n' | wc -l`
Expected: `22`

- [ ] **Step 4: Script — parameter, wrappers, recipe**

Add to the 0.6.0 section:

- `local AREA_TAB_VALUE = "KampfmoehreRunningCostsArea"`, `local AREA_TAB_MARKER = "cargolifetime_tab"`, `local areaTabCurrent = nil` (value of the finance window's selected tab as far as we know), `local areaTabInstalled = false`.
- `local function financeTabEnabled()` — pcall `api.engine.config.getModParams()`, `all["kampfmoehre_running_costs_1"]`, `mine.finance_tab`; nil/absent → true; else `== 2`. Log one line `"finance tab: on|off (mod param)"`.
- `local function playerPresent()` — pcall `api.engine.util.getPlayer()` → number ≥ 0.
- `local function lastArg(...) return select(select('#', ...), ...) end`.
- `AreaOverview = react.RegisterRecipe("KampfmoehreRunningCostsAreaOverview", function(p)` with `p.selected` (boolean):
  - `react.onMount`/`onUnmount` maintain `areaCards` as `AreaTable` does; `areaWant()` is called on mount and in the 1 s `onStepTimer` **only if `p.selected`**. The timer closure captures the `p` of the render that registered it; `FinanceAccount` re-renders on every tab change, so the recipe re-renders with a fresh `p` and the hooks are registered again (same pattern as `FeeTable`'s timer).
  - `react.useState(0)` + `react.onEvent(AREA_EVENT, …)` for re-render, like `AreaTable`.
  - Data: `S = areaScanner`; `towns = S and S.towns()`; nil → `calculating`/"–" line as in `AreaTable`. Else `O = area_upkeep.overview(S.result().acc, towns, env label)` — the scanner exposes no `env.templateLabel`; labels are not needed here (no template children), pass `tostring`.
  - Layout: `builtin.BoxLayout{ meta = { class = "content-layout" }, orientation = Vertical, children = { content_card.ContentCard{ title = _("running_costs_area_overview_title") }, builtin.ScrollArea{ content = builtin.Component{ layout = table }, horizontalPolicy = AsNeeded, verticalPolicy = AsNeeded }, stepLine, hintLine } }`.
  - Table: `builtin.TableLayout{ rows = rows, columnWeights = { 10, -1, -1, -1, -1, -1, -1, -1, -1, -1 } }`; header row (`localKey = "head"`): `cell(_("running_costs_area_col_town"), "font-scale-annotation")`, then for `"total"` and each key of `area_upkeep.CATEGORY_ORDER`: `cell(_("running_costs_area_" .. key), "font-scale-annotation, kampfmoehre-rc-money")`; one row per `O.rows` entry (`localKey = "t" .. town`): name cell = `builtin.Button{ meta = { class = "kampfmoehre-rc-namebutton", tooltip = fullName }, content = BoxLayout{ cell(shorten(fullName)) }, onClick = function() react.fireEvent(nil, "selectEntity", { entity = town, stack = true }) end }` with `fullName = entityName(town)`; amount cells `cell(amount >= 0.5 and money(amount) or "–", "font-scale-body, negative, kampfmoehre-rc-money")` (class without `negative` for "–"); tracks/roads cells get `meta.tooltip = fmt("running_costs_area_km", { label = _("running_costs_area_tracks"|"roads"), km = km(m) })` when m > 0; sum row (`localKey = "sum"`): `cell(_("running_costs_sum"), "font-scale-body, bold")` + bold money cells of `O.sum`.
  - `stepLine`: `steps = area_upkeep.normaliseSteps(baseConfig.treeCostYearMultipliers)` and `year` from `api.engine.util.getCalendarDate(gameTime.gameTime).year` (both pcall; read once per render, cached per module for 10 s is not needed: one render per event); `st = area_upkeep.nextPriceStep(steps, year)`; text `st and fmt("running_costs_area_next_step", { year = tostring(st.year), percent = tostring(st.percent) }) or _("running_costs_area_no_step")` as a `TextView{ meta = { class = "font-scale-annotation", tooltip = _("running_costs_area_next_step_tooltip") } }`; omitted entirely when `#steps == 0` or the year read failed.
  - `hintLine`: `TextView{ meta = { class = "font-scale-annotation" }, text = _("running_costs_area_total_tooltip") }`.
- `local function installFinanceTab()` — guarded by `areaTabInstalled`; `local origChild, origWidget = builtin.TabWidgetChild, builtin.TabWidget`; `local keyOf = {}` (node → localKey):
  - `builtin.TabWidgetChild = function(...) local params = lastArg(...); local node = origChild(...); if type(params) == "table" and type(params.localKey) == "string" then keyOf[node] = params.localKey end; return node end`.
  - `builtin.TabWidget = function(...)`: `params = lastArg(...)`; if not a table with a list `params.tabs`, or `not playerPresent()` → `return origWidget(...)`. Build `keys[i] = keyOf[params.tabs[i]]`; `idx = area_upkeep.tabInjectionIndex(keys, AREA_TAB_MARKER)`; nil → `origWidget(...)`. Else: `if areaTabCurrent == nil then areaTabCurrent = params.initialValue end`; copy params shallowly (`copy[k] = v for pairs(params)`), `copy.tabs` = copy of the list with our child appended (the `TabWidgetChild` from the spec, `item = AreaOverview{ meta = { tag = "menu.finances.kampfmoehre-area" }, selected = (areaTabCurrent == AREA_TAB_VALUE) }`); `local origOnChange = params.onValueChange; copy.onValueChange = function(v, ...) areaTabCurrent = v; if origOnChange then return origOnChange(v, ...) end end`; `keyOf = {}` (reset after use); call `origWidget` with the same argument count: `local n = select('#', ...); if n >= 2 then return origWidget(select(1, ...), copy) else return origWidget(copy) end` — more precisely replace only the last argument (a `ref` may precede it): collect `args = { n = n, ... }`, `args[n] = copy`, `origWidget(unpack(args, 1, n))`.
  - Everything inside the two wrappers is wrapped in `pcall`; on error log once and fall back to `origWidget(...)` / `origChild(...)`.
- `M.EntryPlugin`: in its body add `react.onMount(function() if financeTabEnabled() then installFinanceTab() end end)` (keep the existing `react.onStep(areaStep)`).
- Load log line: append `, finance tab`.

- [ ] **Step 5: Syntax, tests, sync**

Run: `for f in kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/*.lua kampfmoehre_running_costs_1/content/running_costs/*.lua; do luajit -bl "$f" > /dev/null || echo "FAIL $f"; done; for t in test/*_test.lua; do luajit "$t" > /dev/null || echo "FAIL $t"; done; echo done; ./sync.sh | tail -1`
Expected: `done` with no `FAIL`, then `synced -> …`

- [ ] **Step 6: In-game check (user)** — reload the big save: (1) log `… GUI loaded (…, finance tab)` and `finance tab: on (mod param)`; (2) finance window: sixth tab "Infrastruktur" after "Lieferzeit"; opening the window on "Übersicht" and waiting 40 s writes no `area scan:` line; (3) selecting "Infrastruktur": "wird berechnet …" briefly, then the table with 16 towns sorted by total, sum row = the log line's "all towns" figure, zero cells "–"; (4) town name opens the town window, its card total equals the row's total; (5) tracks/roads cell tooltip shows km; (6) step line "Gebäude und Lagerhäuser: nächste Preisstufe 1980 (+25 %)"; (7) switch tabs back and forth, close and reopen the window: tab persists, no error; (8) Mod-Hub: parameter "Tab im Finanzfenster" Aus → reload → window has five tabs, town card still works; (9) test save (2010): step line "2020 (+20 %)", Fellbach row shows "–" everywhere, Filderstadt row 150.000 under Depots. Fix, re-sync, repeat.

- [ ] **Step 7: Commit**

```bash
git add kampfmoehre_running_costs_1/strings.json kampfmoehre_running_costs_1/mod.json kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.script.lua kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/running_costs.css.lua
git commit -m "feat(area): infrastructure upkeep tab in the finance window"
```

---

### Task 5: Docs

**Files:**
- Modify: `CHANGELOG.md` (0.6.0 entry: bullet for the tab + parameter), `README.md` (part-1 section: paragraph on the tab and the parameter; "How it works": the wrapper pair and the selected-tab mirroring; mention `6.png` placeholder as image line once the user provides it)
- Modify: `/home/satan/dev/tpf3-modding/CLAUDE.md` (Running Cost Breakdown row: finance tab, wrapper pattern `TabWidgetChild` key recording + `TabWidget` injection, param `finance_tab`, rule count 22, strings 101)

- [ ] **Step 1: Write the three edits.** Hub sentence for the user (EN, to append to the 0.6.0 bullet): "The finance window gets a tab 'Infrastructure' with all towns side by side and the year of the next price step for buildings; a mod setting can switch the tab off." DE: "Das Finanzfenster erhält einen Tab 'Infrastruktur' mit allen Städten nebeneinander und dem Jahr der nächsten Preisstufe für Gebäude; eine Mod-Einstellung kann den Tab abschalten."

- [ ] **Step 2: Verify**

Run: `grep -c 'finance_tab\|Finanzfenster\|finance window' CHANGELOG.md README.md`
Expected: both counts ≥ 1

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md README.md
git commit -m "docs: finance window tab for the area upkeep (0.6.0)"
```
