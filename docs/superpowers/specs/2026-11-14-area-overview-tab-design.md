# Infrastructure upkeep overview tab in the finance window — design (2026-11-14)

Running Cost Breakdown 0.6.0, part 2 (ships in the same upload as the town card of
`2026-11-13-area-upkeep-design.md`): a tab "Infrastructure" in the game's finance
window that lists every town's area upkeep side by side, so the expensive areas
can be compared without opening sixteen town windows.

## Intent

The town card (part 1) answers "what does my infrastructure in this town cost".
The comparison "which towns cost the most, and in which category" needs all towns
in one table. The user first planned a separate mod window (mod button); on
2026-11-14 he preferred a tab in the finance window, "the place where one would
look anyway". The finance window's other tabs show history columns; this tab
shows the current yearly rate, like the station windows and the "Delivery Time"
tab, which is also a snapshot. The tab also carries the "next price step" line
(buildings' upkeep jumps every 20 game years), which did not fit the town card.
As always: figures only, no recommendations.

## Goals

- A tab "Infrastructure" after "Delivery Time" in the finance window
  (`game_mechanics/finance/account.tl`, recipe `FinanceAccount`, window id
  `menu.finance.window`).
- One row per town with the player's yearly infrastructure upkeep in that town's
  area: total and the eight categories of the town card, sorted by total
  descending; a sum row over all towns at the bottom (comparable with the
  finance table's "Upkeep …" rows summed over the carriers).
- The town name opens the town window (like vehicle names in the fee card).
- A line below the table with the next price step for buildings:
  "Buildings and warehouses: next price step 1980 (+25 %)".
- The scan is the one of part 1 (same cache, same slices, same 30 s refresh
  while the tab is open), nothing new is sampled or saved.

## Non-goals

- No per-category sub-rows (carriers, track types) in the overview: the town
  card has them, the row's name opens it.
- No history, no charts, no sorting by column (fixed: total descending).
- No change to the town card.
- No ranking language ("most expensive", "wasted").

## Anti-goals

- A broken finance window when the game changes its tab list: if our detection
  does not match, the finance window must render exactly as without the mod.
- A Lua error inside the base recipe `FinanceAccount` (our wrapper code runs
  inside it): every engine call stays in `pcall`, the wrapper never throws.
- Stylesheet growth beyond 2 rules (20 → 22; shared budget ≈ 600 across mods).

## Approaches considered

1. **Tab in the finance window via builtin wrappers** (chosen). The tab list is a
   literal inside `FinanceAccount`; there is no extension point for it. We wrap
   `builtin.TabWidgetChild` and `builtin.TabWidget` (the module table is shared
   with all base scripts, the same technique as Window Placement's `Window` and
   Preview Toggle's `FloatingLayout`/`FloatingLayoutChild` wrappers) and append
   our tab when the widget being built contains the game's `cargolifetime_tab`.
   Pro: where players look, no extra button. Con: two more builtin wrappers; a
   renamed base tab key makes our tab vanish silently (but breaks nothing).
2. **Own window behind a mod button** (`::MainModButtonAreaExtension` +
   `builtin.Window` via `game_react_globals.getDefaultWindowApi()`, Line Profit
   Auditor pattern). Pro: no hook, independent of base code. Con: one more
   button, discoverability.
3. **Columns in the statistics window's "Towns" tab**: column list is local
   too, and the user had already said there is no room there. Dropped.

## Where the tab lives: the injection

In `running_costs.script.lua`, installed once per GUI Lua state (the GUI script
is loaded at game start by `entry.res.lua`), guarded by a mod parameter (below):

- `builtin.TabWidgetChild` wrapper: forwards ALL arguments to the original
  (`X{params}` and `X(ref, params)` forms), remembers `nodeId → params.localKey`
  for the returned node in a small table (weak keys are not needed: node ids
  are numbers, keep the last ~32 entries or clear the table in the TabWidget
  wrapper after use).
- `builtin.TabWidget` wrapper: forwards all arguments; if `params.tabs` is a
  list containing a node whose recorded localKey is `"cargolifetime_tab"`, it
  copies the list, appends our child and passes the copy to the original:

  ```lua
  builtin.TabWidgetChild{
      localKey = "kampfmoehre_rc_area_tab",
      value = "KampfmoehreRunningCostsArea",
      indicator = builtin.TextView{ meta = { class = "font-scale-tab-widget-indicator" }, text = _("running_costs_area_tab") },
      item = AreaOverview{ meta = { tag = "menu.finances.kampfmoehre-area" } },
  }
  ```

  The wrapper executes inside `FinanceAccount`, so calling our recipe there only
  creates a node (its body runs later, as its own recipe). The detection via the
  recorded key does not need the recipe identity (`FinanceAccount` is a local of
  `account.tl` and not exported, so `react.GetRecipeId` is not available).
- Any other TabWidget passes through untouched. The wrapper must not use react
  hooks (it also runs inside recipes we do not control).
- **Only the selected tab scans** (builder-check decision): a TabWidget child's
  recipe body runs while another tab is shown (the base `FinancesCharts` /
  `FinancesAssets` take a `tabValue` param for that reason), so mount-based
  triggering would start a scan whenever the finance window opens on any tab
  and refresh it every 30 s. Instead the wrapper mirrors the selection without
  hooks: module-level `areaTabCurrent` starts from `params.initialValue` and is
  updated by a wrapped `params.onValueChange` (which also calls the original);
  `FinanceAccount` re-renders on every tab change (its own `tabState:set`), so
  the wrapper runs again and passes `selected = (areaTabCurrent == "KampfmoehreRunningCostsArea")`
  to `AreaOverview`. The recipe calls `areaWant()` and keeps the 1 s re-trigger
  only while `selected`; it still re-renders on `AREA_EVENT`. Whether a hidden
  tab's subtree (`useChildPausedModes`) receives events or timers is unknown and
  no longer matters: the selected flag arrives through a fresh render.
- **Not without a player** (builder-check decision, minor): the finance window
  also exists in the map editor; the wrapper skips the injection when
  `api.engine.util.getPlayer()` (pcall) is nil or negative. No editor flag is
  threaded through.
- Mod parameter `finance_tab` (Off/On, default On, `mod.json` `params` like Rate
  Preview's; `api.engine.config.getModParams()["kampfmoehre_running_costs_1"]
  ["finance_tab"]`, value 2 = On) decides whether the wrappers are installed at
  all. Reason: a second mod that wraps the same builtins could conflict; the
  user can then switch the tab off and keep the town card.

## Content of the tab (`AreaOverview` recipe, `KampfmoehreRunningCostsAreaOverview`)

Layout like the other finance tabs: a vertical `BoxLayout` with class
`content-layout` containing a `content_card.ContentCard{ title = _("running_costs_area_overview_title") }`
("Infrastructure upkeep per town area") as heading, a `builtin.ScrollArea`
(vertical as needed) holding the table, and the annotation lines below.

Table (`builtin.TableLayout`, header row + one row per town + sum row):

| Town | Total | Stations | Depots | Maintenance buildings | Warehouses | Other buildings | Tracks | Roads | Signals |
|---|---|---|---|---|---|---|---|---|---|

- Header texts = the town card's category strings (`running_costs_area_<key>`),
  class `font-scale-annotation`, numbers right-aligned (`kampfmoehre-rc-money`).
  The header carries the unit once ("per year", `running_costs_area_per_year`
  in the card title or as a sub-line: builder's choice), the cells show
  `money(x)` without the "/Year" suffix (ten columns must fit 1488 px).
- Town name = `builtin.Button{ meta = { class = "kampfmoehre-rc-namebutton" },
  content = …TextView, onClick = react.fireEvent(nil, "selectEntity", { entity = town, stack = true }) }`
  (as in `FeeTable`); name from `api.engine.util.getEntityName(town)` (pcall,
  fallback `tostring(town)`), cut like the fee table's `shorten`.
- Rows sorted by total descending, ties by name. Zero cells show "–" (not 0),
  a town with total 0 still gets a row (the player sees the area is free of his
  infrastructure); towns with 0 sort last.
- Sum row (bold): per column the sum over all towns; first cell
  `_("running_costs_sum")` (existing key). The Total sum equals the log line's
  "all towns" figure.
- Tracks/Roads cells carry the km in their tooltip
  (`running_costs_area_km` with the category label).
- While no scan result exists: one line `running_costs_area_calculating` (or
  "–" when the scanner gave up, as in the card).

Annotation lines below the table (`font-scale-annotation`):

- The next price step: from `api.res.getBaseConfig().treeCostYearMultipliers`
  (steps 1900 1, 1920 1.5, 1940 2.2, 1960 3.2, 1980 4, 2000 5, 2020 6 in the
  base game; the builder checks the Lua shape of that table, a map or a list of
  pairs, and normalises it to a sorted list `{ {year, factor}, … }`) and the
  current calendar year (`api.engine.util.getCalendarDate(gameTime).year`, as
  `area_env.begin` does): the first step with `year > current`; text
  `running_costs_area_next_step` = "Buildings and warehouses: next price step
  {year} (+{percent} %)" with percent = round((next/current − 1) × 100); after
  the last step: `running_costs_area_no_step` = "Buildings and warehouses: no
  further price step". Tracks, roads and signals do not step (the tooltip of the
  line says so: `running_costs_area_next_step_tooltip` = "The game raises the
  upkeep of buildings in steps every 20 years (1920, 1940, …, 2020). Tracks,
  roads and signals keep their rate.").
- The explanation of part 1's Total tooltip as a second line
  (`running_costs_area_total_tooltip`, already wrapped in three lines; use its
  first sentence only or show it as tooltip of the heading: builder's choice).

Pure helpers in `area_upkeep.lua` (luajit-tested):

- `M.overview(acc, towns, labelOf) -> { rows = { { town, total, cats = { [cat] = amount }, meters = { tracks = m, roads = m } } … }, sum = { total, cats = {…} } }`
  built from `M.rows` per town, sorted total desc; `towns` = `S.towns()`.
- `M.nextPriceStep(steps, year) -> { year, percent } | nil` with `steps` the
  normalised sorted list; nil after the last step; the current factor is the
  last step with `year <= current` (1 before the first step).

Scanner: `S.rows(town)` / `S.grandTotal()` exist (part 1). `S.towns()` today
lists only towns that received an entry; the scanner stores the scanned town
list (`env.towns()` at start) in the result so `S.towns()` returns every town,
also those with total 0 (small change + test in `area_scan_test.lua`). The tab
recipe counts itself like a card (`areaCards`, `areaWant()` on mount and on the
1 s timer, re-render on `AREA_EVENT`) but only while `selected` (see above), so
selecting the tab starts or refreshes the scan exactly like a town window and
the other finance tabs cost nothing.

## Strings

New keys EN/DE (uk = EN placeholder): `running_costs_area_tab` ("Infrastructure" /
"Infrastruktur"), `running_costs_area_overview_title` ("Infrastructure upkeep per
town area, per game year" / "Infrastruktur-Unterhalt pro Stadtgebiet, pro
Spieljahr"), `running_costs_area_col_town` ("Town" / "Stadt"),
`running_costs_area_next_step`, `running_costs_area_no_step`,
`running_costs_area_next_step_tooltip` (texts above; DE: "Gebäude und Lagerhäuser:
nächste Preisstufe {year} (+{percent} %)", "Gebäude und Lagerhäuser: keine weitere
Preisstufe", "Das Spiel erhöht den Unterhalt von Gebäuden alle 20 Jahre stufenweise
(1920, 1940, …, 2020). Gleise, Strassen und Signale behalten ihren Satz."),
param strings `running_costs_param_finance_tab_name` ("Finance window tab" /
"Tab im Finanzfenster"), `running_costs_param_finance_tab_tooltip` ("Adds the
tab 'Infrastructure' (upkeep per town area) to the finance window. Switch off if
another mod changes that window's tabs." / "Fügt dem Finanzfenster den Tab
'Infrastruktur' (Unterhalt pro Stadtgebiet) hinzu. Ausschalten, falls eine andere
Mod die Tabs dieses Fensters verändert."), `running_costs_param_off`/`_on`
("Off"/"On", "Aus"/"Ein"; no such keys exist yet). Param read like Preview Toggle's
`applyModParams`: pcall `api.engine.config.getModParams()`, value 2 = On, default
On when absent.

## Stylesheet

At most two new rules: `R::KampfmoehreRunningCostsAreaOverview BoxLayout!content-layout`
(gravity {-1,-1}, innerSpacing {8,8}, like the base finance tabs) and
`R::KampfmoehreRunningCostsAreaOverview TextView` padding appended as one more
comma part to the existing padding rule (+1). The namebutton/money classes are
already unscoped. Count after: ≤ 22.

## Versioning and docs

Still 0.6.0 (unreleased, revision 10): CHANGELOG 0.6.0 entry gets a bullet for
the tab and the parameter, README section of part 1 gets a paragraph + the tab
in "How it works", hub sentence gets a second sentence ("The finance window gets
a tab 'Infrastructure' with all towns side by side and the year of the next
price step for buildings."). Gallery image `6.png` from the user later.

## Testing

- luajit: `overview` (sorting, zero town last, sums, meters), `nextPriceStep`
  (before first step → 1920 +50 %, 1961 → 1980 +25 %, after 2020 → nil, exact
  step year counts as reached).
- In game (user): finance window opens unchanged with the parameter Off; with
  On the sixth tab "Infrastruktur" appears after "Lieferzeit"; opening the
  finance window on "Übersicht" and leaving it there writes no `area scan:` log
  line (only selecting our tab does); table with all 16
  towns sorted, sum row equals the log line's "all towns" figure and the town
  cards' totals, name opens the town window, next step line reads "1980 (+25 %)"
  on the big save (1961) and "2020 (+20 %)" on the 2010 test save; no stutter; the tab survives switching tabs and reopening the
  window; `Reload UI` keeps working.
- `luajit -bl` on changed scripts; rule count ≤ 22.

## Later

- Gallery image, Ukrainian strings from Altmano61.
- If a conflict report arrives: detect foreign wrappers of `TabWidget`
  (`react.GetRecipeId` nil check as in Window Placement) and log a hint.
