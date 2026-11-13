# Area probe: infrastructure upkeep per town area (2026-11-13)

Temporary game script (`area_probe.gs.lua` + `area_probe.script.lua`, run from
`content/area_probe/` while probing, kept here afterwards). Question from forum
thread 4666 (UG.sam: "a breakdown of infrastructure costs on a per municipal
area basis"): can the mod attribute the player's infrastructure upkeep to town
areas? Measured on the big save (16 towns, ~190 player constructions, 12.8k
edges, year 1958, `infrastructureMaintenanceScale` 1.25, year multiplier 2.2; that save
runs a harder difficulty and a half-speed calendar, so a calendar year holds two
default years and the finance table's "half-year" columns are default years). A
test save on normal difficulty and normal calendar speed (2010) has scale 1.0 and
year multiplier 5.0; a road depot built across a town border was listed by exactly
one town (Filderstadt, by both lookups) although the game named it "Fellbach
Strassendepot": naming and area assignment follow different rules.

## Findings

**Town area = Voronoi cell.** `api.engine.util.town.getClosestTown(Vec3f)` (the
`town` sub-table, not `api.engine.util.getClosestTown`) returns the town for any
position; `streetConnectorSystem.getTownClosestConstructions(town)` lists the
constructions of a town and `getConstructionClosestTown(construction)` agrees
with it for every construction (0 mismatches). No overlaps, no gaps: every edge
midpoint got a town.

**Constructions** (stations, depots, maintenance buildings, warehouses,
landmarks): `MAINTENANCE_COST` component; upkeep per default year =
`round(maintenanceCost × costs.infrastructureMaintenanceScale × yearMult) +
Σ accumulatedCost`, `yearMult` = `construction.getCostMultiplierForYear(
baseConfig.treeCostYearMultipliers, year)` only when the construction desc has
`costsYearProgression`. Identical to `util.maintenance.calcMaintenanceForStationGroup`
for every station checked (the game's value leaves `accumulatedCost` out: airport
826 760 vs 825 000). Landmarks cost 0. `getTownClosestConstructions` also returns
town buildings and industries (filter by `PLAYER_OWNED.player == getPlayer()`).
**Constructions have no ACCOUNT** except depots / maintenance buildings / airports
(57 of 192); `finance.calculateBalance` on an entity WITHOUT an account throws an
engine assertion that is caught but costs ~1 s each on the sim thread (the game
froze for minutes) — always check `getComponent(e, ACCOUNT)` first.

**Edges** (`BASE_EDGE`): not loopable with `getEntitiesWithComponent` /
`forEachEntityWithComponent` ("Cannot loop over this component type"); enumerate
via `streetSystem.getNode2SegmentMap()` (node → segments, dedupe). `BaseEdge.distance`
is NOT the length (5 for tracks, 0 for streets); the Hermite length from
`position0/1`, `tangent0/1` (tangent magnitude = length) is right. Upkeep per
default year = length × `streetTemplateRep.get(find(roadTemplate)).maintenanceCost`
(+ `bridgeTypeRep` / `tunnelTypeRep.get(typeIndex).maintenanceCost` for
`type == BRIDGE/TUNNEL`), **without** the global scale: the template rate is
already scaled (with the scale the estimate was exactly 1.25× the booked amount).
Industry tracks carry rate −1 (free). Only `PLAYER_OWNED` edges outside
constructions (`getConstructionEntityForEdge == nil`) are charged; town streets
are not. Result vs the finance table: tracks 4.126 M estimated / 4.111 M booked,
streets 3.89 M / 3.76 M (streets were being built during the run).

**Edge objects** (`BaseEdge.objects` = `{entity, EdgeObjectType}` tables):
signals, roadside bus stops (`stations/street/small_stops/*.con`), runway signs.
Not constructions, so missing from `getTownClosestConstructions`, but they carry
`MAINTENANCE_COST` (+ `EDGE_OBJECT.edgeObjectConstruction` for the desc) and are
charged like constructions: 807 objects = 5.87 M/yr on the big save (489 path
signals × 4 125 = 2.0 M, 272 bus stops 3.7 M). Attribute them to the edge's town.
A two-sided roadside stop is TWO edge objects (one per side, `maintenanceCost` 5 000
each = half the `.con` file's 10 000); summing the objects of a station group gives
exactly `calcMaintenanceForStationGroup` for all 145 stop groups (0 mismatches), e.g.
the stop window's 27 500/yr = 2 × 5 000 × 1.25 × 2.2.

**Year multiplier** `baseConfig.treeCostYearMultipliers` = {1900: 1, 1920: 1.5, 1940: 2.2,
1960: 3.2, 1980: 4, 2000: 5, 2020: 6}, applied as steps without interpolation to every
construction and edge object with `costsYearProgression` (the "upkeep jumps every 20
years" complaint in the forum). Track/street template rates do not carry it (the
booked track upkeep matched length × rate without a year factor in 1958).

**Totals**: constructions 47.9 M + tracks 4.13 M + streets 3.89 M + bridges/
tunnels 0.04 M + edge objects 5.87 M = 61.8 M per default year vs 62.8 M booked
(`calculateBalance({player}, now − 1461 s, now, true, INFRASTRUCTURE)`), 1.5 %
gap with construction going on; last run 62.54 M vs 63.26 M (1.1 %). The finance table (`finance.computeFinanceTable`,
`ChartConfig.count = 4`) has an interval of 1 461 000 ms per column although the
headers read like calendar half-years; "Upkeep Buildings" is booked per carrier
(road and rail each ≈ 22.5 M here), "Upkeep Roads/Tracks" per carrier, warehouses
under carrier OTHER.

**Cost of a full pass** on the engine thread: constructions 25 ms, edges + edge
objects 450 ms (12.8k edges, ~35 µs per edge incl. town lookup and template
rate). A shipped feature must cache per edge or spread the pass over steps.

**GUI thread** (`area_gui_probe.script.lua`, plugin at `::ModEntryPointExtension`,
runs once in `react.onMount`; the `.res.lua` must sit under `content/gui/`, a res
file in `content/area_probe/` was never instantiated): every call the feature
needs works in the GUI Lua state and is much cheaper there than the engine-side
probe suggested (the engine probe logged and summed per edge): TOWN entities 16;
constructions 11 806 listed / 180 player-owned in 4.4 ms; `getCarriers(group)`
ok (carriers 1,2, modes 7,8,14,15 for a rail+road group); `getNode2SegmentMap`
4.5 ms, dedupe to 13 011 edges 4.1 ms; a sample of 407 edges (BASE_EDGE,
PLAYER_OWNED, `getConstructionEntityForEdge`, midpoint `getClosestTown`, template
rate cached, edge objects' EDGE_OBJECT/MAINTENANCE_COST/STATION) 2.5 ms = 6 µs
per edge → full pass ≈ 78 ms; whole probe 15.6 ms. So a GUI-side scan of all
towns costs ≈ 100 ms once, sliced over frames it is invisible.

## Log excerpt (last run)

```
ESTIMATE per year: constructions 47908637 ... | free owned edges: track 4126190, street 3888066, bridges 11527, tunnels 24698 | edge objects 5872571 | BOOKED infrastructure maintenance last 1461 s: -62797331
finance ROAD MAINTENANCE/INFRASTRUCTURE/STREET: -3914022 | -3757488 | -3804129 | ...
finance RAIL MAINTENANCE/INFRASTRUCTURE/TRACK: -4283470 | -4111008 | -4111008 | ...
cost: constructions 24.9 ms, edges 449.9 ms (12810 edges), 16 towns
```
