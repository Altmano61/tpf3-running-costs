-- run: luajit test/area_upkeep_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local M = require "area_upkeep"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end
local function near(name, got, want, tol)
	check(name, type(got) == "number" and math.abs(got - want) <= tol, string.format("got %s, want %s", tostring(got), tostring(want)))
end

-- formulas ------------------------------------------------------------------
-- straight edge: chord 100 m along x, tangents of length 100 -> 100 m
near("hermite straight", M.hermiteLength({x=0,y=0,z=0}, {x=100,y=0,z=0}, {x=100,y=0,z=0}, {x=100,y=0,z=0}), 100, 1e-6)
-- quarter circle radius 100 (tangent length 3 × 0.5523 × r, the cubic-Bezier circle): arc 157.08
near("hermite curve", M.hermiteLength({x=100,y=0,z=0}, {x=0,y=165.69,z=0}, {x=0,y=100,z=0}, {x=-165.69,y=0,z=0}), 157.08, 0.3)
local mx, my, mz = M.midpoint({x=0,y=0,z=0}, {x=100,y=0,z=0}, {x=100,y=0,z=0}, {x=100,y=0,z=0})
near("midpoint x", mx, 50, 1e-9); near("midpoint y", my, 0, 1e-9); near("midpoint z", mz, 0, 1e-9)
check("construction upkeep with progression", M.constructionUpkeep(100000, 0, 1.25, 2.2, true) == 275000)
check("construction upkeep without progression", M.constructionUpkeep(100000, 0, 1.25, 2.2, false) == 125000)
check("construction upkeep adds accumulated", M.constructionUpkeep(100000, 1760, 1.0, 5.0, true) == 501760)
check("construction upkeep nil-safe", M.constructionUpkeep(nil, nil, 1.0, 1.0, false) == 0)
near("edge upkeep", M.edgeUpkeep(1000, 13, 0), 13000, 1e-9)
near("edge upkeep negative rate is free", M.edgeUpkeep(1000, -1, 0), 0, 1e-9)
near("edge upkeep bridge extra", M.edgeUpkeep(100, 38, 7), 4500, 1e-9)
local T = "::/infrastructure/track/simple/simple_catenary.street_template"
check("catenary folds into base", M.templateGroup(T) == "::/infrastructure/track/simple/simple.street_template")
check("tram_electrified folds into base", M.templateGroup("::/infrastructure/street/town/town_new_large_tram_electrified.street_template") == "::/infrastructure/street/town/town_new_large.street_template")
check("base template unchanged", M.templateGroup("::/infrastructure/track/simple/simple.street_template") == "::/infrastructure/track/simple/simple.street_template")
check("barriers stay separate", M.templateGroup("::/infrastructure/street/country/country_new_large_barriers.street_template") == "::/infrastructure/street/country/country_new_large_barriers.street_template")
check("template base name", M.templateBaseName("::/infrastructure/track/simple/simple.street_template") == "simple")

-- classification --------------------------------------------------------------
check("rail station", M.classifyStation({ "RAIL" }, { "TRAIN", "ELECTRIC_TRAIN" }) == "rail_stations")
check("multi-carrier station counts as rail", M.classifyStation({ "ROAD", "RAIL" }, { "BUS", "TRAIN" }) == "rail_stations")
check("airport", M.classifyStation({ "AIR" }, { "AIRCRAFT", "HELICOPTER" }) == "airports")
check("heliport", M.classifyStation({ "AIR" }, { "HELICOPTER" }) == "heliports")
check("harbour before road", M.classifyStation({ "ROAD", "WATER" }, { "SHIP", "BUS" }) == "harbours")
check("tram stop is a road terminal", M.classifyStation({ "TRAM" }, { "TRAM" }) == "road_terminals")
check("no carrier", M.classifyStation({}, {}) == "other_stations")
check("road depot", M.classifyDepot("ROAD", { "BUS", "TRUCK" }) == "road_depots")
check("tram depot is a road depot", M.classifyDepot("TRAM", { "TRAM" }) == "road_depots")
check("ship depot", M.classifyDepot("WATER", { "SHIP" }) == "ship_depots")
check("helicopter hangar", M.classifyDepot("AIR", { "HELICOPTER" }) == "heli_hangars")
check("hangar", M.classifyDepot("AIR", { "AIRCRAFT", "HELICOPTER" }) == "hangars")
check("unknown depot carrier", M.classifyDepot("OTHER", {}) == nil)
local function con(t) return setmetatable(t, { __index = { fileName = "", nStations = 0, nDepots = 0, nTownBuildings = 0, carriers = {}, modes = {}, depotCarrier = nil, depotModes = {}, upkeep = 0 } }) end
local c, s = M.classifyConstruction(con{ nStations = 1, carriers = { "RAIL" }, modes = { "TRAIN" }, upkeep = 5 })
check("station construction", c == "stations" and s == "rail_stations")
c, s = M.classifyConstruction(con{ nDepots = 1, fileName = "depots/road/road_depot/road_depot.con", depotCarrier = "ROAD", depotModes = { "BUS" }, upkeep = 5 })
check("depot construction", c == "depots" and s == "road_depots")
c, s = M.classifyConstruction(con{ nDepots = 1, fileName = "depots/rail/rail_maint_station.con", depotCarrier = "RAIL", upkeep = 5 })
check("maintenance building", c == "maintenance" and s == nil)
c, s = M.classifyConstruction(con{ fileName = "::/warehouses/warehouse.con", upkeep = 5 })
check("warehouse", c == "warehouses" and s == nil)
c, s = M.classifyConstruction(con{ fileName = "landmark/x.con", upkeep = 7 })
check("other building with upkeep", c == "other_buildings")
check("zero-upkeep other building is dropped", M.classifyConstruction(con{ fileName = "landmark/x.con", upkeep = 0 }) == nil)
check("town building is dropped", M.classifyConstruction(con{ nTownBuildings = 2, upkeep = 9 }) == nil)
c, s = M.classifyEdgeObject(true); check("roadside stop", c == "stations" and s == "roadside_stops")
c, s = M.classifyEdgeObject(false); check("signal", c == "signals" and s == nil)

