# Holding pattern row (Running Cost Breakdown 0.4.0) — design

Date: 2026-11-01. Fourth feature of `kampfmoehre_running_costs_1` (repo `tpf3-running-costs/`). Builds on
the cost classes (`cost_classes.lua`), the sampler (`running_costs.script.lua`) and the cost table. Read
`2026-10-20-running-cost-breakdown-design.md` first; the measurements behind the rules are in
`docs/probes/holding_probe/README.md`.

## Intent

A mod.io user (x4dzior, playing at 150 % costs) asked whether aircraft that go around because the runway is
occupied should count as "waiting en route" rather than "driving". The game charges 100 % either way, but the
orange row exists to expose time that is paid for without progress, and circling aircraft, hovering helicopters
and ships queueing for a berth are exactly that. Today they count as "driving" because they move faster than
the 0.5 m/s standing threshold.

## Goals

1. A fifth cost class `holding` ("holding pattern" / DE "Warteschleife"), factor 1.0, orange like waiting, in
   the vehicle window's live line, the vehicle table and the line table. Rows appear only when the class has
   time in the window (existing rule), so road and rail vehicles never show it.
2. Aircraft: the row's label carries the number of aborted approaches in the window, e.g.
   "holding pattern (3 go-arounds)", because the count is the figure a player acts on (more runways, fewer
   aircraft, longer line).
3. Zero influence on the simulation; cost per sample stays negligible (air and water vehicles are few).

## Non-goals

- No change to the classification of road and rail vehicles, no path reading, no prediction.
- No separate "waiting for berth" class: ships share `holding` (label "holding pattern / waiting for berth"
  is avoided; the row tooltip explains both).

## Decided

### Detection (sampler, every 3 s of game time, EN_ROUTE and GOING_TO_DEPOT vehicles only)

- Carrier: cached per vehicle in a flat state table `statC[v]` (AIR / WATER / other as 1 / 2 / 0), read from
  the `TRANSPORT_VEHICLE` component the sampler already fetches in `staticOf` (re-read with the static rate).
  Only AIR and WATER vehicles get the extra reads below.
- Aircraft (`MOVE_PATH_AIRCRAFT` → `aircraftState`, `AIRCRAFT` → `reservedLandingRunway`), per vehicle
  memory in flat state tables `airF[v]` (last flight state) and `airH[v]` (1 while holding):
  - a drop of the flight state from Landing or Approach to Flight, or from Landing to Approach, between two
    samples starts a holding episode and counts one aborted approach (bucket field `g` via a generic
    `cost_history.addCount(h, nowMs, "g", 1)`);
  - the episode ends when the vehicle is in Landing with the runway reserved, in Landing below half its
    cruise altitude, in Taxi0/Taxi1, not EN_ROUTE any more, or when its `stopIndex` changes;
  - hovering: flight state Flight with speed below 5 m/s (helicopters in the landing queue) counts as holding
    for that sample without an episode (aircraft never fly below 5 m/s in Flight).
- Ships (`MOVE_PATH_AIRCRAFT` → `shipState.dyn.approachingStation`): approaching with speed below 1 m/s
  counts as holding for that sample. Ships standing elsewhere stay "waiting en route".
- `cost_classes.classify(stateName, speedMps, standingSpeed, holding)` gains the boolean: EN_ROUTE or
  GOING_TO_DEPOT with `holding` → "holding", checked before the standing test.
- Unknown values (missing components, nil fields) fall back to today's behaviour.

### Presentation (GUI)

- `cost_classes.CLASSES` gets `{ key = "holding", factor = 1.0, labelKey = "running_costs_class_holding",
  shortKey = "running_costs_short_holding", colour = "warn" }` after `waiting`; rows and the live line
  follow the list automatically.
- Label with count: `cost_rows.build` passes the window's `g` sum (`summary.g`, deflated like the rest) and
  the GUI renders `running_costs_class_holding` as "holding pattern" and, when g > 0,
  `running_costs_class_holding_n` "holding pattern ({n} go-arounds)" (singular key for 1).
- Tooltip on the row label (TextView `meta.tooltip`): "Aircraft circling for a free runway or hovering in the
  landing queue, ships waiting for a free berth. Charged at 100 % by the game like driving."
- EN/DE texts; README section; CHANGELOG (technical) entry; the mod-hub description is the user's.
- Version 0.4.0, revision 6; `STATE_VERSION` unchanged (new keys are optional, old histories simply have no
  holding seconds yet).

## Left to the builder

- Exact placement of the count in the summary (`g` as a flat summary field) and of `addCount` in
  `cost_history` (a bucket field summed in `window()` like the seconds, weighted pro rata).
- Whether GOING_TO_DEPOT aircraft can hold (treat like EN_ROUTE).
- Unit tests: classify with the holding flag; episode start/end rules as a pure function
  `holding.step(prev, now) -> state, goAround` in its own module (`holding.lua`, luajit-tested) fed with the
  probe's sequences (go-around at 44 m, cruise-altitude loop, helicopter hover, ship queue).

## Verification

Test save (`mods-test`): Flugzeug 2 shows several go-arounds and a holding share; helicopters show holding
while queued; ships show holding in the queue and "waiting en route" only when standing elsewhere; the big
save shows no holding rows for road and rail vehicles and no perf change.
