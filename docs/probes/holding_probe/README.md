# Holding-pattern probe (2026-11-01)

Temporary game script that logged, every 2 s of game time, what the engine exposes for aircraft and
ships (`MOVE_PATH_AIRCRAFT` component: `aircraftState` / `shipState`, `AIRCRAFT` component: runway
reservations, plus speed and altitude). Test save: two airports 1 line with 10 small aircraft, a
helicopter line with 10 helicopters, a harbour pair with one berth and 10 ships (build 40425). To run
it again copy the folder into `kampfmoehre_running_costs_1/content/`, load a save and read the
"[kampfmoehre_hold_probe]" lines in `stdout.txt`; remove it before any upload.

## Findings

**Aircraft.** `flightState` is an integer in definition order: 0 Taxi0, 1 TakeOff, 2 Flight,
3 Approach, 4 Landing, 5 Taxi1. A normal flight: 0 → 1 → 2 → 3 (a few seconds at cruise altitude)
→ 4 without `reservedLandingRunway` (the descent from cruise altitude, 40-50 s) → 4 with the
reservation (granted at 150-280 m altitude, ~15 s before touchdown) → 5. `waitingDistance` is 0 and
`waitingPriority` -1 for aircraft throughout, useless. Aborted approaches show as the flight state
falling back: 4 → 2 (also 3 → 2 and 4 → 3), in two forms:

- go-around near the runway: Landing at 44-50 m altitude → Flight, climb back to cruise altitude,
  new attempt; one aircraft did five in a row;
- holding at cruise altitude: the aircraft loops at 620-740 m and cycles 2 → 3 → 4 → 2 every few
  seconds for minutes (that is the "circling because the runway is occupied" of the mod.io comment).

The flight path shows the same thing: after the taxi-out path (`path0`, 24 edges) is done the flight
path `path1` is re-planned to 5 or 6 segments for the approach; a go-around replaces it by an
8-segment loop whose position index restarts at 1 for every further loop. The flight-state drop is the
simpler signal and needs no path reading.

**Helicopters.** `waitingPriority` is the position in the landing queue (0 = next, up to 7 seen)
and `waitingDistance` 150 m × (position + 1); both are set already in flight. A waiting helicopter
hovers in flight state 2 at 100-335 m altitude with 1-4 m/s (up to a minute per helicopter here),
which the 0.5 m/s standing threshold of the "waiting en route" class does not catch. Rule: flight
state Flight with less than 5 m/s = hovering; aircraft never fly that slowly, so the rule needs no
helicopter detection. The vertical landing itself happens in state 4 with the reservation.

**Ships.** Before a single berth they queue staggered in `waitingDist` steps of 75 m (200, 275,
350, 425 m) with `approachingStation` true, mostly at 0 m/s (already "waiting en route"), creeping
forward at 1-3 m/s when the queue moves (today "driving"). `clearToLand` is not a clean signal: one
ship held it for 78 s while standing, lost it again and only then entered the berth. Rule:
`approachingStation` with less than 1 m/s = waiting for a berth.

Costs: all of this is EN_ROUTE and charged at 100 % by the game; the new class only labels the time.
