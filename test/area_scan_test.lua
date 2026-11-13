-- run: luajit test/area_scan_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local M = require "area_scan"
local U = require "area_upkeep"

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

-- fake environment: the clock advances 10 us per now() call
local T = 0
local function pt(x, y, z) return { x = x, y = y, z = z } end
local straight = function(x0) -- 100 m along x starting at x0
	return { p0 = pt(x0, 0, 0), t0 = pt(100, 0, 0), p1 = pt(x0 + 100, 0, 0), t1 = pt(100, 0, 0) }
end
local CONS = {
	[11] = { fileName = "station/rail/x.con", nStations = 1, nDepots = 0, nTownBuildings = 0, carriers = { "RAIL" }, modes = { "TRAIN" }, depotModes = {}, upkeep = 1000 },
	[12] = { fileName = "depots/road/road_depot/road_depot.con", nStations = 0, nDepots = 1, nTownBuildings = 0, carriers = {}, modes = {}, depotCarrier = "ROAD", depotModes = { "BUS" }, upkeep = 500 },
	[13] = { fileName = "town/x.con", nStations = 0, nDepots = 0, nTownBuildings = 3, carriers = {}, modes = {}, depotModes = {}, upkeep = 77 },
	-- 21: not owned -> nil
}
local function edgeInfo(x0, kind, etype, rate, extra, group, objects, owned, inConstruction)
	local e = straight(x0)
	e.kind, e.etype, e.rate, e.extra, e.group, e.objects = kind, etype, rate, extra, group, objects
	e.owned = owned ~= false
	e.inConstruction = inConstruction == true
	return e
end
local EDGES = {
	[31] = edgeInfo(0, "STREET", "NORMAL", 20, 0, "town_new_small", { 45 }, true, true),  -- inside a construction: no metres, objects count
	[32] = edgeInfo(0, "TRACK", "NORMAL", 13, 0, "simple", { 41, 42 }),        -- midpoint x = 50 -> town 1
	[33] = edgeInfo(1000, "STREET", "BRIDGE", 20, 5, "town_new_small", {}),  -- midpoint x = 1050 -> town 2
	[34] = edgeInfo(9999, "TRACK", "NORMAL", 13, 0, "simple", { 43 }),       -- no town: dropped with its object
	[35] = edgeInfo(100, "STREET", "NORMAL", 20, 0, "town_new_small", { 44 }, false), -- town street: no metres, the stop counts
	-- 36: no BASE_EDGE -> nil
}
local OBJS = {
	[41] = { upkeep = 4125, isStation = false },
	-- 42: not owned -> nil
	[43] = { upkeep = 4125, isStation = false },
	[44] = { upkeep = 5000, isStation = true },   -- roadside stop on a town street
	[45] = { upkeep = 4125, isStation = false },  -- signal inside a station
}
local begins = 0
local env = {
	now = function() T = T + 10; return T end,
	begin = function() begins = begins + 1 end,
	towns = function() return { 1, 2 } end,
	constructionsOf = function(town) return town == 1 and { 11, 12, 13 } or { 21 } end,
	construction = function(e) return CONS[e] end,
	edges = function() return { 31, 32, 33, 34, 35, 36 } end,
	edge = function(e) return EDGES[e] end,
	townAt = function(x, y, z) if x < 500 then return 1 elseif x < 5000 then return 2 end return nil end,
	edgeObject = function(e) return OBJS[e] end,
	templateLabel = function(g) return "L" .. g end,
}

local S = M.new(env, U)
check("no result before start", S.result() == nil and S.rows(1) == nil and S.running() == false)
check("step without start is a no-op", S.step(1000) == false)
S.start()
check("running", S.running() == true)
check("begin hook called", begins == 1)
local steps, finished = 0, false
while S.running() and steps < 1000 do
	steps = steps + 1
	if S.step(25) then finished = true end     -- 25 us budget = 2-3 items per step
end
check("finished in several steps", finished and steps > 3, "steps=" .. steps)
local R1 = S.rows(1)
near("town 1 total", R1.total, 1000 + 500 + 100 * 13 + 4125 + 5000 + 4125, 1e-6)
check("stop on a town street counts, the street does not", (function()
	for __, r in ipairs(R1.rows) do if r.key == "roads" then return false end end
	return R1.rows[1].children[1].key == "roadside_stops" and R1.rows[1].children[1].amount == 5000
end)())
local R2 = S.rows(2)
near("town 2 total", R2.total, 100 * (20 + 5), 1e-6)
check("edge without town is skipped", S.stats().edges == 2 and S.rows(1).total + S.rows(2).total == R1.total + R2.total)
check("stats", S.stats().towns == 2 and S.stats().constructions == 2 and S.stats().objects == 3 and S.stats().steps == steps,
	string.format("towns=%s cons=%s objs=%s steps=%s/%s", S.stats().towns, S.stats().constructions, S.stats().objects, S.stats().steps, steps))
check("duration recorded", type(S.stats().durationUs) == "number" and S.stats().durationUs > 0)
check("bridge surcharge recorded", R2.rows[1].key == "roads" and R2.rows[1].bridges.extra == 500)
check("template label from env", R1.rows[3].children[1].label == "Lsimple")
check("age", S.ageUs(S.result().at + 5) == 5)
check("towns of the result", #S.towns() == 2 and M.new(env, U).towns() == nil)
near("grand total over all towns", S.grandTotal(), R1.total + R2.total, 1e-6)
-- a second scan: start while running is a no-op, old result survives until done
local at1 = S.result().at
S.start()
S.start()
check("start while running is a no-op", S.running() and begins == 2)
check("old result survives a rescan", S.result().at == at1 and S.rows(1).total == R1.total)
while S.running() do S.step(1e9) end
check("rescan replaces the result", S.result().at > at1 and S.rows(1).total == R1.total)
-- a huge budget finishes in one step
local S2 = M.new(env, U); S2.start()
check("one step with a large budget", S2.step(1e9) == true and S2.running() == false)
check("age without result", M.new(env, U).ageUs(5) == nil and M.new(env, U).age() == nil)
-- age() reads the scanner's own clock (env.now advances 10 us per call)
check("age from the env clock", S2.age() == 10)
-- a scan whose env throws is aborted by the caller: no retry, old result stays
local S3 = M.new(env, U)
S3.start(); while S3.running() do S3.step(1e9) end
local at3 = S3.result().at
local brokenEdge = env.edge
env.edge = function() error("engine says no") end
S3.start()
check("failing env step raises", not pcall(S3.step, 1e9) and S3.running())
S3.abort()
check("abort drops the scan, keeps the result", S3.running() == false and S3.result().at == at3 and S3.step(1e9) == false)
env.edge = brokenEdge
S3.start(); while S3.running() do S3.step(1e9) end
check("scan works again after abort", S3.result().at > at3)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
