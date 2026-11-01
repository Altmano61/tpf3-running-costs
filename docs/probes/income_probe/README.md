# Income probe (2026-11-01, temporary, not shipped)

Question (mod.io report by x4dzior on 0.4.0): cargo handed over between lines
(warehouses, transfer chains) never showed in the earlier legs' income tables,
although the game booked income there; on a vehicle with a second, directly
delivered cargo that cargo absorbed the booked money.

How to run: copy both files to `kampfmoehre_running_costs_1/content/income_probe/`,
`./sync.sh`, load a save with transfer chains, grep `stdout.txt` for `income probe`.
The handler only logs (never returns a value: a returned table would change prices).

## Findings (big save, 1157 batches, 560 multi-leg items, ~5 min)

- `OnCalcTicketPrice` comes **once per item, at the final delivery**; no item
  repeated inside a batch, only id `TransportVehicleSystem` for cargo.
- The event's `lineEntity` and the item's `SIM_ENTITY_AT_VEHICLE.vehicle` are
  the **last leg's** line and vehicle.
- `basePrice` = straight-line distance source → destination × ≈ 3.80 per metre
  for every cargo seen (plastics 6498 m → 24 691, 5584 m → 21 218; 3587 m →
  13 632), independent of the path, i.e. the **whole journey's** price. The
  shares of the earlier legs are booked in C++ without a further event.
- `SIM_CARGO.pickupPoints` holds one entry per leg in travel order: `vehicle`,
  `line`, `carrier`, `position` = **world position of the pickup** (leg lengths
  of 1.2–5.5 km between consecutive points, last point 300–600 m from `toPos`).
  A vehicle sold since shows as `vehicle = -1, line = -1` (15 of 560 items).
- `fromPos` = source industry, `toPos` = destination building (varies per item
  by the building's position).

Consequence: 0.4.1 splits a multi-leg item over all legs' vehicles by
straight-line leg length (`content/running_costs/income_legs.lua`). The game's
own split key is not observable; the per-line scaling to booked income fixes
the totals, the key only sets the weights between cargo types inside a line.
