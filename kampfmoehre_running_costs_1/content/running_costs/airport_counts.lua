-- Running Cost Breakdown: missed approaches per airport (0.5.0).
--
-- holding.lua detects an aborted landing approach (go-around) per aircraft;
-- the sampler counts it in the aircraft's own history and, through this
-- module, for the airport it was approaching: the station group of the
-- line stop the aircraft heads to (TransportVehicle.stopIndex, still the
-- approached stop at that moment because the aircraft has not landed). One
-- bucket ring per airport (cost_history, field g), created on the first
-- go-around, dropped again when the airport is gone or its window is empty,
-- so airports without problems cost nothing in the state. Pure: the
-- history module is passed in so the file tests outside the game.
local M = {}

-- station group entity of the line's stop `stopIndex` (0-based), nil when
-- unknown. In the game script the LINE component is userdata (not the plain
-- table the GUI gets), so fields are read through pcall without type checks.
function M.stopStationGroup(lineComp, stopIndex)
	if lineComp == nil or type(stopIndex) ~= "number" or stopIndex < 0 then return nil end
	local ok, sg = pcall(function()
		local stops = lineComp.stops
		local stop = stops and stops[stopIndex + 1] or nil
		return stop and stop.stationGroup or nil
	end)
	if ok and type(sg) == "number" and sg >= 0 then return sg end
	return nil
end

-- one more missed approach at station group `sg` at nowMs
function M.record(airG, sg, nowMs, history)
	local ring = airG[sg]
	if ring == nil then
		ring = history.new(nowMs)
		airG[sg] = ring
	end
	history.addCount(ring, nowMs, "g", 1)
end

local function zero() return 0 end
local NO_KEYS = {}

-- missed approaches of a ring inside the window, rounded; 0 without a ring
function M.count(ring, nowMs, windowMs, history)
	if ring == nil then return 0 end
	local w = history.window(ring, nowMs, windowMs, zero, windowMs, NO_KEYS)
	return math.floor((w.g or 0) + 0.5)
end

-- 1 when the last third of the window saw clearly more missed approaches
-- than the third before it, -1 when clearly fewer, 0 otherwise. "Clearly" =
-- a difference of at least 2 that is at least half the smaller count, so a
-- line hovering between 2 and 3 shows no arrow. The oldest third of the
-- window does not take part. Thirds are cut pro rata through the 4-minute
-- buckets (cost_history.window), i.e. assuming an even spread inside a bucket.
function M.trend(ring, nowMs, windowMs, history)
	if ring == nil then return 0 end
	local third = windowMs / 3
	local recent = (history.window(ring, nowMs, third, zero, windowMs, NO_KEYS).g or 0)
	local both = (history.window(ring, nowMs, 2 * third, zero, windowMs, NO_KEYS).g or 0)
	local prev = math.max(0, both - recent)
	local lo, hi = math.min(recent, prev), math.max(recent, prev)
	if hi - lo < 2 or hi < 1.5 * lo then return 0 end
	return recent > prev and 1 or -1
end

-- drop rings of station groups that no longer exist (exists(e) -> boolean)
-- and rings whose window holds nothing; returns the number of rings kept
function M.prune(airG, nowMs, windowMs, exists, history)
	if type(airG) ~= "table" then return 0 end
	local kept = 0
	for sg, ring in pairs(airG) do
		if not exists(sg) or M.count(ring, nowMs, windowMs, history) == 0 then
			airG[sg] = nil
		else
			kept = kept + 1
		end
	end
	return kept
end

return M
