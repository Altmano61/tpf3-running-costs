-- TEMPORARY diagnostic (2026-11-13): can infrastructure upkeep be attributed to
-- town areas? Every RUN_MS of game time:
--   1. per town (TOWN entities): the constructions whose closest town it is
--      (streetConnectorSystem.getTownClosestConstructions), with owner,
--      category (station / depot / warehouse / landmark / other), the upkeep
--      computed like the station window does (MAINTENANCE_COST x scale x year
--      multiplier + accumulatedCost) and, for stations, the game's own
--      calcMaintenanceForStationGroup; cross-check getConstructionClosestTown.
--   2. all BASE_EDGE entities: owner, STREET/TRACK, template, bridge/tunnel,
--      length (BaseEdge.distance vs. a numeric Hermite length), inside a
--      construction or free, the town of the midpoint (util.getClosestTown),
--      estimated upkeep = length x template maintenanceCost (+ bridge/tunnel
--      type maintenanceCost) x scale; sums per town and per kind.
--   3. the booked INFRASTRUCTURE maintenance of the last default year
--      (finance.calculateBalance) for comparison with the estimates.
-- Prefix [kampfmoehre_area_probe].
function data()
	local RUN_MS = 180000
	local FIRST_RUN_MS = 5000
	local DETAIL = true          -- one line per player-owned construction
	local EDGE_DETAIL_MAX = 12   -- the most expensive edges per run
	local LOG_PREFIX = "[kampfmoehre_area_probe] "

	local gameLog = log
	local function log(text)
		if type(gameLog) == "table" and gameLog.message then gameLog.message(LOG_PREFIX .. tostring(text)) else print(LOG_PREFIX .. tostring(text)) end
	end
	local function num(v, step) if type(v) ~= "number" then return tostring(v) end return string.format("%." .. (step or 0) .. "f", v) end
	local function round(v) return math.floor(v + 0.5) end

	local function gameTime()
		local gt = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		return gt and gt.gameTime or nil
	end
	local function entityName(e)
		local ok, n = pcall(api.engine.getComponent, e, api.type.ComponentType.NAME)
		if ok and n and n.name and n.name ~= "" then return n.name end
		return "#" .. tostring(e)
	end
	local function comp(e, ct)
		local ok, c = pcall(api.engine.getComponent, e, api.type.ComponentType[ct])
		if ok then return c end
		return nil
	end
	local function count(t)
		local n = 0
		local ok = pcall(function() for __ in pairs(t) do n = n + 1 end end)
		if not ok then n = -1 end
		return n
	end
	local function listLen(t)
		if t == nil then return 0 end
		local ok, n = pcall(function() return #t end)
		if ok and type(n) == "number" then return n end
		return count(t)
	end

	-- enum values are not iterable, resolve the names we need (see station_probe)
	local function enumNames(enumTable, members)
		local names = {}
		for __, name in ipairs(members) do
			local ok, value = pcall(function() return enumTable[name] end)
			if ok and value ~= nil then names[tostring(value)] = name end
		end
		return names
	end
	local roadTypeNames, edgeTypeNames = {}, {}
	pcall(function() roadTypeNames = enumNames(api.type["enum"].RoadType, { "STREET", "TRACK" }) end)
	if count(roadTypeNames) == 0 then pcall(function() roadTypeNames = enumNames(api.type.RoadType, { "STREET", "TRACK" }) end) end
	pcall(function() edgeTypeNames = enumNames(api.type["enum"].BaseEdgeType, { "NORMAL", "BRIDGE", "TUNNEL" }) end)
	if count(edgeTypeNames) == 0 then pcall(function() edgeTypeNames = enumNames(api.type.BaseEdgeType, { "NORMAL", "BRIDGE", "TUNNEL" }) end) end
	local function nameOf(names, value)
		if value == nil then return "nil" end
		return names[tostring(value)] or tostring(value)
	end

	-- Hermite length of a base edge (16 segments) to check BaseEdge.distance
	local function hermiteLength(p0, p1, t0, t1)
		local ok, len = pcall(function()
			local N = 16
			local function at(t)
				local t2, t3 = t * t, t * t * t
				local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
				return h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x,
				       h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y,
				       h00 * p0.z + h10 * t0.z + h01 * p1.z + h11 * t1.z
			end
			local l = 0
			local px, py, pz = at(0)
			for i = 1, N do
				local x, y, z = at(i / N)
				l = l + math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
				px, py, pz = x, y, z
			end
			return l
		end)
		if ok then return len end
		return nil
	end
	local function midpoint(p0, p1, t0, t1)
		local ok, v = pcall(function()
			return api.type.Vec3f.new(0.5 * (p0.x + p1.x) + 0.125 * (t0.x - t1.x),
			                          0.5 * (p0.y + p1.y) + 0.125 * (t0.y - t1.y),
			                          0.5 * (p0.z + p1.z) + 0.125 * (t0.z - t1.z))
		end)
		if ok then return v end
		return nil
	end

	local function categoryOf(con, fileName)
		local f = string.lower(fileName or "")
		if listLen(con.townBuildings) > 0 or f:find("/building/", 1, true) or f:find("town_building", 1, true) then return "townbuilding" end
		if listLen(con.stations) > 0 then return "station" end
		if f:find("perk", 1, true) or f:find("landmark", 1, true) or f:find("headquarter", 1, true) then return "landmark" end
		if f:find("warehouse", 1, true) then return "warehouse" end
		if f:find("maintenance", 1, true) then return "maintenance" end
		if listLen(con.depots) > 0 or f:find("depot", 1, true) then return "depot" end
		if f:find("industry", 1, true) then return "industry" end
		return "other"
	end

	local function run(now)
		local clock = api.type.Clock.new()
		local baseConfig = api.res.getBaseConfig()
		local scale = 1
		pcall(function() scale = baseConfig.costs["infrastructureMaintenanceScale"] or 1 end)
		local year = api.engine.util.getYear()
		local yearMult = 1
		pcall(function() yearMult = api.engine.util.construction.getCostMultiplierForYear(baseConfig.treeCostYearMultipliers, year) end)
		local chargeInterval = "?"
		pcall(function() chargeInterval = tostring(baseConfig.chargeMaintenanceInterval) end)
		local player = api.engine.util.getPlayer()
		local yearMs = api.util.getDefaultYearDuration and api.util.getDefaultYearDuration() or 1461000
		local nAccounts, nNoAccount = 0, 0
		local function booked(entity)   -- INFRASTRUCTURE maintenance booked on the entity's own account, last default year
			-- calculateBalance on an entity WITHOUT an ACCOUNT component throws an engine assertion
			-- (caught, but ~1 s each and the game stalls, 2026-11-13): check the component first
			if comp(entity, "ACCOUNT") == nil then nNoAccount = nNoAccount + 1; return nil end
			nAccounts = nAccounts + 1
			local ok, v = pcall(api.engine.util.finance.calculateBalance, { entity }, now - yearMs, now, true, api.type.JournalEntry.Maintenance.INFRASTRUCTURE)
			if ok and type(v) == "number" then return v end
			return nil
		end
		log(string.format("run at game time %s, year %d, infrastructureMaintenanceScale %s, yearMult %s, chargeMaintenanceInterval %s, player %s",
			tostring(now), year, num(scale, 3), num(yearMult, 3), chargeInterval, tostring(player)))
		-- cost config keys with "aint" in the name (what else scales upkeep?)
		pcall(function()
			local keys = {}
			for k, v in pairs(baseConfig.costs) do
				if string.find(string.lower(tostring(k)), "aint", 1, true) or string.find(string.lower(tostring(k)), "infra", 1, true) then keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
			end
			table.sort(keys)
			log("costs keys: " .. table.concat(keys, ", "))
		end)

		-- 1. constructions per town --------------------------------------------
		local towns = api.engine.getEntitiesWithComponent(api.type.ComponentType.TOWN)
		local townOf = {}   -- town entity -> name
		local conTotals = { station = 0, depot = 0, warehouse = 0, landmark = 0, maintenance = 0, other = 0 }
		local conBookedTotal, nConBooked = 0, 0
		local nConCrossFail = 0
		for __, town in ipairs(towns) do
			townOf[town] = entityName(town)
			local okC, cons = pcall(api.engine.system.streetConnectorSystem.getTownClosestConstructions, town)
			if not okC then
				log(string.format("town %s: getTownClosestConstructions failed: %s", townOf[town], tostring(cons)))
				cons = {}
			end
			local sums, counts, bookedSums = {}, {}, {}
			local nOther, nForeign = 0, 0
			for ___, c in ipairs(cons) do
				local con = comp(c, "CONSTRUCTION")
				local owned = comp(c, "PLAYER_OWNED")
				local isOurs = owned ~= nil and owned.player == player
				local fileName = con and con.fileName or "?"
				local cat = con and categoryOf(con, fileName) or "nocon"
				if not isOurs then
					nForeign = nForeign + 1
				elseif cat ~= "townbuilding" and cat ~= "industry" then
					local mc = comp(c, "MAINTENANCE_COST")
					local base, accu, nAccu = 0, 0, 0
					local progression = false
					if mc then
						base = mc.maintenanceCost or 0
						pcall(function()
							for ____, a in pairs(mc.accumulatedCost) do accu = accu + a; nAccu = nAccu + 1 end
						end)
						pcall(function()
							local desc = api.res.constructionRep.get(api.res.constructionRep.find(fileName))
							progression = desc and desc.costsYearProgression or false
						end)
					end
					local upkeep = round(base * scale * (progression and yearMult or 1)) + round(accu)
					local bk = booked(c)
					if bk ~= nil then conBookedTotal = conBookedTotal - bk; nConBooked = nConBooked + 1 end
					bookedSums[cat] = (bookedSums[cat] or 0) - (bk or 0)
					sums[cat] = (sums[cat] or 0) + upkeep
					counts[cat] = (counts[cat] or 0) + 1
					conTotals[cat] = (conTotals[cat] or 0) + upkeep
					local okT, closest = pcall(api.engine.system.streetConnectorSystem.getConstructionClosestTown, c)
					local cross = (okT and closest == town) and "" or (" CROSS-CHECK closestTown=" .. tostring(okT and closest or "err"))
					if cross ~= "" then nConCrossFail = nConCrossFail + 1 end
					local sg = ""
					if cat == "station" then
						pcall(function()
							local st = con.stations[1]
							local group = api.engine.system.stationGroupSystem.getStationGroup(st)
							sg = string.format(" stationGroup %s upkeep(game) %s", entityName(group), num(api.engine.util.maintenance.calcMaintenanceForStationGroup(group)))
						end)
					end
					if DETAIL then
						log(string.format("  town %s: %s %s (%s) mc=%s%s accu=%s(%d) -> %s/yr booked %s%s%s",
							townOf[town], cat, entityName(c), fileName, num(base), progression and "*year" or "", num(accu), nAccu, num(upkeep), bk and num(-bk) or "nil", sg, cross))
					end
				else
					nOther = nOther + 1
				end
			end
			local parts = {}
			for cat, s in pairs(sums) do parts[#parts + 1] = string.format("%s %d = %s (booked %s)", cat, counts[cat], num(s), num(bookedSums[cat] or 0)) end
			table.sort(parts)
			log(string.format("town %s: %d constructions (%d not ours, %d town buildings/industries of ours): %s",
				townOf[town], listLen(cons), nForeign, nOther, table.concat(parts, " | ")))
		end
		local t1 = clock:getTime()

		-- 2. edges --------------------------------------------------------------
		-- BASE_EDGE is not loopable via getEntitiesWithComponent ("Cannot loop over this
		-- component type", 2026-11-13): try the alternatives in turn
		local edges, edgeSource = nil, "?"
		local okE, res = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.BASE_EDGE)
		if okE and type(res) == "table" then edges, edgeSource = res, "getEntitiesWithComponent" end
		if edges == nil then
			local list = {}
			local okF, errF = pcall(api.engine.forEachEntityWithComponent, function(e) list[#list + 1] = e end, api.type.ComponentType.BASE_EDGE)
			if okF and #list > 0 then edges, edgeSource = list, "forEachEntityWithComponent" else log("forEachEntityWithComponent(BASE_EDGE): " .. tostring(errF) .. ", " .. #list .. " entities") end
		end
		if edges == nil then
			local okM, map = pcall(api.engine.system.streetSystem.getNode2SegmentMap)
			if okM and map then
				local set, list = {}, {}
				pcall(function()
					for __, segs in pairs(map) do
						for ___, seg in pairs(segs) do
							if not set[seg] then set[seg] = true; list[#list + 1] = seg end
						end
					end
				end)
				if #list > 0 then edges, edgeSource = list, "streetSystem.getNode2SegmentMap" end
			else
				log("getNode2SegmentMap: " .. tostring(map))
			end
		end
		if edges == nil then
			local okT, res2 = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.TRANSPORT_NETWORK)
			if okT and type(res2) == "table" then edges, edgeSource = res2, "getEntitiesWithComponent(TRANSPORT_NETWORK)" else log("getEntitiesWithComponent(TRANSPORT_NETWORK): " .. tostring(res2)) end
		end
		edges = edges or {}
		log(string.format("edge list via %s: %d entities", edgeSource, #edges))
		local templateRate = {}   -- roadTemplate name -> maintenanceCost per unit length (or false)
		local function rateOf(name)
			if templateRate[name] == nil then
				local ok, r = pcall(function()
					local id = api.res.streetTemplateRep.find(name)
					local t = api.res.streetTemplateRep.get(id)
					return { maint = t.maintenanceCost, cost = t.cost, name = t.name }
				end)
				templateRate[name] = ok and r or false
			end
			return templateRate[name]
		end
		local perTown = {}   -- town -> { kind -> {len, cost, n} }
		local function add(town, kind, len, cost)
			perTown[town] = perTown[town] or {}
			local k = perTown[town][kind] or { len = 0, cost = 0, n = 0 }
			k.len, k.cost, k.n = k.len + len, k.cost + cost, k.n + 1
			perTown[town][kind] = k
		end
		local nEdges, nOwned, nInCon, nNoTown, nDistMismatch, nNoRate = 0, 0, 0, 0, 0, 0
		local townErrLogged, midErrLogged, sampleCount = false, false, {}
		local nNegRate = 0
		-- edge objects (signals, crossings, waypoints, ...): not constructions, but they carry
		-- MAINTENANCE_COST (entity_window_util reads EDGE_OBJECT.edgeObjectConstruction for them)
		local objByName, objPerTown, nObj, nObjOurs, nObjMc, objTotal, objShapeLogged = {}, {}, 0, 0, 0, 0, false
		local function edgeObjects(be, e, town, isOursEdge)
			local objs = be.objects
			local n = listLen(objs)
			for i = 1, n do
				local o = objs[i]
				local ent = nil
				pcall(function() ent = o[1] end)
				if type(ent) ~= "number" then pcall(function() ent = o.entity end) end
				if not objShapeLogged then
					objShapeLogged = true
					local t2 = nil; pcall(function() t2 = o[2] end)
					log(string.format("edge object shape: entry=%s type(entry)=%s [1]=%s [2]=%s", tostring(o), type(o), tostring(ent), tostring(t2)))
				end
				if type(ent) == "number" then
					nObj = nObj + 1
					local eo = comp(ent, "EDGE_OBJECT")
					local owned = comp(ent, "PLAYER_OWNED")
					local ours = owned ~= nil and owned.player == player
					if ours then nObjOurs = nObjOurs + 1 end
					local mc = comp(ent, "MAINTENANCE_COST")
					local name = eo and tostring(eo.edgeObjectConstruction) or "?"
					local upkeep = 0
					if mc then
						nObjMc = nObjMc + 1
						local progression = false
						pcall(function() local d = api.res.constructionRep.get(api.res.constructionRep.find(name)); progression = d and d.costsYearProgression or false end)
						local accu = 0
						pcall(function() for __, a in pairs(mc.accumulatedCost) do accu = accu + a end end)
						upkeep = round((mc.maintenanceCost or 0) * scale * (progression and yearMult or 1)) + round(accu)
					end
					local key = (ours and "" or "foreign ") .. name
					local b = objByName[key] or { n = 0, sum = 0, mcN = 0 }
					b.n, b.sum, b.mcN = b.n + 1, b.sum + upkeep, b.mcN + (mc and 1 or 0)
					objByName[key] = b
					if ours then
						objTotal = objTotal + upkeep
						objPerTown[town] = (objPerTown[town] or 0) + upkeep
					end
				end
			end
		end
		local totals = { TRACK = 0, STREET = 0, bridge = 0, tunnel = 0 }
		local expensive = {}
		for __, e in ipairs(edges) do
			nEdges = nEdges + 1
			local be = comp(e, "BASE_EDGE")
			if be then
				local owned = comp(e, "PLAYER_OWNED")
				local isOurs = owned ~= nil and owned.player == player
				local okI, conOfEdge = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForEdge, e)
				local inCon = okI and conOfEdge ~= nil and conOfEdge ~= -1
				if isOurs then nOwned = nOwned + 1 end
				if inCon then nInCon = nInCon + 1 end
				local dist = be.distance or 0
				local hl = hermiteLength(be.position0, be.position1, be.tangent0, be.tangent1)
				if hl and math.abs(hl - dist) > math.max(2, 0.05 * dist) then nDistMismatch = nDistMismatch + 1 end
				local len = hl or 0   -- BaseEdge.distance is NOT the length (5 for tracks, 0 for streets, 2026-11-13)
				local mid = midpoint(be.position0, be.position1, be.tangent0, be.tangent1)
				local town = nil
				if mid then
					local okT, t = pcall(api.engine.util.town.getClosestTown, mid)
					if okT and t ~= nil and t ~= -1 then town = t
					elseif not townErrLogged then
						townErrLogged = true
						log(string.format("getClosestTown debug: ok=%s result=%s mid=%s,%s,%s", tostring(okT), tostring(t), tostring(mid.x), tostring(mid.y), tostring(mid.z)))
						local ok2, t2 = pcall(function() return api.engine.util.town.getClosestTown(api.type.Vec3f.new(mid.x, mid.y, mid.z)) end)
						local ok3, t3 = pcall(function() return api.engine.util.town.getClosestTown(api.type.Vec2f.new(mid.x, mid.y)) end)
						local ok4, t4 = pcall(function() return api.engine.util.town.getClosestTown(be.position0) end)
						log(string.format("getClosestTown variants: Vec3f %s/%s, Vec2f %s/%s, position0 %s/%s", tostring(ok2), tostring(t2), tostring(ok3), tostring(t3), tostring(ok4), tostring(t4)))
					end
				elseif not midErrLogged then
					midErrLogged = true
					local okV, errV = pcall(function() return api.type.Vec3f.new(1, 2, 3) end)
					log(string.format("midpoint failed; Vec3f.new(1,2,3): %s %s; position0=%s tangent0=%s", tostring(okV), tostring(errV), tostring(be.position0), tostring(be.tangent0)))
				end
				local kindForSample = nameOf(roadTypeNames, be.roadType)
				if isOurs and not inCon and (sampleCount[kindForSample] or 0) < 3 then
					sampleCount[kindForSample] = (sampleCount[kindForSample] or 0) + 1
					local okS, line = pcall(function()
						local p0, p1, t0, t1 = be.position0, be.position1, be.tangent0, be.tangent1
						local chord = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2 + (p1.z - p0.z) ^ 2)
						local lt0 = math.sqrt(t0.x ^ 2 + t0.y ^ 2 + t0.z ^ 2)
						local lt1 = math.sqrt(t1.x ^ 2 + t1.y ^ 2 + t1.z ^ 2)
						local bkE, bkN0 = booked(e), booked(be.node0)
						return string.format("sample %s edge #%s: distance=%s hermite=%s chord=%s template=%s lanes=%d town %s booked(edge)=%s booked(node0)=%s est=%s",
							kindForSample, tostring(e), tostring(be.distance), num(hl or -1, 1), num(chord, 1), tostring(be.roadTemplate), listLen(be.laneConfigs),
							townOf[town] or tostring(town), tostring(bkE), tostring(bkN0), num(len * ((rateOf(be.roadTemplate) or {}).maint or 0) * scale))
					end)
					log(okS and line or ("sample failed: " .. tostring(line)))
				end
				if town == nil then nNoTown = nNoTown + 1; town = "none" end
				local kind = nameOf(roadTypeNames, be.roadType)
				local etype = nameOf(edgeTypeNames, be.type)
				local rate = rateOf(be.roadTemplate)
				local perM = rate and rate.maint or nil
				if perM == nil then nNoRate = nNoRate + 1 end
				local extra = 0
				if etype == "BRIDGE" or etype == "TUNNEL" then
					pcall(function()
						local rep = (etype == "BRIDGE") and api.res.bridgeTypeRep or api.res.tunnelTypeRep
						extra = rep.get(be.typeIndex).maintenanceCost or 0
					end)
				end
				if perM ~= nil and perM < 0 then perM = 0; nNegRate = nNegRate + 1 end   -- industry tracks carry -1
				local cost = len * ((perM or 0) + extra)   -- template rates are already scaled by infrastructureMaintenanceScale (verified against the booked track upkeep)
				pcall(edgeObjects, be, e, town, isOurs)
				local key = (isOurs and "" or "foreign ") .. (inCon and "inCon " or "") .. kind
				add(town, key, len, cost)
				if isOurs and not inCon then
					totals[kind] = (totals[kind] or 0) + len * (perM or 0)
					if extra > 0 then totals[string.lower(etype)] = totals[string.lower(etype)] + len * extra end
					expensive[#expensive + 1] = { e = e, cost = cost, len = len, kind = kind, etype = etype, tpl = be.roadTemplate, town = town, perM = perM, extra = extra }
				end
			end
		end
		local t2 = clock:getTime()
		for town, kinds in pairs(perTown) do
			local parts = {}
			for kind, k in pairs(kinds) do parts[#parts + 1] = string.format("%s %d edges %s km = %s/yr", kind, k.n, num(k.len / 1000, 2), num(k.cost)) end
			table.sort(parts)
			log(string.format("edges town %s: %s | edge objects (ours) %s/yr", townOf[town] or tostring(town), table.concat(parts, " | "), num(objPerTown[town] or 0)))
		end
		table.sort(expensive, function(a, b) return a.cost > b.cost end)
		for i = 1, math.min(EDGE_DETAIL_MAX, #expensive) do
			local x = expensive[i]
			log(string.format("  edge #%s %s %s %s len %s m rate %s + %s -> %s/yr town %s",
				tostring(x.e), x.kind, x.etype, tostring(x.tpl), num(x.len, 1), tostring(x.perM), num(x.extra), num(x.cost), townOf[x.town] or tostring(x.town)))
		end
		local tplParts = {}
		for name, r in pairs(templateRate) do tplParts[#tplParts + 1] = string.format("%s maint=%s cost=%s", name, r and tostring(r.maint) or "?", r and tostring(r.cost) or "?") end
		table.sort(tplParts)
		log("templates: " .. table.concat(tplParts, "; "))
		log(string.format("edges: %d total, %d ours, %d inside constructions, %d without town, %d distance mismatches (Hermite vs BaseEdge.distance), %d without rate, %d negative rates",
			nEdges, nOwned, nInCon, nNoTown, nDistMismatch, nNoRate, nNegRate))
		local objParts = {}
		for name, b in pairs(objByName) do objParts[#objParts + 1] = string.format("%s x%d (%d with MAINTENANCE_COST) = %s/yr", name, b.n, b.mcN, num(b.sum)) end
		table.sort(objParts)
		log(string.format("edge objects: %d total, %d ours, %d with MAINTENANCE_COST, ours sum %s/yr: %s", nObj, nObjOurs, nObjMc, num(objTotal), table.concat(objParts, "; ")))

		-- 3. totals vs. booked ----------------------------------------------------
		local conSum = 0
		local conParts = {}
		for cat, s in pairs(conTotals) do conSum = conSum + s; conParts[#conParts + 1] = cat .. " " .. num(s) end
		table.sort(conParts)
		local bookedAll = "?"
		pcall(function()
			bookedAll = num(api.engine.util.finance.calculateBalance({ player }, now - yearMs, now, true, api.type.JournalEntry.Maintenance.INFRASTRUCTURE))
		end)
		log(string.format("ESTIMATE per year: constructions %s, booked on their accounts %s (%d of them) (%s; %d cross-check failures) | free owned edges: track %s, street %s, bridges %s, tunnels %s | edge objects %s | BOOKED infrastructure maintenance last %d s: %s",
			num(conSum), num(conBookedTotal), nConBooked, table.concat(conParts, ", "), nConCrossFail, num(totals.TRACK), num(totals.STREET), num(totals.bridge), num(totals.tunnel), num(objTotal), round(yearMs / 1000), bookedAll))
		-- 4. the game's own finance table (what the Finances tab shows) -------------
		pcall(function()
			local JE = api.type.JournalEntry
			local typeNames = enumNames(JE.Type, { "LOAN", "INTEREST", "CONSTRUCTION", "ACQUISITION", "MAINTENANCE", "INCOME", "OTHER", "SUBSIDY" })
			local maintNames = enumNames(JE.Maintenance, { "VEHICLE", "INFRASTRUCTURE", "OTHER", "VEHICLE_MAINTENANCE" })
			local conNames = enumNames(JE.Construction, { "STREET", "TRACK", "SIGNAL", "STATION", "DEPOT", "BULLDOZER", "WAREHOUSE", "OTHER" })
			local carrierNames = enumNames(JE.Carrier, { "ROAD", "RAIL", "TRAM", "OTHER", "AIR", "WATER" })
			local config = api.type.ChartConfig.new()
			config.count = 4
			local fd = api.engine.util.finance.computeFinanceTable(player, config)
			local header = {}
			pcall(function() for __, h in ipairs(fd.header) do header[#header + 1] = tostring(h) end end)
			log("finance table header: " .. table.concat(header, " | ") .. " (interval " .. tostring(config.interval) .. ")")
			fd:foreach_carrier(function(carrier)
				fd:foreach_transport(function(key, values)
					local k = fd:unfoldKey(key)
					local vals = {}
					for __, v in ipairs(values) do vals[#vals + 1] = num(v) end
					log(string.format("finance %s %s/%s/%s: %s", nameOf(carrierNames, carrier), nameOf(typeNames, k[1]), nameOf(maintNames, k[2]), nameOf(conNames, k[3]), table.concat(vals, " | ")))
				end, carrier)
			end)
		end)
		log(string.format("cost: constructions %s ms, edges %s ms (%d edges), %d towns; entities with ACCOUNT %d, without %d", num(t1 / 1000, 1), num((t2 - t1) / 1000, 1), nEdges, #towns, nAccounts, nNoAccount))
	end

	local M = {}
	function M.update(userParams, state, dt)
		local now = gameTime()
		if now == nil then return end
		local s = state:get() or {}
		local due = s.nextRun or (now + FIRST_RUN_MS)
		if now < due then
			if s.nextRun == nil then s.nextRun = due; state:set(s) end
			return
		end
		s.nextRun = now + RUN_MS
		state:set(s)
		local ok, err = pcall(run, now)
		if not ok then log("run failed: " .. tostring(err)) end
	end
	return M
end
