# Changelog

## 0.5.0 (2026-11-02)

- Airport windows (station groups with an airport) show "Missed approaches: N in the last 24 min": the aborted
  landing approaches of all aircraft heading for that airport, so the bottleneck airport can be told from the
  lines that suffer (mod.io request). The go-around already detected by `holding.step` is counted a second
  time for the station group of the aircraft's current line stop (two component reads per go-around, nothing
  per sample; `airport_counts.lua`, tested). One bucket ring per airport in the state under `airG`, created on
  the first go-around and pruned when the airport is gone or its window is empty. "–" until the sampler has run.

## 0.4.1 (2026-11-01)

- Fix: cargo handed over between lines (warehouses, transfer chains) was credited entirely to the vehicle
  of the last leg; the earlier legs showed "no income yet" next to a booked amount, and on a vehicle
  with a second cargo delivered directly that cargo absorbed the booked money (mod.io report). The game
  raises one `OnCalcTicketPrice` event per item at the final delivery with the whole journey's base
  price; the collector now splits it over the vehicles of all legs from `SIM_CARGO.pickupPoints`,
  proportional to the straight-line leg lengths (`income_legs.lua`, tested). Each leg counts the item once.
- The income perf line counts the items split over legs.
- Fix: the capacity column of the income table followed the load configuration currently on the
  wagons (`config.capacities`), so a multi-cargo wagon showed "–" for the cargo it was not carrying
  at that moment; it now uses `config.allCaps`, the capacity over all load configurations.

## 0.4.0 (unreleased)

- New cost class "holding pattern" for aircraft circling for a free runway or hovering in the landing
  queue and for ships waiting for a berth (mod.io request by x4dzior): detected from the engine's flight
  state falling back (Landing/Approach → Flight), hovering below 5 m/s in flight, or ships below 1 m/s in
  the harbour approach zone; charged at 100 % like driving. The row label counts the aborted approaches
  in the window ("holding pattern (3 go-arounds)"); the live line shows "holding".
- New cost class "waiting at station" for road, tram and rail vehicles standing in the approach of a
  station because no terminal or platform is free (the lorry queue before a loading bay); standing at
  signals or in traffic stays "waiting en route". Detected from `MOVE_PATH.dyn.approachingStation`
  (measured in `docs/probes/station_probe/`, one 1-3 µs read per standing vehicle).
- The maintenance-fee card's headline share is now the fee charged for vehicles at exactly 100 %
  condition (nothing left to repair); the game's "very good" band (80 % and better) read 100 % on almost
  every building of a well-covered network and moved to the tooltip. "Also covered elsewhere" is a share
  of the 100 % part.
- `holding.lua` (pure, luajit-tested) holds the rules; the sampler reads `MOVE_PATH_AIRCRAFT` /
  `AIRCRAFT` only for aircraft and ships en route (carrier cached per vehicle); state tables `statC`,
  `airF`, `airH`, `airS`, bucket field `g`; STATE_VERSION unchanged.

## 0.3.1 (2026-10-31)

- Smaller saved state, same display: each closed time bucket of the per-vehicle cost and income
  histories is stored as one packed string instead of a table of fields, and the per-vehicle summaries
  as flat fields. The game copies the whole sampler state in and out on every sample and pays per
  element (measured with a probe, `docs/probes/state_probe/`), so the copy time halves: on a save with
  ~380 vehicles the sampler takes about 15 ms instead of 20 ms per 3 s of game time on one simulation
  thread, with the state at ~25 000 elements instead of ~54 000.
- The perf log line now prints the mean over the samples since the previous line (and the share spent
  in the history code), not one sample.
- The saved history is rebuilt once on the first load with 0.3.1.

## 0.3.0 (2026-10-31)

- Depot and maintenance building windows get a "Maintenance fee" card: the "Maintenance Vehicles"
  fee the building charged in the last default game year, how much of it went to vehicles that were
  already in very good condition (80 % and better), and how much of that to vehicles another building
  also maintained in the window. Expand it for the vehicles, sorted by fee: minutes in the pool, fee
  share, condition at entry and exit of the latest visit, and the other buildings (tooltip). A click on
  the name opens the vehicle window; its tooltip shows the full name and the line.
- The fee rule, measured in game: every depot or maintenance building charges 25 % of the running costs
  of each vehicle inside its area that holds one of its slots, per second it stays, also at 100 %
  condition. The card does not change it; it shows which buildings mostly pay for healthy vehicles.
- The "in depot" bar of the cost table uses a readable blue instead of a dark grey.
- The sampler costs about 2 ms more per 3 s of game time on a save with 379 vehicles and 48 depots
  (18 → 20 ms on one simulation thread), see the README.
- The saved cost history is rebuilt once on the first load with 0.3.0 (new state format).

## 0.2.0 (2026-10-22)

- Income per cargo type under the cost table, for lines and vehicles: items, income, income per item,
  on-time share and the consist's capacity for the cargo; passengers as one row; a Result line
  (income minus running costs of the window).
- Income is scaled to what the game booked on the line's or vehicle's account in the same window;
  the footnote says which. Without a readable account base prices are shown and the Result is "–".
- A second game script collects the paid items (a few seconds behind the game); it changes no prices.
- The saved cost history is rebuilt once on the first load with 0.2.0 (new state format).

## 0.1.1 (2026-10-21)

- "1 vehicle with less data" in the singular.
- The oldest part of the window is weighted against the data that actually exists there, so a history that
  started mid-bucket no longer under-counts for its first minutes with a full window.
- A vehicle that lags a few seconds behind the others between two reads no longer flickers into "less data".
- Less work per refresh in the windows; a state that keeps failing is rebuilt after ten attempts.

## 0.1.0 (2026-10-21)

- First release: live "Now €X/min" line in the vehicle window with the current rate, state and condition
  surcharge; expandable table of the last default game year (24 min of game time) by state: driving,
  waiting en route, at terminal (40 %), in depot (5 %), condition surcharge, sum.
- The same table for all vehicles of a line under the income graph of the line window's "Balance" card,
  with the amount booked by the game for comparison.
- The history is sampled every 3 s of game time and saved with the game.
