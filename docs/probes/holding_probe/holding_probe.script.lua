-- TEMPORARY diagnostic (2026-11-01): how to recognise an aircraft in a holding
-- pattern (go-around, runway occupied) and a ship waiting for a berth, so a
-- later version can show that time as its own cost row. Logs to stdout.txt,
-- prefix [kampfmoehre_hold_probe].
--
-- Every SAMPLE_MS of game time, for every aircraft and ship: the transport
-- vehicle state, the MOVE_PATH_AIRCRAFT component's aircraftState (flightState,
-- waitingDistance, waitingPriority, cruise altitude, altitude, path state) or
-- shipState (waitingDist, clearToLand, approachingStation), the AIRCRAFT
-- component's runway reservations, and the speed. A line is written whenever
-- a vehicle's discrete fields change, plus a full dump every DUMP_MS.
function data()
	local SAMPLE_MS = 2000
	local DUMP_MS = 10000
	local LOG_PREFIX = "[kampfmoehre_hold_probe] "

	local gameLog = log
	local function log(text)
		if type(gameLog) == "table" and gameLog.message then gameLog.message(LOG_PREFIX .. tostring(text)) else print(LOG_PREFIX .. tostring(text)) end
	end

	-- the game's enum tables cannot be iterated with pairs (metatable __index),
	-- so the member names are listed here and resolved one by one
	local function enumNames(enumTable, members)
		local names = {}
		for __, name in ipairs(members) do
			local ok, value = pcall(function() return enumTable[name] end)
			if ok and value ~= nil then names[tostring(value)] = name end
		end
		return names
	end
	local tvsNames, flightNames, pathNames, carrierNames = {}, {}, {}, {}
	pcall(function()
		local E = api.type["enum"]
		tvsNames = enumNames(E.TransportVehicleState, { "IN_DEPOT", "EN_ROUTE", "AT_TERMINAL", "GOING_TO_DEPOT" })
		flightNames = enumNames(E.FlightState, { "Taxi0", "TakeOff", "Flight", "Approach", "Landing", "Taxi1" })
		carrierNames = enumNames(E.Carrier, { "ROAD", "RAIL", "TRAM", "AIR", "WATER" })
		if E.MovePathAircraft and E.MovePathAircraft.PathState then
			pathNames = enumNames(E.MovePathAircraft.PathState, { "PATH0", "PATH1", "PATH2" })
		end
	end)
	local enumsLogged = false
	local function nameOf(names, value)
		if value == nil then return "nil" end
		return names[tostring(value)] or tostring(value)
	end

	local function round(n, step)
		if type(n) ~= "number" then return tostring(n) end
		return string.format("%.0f", math.floor(n / step + 0.5) * step)
	end
	local function b(v) if v == nil then return "nil" end return v and "1" or "0" end

	local function gameTime()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		return gt and gt.gameTime or nil
	end

	local function entityName(e)
		local ok, n = pcall(api.engine.util.getEntityName, e)
		return (ok and n) or tostring(e)
	end

	local function getComp(e, ctype)
		if ctype == nil then return nil end
		local ok, c = pcall(api.engine.getComponent, e, ctype)
		if ok then return c end
		return nil
	end

	-- -> key (discrete fields), detail (everything, for the log line), carrier name
	local function describe(v, tvState)
		local tv = getComp(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		if not tv then return nil end
		-- TRANSPORT_VEHICLE has `carrier` in some builds; otherwise the components
		-- tell: AIRCRAFT -> aircraft, MOVE_PATH_AIRCRAFT without AIRCRAFT -> ship
		local mpa = getComp(v, api.type.ComponentType.MOVE_PATH_AIRCRAFT)
		local acEarly = getComp(v, api.type.ComponentType.AIRCRAFT)
		local carrier
		if tv.carrier ~= nil then
			carrier = nameOf(carrierNames, tv.carrier)
		elseif acEarly then
			carrier = "AIR"
		elseif mpa then
			carrier = "WATER"
		else
			carrier = "none"
		end
		if carrier ~= "AIR" and carrier ~= "WATER" then return nil, "carrier " .. carrier end
		local okS, speed = pcall(api.engine.util.vehicle.getSpeed, v)
		speed = (okS and type(speed) == "number") and speed or -1
		local key, detail
		if carrier == "AIR" then
			local ac = getComp(v, api.type.ComponentType.AIRCRAFT)
			local st = mpa and mpa.aircraftState or nil
			local dyn = st and st.dyn or nil
			key = table.concat({
				carrier, nameOf(tvsNames, tvState), "flight=" .. nameOf(flightNames, st and st.flightState),
				"wp=" .. tostring(st and st.waitingPriority), "landRes=" .. b(ac and ac.reservedLandingRunway),
				"tkRes=" .. b(ac and ac.reservedTakeOffRunway), "path=" .. nameOf(pathNames, mpa and mpa.pathState),
				"stop=" .. tostring(tv.stopIndex), "gear=" .. b(st and st.gear),
			}, " ")
			local n0 = (mpa and mpa.path0 and type(mpa.path0.edges) == "table") and #mpa.path0.edges or -1
			local n1 = (mpa and type(mpa.path1) == "table") and #mpa.path1 or -1
			local n2 = (mpa and mpa.path2 and type(mpa.path2.edges) == "table") and #mpa.path2.edges or -1
			local pp = mpa and mpa.pathPos or nil
			detail = string.format("%s wd=%s cruise=%s alt=%s speed=%s idx=%s res=%s..%s paths=%d/%d/%d pos=%s", key,
				round(st and st.waitingDistance, 1), round(st and st.cruiseAlt, 1), round(dyn and dyn.alt, 1),
				round(speed, 0.1), tostring(ac and ac.pathIndex), tostring(ac and ac.reservedFrom), tostring(ac and ac.reservedTo),
				n0, n1, n2, pp and tostring(pp.edgeIndex) or "nil")
		else
			local st = mpa and mpa.shipState or nil
			local dyn = st and st.dyn or nil
			key = table.concat({
				carrier, nameOf(tvsNames, tvState), "clear=" .. b(st and st.clearToLand),
				"approach=" .. b(dyn and dyn.approachingStation), "path=" .. nameOf(pathNames, mpa and mpa.pathState),
				"stop=" .. tostring(tv.stopIndex),
			}, " ")
			detail = string.format("%s wd=%s speed=%s mpa=%s", key, round(st and st.waitingDist, 1), round(speed, 0.1), tostring(mpa ~= nil))
		end
		return key, detail
	end

	local M = {}
	function M.update(userParams, state, dt)
		local now = gameTime()
		if type(now) ~= "number" then return end
		if not enumsLogged then
			enumsLogged = true
			local parts = {}
			for __, t in ipairs({ { "carrier", carrierNames }, { "flight", flightNames }, { "tvs", tvsNames }, { "path", pathNames } }) do
				local n = 0
				for __ in pairs(t[2]) do n = n + 1 end
				parts[#parts + 1] = t[1] .. "=" .. n
			end
			log("enum names resolved: " .. table.concat(parts, " "))
		end
		local s = state:get()
		if type(s) ~= "table" or type(s.last) ~= "table" then
			s = { t = now, tDump = now, last = {} }
			state:set(s)
			log("started at gameTime=" .. now)
			return
		end
		if now - (s.t or 0) < SAMPLE_MS then return end
		s.t = now
		local dump = now - (s.tDump or 0) >= DUMP_MS
		if dump then s.tDump = now end
		local tvs = api.engine.system.transportVehicleSystem
		local E = api.type["enum"].TransportVehicleState
		local lines, seen = 0, {}
		for __, stateName in ipairs({ "EN_ROUTE", "AT_TERMINAL", "GOING_TO_DEPOT", "IN_DEPOT" }) do
			local ok, list = pcall(tvs.getVehiclesWithState, E[stateName])
			if ok and type(list) == "table" then
				for __, v in ipairs(list) do
					local okD, key, detail = pcall(describe, v, E[stateName])
					if okD and key then
						seen[v] = true
						if dump or s.last[v] ~= key then
							s.last[v] = key
							log(string.format("t=%d %s v=%d \"%s\" %s", now, dump and "dump" or "change", v, entityName(v), detail))
							lines = lines + 1
						end
					elseif not okD then
						log("error for vehicle " .. tostring(v) .. ": " .. tostring(key))
					end
				end
			end
		end
		for v in pairs(s.last) do if not seen[v] then s.last[v] = nil end end
		state:set(s)
	end
	return M
end
