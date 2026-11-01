-- Holding detection of Running Cost Breakdown (0.4.0): is an aircraft circling
-- for a free runway or hovering in the landing queue, is a ship waiting for a
-- berth? Measured 2026-11-01 (docs/probes/holding_probe/README.md):
--  * the aircraft flight state is 0 Taxi0, 1 TakeOff, 2 Flight, 3 Approach,
--    4 Landing, 5 Taxi1; an aborted approach shows as the state falling back
--    (4 -> 2, 3 -> 2, 4 -> 3). From such a drop the aircraft is "holding" until
--    it lands for real: Landing with the runway reserved or below half its
--    cruise altitude, taxiing, leaving EN_ROUTE, or a new stop;
--  * helicopters queue by hovering in state Flight at 1-4 m/s (aircraft never
--    fly below 5 m/s in Flight);
--  * ships queue in the harbour approach zone (approachingStation) at 0-1 m/s.
-- step() is a pure function of the previous memory and the current
-- observation, so the sampler keeps only three numbers per aircraft.
-- No game API, unit-tested with plain luajit (test/holding_test.lua).
local M = {}

M.HOVER_SPEED = 5   -- m/s: slower in state Flight = hovering (helicopter queue)
M.BERTH_SPEED = 1   -- m/s: slower in the harbour approach zone = waiting for a berth
M.TAXI0, M.TAKEOFF, M.FLIGHT, M.APPROACH, M.LANDING, M.TAXI1 = 0, 1, 2, 3, 4, 5

-- prev = { f = last flight state, h = 1 while in an episode, a = 1 while a drop
--   may be counted (armed: the state has risen since the last counted drop, so a
--   drop seen in two steps 4 -> 3 -> 2 counts once), stop = stop index } | nil
-- obs = { carrier = "AIR" | "WATER" | other, enRoute, flight, landRes, alt,
--   cruise, speed, stop, approaching } | nil
-- -> next memory (AIR only, else nil), isHolding, goAround
function M.step(prev, obs)
	if type(obs) ~= "table" then return nil, false, false end
	if obs.carrier == "WATER" then
		local hold = obs.enRoute == true and obs.approaching == true and (obs.speed or 0) < M.BERTH_SPEED
		return nil, hold, false
	end
	if obs.carrier ~= "AIR" then return nil, false, false end

	local f = obs.flight
	local next = { f = prev and prev.f or nil, h = prev and prev.h or 0, a = prev and prev.a or 1, stop = prev and prev.stop or nil }
	if prev and prev.a == nil then next.a = 1 end   -- memory from before the flag: armed
	if type(f) ~= "number" then
		-- component unreadable this sample: keep the memory, claim nothing
		return next, false, false
	end
	local goAround = false
	if obs.enRoute ~= true then
		next.h = 0
	else
		local pf = prev and prev.f or nil
		if pf ~= nil and f > pf then next.a = 1 end   -- climbed a phase: the next drop is a new event
		if prev and prev.stop ~= nil and obs.stop ~= nil and obs.stop ~= prev.stop then
			next.h = 0   -- next leg: whatever happened belongs to the old one
		elseif pf ~= nil and ((pf == M.LANDING or pf == M.APPROACH) and f == M.FLIGHT or (pf == M.LANDING and f == M.APPROACH)) then
			next.h = 1
			if next.a == 1 then
				goAround = true
				next.a = 0
			end
		end
		if next.h == 1 then
			local lowEnough = type(obs.alt) == "number" and type(obs.cruise) == "number" and obs.cruise > 0 and obs.alt < 0.5 * obs.cruise
			if f == M.TAXI0 or f == M.TAKEOFF or f == M.TAXI1 then
				next.h = 0
			elseif f == M.LANDING and (obs.landRes == true or lowEnough) then
				next.h = 0
			end
		end
	end
	next.f = f
	if obs.stop ~= nil then next.stop = obs.stop end
	local hover = obs.enRoute == true and f == M.FLIGHT and (obs.speed or 0) < M.HOVER_SPEED
	return next, next.h == 1 or hover, goAround
end

return M
