# Maintenance Fee Breakdown (Running Cost Breakdown 0.3.0) — design

Date: 2026-10-31. Third feature of `kampfmoehre_running_costs_1` (repo `tpf3-running-costs/`). Builds on the
cost sampler (`running_costs.script.lua`, per-vehicle histories in `cost_history.lua`, state saved with the
game), the income collector (0.2.0) and the GUI card patterns. Read
`2026-10-20-running-cost-breakdown-design.md` first; conventions in `../../../CLAUDE.md` (section
"Ideas / backlog", entry "Maintenance Vehicles", holds the measured mechanics).

## Intent

The finance window's category "Maintenance Vehicles" is a pool fee, not a repair price: every depot or
maintenance building charges 25 % of the running-cost rate of every vehicle inside its catchment area that
holds one of its slots, for as long as the vehicle stays, also when the vehicle is already at 100 %
condition (on the big save 96 % of the charged pool entries were healthy vehicles). Players place
maintenance buildings to cover as many lines as possible, because poor condition raises noise and
pollution and lowers comfort and therefore income. Since the fee runs regardless of need, over-coverage
costs money without benefit. The player wants to open a building's window and see how much of its fee
went to vehicles that were already fine, and whether those vehicles are covered by other buildings too,
to decide between keeping, moving and removing the building.

## Mechanics (measured, see CLAUDE.md)

- Fee per maintained vehicle per minute = `0.25 × getRunningCost(v) × 60 / 1461`, booked every 60 s of
  game time on the account of the building's construction, pro rata by seconds in the pool. Running cost
  includes the condition surcharge, so the fee falls while the vehicle recovers.
- A vehicle is in a building's pool when it is inside the catchment area (parked or driving) and a slot
  (`VehicleDepot.maintenancePool`) is free; `transportVehicleSystem.getVehiclesForMaintenanceStation(d)`
  lists the pool, `tv.maintenanceStation` names the building from the vehicle's side.
- Condition rises +0.0024 per 2 s while maintained (0 → 1 in ~14 min). The game calls condition ≥ 0.8
  "Very good" (`vehicle_store_util.tl:231`, five bands of 0.2).
- Depots with a pool and maintenance buildings both open the maintenance-station entity window
  (`view_manager.tl:560`: only pool-less depots open the manager window); its extension point is
  `::MaintenanceStationEowExtensionPoint` with plugins pool 20, balance 30, statistics 40, vehicles 50;
  the plugin gets `entityId` (the `VEHICLE_DEPOT` entity for depots and maintenance buildings alike).
  **The game's balance plugin (order 30) never renders in build 40425**: `maintenance_station.tl` never sets
  `state.constructionHasAccount`, so its condition is false; the window shows pool bar, statistics and
  vehicles only (confirmed by the user's screenshots). Our card is therefore the only money figure in
  that window.

## Goals

1. In the window of a depot or maintenance building, a collapsible card "Maintenance fee of the last
   N min of game time" at order 35 (between the pool bar and the statistics graph, where the game's
   dormant balance card would sit) showing, collapsed: the fee of the rolling window, the share of it
   charged for vehicles that were already "Very good" (≥ 0.8), with the share for vehicles at exactly 1.0
   in the tooltip, and of that wasted share how much went to vehicles that another building also
   maintained inside the window ("also covered elsewhere"). Expanded: one row per vehicle that was in
   this pool during the window: name, minutes in this pool, its fee share, condition at entry → now, and
   a marker "elsewhere" when at least one other building maintained it in the window (names of those
   buildings in the row tooltip). Rows sorted by fee, descending, **all of them** (my call after the
   builder check: a busy building may list 20-60 vehicles; a cap or a split "in the pool now / earlier"
   is decided from the user's feedback on the first in-game version, not up front). Footnote: "booked by
   the game: €X" from the construction's account (type `VEHICLE_MAINTENANCE`, two-lump rule) and, as the
   game's own figure is missing from this window, the booked amount of the last default year in the
   card's title line ("last year: €Y").
2. Same rolling window, coverage header, saved state and state-version semantics as the cost table; the
   fee is derived from the sampler's existing per-vehicle data (running cost already read every sample)
   plus the pool membership read per building.
3. Zero influence on the simulation (cosmetic).
4. EN/DE texts; the depot bar colour fix (committed, no changelog entry yet) ships with this version
   (0.2.1 is folded into 0.3.0).

## Non-goals

- No list of all buildings sorted by waste (a statistics-window feature; backlog).
- No per-line view, no recommendation ("remove this building"), no change to the game's pool list.
- No "what would the condition be without this building" simulation.

## Anti-goals

- A sampler that reads a `TRANSPORT_VEHICLE` component per vehicle per sample again (that was the
  expensive thing); pool membership comes from the per-building list call (one call per building, ~30
  on the big save), the running cost is already in the per-vehicle summary.
- State growth proportional to buildings × vehicles × buckets without bound: per building only the
  vehicles that were in its pool inside the window, pruned with the ring.
- Numbers that swing with reloads (saved state, as the costs).

## Decided

### Data collection (cost sampler, engine side)

- Every sample (3 s): for each entity with a `VEHICLE_DEPOT` component and `maintenancePool > 0`, read
  `getVehiclesForMaintenanceStation(d)`; for each listed vehicle `v` add to the building's ring
  (`cost_history` ring keyed by building, bucket field `pool[v] = { s = seconds, fee = Σ 0.25 × rc/year × dt,
  good = seconds at condition ≥ 0.8, full = seconds at condition 1.0, c0 = condition at first sight in the
  bucket }`). `rc` and the condition come from the per-vehicle data the sampler already has
  (`staticOf`/`rc` are read anyway; the condition is `getVehicleMaintenanceState(v)`, one call per
  maintained vehicle, ~40-60 on the big save).
- Per vehicle a small set `maintainedBy[v] = { [building] = lastSeenMs }` kept in the sampler state so the
  GUI can show "also covered elsewhere" without scanning every building's ring; entries older than the
  window are dropped.
- Weighting/coverage: the building's ring gets its own `first` (the sampler's first sight of the
  building); `bucketWeight` applies as for the costs.
