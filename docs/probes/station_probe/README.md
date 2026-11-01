# Station-queue probe (2026-11-01)

Temporary game script that logged, every 2 s of game time, every road, tram or rail vehicle standing
(< 0.5 m/s) while EN_ROUTE / GOING_TO_DEPOT: `MOVE_PATH.dyn.approachingStation`, `timeStanding`, the
position on the section (`pathPos.edgeIndex` of `#path.edges`), `blocked`, the stop index, and the
wall-clock cost of the `MOVE_PATH` read. Run on the big save (420 vehicles, build 40425), 76 dumps over
~25 min of game time, 2 928 rows (1 712 road, 712 tram, 504 rail). To run it again copy the folder into
`kampfmoehre_running_costs_1/content/`, load a save, read the "[kampfmoehre_station_probe]" lines in
`stdout.txt`; remove it before any upload.

## Findings

- `approachingStation` separates the queue before a station from traffic: of the standing rows with the
  flag 915 of 1 150 are at most 2 edges before the stop, the rest mostly within 15 edges (trucks queueing
  back along the street: three lorries of one line at 6 / 15 / 15 edges, standing 20-40 s between moves);
  rows without the flag are spread over the whole section (signals, junctions, a station exit: three
  lorries standing 20-40 s at edge 0-1 of their next section).
- The flag is also set for *moving* trains up to ~30 edges before a station (the rail approach zone
  starts early), with `timeStanding` 0; for standing vehicles it is clean.
- Per dump on average 8 vehicles stood in traffic and 3 before a station.
- `blocked` is almost always 0 (1-3 in 31 rows), not useful.
- A `MOVE_PATH` component read costs 1-3 µs (the section path is not copied edge by edge), so reading it
  for every standing vehicle in every sample is free compared with the state copy.

Rule for the mod (0.4.0, class "at station queue"): EN_ROUTE / GOING_TO_DEPOT, speed < 0.5 m/s and
`MOVE_PATH.dyn.approachingStation` true → waiting in front of a station; standing without the flag stays
"waiting en route".
