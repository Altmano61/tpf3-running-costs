-- Infrastructure upkeep per town area (Running Cost Breakdown 0.6.0): the
-- engine side of the area scan, i.e. the environment table area_scan.lua
-- drives (see its header for the contract). Everything here was verified on
-- the GUI thread with the probe in docs/probes/area_probe/ (2026-11-13):
-- every call works in the GUI Lua state, a full pass costs ~100 ms on a
-- 13k-edge save. Every engine call is wrapped in pcall; a failure yields
-- "nothing here", never a Lua error.
--
-- M.new(area_upkeep) -> env
local M = {}

local function listLen(t)
	if t == nil then return 0 end
	local ok, n = pcall(function() return #t end)
	if ok and type(n) == "number" then return n end
	return 0
end

local function comp(e, ct)
	local ok, c = pcall(api.engine.getComponent, e, api.type.ComponentType[ct])
	if ok then return c end
	return nil
end

-- { [tostring(enumValue)] = name } for the members we care about; the game's
-- enum tables cannot be iterated, so the names are resolved one by one
local function enumNames(enumName, members)
	local names = {}
	local tables = {}
	pcall(function() tables[#tables + 1] = api.type["enum"][enumName] end)
	pcall(function() tables[#tables + 1] = api.type[enumName] end)
	for __, enumTable in ipairs(tables) do
		for ___, name in ipairs(members) do
			local ok, value = pcall(function() return enumTable[name] end)
			if ok and value ~= nil then names[tostring(value)] = name end
		end
	end
	return names
end

local function nameOf(names, value)
	if value == nil then return nil end
	return names[tostring(value)] or tostring(value)
end

-- a list of enum values, or a map { enumValue = boolean } (VEHICLE_DEPOT.transportModes)
local function namesOf(names, t)
	local out = {}
	if t == nil then return out end
	local n = listLen(t)
	if n > 0 then
		for i = 1, n do
			local ok, v = pcall(function() return t[i] end)
			if ok and v ~= nil then out[#out + 1] = nameOf(names, v) end
		end
		return out
	end
	pcall(function()
		for k, v in pairs(t) do
			if v == true then out[#out + 1] = nameOf(names, k) end
		end
	end)
	return out
end

local function accumulated(mc)
	local sum = 0
	pcall(function()
		for __, a in pairs(mc.accumulatedCost) do sum = sum + a end
	end)
	return sum
end

function M.new(area_upkeep)
	local env = {}
	local clock = api.type.Clock.new()
	local player = api.engine.util.getPlayer()
	local roadTypeNames = enumNames("RoadType", { "STREET", "TRACK" })
	local edgeTypeNames = enumNames("BaseEdgeType", { "NORMAL", "BRIDGE", "TUNNEL" })
	local carrierNames = enumNames("Carrier", { "ROAD", "RAIL", "TRAM", "OTHER", "AIR", "WATER" })
	local MODE_MEMBERS = { "PERSON", "CARGO", "CAR", "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM", "TRAIN", "ELECTRIC_TRAIN",
		"AIRCRAFT", "SHIP", "SMALL_AIRCRAFT", "SMALL_SHIP", "HELICOPTER", "TRAM_TRACK", "ELECTRIC_TRAM_TRACK" }
	local modeNames = enumNames("TransportMode", MODE_MEMBERS)
	-- numeric enum values by name, for indexing VEHICLE_DEPOT.transportModes
	local modeValues = {}
	for value, name in pairs(modeNames) do modeValues[name] = tonumber(value) end

	local scale, yearMult = 1, 1
	local progressionCache = {}   -- [fileName] = boolean
	local rateCache = {}          -- [roadTemplate] = number
	local extraCache = {}         -- [etype .. typeIndex] = number
	local labelCache = {}         -- [group] = string

	function env.now()
		return clock:getTime()
	end

	-- once per scan: the maintenance scale and the year multiplier (steps every
	-- 20 game years, so it must not be frozen at load time)
	function env.begin()
		scale, yearMult = 1, 1
		pcall(function()
			local baseConfig = api.res.getBaseConfig()
			scale = baseConfig.costs["infrastructureMaintenanceScale"] or 1
			local gameTime = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
			local date = api.engine.util.getCalendarDate(gameTime.gameTime)
			yearMult = api.engine.util.construction.getCostMultiplierForYear(baseConfig.treeCostYearMultipliers, date.year) or 1
		end)
	end

	local function progression(fileName)
		if fileName == nil then return false end
		local v = progressionCache[fileName]
		if v == nil then
			v = false
			pcall(function()
				local desc = api.res.constructionRep.get(api.res.constructionRep.find(fileName))
				v = (desc and desc.costsYearProgression) and true or false
			end)
			progressionCache[fileName] = v
		end
		return v
	end

	local function owned(e)
		local po = comp(e, "PLAYER_OWNED")
		return po ~= nil and po.player == player
	end

	function env.towns()
		local ok, towns = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.TOWN)
		if ok and type(towns) == "table" then return towns end
		return {}
	end

	function env.constructionsOf(town)
		local ok, cons = pcall(api.engine.system.streetConnectorSystem.getTownClosestConstructions, town)
		if ok and type(cons) == "table" then return cons end
		return {}
	end

	function env.construction(e)
		if not owned(e) then return nil end
		local con = comp(e, "CONSTRUCTION")
		if con == nil then return nil end
		local mc = comp(e, "MAINTENANCE_COST")
		local fileName = tostring(con.fileName or "")
		local info = {
			fileName = fileName,
			nStations = listLen(con.stations),
			nDepots = listLen(con.depots),
			nTownBuildings = listLen(con.townBuildings),
			carriers = {}, modes = {}, depotCarrier = nil, depotModes = {},
			upkeep = area_upkeep.constructionUpkeep(mc and mc.maintenanceCost, mc and accumulated(mc) or 0, scale, yearMult, progression(fileName)),
		}
		if info.nStations > 0 then
			pcall(function()
				local group = api.engine.system.stationGroupSystem.getStationGroup(con.stations[1])
				local car = api.engine.system.stationGroupSystem.getCarriers(group, -1, -1)
				info.carriers = namesOf(carrierNames, car[1])
				info.modes = namesOf(modeNames, car[2])
			end)
		elseif info.nDepots > 0 then
			-- VEHICLE_DEPOT.carrier is nil in the GUI state (2026-11-13);
			-- transportModes is a list of booleans indexed by the mode's enum value
			pcall(function()
				local vd = comp(con.depots[1], "VEHICLE_DEPOT")
				if vd == nil then return end
				info.depotCarrier = nameOf(carrierNames, vd.carrier)
				local modes = vd.transportModes
				for name, value in pairs(modeValues) do
					local ok, on = pcall(function() return modes[value] end)
					if ok and on == true then info.depotModes[#info.depotModes + 1] = name end
				end
			end)
		end
		return info
	end

	-- BASE_EDGE is not loopable: enumerate the segments of all nodes once
	function env.edges()
		local ok, map = pcall(api.engine.system.streetSystem.getNode2SegmentMap)
		if not ok or type(map) ~= "table" then return {} end
		local set, edges = {}, {}
		for __, segs in pairs(map) do
			for ___, seg in pairs(segs) do
				if not set[seg] then
					set[seg] = true
					edges[#edges + 1] = seg
				end
			end
		end
		return edges
	end

	local function vec(v)
		return { x = v.x, y = v.y, z = v.z }
	end

	local function templateRate(name)
		local r = rateCache[name]
		if r == nil then
			r = 0
			pcall(function()
				r = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(name)).maintenanceCost or 0
			end)
			rateCache[name] = r
		end
		return r
	end

	local function structureRate(etype, typeIndex)
		local key = etype .. tostring(typeIndex)
		local r = extraCache[key]
		if r == nil then
			r = 0
			pcall(function()
				local rep = (etype == "BRIDGE") and api.res.bridgeTypeRep or api.res.tunnelTypeRep
				r = rep.get(typeIndex).maintenanceCost or 0
			end)
			extraCache[key] = r
		end
		return r
	end

	-- every edge with a BASE_EDGE; `owned` / `inConstruction` tell the scanner
	-- whether the edge's own upkeep counts (its objects may count regardless)
	function env.edge(e)
		local be = comp(e, "BASE_EDGE")
		if be == nil then return nil end
		local objects = {}
		local objs = be.objects
		for j = 1, listLen(objs) do
			local ent = nil
			pcall(function() ent = objs[j][1] end)
			if type(ent) == "number" then objects[#objects + 1] = ent end
		end
		local isOwned = owned(e)
		local okI, conOf = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForEdge, e)
		local inConstruction = okI and conOf ~= nil and conOf ~= -1
		if (not isOwned or inConstruction) and #objects == 0 then
			return { owned = isOwned, inConstruction = inConstruction, objects = objects }
		end
		local okV, info = pcall(function()
			local etype = nameOf(edgeTypeNames, be.type) or "NORMAL"
			local template = tostring(be.roadTemplate)
			return {
				owned = isOwned, inConstruction = inConstruction,
				p0 = vec(be.position0), t0 = vec(be.tangent0), p1 = vec(be.position1), t1 = vec(be.tangent1),
				kind = nameOf(roadTypeNames, be.roadType),
				etype = etype,
				rate = templateRate(template),
				extra = (etype == "BRIDGE" or etype == "TUNNEL") and structureRate(etype, be.typeIndex) or 0,
				group = area_upkeep.templateGroup(template),
				objects = objects,
			}
		end)
		if not okV then return nil end
		return info
	end

	function env.townAt(x, y, z)
		local ok, town = pcall(function()
			return api.engine.util.town.getClosestTown(api.type.Vec3f.new(x, y, z))
		end)
		if ok and type(town) == "number" and town >= 0 then return town end
		return nil
	end

	function env.edgeObject(e)
		if not owned(e) then return nil end
		local mc = comp(e, "MAINTENANCE_COST")
		if mc == nil then return nil end
		local eo = comp(e, "EDGE_OBJECT")
		local fileName = nil
		pcall(function() fileName = tostring(eo.edgeObjectConstruction) end)
		return {
			upkeep = area_upkeep.constructionUpkeep(mc.maintenanceCost, accumulated(mc), scale, yearMult, progression(fileName)),
			isStation = comp(e, "STATION") ~= nil,
		}
	end

	function env.templateLabel(group)
		local label = labelCache[group]
		if label == nil then
			label = ""
			pcall(function()
				local t = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(group))
				label = (t.description and t.description.name) or ""
				if label == "" then label = t.name or "" end
			end)
			if label == "" then label = area_upkeep.templateBaseName(group) end
			labelCache[group] = label
		end
		return label
	end

	return env
end

return M