- `STATE_VERSION` 4 (new fields); old states rebuilt.
- Budget: the pool reads add ~30 list calls + ~50 condition calls per sample; expected < 1 ms, measured
  in the perf line (add "N buildings, M pool entries" to it).

### Presentation (GUI)

- New plugin recipe `MaintenanceFeePlugin` at `::MaintenanceStationEowExtensionPoint`, order 35, shown only
  when `extensionParams.ownershipState == "Player"` (the balance plugin's own rule); a `.res.lua` like the
  vehicle one.
- Reads the building's ring via `state_native:findPath({"pool", d})` (same path mechanics as the summaries)
  and the `maintainedBy` sets of its vehicles.
- Pure row builder `fee_rows.lua` (luajit-tested): `build(ring entries, windowMs, now, maintainedBy) →
  { fee, wastedGoodShare, wastedFullShare, elsewhereShare, rows = { { vehicle, seconds, fee, c0, cNow?,
  elsewhere = {buildings} } }, coverageMs, empty }`; `cNow` is read in the GUI per row (one call per row
  on refresh, acceptable: the window shows one building).
- Texts (EN; DE by the builder): header "Maintenance fee of the last {minutes} min of game time";
  collapsed line "{fee} · {pct} % for vehicles already in very good condition ({pctElsewhere} % of it also
  covered elsewhere)"; tooltip explains the fee rule in two sentences and names the 1.0 share; columns
  "Vehicle", "min in pool", "Fee", "Condition" (as "0.73 → 1.00"), "Elsewhere" (count, tooltip names);
  footnote "booked by the game: {amount}"; empty: "no vehicles maintained yet".
- Version 0.3.0, revision 4, CHANGELOG, README section "Maintenance fee", modinfo EN/DE.

## Left to the builder

- Exact bucket layout for `pool` entries and pruning of `maintainedBy`.
- Whether `getVehiclesForMaintenanceStation` works for all `VEHICLE_DEPOT` entities (depots with a
  pool) or only for maintenance buildings; the probe already used it on a road depot successfully.
- Condition measure: `api.engine.util.vehicle.getVehicleMaintenanceState(v)` as designed (one call per
  pool vehicle). The game's vehicle column two cards below uses the mean over parts
  (`vehicle_util.getAvgMaintenanceState`); compare both on a multi-part train during the single-save
  check and switch to the mean only if they differ (my call: the engine value is what the fee follows).
- The `elsewhere` marker's time basis (any overlap inside the window vs. simultaneous): any overlap
  inside the window, my call.
- Tests for the row builder: waste shares with mixed conditions, elsewhere detection, empty ring,
  coverage header.

## Verification

Single-truck save: truck repaired in the depot → the depot window shows the fee, condition 0.x → 1.00,
waste share rising to 100 % after the truck reached 1.0, footnote equal to the "Maintenance Vehicles" row of
the finance window for the same span within a lump. Big save: Emmaboda Wartungsgebäude shows ~4 rows, waste share ≈ 96 %, elsewhere marks on
vehicles whose lines cross other buildings; perf line within budget; no errors.
