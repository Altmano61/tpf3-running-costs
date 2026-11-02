-- run: luajit test/airport_counts_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local M = require "airport_counts"
local H = require "cost_history"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end

local YEAR = 1461 * 1000
local MIN = 60 * 1000

-- stopStationGroup(lineComponent, stopIndex) -> station group entity or nil
local line = { stops = { { stationGroup = 501 }, { stationGroup = 502 }, { stationGroup = 503 } } }
check("stop index is 0-based", M.stopStationGroup(line, 0) == 501 and M.stopStationGroup(line, 2) == 503)
check("index past the end: nil", M.stopStationGroup(line, 3) == nil and M.stopStationGroup(line, -1) == nil)
check("missing line or stops: nil", M.stopStationGroup(nil, 0) == nil and M.stopStationGroup({}, 0) == nil)
check("negative station group: nil", M.stopStationGroup({ stops = { { stationGroup = -1 } } }, 0) == nil)
check("non-numeric index: nil", M.stopStationGroup(line, nil) == nil)

-- in the game script the component is userdata that answers to .stops / [i] / .stationGroup
-- (the base game's achievements.script.tl indexes it the same way); no type checks may reject it
local function ud(fields)
	local u = newproxy(true)
	getmetatable(u).__index = function(_, k) return fields[k] end
	return u
end
local udLine = ud({ stops = ud({ ud({ stationGroup = 601 }), ud({ stationGroup = 602 }) }) })
check("userdata component", M.stopStationGroup(udLine, 1) == 602 and M.stopStationGroup(udLine, 5) == nil)
check("userdata that throws on access: nil", M.stopStationGroup(ud(setmetatable({}, { __index = function() error("boom") end })), 0) == nil)

-- record(airG, sg, nowMs, history) counts one missed approach for the airport
local airG = {}
M.record(airG, 501, 10 * MIN, H)
M.record(airG, 501, 11 * MIN, H)
M.record(airG, 502, 11 * MIN, H)
check("one ring per airport", airG[501] ~= nil and airG[502] ~= nil and airG[503] == nil)
check("count within the window", M.count(airG[501], 12 * MIN, YEAR, H) == 2 and M.count(airG[502], 12 * MIN, YEAR, H) == 1)
check("count of a missing ring is 0", M.count(nil, 12 * MIN, YEAR, H) == 0)

-- the count slides out with the window (whole buckets, pro rata for the oldest)
check("old approaches leave the window", M.count(airG[501], 12 * MIN + 2 * YEAR, YEAR, H) == 0)

-- prune(airG, nowMs, windowMs, exists, history): gone airports and empty windows go
local function exists(e) return e ~= 502 end
local kept = M.prune(airG, 12 * MIN, YEAR, exists, H)
check("demolished airport pruned", airG[502] == nil and airG[501] ~= nil and kept == 1)
kept = M.prune(airG, 12 * MIN + 2 * YEAR, YEAR, exists, H)
check("empty window pruned", airG[501] == nil and kept == 0)
check("prune tolerates nil", M.prune(nil, 0, YEAR, exists, H) == 0)

-- an airport pruned while idle starts over cleanly
M.record(airG, 501, 5 * YEAR, H)
check("record after prune", M.count(airG[501], 5 * YEAR + MIN, YEAR, H) == 1)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
