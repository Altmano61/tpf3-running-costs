-- Running Cost Breakdown for Transport Fever 3: the sampler (game script).
--
-- Every SAMPLE_MS of game time it classifies every vehicle (cost_classes.lua:
-- driving / waiting en route / at terminal / in depot) and accumulates the
-- time and the cost of that state into the vehicle's history (cost_history.lua,
-- a ring of buckets covering one default game year). The cost is split into
-- the vehicle's static rate (the sum of its parts' runningCosts, what a
-- healthy vehicle costs) and the maintenance-state surcharge on top
-- (getRunningCost - static), both charged at the state's factor, so the GUI
-- can show the surcharge as its own row.
--
-- update() is dispatched to one of the sim pool threads, each with its own
-- Lua state: nothing persistent lives in locals, everything goes through the
-- game-script state (saved with the game). State layout:
--   { version, tSample, tPerfLog, fails,
--     v = { [vehicle] = History },
--     summary = { [vehicle] = flat Summary (cost_history.deflateSummary) + { line, rc, static, key, first } },
--     inc = { [vehicle or "L<line>"] = Ring with bucket.inc } (income records consumed
--           from income.script.lua's queue state), incSeen = { [recordId] = t },
--     statR = { [vehicle] = static rate per year }, statT = { [vehicle] = ms of the last check },
--     statC = { [vehicle] = carrier: 1 air, 2 water, 0 other } (0.4.0, read with the static rate),
--     airG = { [station group] = Ring with bucket.g } (missed approaches per airport, 0.5.0; pruned when empty),
--     airF / airH / airA / airS = { [aircraft] = last flight state / 1 while holding / 1 while a drop may be
--           counted / stop index while holding } (holding.lua memory),
--     pool = { [building] = Pool (cost_history.newPool: one sliding-span entry per vehicle) },
--     mb = { ["<vehicle>:<building>"] = last seen ms } (one flat table), poolInfo = { buildings, entries }, poolStored,
--     perf = { lastMs, n, get, cls, lua, set, setN = sums since the last perf line } }
-- Vehicles come from transportVehicleSystem.getVehiclesWithState (four lists)
-- and getLine2VehicleMap; the TRANSPORT_VEHICLE component is only read when
-- the static rate is (re)checked, every STATIC_RECHECK_MS or when the running
-- cost drops below it (consist changed).
-- A version mismatch rebuilds the state from scratch.

function data()
	local VERSION = "0.5.1"
	local STATE_VERSION = 7       -- 2: histories carry `first`; 3: income rings `inc` (0.2.0); 5: pools + maintainedBy (0.3.0); 6/7: flat summaries, buckets packed into strings (0.3.1)
	local MAX_FAILS = 10          -- consecutive failed steps before the state is rebuilt
	local SAMPLE_MS = 3000       -- game time between samples (8.5 ms per sample at 364 vehicles: state get 2.8, classify 2.8, set 2.9)
	local SWEEP_MS = 60000       -- game time between sweeps of rings keyed by lines / buildings
	local PERF_LOG_MS = 300000   -- game time between perf log lines
	local pendingSet = nil       -- set time of this thread's previous sample, not yet summed
	local luaMs = 0              -- time inside cost_history (add + window) of the current sample
	local LOG_PREFIX = "[kampfmoehre_running_costs] "

	local classes = ug_require "kampfmoehre_running_costs_1::/running_costs/cost_classes.lua"
	local history = ug_require "kampfmoehre_running_costs_1::/running_costs/cost_history.lua"
	local holding = ug_require "kampfmoehre_running_costs_1::/running_costs/holding.lua"
	local airports = ug_require "kampfmoehre_running_costs_1::/running_costs/airport_counts.lua"

	local gameLog = log   -- the game's global log table, before the local below shadows it
	local function log(text)
		if type(gameLog) == "table" and gameLog.message then
			gameLog.message(LOG_PREFIX .. tostring(text))
		else
			print(LOG_PREFIX .. tostring(text))
		end
	end

	local errorCount = 0
	local incomeSeen = false   -- log once per thread when the income queue delivered
	local INCOME_GS_NAME = "kampfmoehre_running_costs_1::/running_costs/income.gs"
	local incomeEntity = nil
	-- the queue of the income collector's state (a copy; tiny), or nil
	local function incomeQueue()
		if incomeEntity == nil then
			local ok, e = pcall(api.engine.system.gameScriptSystem.getEntityForGameScript, INCOME_GS_NAME)
			if ok and type(e) == "number" and e >= 0 then incomeEntity = e else return nil end
		end
		local ok, gs = pcall(api.engine.getComponent, incomeEntity, api.type.ComponentType.GAME_SCRIPT)
		if not ok or not gs then return nil end
		local okS, st = pcall(function() return gs.state end)
		if okS and type(st) == "table" and type(st.q) == "table" then return st.q end
		return nil
	end
	local STATE_NAMES = { "IN_DEPOT", "EN_ROUTE", "AT_TERMINAL", "GOING_TO_DEPOT" }

	-- static running cost per year of a consist: sum of the parts' metadata
	-- runningCosts (the rate of a healthy vehicle); cached per model id
	local modelStatic = {}
	local function staticPerYear(tv)
		local sum = 0
		local cfg = tv.transportVehicleConfig
		local parts = cfg and cfg.vehicles
		if type(parts) ~= "table" then return 0 end
		for __, part in ipairs(parts) do
			local id = part.part and part.part.modelId
			if id ~= nil then
				local v = modelStatic[id]
				if v == nil then
					v = 0
					local ok, model = pcall(api.res.modelRep.get, id)
					local maint = ok and model and model.metadata and model.metadata.maintenance
					if maint and type(maint.runningCosts) == "number" and maint.runningCosts > 0 then
						v = maint.runningCosts
					end
					modelStatic[id] = v
				end
				sum = sum + v
			end
		end
		return sum
	end

	-- Carrier enum value -> 1 air, 2 water, 0 other (compared as strings: the
	-- enum values are not iterable, see docs/probes/holding_probe)
	local carrierAir, carrierWater = nil, nil
	pcall(function()
		local C = api.type["enum"].Carrier
		carrierAir, carrierWater = tostring(C.AIR), tostring(C.WATER)
	end)
	local function carrierCode(carrier)
		if carrier == nil then return 0 end
		local c = tostring(carrier)
		if c == carrierAir then return 1 end
		if c == carrierWater then return 2 end
		return 0
	end

	-- consist static rate per vehicle, kept in the state: { r = per year, t = last check }
	local STATIC_RECHECK_MS = 60000
	local MAX_PENALTY_FACTOR = 1.3
	local function staticOf(s, v, now, rc)
		s.statR = s.statR or {}
		s.statT = s.statT or {}
		local r, t = s.statR[v], s.statT[v]
		-- recheck early when rc dropped below the static rate (consist shrunk)
		-- or rose further above it than the condition penalty can explain
		-- (consist grew; the penalty tops out around +23 %)
		if r and now - (t or 0) < STATIC_RECHECK_MS and rc >= r and rc <= r * MAX_PENALTY_FACTOR then
			return r
		end
		local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
		r = tv and staticPerYear(tv) or 0
		s.statR[v], s.statT[v] = r, now
		s.statC = s.statC or {}
		local cc = tv and carrierCode(tv.carrier) or 0
		if tv and tv.carrier == nil then
			-- no carrier field in this build: the components tell (probe fallback)
			local okA, ac = pcall(api.engine.getComponent, v, api.type.ComponentType.AIRCRAFT)
			if okA and ac then
				cc = 1
			else
				local okM, mpa = pcall(api.engine.getComponent, v, api.type.ComponentType.MOVE_PATH_AIRCRAFT)
				if okM and mpa and mpa.shipState then cc = 2 end
			end
		end
		s.statC[v] = cc
		return r
	end

	-- standing in the approach of a station (0.4.0): the queue before an
	-- occupied terminal or platform. MOVE_PATH.dyn.approachingStation is clean
	-- for standing vehicles and the read costs 1-3 us (docs/probes/station_probe)
	local function atStation(v)
		local okM, mp = pcall(api.engine.getComponent, v, api.type.ComponentType.MOVE_PATH)
		return okM and mp ~= nil and mp.dyn ~= nil and mp.dyn.approachingStation == true
	end

	-- holding detection (0.4.0): the extra component reads only for aircraft
	-- (carrier 1) and ships (2) that are en route; one observation per sample
	-- for holding.step()
	local function observe(v, cc, speed, withStop)
		local okM, mpa = pcall(api.engine.getComponent, v, api.type.ComponentType.MOVE_PATH_AIRCRAFT)
		if not okM then mpa = nil end
		if cc == 2 then
			local st = mpa and mpa.shipState or nil
			local dyn = st and st.dyn or nil
			return { carrier = "WATER", enRoute = true, speed = speed, approaching = dyn and dyn.approachingStation == true or false }
		end
		local st = mpa and mpa.aircraftState or nil
		local okA, ac = pcall(api.engine.getComponent, v, api.type.ComponentType.AIRCRAFT)
		if not okA then ac = nil end
		-- the stop index (a new leg ends an episode) costs a TRANSPORT_VEHICLE
		-- copy, so it is read only while an episode runs
		local okT, tv = false, nil
		if withStop then okT, tv = pcall(api.engine.getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE) end
		local f = st and st.flightState or nil
		if type(f) ~= "number" then f = tonumber(tostring(f)) end
		return {
			carrier = "AIR", enRoute = true, speed = speed,
			flight = f,
			landRes = ac and ac.reservedLandingRunway == true or false,
			alt = st and st.dyn and st.dyn.alt or nil,
			cruise = st and st.cruiseAlt or nil,
			stop = (okT and tv) and tv.stopIndex or nil,
		}
	end

	-- class keys for cost_history.window (fast path, no field scan)
	local CLASS_KEYS = {}
	for i, cl in ipairs(classes.CLASSES) do CLASS_KEYS[i] = cl.key end

	local function vehicleStateEnum()
		return api.type["enum"] and api.type["enum"].TransportVehicleState
	end

	-- maintenance pools (0.3.0): every depot / maintenance building charges
	-- 25 % of the running cost of each vehicle it lists (CLAUDE.md "Maintenance
	-- Vehicles"); one list call per building, one condition read per listed
	-- vehicle. s.pool[d] = Pool (one sliding-span entry per vehicle, see
	-- cost_history.addPool), s.mb["<v>:<d>"] = last seen ms for the "also
	-- covered elsewhere" marker (one flat table instead of one per vehicle).
	local function samplePools(s, now, dtMs, rcOf, yearMs)
		s.pool = s.pool or {}
		s.mb = s.mb or {}
		local buildings, entries = 0, 0
		local okD, depots = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.VEHICLE_DEPOT)
		if not okD or type(depots) ~= "table" then return buildings, entries end
		local tvs = api.engine.system.transportVehicleSystem
		for __, d in ipairs(depots) do
			local okL, list = pcall(tvs.getVehiclesForMaintenanceStation, d)
			if okL and type(list) == "table" and #list > 0 then
				buildings = buildings + 1
				local pool = s.pool[d]
				if pool == nil then
					pool = history.newPool(now)
					s.pool[d] = pool
				end
				for __, v in ipairs(list) do
					entries = entries + 1
					local okC, cond = pcall(api.engine.util.vehicle.getVehicleMaintenanceState, v)
					if not okC or type(cond) ~= "number" then cond = nil end
					history.addPool(pool, now, dtMs, v, rcOf[v] or 0, cond, yearMs, yearMs)
					s.mb[v .. ":" .. d] = now
				end
			end
		end
		return buildings, entries
	end

	local function sample(s, now, dtMs)
		local yearMs = api.util.getDefaultYearDuration()
		local tvs = api.engine.system.transportVehicleSystem
		local enum = vehicleStateEnum()
		-- vehicles per state: four list calls instead of one component copy per vehicle
		local stateOf = {}
		if not enum then return nil end
		for __, name in ipairs(STATE_NAMES) do
			if enum[name] == nil then return nil end
			local ok, list = pcall(tvs.getVehiclesWithState, enum[name])
			if not ok or type(list) ~= "table" then return nil end   -- incomplete list: skip, keep histories
			for __, v in ipairs(list) do stateOf[v] = name end
		end
		local lineOf = {}
		local okM, map = pcall(tvs.getLine2VehicleMap)
		if okM and type(map) == "table" then
			for line, list in pairs(map) do
				for __, v in ipairs(list) do lineOf[v] = line end
			end
		end
		-- tables added in 0.4.0 (states of 0.3.1 lack them; same STATE_VERSION)
		s.statC = s.statC or {}
		s.airF = s.airF or {}
		s.airH = s.airH or {}
		s.airS = s.airS or {}
		s.airG = s.airG or {}   -- 0.5.0: missed approaches per airport (station group)
		s.airA = s.airA or {}
		local count = 0
		local nAir, nWater = 0, 0   -- perf line: how many vehicles get the holding reads
		local rcOf = {}   -- running cost per vehicle, reused by the pool sampler
		local luaClock = api.type.Clock.new()
		luaMs = 0
		for v, name in pairs(stateOf) do
			count = count + 1
			local speed = 0
			local moving = name == "EN_ROUTE" or name == "GOING_TO_DEPOT"
			if moving then
				speed = api.engine.util.vehicle.getSpeed(v) or 0
			end
			local rc = api.engine.util.vehicle.getRunningCost(v) or 0
			rcOf[v] = rc
			local static = staticOf(s, v, now, rc)
			-- holding (0.4.0): aircraft and ships only
			local hold, goAround = false, false
			local cc = s.statC[v]
			if cc == 1 then nAir = nAir + 1 elseif cc == 2 then nWater = nWater + 1 end
			if moving and (cc == 1 or cc == 2) then
				local prev = nil
				if cc == 1 then prev = { f = s.airF[v], h = s.airH[v] or 0, a = s.airA[v], stop = s.airS[v] } end
				local nxt
				nxt, hold, goAround = holding.step(prev, observe(v, cc, speed, prev ~= nil and prev.h == 1))
				if nxt then
					s.airF[v], s.airH[v], s.airA[v] = nxt.f, nxt.h, nxt.a
					s.airS[v] = nxt.h == 1 and nxt.stop or nil
				end
			elseif cc == 1 and s.airH[v] == 1 then
				s.airH[v], s.airS[v] = 0, nil   -- parked or at the terminal: the episode is over
			end
			-- road, tram and rail standing en route: before a station or in traffic?
			local station = false
			if moving and not hold and cc ~= 1 and cc ~= 2 and speed < classes.STANDING_SPEED then
				station = atStation(v)
			end
			local key = classes.classify(name, speed, nil, hold, station)
			if static <= 0 then static = rc end   -- unknown parts: no surcharge, cost at rc
			local h = s.v[v]
			if h == nil then
				h = history.new(now)
				s.v[v] = h
			end
			local tLua = luaClock:getTime()
			history.add(h, now, dtMs, key, static, math.max(0, rc - static), classes.factor(key), yearMs)
			if goAround then
				history.addCount(h, now, "g", 1)
				-- 0.5.0: also count it for the airport the aircraft was approaching:
				-- the station group of its current line stop (two component reads
				-- per go-around, nothing per sample)
				local line = lineOf[v]
				if type(line) == "number" and line >= 0 then
					local okT, tv = pcall(api.engine.getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
					local okL, lc = pcall(api.engine.getComponent, line, api.type.ComponentType.LINE)
					local sg = (okT and tv and okL) and airports.stopStationGroup(lc, tv.stopIndex) or nil
					if sg then airports.record(s.airG, sg, now, history) end
				end
			end
			local w = history.window(h, now, yearMs, classes.factor, yearMs, CLASS_KEYS)
			luaMs = luaMs + (luaClock:getTime() - tLua) / 1000
			w.line = lineOf[v] or -1
			w.first = h.first   -- the income table (0.2.0) shares this window
			w.rc = rc
			w.static = static
			w.key = key
			s.summary[v] = history.deflateSummary(w)   -- flat in the state, inflated by the GUI
		end
		local gone = nil   -- vehicles that left since the last sample
		for v in pairs(s.v) do
			if not stateOf[v] then
				s.v[v] = nil
				s.summary[v] = nil
				if s.statR then s.statR[v] = nil end
				if s.statT then s.statT[v] = nil end
				s.statC[v], s.airF[v], s.airH[v], s.airA[v], s.airS[v] = nil, nil, nil, nil, nil
				if s.inc then s.inc[v] = nil end
				gone = gone or {}
				gone[tostring(v) .. ":"] = true
			end
		end
		if gone and s.mb then
			for k in pairs(s.mb) do
				local prefix = k:match("^%d+:")
				if prefix and gone[prefix] then s.mb[k] = nil end
			end
		end
		local buildings, entries = samplePools(s, now, dtMs, rcOf, yearMs)
		s.poolInfo = { buildings = buildings, entries = entries, air = nAir, water = nWater }
		-- every ~60 s: income rings of lines and pool rings of buildings that no
		-- longer exist, maintainedBy entries older than the window
		if (s.sweep or 0) + SWEEP_MS <= now then
			s.sweep = now
			for k in pairs(s.inc or {}) do
				if type(k) == "string" then
					local line = tonumber(k:match("^L(%d+)$"))
					local okE, exists = line and pcall(api.engine.entityExists, line)
					if not line or (okE and not exists) then s.inc[k] = nil end
				end
			end
			local dropped = {}
			local stored = 0
			for d, pool in pairs(s.pool or {}) do
				local okE, exists = pcall(api.engine.entityExists, d)
				if okE and not exists then
					s.pool[d] = nil
					dropped[d] = true
				else
					history.prunePool(pool, now, yearMs)
					for __ in pairs(pool.v or {}) do stored = stored + 1 end
				end
			end
			s.poolStored = stored   -- entries kept in the state (perf line)
			s.airports = airports.prune(s.airG, now, yearMs, function(e)
				local okE, ex = pcall(api.engine.entityExists, e)
				return not (okE and ex == false)
			end, history)
			for k, t in pairs(s.mb or {}) do
				local d = tonumber(k:match(":(%d+)$"))
				if d == nil or dropped[d] or type(t) ~= "number" or now - t > yearMs then s.mb[k] = nil end
			end
		end
		return count
	end

	-- size of a state subtree: tables and leaf values (perf line, every PERF_LOG_MS)
	local function sizeOf(t)
		local tables, values = 0, 0
		local stack = { t }
		while #stack > 0 do
			local cur = table.remove(stack)
			tables = tables + 1
			for __, v in pairs(cur) do
				if type(v) == "table" then stack[#stack + 1] = v else values = values + 1 end
			end
		end
		return tables, values
	end
	local function stateSizes(s)
		local parts = {}
		for __, k in ipairs({ "v", "summary", "inc", "incSeen", "pool", "mb", "statR", "statT", "statC", "airF", "airH", "airA", "airS", "airG" }) do
			if type(s[k]) == "table" then
				local t, n = sizeOf(s[k])
				parts[#parts + 1] = string.format("%s %d/%d", k, t, n)
			end
		end
		local t, n = sizeOf(s)
		return string.format("state %d tables / %d values (%s)", t, n, table.concat(parts, ", "))
	end

	local function step(state)
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		local now = gt and gt.gameTime
		if type(now) ~= "number" then return end
		local clock = api.type.Clock.new()
		local s = state:get()
		local tGet = clock:getTime() / 1000
		if type(s) ~= "table" or s.version ~= STATE_VERSION or type(s.tSample) ~= "number" or s.tSample > now
			or type(s.v) ~= "table" or type(s.summary) ~= "table" or type(s.pool) ~= "table" then
			s = { version = STATE_VERSION, tSample = now, tPerfLog = now, fails = 0,
				v = {}, summary = {}, inc = {}, pool = {}, mb = {}, statR = {}, statT = {}, statC = {}, airF = {}, airH = {}, airA = {}, airS = {}, airG = {},
				perf = { lastMs = 0, maxMs = 0 } }
			state:set(s)
			log("v" .. VERSION .. " sampler started (fresh state) at gameTime=" .. now)
			return
		end
		if now - s.tSample < SAMPLE_MS then return end
		-- after a long pause one sample must not fill more than one bucket
		local dtMs = math.min(now - s.tSample, history.BUCKET_MS)
		s.tSample = now
		local count = sample(s, now, dtMs)
		if count == nil then return end   -- vehicle lists unavailable this tick: nothing written
		-- income records queued by income.script.lua (its own, tiny state)
		s.inc = s.inc or {}
		s.incSeen = s.incSeen or {}
		local queue = incomeQueue()
		if queue then
			local moved = history.queueConsume(queue, s.inc, s.incSeen, now)
			if moved > 0 then
				s.incItems = (s.incItems or 0) + moved
				if not incomeSeen then
					incomeSeen = true
					log("income queue read from income.script.lua: " .. moved .. " records consumed")
				end
			end
		end
		s.fails = 0
		local tSample = clock:getTime() / 1000
		-- perf sums live in the state, so they must be written before the set;
		-- the set time of a sample is only known afterwards and is carried in
		-- a module local to this thread's next sample (counted separately)
		local perf = s.perf or { lastMs = 0, maxMs = 0 }
		s.perf = perf
		perf.n = (perf.n or 0) + 1
		perf.get = (perf.get or 0) + tGet
		perf.cls = (perf.cls or 0) + (tSample - tGet)
		perf.lua = (perf.lua or 0) + luaMs
		if pendingSet then
			perf.setN = (perf.setN or 0) + 1
			perf.set = (perf.set or 0) + pendingSet
			pendingSet = nil
		end
		local logNow = now - (s.tPerfLog or 0) >= PERF_LOG_MS
		if logNow then s.tPerfLog = now end
		state:set(s)
		local ms = clock:getTime() / 1000
		pendingSet = ms - tSample
		if logNow then
			perf.setN = (perf.setN or 0) + 1
			perf.set = (perf.set or 0) + pendingSet
			pendingSet = nil
			local n, setN = math.max(1, perf.n or 1), math.max(1, perf.setN or 1)
			local meanGet, meanCls, meanSet = perf.get / n, perf.cls / n, perf.set / setN
			local pi = s.poolInfo or {}
			log(string.format("perf: mean of %d samples %.2f ms (state get %.2f, classify %.2f of which history %.2f, state set %.2f), last %.2f ms, %d vehicles (%d aircraft, %d ships), %d buildings, %d pool entries (%d stored), %d income records consumed since the last line; %s",
				n, meanGet + meanCls + meanSet, meanGet, meanCls, (perf.lua or 0) / n, meanSet, ms, count, pi.air or 0, pi.water or 0, pi.buildings or 0, pi.entries or 0, s.poolStored or 0, s.incItems or 0, stateSizes(s)))
			perf.lastMs, perf.n, perf.get, perf.cls, perf.lua, perf.set, perf.setN = ms, 0, 0, 0, 0, 0, 0
			s.incItems = 0
			state:set(s)   -- the reset sums and counters (a second copy, once per PERF_LOG_MS)
		end
	end

	-- a step that keeps failing on a state of the current version (e.g. a
	-- damaged save) is given up after MAX_FAILS: the state is rebuilt
	local function noteFailure(state)
		pcall(function()
			local s = state:get()
			if type(s) ~= "table" then return end
			s.fails = (s.fails or 0) + 1
			if s.fails >= MAX_FAILS then
				log("resetting the state after " .. s.fails .. " failed steps in a row")
				state:set({ version = -1 })
			else
				state:set(s)
			end
		end)
	end

	local function update(userParams, state, dt)
		if dt == 0 then return end
		local ok, err = pcall(step, state)
		if not ok then
			errorCount = errorCount + 1
			if errorCount <= 10 then log("error: " .. tostring(err)) end
			noteFailure(state)
		end
	end

	return {
		update = update,
	}
end
