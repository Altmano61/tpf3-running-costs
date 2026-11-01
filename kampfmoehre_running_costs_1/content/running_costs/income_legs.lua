-- Running Cost Breakdown: splitting one paid cargo item over the legs of its
-- journey (pure, tested in test/income_legs_test.lua).
--
-- Measured 2026-11-01 (docs/probes/income_probe/): the game raises ONE
-- OnCalcTicketPrice event per delivered item, at the final delivery, with the
-- base price of the whole journey (straight line source -> destination) and
-- the last leg's line / vehicle. The booked money is split over the legs in
-- C++. The item's SIM_CARGO.pickupPoints list one entry per leg (vehicle,
-- line, carrier, world position of the pickup), a sold vehicle shows as -1.
-- This module gives each leg a share of the base price proportional to the
-- straight-line length of the leg: pickup point to the next pickup point, the
-- last leg to the delivery position. Unknown geometry falls back to equal shares.
local M = {}

local function pos(p)
	if type(p) ~= "table" then
		if p == nil then return nil end
		local ok, x, y, z = pcall(function() return p.x, p.y, p.z end)
		if ok and type(x) == "number" and type(y) == "number" then return { x = x, y = y, z = z or 0 } end
		return nil
	end
	if type(p.x) == "number" and type(p.y) == "number" then return { x = p.x, y = p.y, z = p.z or 0 } end
	if type(p[1]) == "number" and type(p[2]) == "number" then return { x = p[1], y = p[2], z = p[3] or 0 } end
	return nil
end

local function dist(a, b)
	if a == nil or b == nil then return nil end
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function id(x)
	if type(x) == "number" and x >= 0 then return x end
	return nil
end

-- points: { { vehicle, line, position } ... } in travel order (SIM_CARGO.pickupPoints),
-- toPos: delivery position or nil, base: the item's base price.
-- Returns { { v = vehicle or nil, line = line or nil, base = share } ... }, one per
-- point; empty when there are no points.
function M.split(points, toPos, base)
	local out = {}
	local n = type(points) == "table" and #points or 0
	if n == 0 then return out end
	base = tonumber(base) or 0
	-- leg lengths; any unknown one -> equal shares
	local lengths, total, known = {}, 0, true
	local to = pos(toPos)
	for i = 1, n do
		local a = pos(points[i].position)
		local b = (i < n) and pos(points[i + 1].position) or to
		local d = dist(a, b)
		if d == nil then known = false; break end
		lengths[i] = d
		total = total + d
	end
	if not known or total <= 0 then
		lengths, total = {}, n
		for i = 1, n do lengths[i] = 1 end
	end
	for i = 1, n do
		out[i] = { v = id(points[i].vehicle), line = id(points[i].line), base = base * lengths[i] / total }
	end
	return out
end

return M
