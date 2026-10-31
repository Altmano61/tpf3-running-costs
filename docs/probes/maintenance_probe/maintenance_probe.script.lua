-- TEMPORARY diagnostic: what triggers "Maintenance Vehicles" charges and how
-- they are calculated. Logs to stdout.txt, prefix [kampfmoehre_maint_probe].
--
-- Every SAMPLE_MS of game time:
--  * every depot / maintenance station (entities with a VEHICLE_DEPOT
--    component): the VEHICLE_MAINTENANCE balance of its construction since
--    the probe start; a change is logged as a "booking" with the vehicles
--    the station maintained during the last interval and their condition
--    gain in that interval;
--  * every vehicle: maintenance state (0..1, 1 = new), the station
--    maintaining it; a state increase is logged with the vehicle's running
--    cost per year, depreciated value and purchase price of its parts, so
--    the booked amount can be fitted against state gain × price;
--  * the player's total VEHICLE_MAINTENANCE since the probe start, to see
--    whether charges come in 60 s lumps like the running costs.
-- State lives in the game-script state (update runs on arbitrary pool threads).

function data()
	local VERSION = 1
	local SAMPLE_MS = 2000
	local LOG_PREFIX = "[kampfmoehre_maint_probe] "

	local gameLog = log
	local function log(text)
		if type(gameLog) == "table" and gameLog.message then gameLog.message(LOG_PREFIX .. tostring(text)) else print(LOG_PREFIX .. tostring(text)) end
	end
	local errorCount = 0

	local function fmt(n)
		if type(n) ~= "number" then return tostring(n) end
		if math.abs(n) >= 100 then return string.format("%.0f", n) end
		return string.format("%.3f", n)
	end

	local function gameTime()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		return gt and gt.gameTime or nil
	end

	local function balance(entity, t0, t1)
		local ok, v = pcall(api.engine.util.finance.calculateBalance, { entity }, t0, t1, true,
			api.type.JournalEntry.Maintenance.VEHICLE_MAINTENANCE)
		return (ok and type(v) == "number") and v or nil
	end

	local function entityName(e)
		local ok, n = pcall(api.engine.util.getEntityName, e)
		return (ok and n) or tostring(e)
	end

	local function vehicleFacts(v)
		local okT, tv = pcall(api.engine.getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
		local okS, st = pcall(api.engine.util.vehicle.getVehicleMaintenanceState, v)
		local okR, rc = pcall(api.engine.util.vehicle.getRunningCost, v)
		local okD, dv = pcall(api.engine.util.vehicle.getDepreciatedValue, v)
		local price = 0
		if okT and tv and tv.transportVehicleConfig and type(tv.transportVehicleConfig.vehicles) == "table" then
			for __, part in ipairs(tv.transportVehicleConfig.vehicles) do
				local okP, pp = pcall(api.engine.util.vehicle.getPartPrice, part)
				if okP and type(pp) == "number" then price = price + pp end
			end
		end
		return {
			state = (okS and type(st) == "number") and st or nil,
			station = (okT and tv) and tv.maintenanceStation or nil,
			rc = (okR and type(rc) == "number") and rc or nil,
			value = (okD and type(dv) == "number") and dv or nil,
			price = price,
			tvState = okT and tv and tv.state or nil,
		}
	end

	local function step(state)
		local now = gameTime()
		if type(now) ~= "number" then return end
		local s = state:get()
		if type(s) ~= "table" or s.version ~= VERSION then
			s = { version = VERSION, tStart = now, tSample = now, stations = {}, vehicles = {}, playerBooked = 0 }
			state:set(s)
			log("probe started at gameTime=" .. now .. " (bookings and condition changes are logged as they happen)")
			return
		end
		if now - s.tSample < SAMPLE_MS then return end
		local dt = now - s.tSample
		s.tSample = now

		-- which vehicles are maintained right now (by any depot / station), and
		-- the running cost of each station's pool integrated over the samples
		-- (rc × seconds) since its last booking: the fee should be 0.25 × that / 1461
		local maintainedBy = {}
		s.poolRcSec = s.poolRcSec or {}
		local okE0, depots0 = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.VEHICLE_DEPOT)
		if okE0 and type(depots0) == "table" then
			for __, d in ipairs(depots0) do
				local okV, list = pcall(api.engine.system.transportVehicleSystem.getVehiclesForMaintenanceStation, d)
				if okV and type(list) == "table" then
					local rcSum = 0
					for __, v in ipairs(list) do
						maintainedBy[v] = d
						local okR, rc = pcall(api.engine.util.vehicle.getRunningCost, v)
						if okR and type(rc) == "number" then rcSum = rcSum + rc end
					end
					s.poolRcSec[d] = (s.poolRcSec[d] or 0) + rcSum * dt / 1000
				end
			end
		end
		-- vehicles: state changes and who maintains them
		local gains = {}   -- station -> { {v, from, to} }
		local vehicles = api.engine.util.vehicle.getVehicles()
		local seen = {}
		for __, v in ipairs(vehicles) do
			seen[v] = true
			local f = vehicleFacts(v)
			local prev = s.vehicles[v]
			if f.state ~= nil then
				if prev and prev.state ~= nil and f.state > prev.state + 1e-6 then
					local st = f.station or prev.station or -1
					gains[st] = gains[st] or {}
					gains[st][#gains[st] + 1] = { v = v, from = prev.state, to = f.state }
					log(string.format("condition up: vehicle %d (%s) %.4f -> %.4f (+%.4f) station=%s tvState=%s runningCost/yr=%s value=%s partsPrice=%s",
						v, entityName(v), prev.state, f.state, f.state - prev.state, tostring(st), tostring(f.tvState), fmt(f.rc), fmt(f.value), fmt(f.price)))
				elseif prev and prev.station ~= f.station then
					log(string.format("vehicle %d (%s): maintenance station %s -> %s, state %.4f", v, entityName(v), tostring(prev.station), tostring(f.station), f.state))
				end
				s.vehicles[v] = { state = f.state, station = f.station }
				-- while a vehicle is being maintained, log its state every ~10 s even without a change
				if maintainedBy[v] ~= nil or (f.station or -1) >= 0 then
					s.lastTick = s.lastTick or {}
					if (s.lastTick[v] or 0) + 10000 <= now then
						s.lastTick[v] = now
						log(string.format("tick: vehicle %d state=%s maintainedBy=%s tv.maintenanceStation=%s tvState=%s runningCost/yr=%s (= %s/min at 100 %%) value=%s",
							v, fmt(f.state), tostring(maintainedBy[v]), tostring(f.station), tostring(f.tvState), fmt(f.rc), fmt((f.rc or 0) * 60 / 1461), fmt(f.value)))
					end
				end
			end
		end
		for v in pairs(s.vehicles) do if not seen[v] then s.vehicles[v] = nil end end

		-- stations: bookings since the probe start
		local okE, depots = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.VEHICLE_DEPOT)
		if okE and type(depots) == "table" then
			for __, d in ipairs(depots) do
				local okC, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForDepot, d)
				local account = (okC and type(con) == "number" and con >= 0) and con or d
				local b = balance(account, s.tStart, now)
				if b ~= nil then
					local rec = s.stations[d] or { booked = 0 }
					if math.abs(b - rec.booked) > 0.5 then
						local okV, maintained = pcall(api.engine.system.transportVehicleSystem.getVehiclesForMaintenanceStation, d)
						local names = {}
						if okV and type(maintained) == "table" then
							for __, v in ipairs(maintained) do
								local mf = vehicleFacts(v)
								names[#names + 1] = string.format("%d state=%s rc=%s", v, fmt(mf.state), fmt(mf.rc))
							end
						end
						local okP, dep = pcall(api.engine.getComponent, d, api.type.ComponentType.VEHICLE_DEPOT)
						local pool = (okP and dep) and dep.maintenancePool or "?"
						local rcSum = 0
						if okV and type(maintained) == "table" then
							for __, v in ipairs(maintained) do rcSum = rcSum + (vehicleFacts(v).rc or 0) end
						end
						local perMin = rcSum * 60 / 1461
						if perMin > 0 then
							log(string.format("  ratio (snapshot): booked %s / running cost per minute of the maintained vehicles %s = %.3f", fmt(-(b - rec.booked)), fmt(perMin), -(b - rec.booked) / perMin))
						end
						local integ = (s.poolRcSec[d] or 0) / 1461   -- running cost accrued by the pool since the last booking
						if integ > 0 then
							log(string.format("  ratio (integrated): booked %s / pool running cost over the interval %s = %.3f", fmt(-(b - rec.booked)), fmt(integ), -(b - rec.booked) / integ))
						end
						s.poolRcSec[d] = 0
						log(string.format("booking: station %d (%s) VEHICLE_MAINTENANCE %s -> %s (delta %s) at gameTime=%d, %.1f s after the last sample; maintaining now: [%s] pool=%s",
							d, entityName(account), fmt(rec.booked), fmt(b), fmt(b - rec.booked), now, dt / 1000, table.concat(names, ","), tostring(pool)))
						local g = gains[d]
						if g then
							for __, x in ipairs(g) do
								log(string.format("  gain this interval: vehicle %d %.4f -> %.4f (+%.4f)", x.v, x.from, x.to, x.to - x.from))
							end
						end
						rec.booked = b
					end
					s.stations[d] = rec
				end
			end
		end

		-- player total
		local pb = balance(api.engine.util.getPlayer(), s.tStart, now)
		if pb ~= nil and math.abs(pb - (s.playerBooked or 0)) > 0.5 then
			log(string.format("player total VEHICLE_MAINTENANCE %s -> %s (delta %s) at gameTime=%d (%d ms into the minute)", fmt(s.playerBooked or 0), fmt(pb), fmt(pb - (s.playerBooked or 0)), now, now % 60000))
			s.playerBooked = pb
		end
		state:set(s)
	end

	local function update(userParams, state, dt)
		if dt == 0 then return end
		local ok, err = pcall(step, state)
		if not ok then
			errorCount = errorCount + 1
			if errorCount <= 10 then log("error: " .. tostring(err)) end
		end
	end

	return { update = update }
end