-- accumulator and rows ----------------------------------------------------------
local acc = M.newAcc()
M.addBuilding(acc, 1, "stations", "rail_stations", 275000)
M.addBuilding(acc, 1, "stations", "roadside_stops", 5000)
M.addBuilding(acc, 1, "stations", "roadside_stops", 5000)
M.addBuilding(acc, 1, "depots", nil, 40000)             -- unknown carrier: total only
M.addBuilding(acc, 1, "signals", nil, 4125)
M.addBuilding(acc, 1, "other_buildings", nil, 0)        -- zero: hidden
M.addEdge(acc, 1, "TRACK", "simple", 1000, 13000, "NORMAL", 0)
M.addEdge(acc, 1, "TRACK", "standard", 200, 7600 + 1400, "BRIDGE", 1400)
M.addEdge(acc, 1, "STREET", "town_new_small", 500, 2500, "TUNNEL", 300)
M.addEdge(acc, 2, "TRACK", "simple", 100, 1300, "NORMAL", 0)
local R = M.rows(acc, 1, function(g) return "L:" .. g end)
near("total", R.total, 275000 + 10000 + 40000 + 4125 + 13000 + 9000 + 2500, 1e-6)
local keys = {}
for __, r in ipairs(R.rows) do keys[#keys + 1] = r.key end
check("row order, zero rows hidden", table.concat(keys, ",") == "stations,depots,tracks,roads,signals", table.concat(keys, ","))
check("stations children in fixed order", R.rows[1].children[1].key == "roadside_stops" and R.rows[1].children[1].amount == 10000 and R.rows[1].children[2].key == "rail_stations")
check("depots without sub has no children", R.rows[2].children == nil and R.rows[2].amount == 40000)
local tracks = R.rows[3]
near("tracks meters", tracks.meters, 1200, 1e-9)
check("templates sorted by amount", tracks.children[1].label == "L:simple" and tracks.children[1].meters == 1000 and tracks.children[2].label == "L:standard")
check("bridge surcharge", tracks.bridges.meters == 200 and tracks.bridges.extra == 1400 and tracks.tunnels == nil)
check("tunnel surcharge on roads", R.rows[4].tunnels.meters == 500 and R.rows[4].tunnels.extra == 300)
check("other town", M.rows(acc, 2, tostring).total == 1300 and #M.rows(acc, 2, tostring).rows == 1)
check("unknown town", M.rows(acc, 99, tostring).total == 0 and #M.rows(acc, 99, tostring).rows == 0)
check("unknown kind ignored", (function() M.addEdge(acc, 1, "AIR", "x", 1, 1, "NORMAL", 0); return M.rows(acc, 1, tostring).total end)() == R.total)

-- in-game finding 2026-11-13: VEHICLE_DEPOT.carrier is nil in the GUI state,
-- the carrier is derived from the depot's transport modes
check("depot carrier from modes: rail", M.classifyDepot(nil, { "TRAIN", "ELECTRIC_TRAIN" }) == "rail_depots")
check("depot carrier from modes: road incl. tram", M.classifyDepot(nil, { "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM" }) == "road_depots")
check("depot carrier from modes: ship", M.classifyDepot(nil, { "SHIP", "SMALL_SHIP" }) == "ship_depots")
check("depot carrier from modes: heli", M.classifyDepot(nil, { "HELICOPTER" }) == "heli_hangars")
check("depot carrier from modes: hangar", M.classifyDepot(nil, { "AIRCRAFT" }) == "hangars")
check("depot carrier from modes: none", M.classifyDepot(nil, {}) == nil)
-- street variants (bus lane, trees, barriers) share the display name: one child
local acc2 = M.newAcc()
M.addEdge(acc2, 1, "STREET", "a", 100, 1000, "NORMAL", 0)
M.addEdge(acc2, 1, "STREET", "b", 50, 500, "NORMAL", 0)
M.addEdge(acc2, 1, "STREET", "c", 10, 100, "NORMAL", 0)
local R3 = M.rows(acc2, 1, function(g) return g == "c" and "C" or "AB" end)
check("groups with the same label merge", #R3.rows[1].children == 2 and R3.rows[1].children[1].label == "AB" and R3.rows[1].children[1].meters == 150 and R3.rows[1].children[1].amount == 1500, tostring(#R3.rows[1].children))

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
