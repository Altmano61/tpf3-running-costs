-- run: luajit test/income_legs_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local M = require "income_legs"

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
local function P(x, y, z) return { x = x, y = y, z = z or 0 } end

-- split(points, toPos, base) -> { { v = vehicle, line = line, base = share } ... }
-- points = { { vehicle, line, position = {x,y,z} } ... } in travel order

-- the plastics chain of the probe: lorry 1217 m, train 5550 m, lorry 566 m
local chain = {
	{ vehicle = 262554, line = 91862, position = P(2668, 5017, 4) },
	{ vehicle = 279627, line = 257716, position = P(3454, 4088, 3) },
	{ vehicle = 254755, line = 79424, position = P(6548, -519, 5) },
}
local legs = M.split(chain, P(5987, -593, 19), 24691)
check("one share per leg", #legs == 3)
check("vehicle and line per leg", legs[1].v == 262554 and legs[1].line == 91862 and legs[3].v == 254755 and legs[3].line == 79424)
local total = 0
for __, l in ipairs(legs) do total = total + l.base end
near("shares sum to the base price", total, 24691, 1e-6)
local d1 = math.sqrt((3454 - 2668) ^ 2 + (4088 - 5017) ^ 2 + 1)
local d2 = math.sqrt((6548 - 3454) ^ 2 + (-519 - 4088) ^ 2 + 4)
local d3 = math.sqrt((5987 - 6548) ^ 2 + (-593 + 519) ^ 2 + 14 ^ 2)
near("share proportional to the leg's straight-line length", legs[2].base, 24691 * d2 / (d1 + d2 + d3), 1e-6)
check("long leg gets most", legs[2].base > legs[1].base and legs[1].base > legs[3].base)

-- a single pickup point: the whole price on that leg
local one = M.split({ { vehicle = 7, line = 8, position = P(0, 0) } }, P(100, 0), 500)
check("single leg: whole price", #one == 1 and one[1].base == 500 and one[1].v == 7)

-- no pickup points: nothing to attribute
check("no points: empty", #M.split({}, P(0, 0), 500) == 0 and #M.split(nil, P(0, 0), 500) == 0)

-- a sold vehicle shows as -1 in the game's data: the leg keeps its line
local sold = M.split({ { vehicle = -1, line = -1, position = P(0, 0) }, { vehicle = 5, line = 6, position = P(1000, 0) } }, P(2000, 0), 300)
check("sold vehicle: v nil, line nil", sold[1].v == nil and sold[1].line == nil and sold[2].v == 5)
near("sold vehicle still takes its share", sold[1].base, 150, 1e-9)

-- unknown destination or zero distances: equal shares
local eq = M.split({ { vehicle = 1, line = 1, position = P(0, 0) }, { vehicle = 2, line = 2, position = P(0, 0) } }, nil, 300)
near("no toPos: equal shares (1)", eq[1].base, 150, 1e-9)
near("no toPos: equal shares (2)", eq[2].base, 150, 1e-9)
local zero = M.split({ { vehicle = 1, line = 1, position = P(0, 0) }, { vehicle = 2, line = 2, position = P(0, 0) } }, P(0, 0), 300)
near("all distances zero: equal shares", zero[1].base, 150, 1e-9)
local nopos = M.split({ { vehicle = 1, line = 1 }, { vehicle = 2, line = 2, position = P(0, 0) } }, P(10, 0), 300)
near("missing position: equal shares", nopos[1].base, 150, 1e-9)

-- a zero-length leg in an otherwise measured chain gets nothing but stays listed
local z = M.split({ { vehicle = 1, line = 1, position = P(0, 0) }, { vehicle = 2, line = 2, position = P(0, 0) } }, P(100, 0), 300)
check("zero-length first leg: listed with 0", #z == 2 and z[1].base == 0 and z[2].base == 300)

-- positions may come as arrays {x, y, z}
local arr = M.split({ { vehicle = 1, line = 1, position = { 0, 0, 0 } }, { vehicle = 2, line = 2, position = { 300, 0, 0 } } }, { 400, 0, 0 }, 400)
near("array positions", arr[1].base, 300, 1e-9)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
