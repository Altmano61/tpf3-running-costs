-- TEMPORARY diagnostic (2026-11-01): can "waiting in front of a station" be told
-- from "waiting in traffic"? Every SAMPLE_MS of game time, for every EN_ROUTE /
-- GOING_TO_DEPOT road or rail vehicle slower than 0.5 m/s: MOVE_PATH.dyn
-- (approachingStation, timeStanding, pathPos.edgeIndex, #path.edges), blocked,
-- state, plus the wall-clock cost of the MOVE_PATH read. A line per change of
-- the discrete fields, a full dump every DUMP_MS, and a cost summary per dump.
-- Prefix [kampfmoehre_station_probe].
function data()
	local SAMPLE_MS = 2000
	local DUMP_MS = 20000
	local STANDING = 0.5
	local LOG_PREFIX = "[kampfmoehre_station_probe] "

	local gameLog = log
	local function log(text)
		if type(gameLog) == "table" and gameLog.message then gameLog.message(LOG_PREFIX .. tostring(text)) else print(LOG_PREFIX .. tostring(text)) end
	end

	local function enumNames(enumTable, members)
		local names = {}
		for __, name in ipairs(members) do
			local ok, value = pcall(function() return enumTable[name] end)
			if ok and value ~= nil then names[tostring(value)] = name end
		end
		return names
	end
	local carrierNames = {}
	pcall(function() carrierNames = enumNames(api.type["enum"].Carrier, { "ROAD", "RAIL", "TRAM", "AIR", "WATER" }) end)
	local function nameOf(names, value)
		if value == nil then return "nil" end
		return names[tostring(value)] or tostring(value)
	end
	local function b(v) if v == nil then return "nil" end return v and "1" or "0" end
	local function num(v, step) if type(v) ~= "number" then return tostring(v) end return string.format("%." .. (step or 0) .. "f", v) end

	local function gameTime()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		return gt and gt.gameTime or nil
	end
	local function entityName(e)
		local ok, n = pcall(api.engine.util.getEntityName, e)
		return (ok and n) or tostring(e)
	end

	local M = {}
	function M.update(userParams, state, dt)
		local now = gameTime()
		if type(now) ~= "number" then return end
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
		local clock = api.type.Clock.new()
		local tvs = api.engine.system.transportVehicleSystem
		local E = api.type["enum"].TransportVehicleState
		local seen, reads, readUs, maxUs, standing = {}, 0, 0, 0, 0
		for __, stateName in ipairs({ "EN_ROUTE", "GOING_TO_DEPOT" }) do
			local ok, list = pcall(tvs.getVehiclesWithState, E[stateName])
			if ok and type(list) == "table" then
				for __, v in ipairs(list) do
					local okS, speed = pcall(api.engine.util.vehicle.getSpeed, v)
					speed = (okS and type(speed) == "number") and speed or 99
					if speed < STANDING then
						standing = standing + 1
						local t0 = clock:getTime()
						local okM, mp = pcall(api.engine.getComponent, v, api.type.ComponentType.MOVE_PATH)
						local us = clock:getTime() - t0
						reads, readUs = reads + 1, readUs + us
						if us > maxUs then maxUs = us end
						local okT, tv = pcall(api.engine.getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
						local carrier = (okT and tv) and nameOf(carrierNames, tv.carrier) or "?"
						if carrier == "ROAD" or carrier == "RAIL" or carrier == "TRAM" then
							local dyn = (okM and mp) and mp.dyn or nil
							local edges = (okM and mp and mp.path and type(mp.path.edges) == "table") and #mp.path.edges or -1
							local idx = dyn and dyn.pathPos and dyn.pathPos.edgeIndex or nil
							local key = table.concat({ carrier, stateName, "appr=" .. b(dyn and dyn.approachingStation),
								"blocked=" .. tostring(okM and mp and mp.blocked), "left=" .. tostring(edges >= 0 and idx and (edges - 1 - idx) or "nil"),
								"stop=" .. tostring(okT and tv and tv.stopIndex), "doors=" .. b(okT and tv and tv.doorsOpen) }, " ")
							seen[v] = true
							if dump or s.last[v] ~= key then
								s.last[v] = key
								log(string.format("t=%d %s v=%d \"%s\" %s standing=%ss edges=%d idx=%s read=%dus", now, dump and "dump" or "change", v, entityName(v), key,
									num(dyn and dyn.timeStanding, 1), edges, tostring(idx), us))
							end
						end
					end
				end
			end
		end
		for v in pairs(s.last) do if not seen[v] then s.last[v] = nil end end
		if dump then
			log(string.format("t=%d cost: %d standing vehicles, %d MOVE_PATH reads, %.2f ms total, mean %.0f us, max %d us", now, standing, reads, readUs / 1000, reads > 0 and readUs / reads or 0, maxUs))
		end
		state:set(s)
	end
	return M
end
