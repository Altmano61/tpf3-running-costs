-- TEMPORARY GUI-side probe (2026-11-13): run the area scan's engine calls once
-- on the GUI thread (react.onMount of a ModEntryPoint plugin) with wall-clock
-- timings. Prefix [kampfmoehre_area_gui_probe].
function data()
	local react = ug_require "::/gui/main/react.lua"
	local builtin = ug_require "::/gui/main/builtin.lua"
	local LOG_PREFIX = "[kampfmoehre_area_gui_probe] "
	local EDGE_SAMPLE = 400
	local gameLog = log
	local function log(text)
		if type(gameLog) == "table" and gameLog.message then gameLog.message(LOG_PREFIX .. tostring(text)) else print(LOG_PREFIX .. tostring(text)) end
	end
	local function ms(clock, t0) return string.format("%.1f ms", (clock:getTime() - t0) / 1000) end
	local function comp(e, ct)
		local ok, c = pcall(api.engine.getComponent, e, api.type.ComponentType[ct])
		if ok then return c end
		return nil
	end
	local function listLen(t)
		if t == nil then return 0 end
		local ok, n = pcall(function() return #t end)
		if ok and type(n) == "number" then return n end
		return 0
	end

	local function run()
		local clock = api.type.Clock.new()
		local t0 = clock:getTime()
		-- 1. towns + constructions
		local okT, towns = pcall(api.engine.getEntitiesWithComponent, api.type.ComponentType.TOWN)
		log(string.format("TOWN entities: ok=%s n=%s (%s)", tostring(okT), tostring(okT and #towns or towns), ms(clock, t0)))
		if not okT then return end
		local t1 = clock:getTime()
		local nCon, nOurs = 0, 0
		local player = api.engine.util.getPlayer()
		local firstGroup = nil
		for __, town in ipairs(towns) do
			local okC, cons = pcall(api.engine.system.streetConnectorSystem.getTownClosestConstructions, town)
			if not okC then log("getTownClosestConstructions failed: " .. tostring(cons)); break end
			for ___, c in ipairs(cons) do
				nCon = nCon + 1
				local owned = comp(c, "PLAYER_OWNED")
				if owned and owned.player == player then
					nOurs = nOurs + 1
					local con = comp(c, "CONSTRUCTION")
					local mc = comp(c, "MAINTENANCE_COST")
					if con and firstGroup == nil and listLen(con.stations) > 0 then
						local okG, g = pcall(api.engine.system.stationGroupSystem.getStationGroup, con.stations[1])
						if okG then firstGroup = g end
					end
				end
			end
		end
		log(string.format("constructions: %d listed, %d ours, %s", nCon, nOurs, ms(clock, t1)))
		-- carriers of one station group
		if firstGroup then
			local okCar, car = pcall(api.engine.system.stationGroupSystem.getCarriers, firstGroup, -1, -1)
			local carriers, modes = "?", "?"
			if okCar then
				pcall(function()
					local a, b = {}, {}
					for __, v in ipairs(car[1]) do a[#a + 1] = tostring(v) end
					for __, v in ipairs(car[2]) do b[#b + 1] = tostring(v) end
					carriers, modes = table.concat(a, ","), table.concat(b, ",")
				end)
			end
			log(string.format("getCarriers(group %s): ok=%s carriers=%s modes=%s", tostring(firstGroup), tostring(okCar), carriers, modes))
		end
		-- 2. edge list
		local t2 = clock:getTime()
		local okM, map = pcall(api.engine.system.streetSystem.getNode2SegmentMap)
		log(string.format("getNode2SegmentMap: ok=%s type=%s (%s)", tostring(okM), type(map), ms(clock, t2)))
		if not okM then return end
		local t3 = clock:getTime()
		local set, edges = {}, {}
		for __, segs in pairs(map) do
			for ___, seg in pairs(segs) do
				if not set[seg] then set[seg] = true; edges[#edges + 1] = seg end
			end
		end
		log(string.format("edge dedupe: %d edges (%s)", #edges, ms(clock, t3)))
		-- 3. per-edge reads on a sample
		local t4 = clock:getTime()
		local n, nTown, nObj, nRate = 0, 0, 0, 0
		local tplCache = {}
		local step = math.max(1, math.floor(#edges / EDGE_SAMPLE))
		for i = 1, #edges, step do
			local e = edges[i]
			local be = comp(e, "BASE_EDGE")
			if be then
				n = n + 1
				local owned = comp(e, "PLAYER_OWNED")
				local okI, conOf = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForEdge, e)
				local p0, p1, tg0, tg1 = be.position0, be.position1, be.tangent0, be.tangent1
				local okV, mid = pcall(function()
					return api.type.Vec3f.new(0.5 * (p0.x + p1.x) + 0.125 * (tg0.x - tg1.x), 0.5 * (p0.y + p1.y) + 0.125 * (tg0.y - tg1.y), 0.5 * (p0.z + p1.z) + 0.125 * (tg0.z - tg1.z))
				end)
				if okV then
					local okTw, tw = pcall(api.engine.util.town.getClosestTown, mid)
					if okTw and tw ~= nil then nTown = nTown + 1 elseif n == 1 then log("getClosestTown: " .. tostring(tw)) end
				elseif n == 1 then log("Vec3f.new: " .. tostring(mid))
				end
				local name = be.roadTemplate
				if tplCache[name] == nil then
					local okR, r = pcall(function() return api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(name)).maintenanceCost end)
					tplCache[name] = okR and r or false
					if okR then nRate = nRate + 1 elseif n == 1 then log("streetTemplateRep: " .. tostring(r)) end
				end
				local objs = be.objects
				for j = 1, listLen(objs) do
					local ent = nil
					pcall(function() ent = objs[j][1] end)
					if type(ent) == "number" then
						local eo = comp(ent, "EDGE_OBJECT")
						local mc = comp(ent, "MAINTENANCE_COST")
						local st = comp(ent, "STATION")
						if eo and mc then nObj = nObj + 1 end
					end
				end
				if n == 1 then
					log(string.format("first edge #%s: BASE_EDGE type(be)=%s roadType=%s template=%s owned=%s conOf=%s/%s objects=%d",
						tostring(e), type(be), tostring(be.roadType), tostring(name), tostring(owned and owned.player), tostring(okI), tostring(conOf), listLen(objs)))
				end
			end
		end
		local dt = (clock:getTime() - t4) / 1000
		log(string.format("edge sample: %d edges read in %.1f ms = %.0f us per edge -> full pass of %d edges ~ %.0f ms; towns found %d, templates %d, edge objects with mc %d",
			n, dt, dt * 1000 / math.max(n, 1), #edges, dt * #edges / math.max(n, 1), nTown, nRate, nObj))
		log(string.format("total %s", ms(clock, t0)))
	end

	local M = {}
	M.Plugin = react.RegisterPluginRecipe({ id = "::ModEntryPointExtension" }, "KampfmoehreAreaGuiProbe", function()
		react.onMount(function()
			local ok, err = pcall(run)
			if not ok then log("run failed: " .. tostring(err)) end
		end)
		return builtin.BoxLayout{ children = {} }
	end)
	return M
end
