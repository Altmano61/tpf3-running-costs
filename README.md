# Running Cost Breakdown (Transport Fever 3)

A small UI mod for Transport Fever 3 that shows **where a vehicle's or a
line's running costs come from**. The game charges running costs at
different rates depending on what the vehicle is doing, but shows only one
"Running Costs" bar. This mod breaks that bar down:

| Vehicle state | Share of the running costs charged |
|---|---|
| driving (also standing in traffic or at a signal) | 100 % |
| stopped by the player, outside a depot | 100 % |
| at a terminal: loading, unloading, waiting for departure or a full load | 40 % |
| in a depot | 5 % |

On top of that the game adds a surcharge for poor condition (about +7 % at
"Fair", +23 % at "Very poor"), which is invisible in the finance window as
soon as a company has more than one vehicle.

What the mod adds:

- **Vehicle window:** a live line below the "Balance" card, `Now €X/min ·
  terminal 40 % · condition +12 %`, green while the vehicle runs at a
  reduced rate (terminal, depot), orange while it waits en route and pays
  the full rate. Expand it for a table of the last default game year:
  time share and cost per state, the condition surcharge, and the sum.
- **Line window:** the same table for all vehicles of the line, under the
  income graph in the "Balance" card. The sum is what the game booked; a
  footnote shows the booked amount from the line's account for comparison.
- Rows with no time in the window are hidden. Vehicles that joined the line
  later have a shorter history; the header then says "n vehicles with less
  data" and lists them in a tooltip.
- No recommendations: the mod shows facts, you draw the conclusions (fewer
  vehicles, a cheaper or faster model, faster terminals, a different route).
- **Depot and maintenance building windows (0.3.0):** a card with the
  building's "Maintenance Vehicles" fee of the window and the share of it
  charged for vehicles that were already in very good condition; see below.
- Purely cosmetic, achievements stay enabled. English and German.

The time window is one **default game year** (1461 s of game time), the unit
the game itself books in. It does not follow the calendar speed setting: at
0.5× it spans two calendar years, at 2× half a year. The header therefore
says "last 24 min of game time" rather than "last year". The history is
recorded by the mod every 3 s of game time and saved with the game, so it
starts when the mod is first active in a save and survives reloads.

Available on mod.io: <https://mod.io/g/transportfever3/m/running-cost-breakdown>

## Income per cargo type (0.2.0)

Under the cost table a second table shows the **income of the same window
per cargo type**: items delivered, income, income per item, the share
delivered on time, and the capacity the consist(s) offer for that cargo.
Passengers are one row. Rows are sorted by income; a sum row and a
**Result** line (income minus running costs of the window) close the block.

Where the numbers come from: the game raises an event for every paid item
with its base income (`basePrice`, the whole amount before the company-level
factor; the event's `vehicleEntity` field repeats the item, so the vehicle
is taken from the item's `SIM_ENTITY_AT_VEHICLE` component); the mod counts
them per vehicle and cargo type in the same time buckets as the costs. The base
values are not what the game books (the company level scales ticket prices,
subventions double single items), so the table scales them to the income
booked on the line's account in the same window; the footnote shows that
amount. For a single vehicle the vehicle's own account is used when the
game provides one, otherwise the line's factor ("scaled with the line's
bookings"). Only when no account is readable are base prices shown and the
Result line is replaced by "–".

The income table uses the cost table's coverage: a vehicle that exists but
delivered nothing shows "no income yet" and a Result of minus its costs.
There is deliberately no profit per cargo type: splitting the running costs
between cargos would need an arbitrary key. The capacity column is there so
you can compare "share of income" with "share of the train" yourself.

## Maintenance fee (0.3.0)

The finance category **"Maintenance Vehicles"** is not a repair price. Every
depot and maintenance building charges **25 % of the running-cost rate of
every vehicle inside its catchment area that holds one of its slots**, for
as long as the vehicle stays there, parked or driving through, also when
the vehicle is already at 100 % condition. On a large save 96 % of the
charged pool entries were healthy vehicles whose lines merely cross a
catchment area.

The window of a depot or maintenance building therefore gets a card
"Maintenance fee of the last N min of game time", collapsed:
`€X · 87 % for vehicles already very good` and `40 % of that also covered
elsewhere`. "Very good" is the game's own band (condition 0.8 and better);
the share is taken from the fee charged while the vehicle was in that band,
so the higher rate of a poor vehicle counts as poor. The tooltip adds the
share for vehicles at exactly 100 % and the amount the game booked on the
building in the last default year. Expanded, one row per vehicle that was
in the pool during the window: minutes in the pool, its fee share,
condition at entry and when last seen in the pool ("73 → 100"; a vehicle that
left wears down again, so "now" would blame the building), and how
many other buildings maintained it in the same window (names in the
tooltip). A footnote shows the amount the game booked for the window.

Reading it: a building whose fee mostly goes to vehicles that were already
fine, and that are covered elsewhere too, costs money without benefit and
can be moved or removed; a building whose rows start at low conditions earns
its keep. The mod changes nothing about the pool.

## Installation

Subscribe on mod.io or in the in-game Mod-Hub, then enable the mod when
loading or creating a game.

Manual installation: copy the folder `kampfmoehre_running_costs_1` into the
game's local mod directory, on Linux
`~/.local/share/Steam/userdata/<steam-id>/3493540/local/mods/`.

## How it works

The cost rule above was measured in October 2026 with a single truck on a
test map: the game books `MAINTENANCE/VEHICLE` every 60 s of game time, and a
minute spent in a state costs `runningCost × 60 / 1461 × factor`.
`api.engine.util.vehicle.getRunningCost` returns the yearly value including
the condition surcharge; the sum of the consist parts' `runningCosts` is the
rate of a healthy vehicle.

- `content/running_costs/running_costs.gs.lua` + `.script.lua`: a game
  script (engine side) that classifies every vehicle every 3 s of game time
  and accumulates seconds per state into a per-vehicle ring of 7 buckets of
  ~244 s (`cost_history.lua`, the oldest bucket counts pro rata), together
  with the healthy rate and the condition surcharge. It also keeps a compact per-vehicle summary of the window
  in the game-script state, which is saved with the game.
- `content/gui/kampfmoehre_running_costs/running_costs.script.lua`: the GUI.
  It reads the summaries through the game script's `GAME_SCRIPT` component,
  renders the table (`cost_rows.lua` turns summaries into rows), adds the
  vehicle window row (`::VehicleEowExtensionPoint`) and puts the table into
  the line window's "Balance" card by wrapping `content_card.ContentCard`
  for the card with `localKey == "lineBalance"`.
- Booked income of an account: the game's own "last year" query
  (`calculateBalance(entity, t0, t1, true)`) is income minus running costs
  of the entity; subtracting the two maintenance types a vehicle or line
  account carries (`VEHICLE`, `VEHICLE_MAINTENANCE`) leaves the income. Its
  income entries answer to the type `OTHER`, so that one must not be
  subtracted. The vehicle's not-yet-booked unload income is added (the game
  books at departure, the events arrive per item while unloading). Verified
  on a single truck: 434 440 against the game's own income bar, exactly.
