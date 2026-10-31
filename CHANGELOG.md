# Changelog

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
