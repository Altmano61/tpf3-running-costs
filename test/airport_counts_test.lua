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

-- trend(ring, nowMs, windowMs, history) -> 1 (clearly more in the last third of the
-- window than in the third before), -1 (clearly fewer), 0 otherwise; "clearly" =
-- a difference of at least 2 and at least half the smaller count
local function ringWith(times)
	local g = {}
	for __, t in ipairs(times) do M.record(g, 1, t, H) end
	return g[1]
end
local T = 10 * YEAR                 -- "now"
local R = YEAR / 3                  -- a third of the window
check("no ring: flat", M.trend(nil, T, YEAR, H) == 0)
check("empty window: flat", M.trend(ringWith({ T - 3 * YEAR }), T, YEAR, H) == 0)
-- 4 in the last third, 1 in the one before -> up
check("rising", M.trend(ringWith({ T - 1.5 * R, T - 0.9 * R, T - 0.6 * R, T - 0.3 * R, T - 0.1 * R }), T, YEAR, H) == 1)
-- 1 in the last third, 4 in the one before -> down
check("falling", M.trend(ringWith({ T - 1.9 * R, T - 1.7 * R, T - 1.5 * R, T - 1.2 * R, T - 0.1 * R }), T, YEAR, H) == -1)
-- 3 vs 2: a difference of one is noise
check("2 -> 3 is flat", M.trend(ringWith({ T - 1.5 * R, T - 1.2 * R, T - 0.6 * R, T - 0.3 * R, T - 0.1 * R }), T, YEAR, H) == 0)
-- 12 vs 10: a difference of two is not enough at that level
check("10 -> 12 is flat", M.trend(ringWith((function()
	local t = {}
	for i = 1, 10 do t[#t + 1] = T - 2 * R + i * (R / 11) end
	for i = 1, 12 do t[#t + 1] = T - R + i * (R / 13) end
	return t
end)()), T, YEAR, H) == 0)
-- 0 -> 2: the first go-arounds after a quiet period count as rising
check("0 -> 2 rises", M.trend(ringWith({ T - 0.5 * R, T - 0.2 * R }), T, YEAR, H) == 1)
-- the oldest third of the window does not take part
check("old events ignored", M.trend(ringWith({ T - 2.9 * R, T - 2.8 * R, T - 2.7 * R, T - 2.6 * R }), T, YEAR, H) == 0)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
