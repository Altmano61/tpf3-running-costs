-- run: luajit test/holding_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local H = require "holding"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end

local function air(t)
	t.carrier = "AIR"
	if t.enRoute == nil then t.enRoute = true end
	t.speed = t.speed or 80
	t.cruise = t.cruise or 525
	t.alt = t.alt or 500
	return t
end

check("constants", H.HOVER_SPEED == 5 and H.BERTH_SPEED == 1 and H.FLIGHT == 2 and H.APPROACH == 3 and H.LANDING == 4)

-- go-around at 44 m (Flugzeug 2): Landing -> Flight starts an episode and counts
local p, hold, ga = H.step(nil, air{ flight = 4, alt = 94, stop = 1 })
check("first sight: landing, no holding", p.f == 4 and p.h == 0 and p.stop == 1 and hold == false and ga == false)
p, hold, ga = H.step(p, air{ flight = 2, alt = 44, stop = 1 })
check("drop 4 -> 2 is a go-around", ga == true and hold == true and p.h == 1)
p, hold, ga = H.step(p, air{ flight = 2, alt = 300, stop = 1 })
check("climbing back: still holding, no new count", hold == true and ga == false)
p, hold, ga = H.step(p, air{ flight = 4, alt = 468, stop = 1 })
check("new attempt above half cruise: still holding", hold == true and ga == false)
p, hold, ga = H.step(p, air{ flight = 4, alt = 214, stop = 1 })
check("landing below half cruise ends the episode", hold == false and ga == false and p.h == 0)
p, hold, ga = H.step(p, air{ flight = 4, alt = 100, stop = 1, landRes = true })
check("stays ended", hold == false and ga == false)

-- cruise-altitude loop (Flugzeug 5): 3 -> 4 -> 2 -> 3 -> 4 -> 2 counts one per drop
p = nil
local count = 0
for __, f in ipairs({ 2, 3, 4, 2, 3, 4, 2, 3, 2 }) do
	local g
	p, hold, g = H.step(p, air{ flight = f, alt = 520, stop = 2 })
	if g then count = count + 1 end
end
check("loop at cruise altitude: three go-arounds (4->2, 4->2, 3->2)", count == 3, tostring(count))
check("still holding at the end of the loop", hold == true)
p, hold, ga = H.step(p, air{ flight = 4, alt = 500, stop = 2, landRes = true })
check("reservation ends it even high up", hold == false)

-- a drop seen in two steps (4 -> 3 -> 2) is ONE go-around (review finding 1)
p = H.step(nil, air{ flight = 4, alt = 700, stop = 0 })
local twoStep = 0
for __, f in ipairs({ 3, 2, 2 }) do
	local g
	p, hold, g = H.step(p, air{ flight = f, alt = 700, stop = 0 })
	if g then twoStep = twoStep + 1 end
end
check("4 -> 3 -> 2 counts once", twoStep == 1 and hold == true, tostring(twoStep))
for __, f in ipairs({ 3, 4, 2 }) do   -- climbed back through 3 and 4, dropped again
	local g
	p, hold, g = H.step(p, air{ flight = f, alt = 700, stop = 0 })
	if g then twoStep = twoStep + 1 end
end
check("a new attempt after a rise counts again", twoStep == 2, tostring(twoStep))
p = H.step(nil, air{ flight = 4, alt = 700, stop = 0 })
p = H.step(p, air{ flight = 4, alt = 650, stop = 0 })
p, hold, ga = H.step(p, air{ flight = 2, alt = 600, stop = 0 })
check("4, 4, 2 counts (armed from the start)", ga == true)

-- 4 -> 3 also counts
p = H.step(nil, air{ flight = 4, alt = 700, stop = 0 })
p, hold, ga = H.step(p, air{ flight = 3, alt = 700, stop = 0 })
check("drop 4 -> 3 counts", ga == true and hold == true)
-- taxi ends, stop change ends without a count, leaving EN_ROUTE ends
p, hold, ga = H.step(p, air{ flight = 5, alt = 5, stop = 0 })
check("taxi ends the episode", hold == false and ga == false)
p = { f = 4, h = 1, stop = 0 }
p, hold, ga = H.step(p, air{ flight = 2, alt = 600, stop = 1 })
check("stop change ends without a go-around", hold == false and ga == false and p.stop == 1)
p = { f = 4, h = 1, stop = 0 }
p, hold, ga = H.step(p, air{ flight = 4, alt = 600, stop = 0, enRoute = false })
check("not en route: no holding", hold == false and p.h == 0)
-- a normal approach: 3 -> 4 -> 4 with reservation never holds
p = nil
local anyHold = false
for __, o in ipairs({ { 2, 700 }, { 3, 700 }, { 4, 700 }, { 4, 400 }, { 4, 200, true }, { 5, 5 } }) do
	p, hold = H.step(p, air{ flight = o[1], alt = o[2], landRes = o[3], stop = 3 })
	anyHold = anyHold or hold
end
check("normal approach never holds", anyHold == false)

-- hovering helicopters: Flight below 5 m/s
p, hold, ga = H.step(nil, air{ flight = 2, speed = 3, alt = 98, stop = 0 })
check("hover is holding", hold == true and ga == false and p.h == 0)
p, hold = H.step(p, air{ flight = 2, speed = 20, alt = 98, stop = 0 })
check("moving helicopter is not", hold == false)
p, hold = H.step(nil, air{ flight = 2, speed = 90, alt = 700, stop = 0 })
check("cruising aircraft is not", hold == false)
p, hold = H.step(nil, air{ flight = 4, speed = 0, alt = 98, stop = 0, landRes = true })
check("vertical landing with reservation is not", hold == false)

-- missing data falls back to nothing
p, hold, ga = H.step({ f = 4, h = 1, stop = 0 }, air{ flight = nil, stop = 0 })
check("missing flight state: not holding, memory kept", hold == false and ga == false and p.h == 1 and p.f == 4)
-- (raw tables: the air() helper fills alt/cruise defaults)
p, hold, ga = H.step(nil, { carrier = "AIR", enRoute = true, flight = 2, speed = 80, stop = 0 })
check("missing altitude tolerated", hold == false)
p = H.step({ f = 4, h = 1, stop = 0 }, { carrier = "AIR", enRoute = true, flight = 4, alt = 100, speed = 60, stop = 0 })
check("missing cruise: altitude rule skipped, still holding", p.h == 1)

-- ships
local function ship(t) t.carrier = "WATER"; if t.enRoute == nil then t.enRoute = true end; return t end
p, hold, ga = H.step(nil, ship{ approaching = true, speed = 0.5 })
check("ship queued before the berth", hold == true and ga == false and p == nil)
p, hold = H.step(nil, ship{ approaching = true, speed = 6 })
check("ship approaching at speed is not", hold == false)
p, hold = H.step(nil, ship{ approaching = false, speed = 0 })
check("ship standing elsewhere is not holding (stays waiting)", hold == false)
p, hold = H.step(nil, ship{ approaching = true, speed = 0, enRoute = false })
check("ship at terminal is not", hold == false)

-- other carriers
p, hold, ga = H.step(nil, { carrier = "ROAD", enRoute = true, speed = 0 })
check("truck: nothing", p == nil and hold == false and ga == false)
p, hold, ga = H.step(nil, nil)
check("nil observation: nothing", p == nil and hold == false and ga == false)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