- `content/running_costs/income.gs.lua` + `income.script.lua`: a second,
  event-only game script with its own small state (a batch of paid items
  arrives on every unload; the cost sampler's state would be too expensive
  to read and write that often). Each batch of paid items becomes a few
  compact records in the collector's own state, a queue that only keeps the
  last 8 s (a write of such a tiny state costs about 0.3 ms);
  the cost sampler reads that queue every 3 s and moves the records it has
  not seen into the income rings of its own state. A delivery therefore
  shows in the income table a few seconds late. The handler never returns a
  value, so prices are untouched.
- Maintenance pools (0.3.0): the sampler asks every depot for its pool list
  (`transportVehicleSystem.getVehiclesForMaintenanceStation`) each sample and
  accumulates per building and vehicle the seconds listed, the fee
  (25 % of the vehicle's running cost per second), the fee charged at
  condition >= 0.8 and at 1.0, and the condition at the start of the latest
  visit and when last seen. Not in the cost table's bucket ring: on a save
  with 379 vehicles about 1300 (building, vehicle) pairs per 4-minute bucket
  tripled the state copy time. Instead one entry per building and vehicle
  with a sliding span (first/last sample); an entry older than the window is
  cut down pro rata before new data is added, entries that ended before the
  window are dropped every 60 s. Per vehicle the sampler also remembers which
  buildings listed it in the window. The GUI
  (`fee_rows.lua`) turns one building's ring into the card
  (`::MaintenanceStationEowExtensionPoint`, order 55, below the vehicle list). The fee was measured on
  a single truck: ratio 0.250 of the running-cost rate in every booking, and
  on the large save as the median over 647 bookings.
- `cost_classes.lua` is the single list of states, factors, texts and
  colours; the sampler and the GUI both iterate it, so later versions can add
  classes (e.g. speed buckets) without touching the table code.

Cost, measured 2026-10-31 on a save with 379 vehicles, 121 lines and 48
depots or maintenance buildings with the window full (the state stops
growing after one default year): 0.2.0 takes about 18 ms of one simulation
pool thread every 3 s of game time, 0.3.0 about 20 ms; reading and writing
the saved state is 80 % of it (the game's copy costs roughly 0.7 µs per
table, the state holds ~13 000 tables, mostly the cost histories and the
income rings; the pool entries are about 5 % of the tables). No visible
frame-rate change. The income collector adds about 0.2 ms per batch of paid
items (~7 batches per second of game time on that save). Open windows read
one small summary and one income ring per shown vehicle every 2 s; a
building window reads its pool and one entry per listed vehicle.

## Development

```
./sync.sh                         # rsync the mod into the game's staging area
luajit test/cost_classes_test.lua # pure modules, no game needed
luajit test/cost_history_test.lua
luajit test/cost_rows_test.lua
```

Reload the savegame to pick up changed files. Log lines start with
`[kampfmoehre_running_costs]`.

## License

MIT, see `LICENSE`.
