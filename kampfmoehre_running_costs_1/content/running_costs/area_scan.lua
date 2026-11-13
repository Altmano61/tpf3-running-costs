-- Infrastructure upkeep per town area (Running Cost Breakdown 0.6.0): a
-- resumable scan over all towns that runs in time slices so the GUI never
-- stalls (a full pass is ~100 ms on a 13k-edge save; the entry plugin feeds it
-- 4 ms per frame). Engine access is injected as an environment table (built by
-- gui/kampfmoehre_running_costs/area_env.lua, faked in test/area_scan_test.lua):
--
--   env.now() -> microseconds            env.begin()  (optional, once per scan)
--   env.towns() -> { entity }            env.constructionsOf(town) -> { entity }
--   env.construction(e) -> info | nil    (area_upkeep.classifyConstruction input, upkeep included)
--   env.edges() -> { entity }            env.edge(e) -> { owned, inConstruction, p0, t0, p1, t1, kind, etype, rate, extra, group, objects } | nil
--   env.townAt(x, y, z) -> entity | nil  env.edgeObject(e) -> { upkeep, isStation } | nil
--   env.templateLabel(group) -> string
--
-- Phases: 1 towns and their constructions, 2 the edge list, 3 edges with their
-- edge objects, 4 publish. The previous result stays readable until the next
-- scan completes. No game API, unit-tested with plain luajit.
--
-- M.new(env, area_upkeep) -> scanner with start/running/step/abort/result/rows/towns/grandTotal/age/ageUs/stats.
local M = {}

-- area_upkeep: the formulas module (passed in like the other modules of this
-- mod take their dependencies; no sibling require inside the game's loader)
function M.new(env, area_upkeep)
	local S = {}
	local result = nil      -- { at, acc }
	local stats = nil       -- of the last completed scan
	local scan = nil        -- state of the running scan, nil when idle

	function S.running()
		return scan ~= nil
	end

	function S.start()
		if scan ~= nil then return end
		if type(env.begin) == "function" then env.begin() end
		scan = {
			phase = 1,
			acc = area_upkeep.newAcc(),
			towns = env.towns() or {},
			ti = 1, cons = nil, ci = 1,
			edges = nil, ei = 1,
			stats = { towns = 0, constructions = 0, edges = 0, objects = 0, steps = 0, durationUs = 0 },
			startedAt = env.now(),
		}
	end

	-- one construction; returns nothing
	local function doConstruction(acc, town, c, st)
		local info = env.construction(c)
		if info == nil then return end
		local cat, sub = area_upkeep.classifyConstruction(info)
		if cat == nil then return end
		area_upkeep.addBuilding(acc, town, cat, sub, info.upkeep or 0)
		st.constructions = st.constructions + 1
	end

	-- one edge with its edge objects. The edge's own upkeep counts only for
	-- player-owned edges outside constructions; its objects (roadside stops on
	-- town streets, signals inside stations) count whenever the object itself
	-- is the player's, as the probe did and the game books it.
	local function doEdge(acc, e, st)
		local info = env.edge(e)
		if info == nil then return end
		local countEdge = info.owned ~= false and not info.inConstruction
		local objects = info.objects or {}
		if not countEdge and #objects == 0 then return end
		local town = env.townAt(area_upkeep.midpoint(info.p0, info.t0, info.p1, info.t1))
		if town == nil then return end
		if countEdge then
			st.edges = st.edges + 1
			local meters = area_upkeep.hermiteLength(info.p0, info.t0, info.p1, info.t1)
			local extra = info.extra or 0
			area_upkeep.addEdge(acc, town, info.kind, info.group, meters,
				area_upkeep.edgeUpkeep(meters, info.rate, extra), info.etype, meters * extra)
		end
		for __, o in ipairs(objects) do
			local oinfo = env.edgeObject(o)
			if oinfo ~= nil and (oinfo.upkeep or 0) > 0 then
				local cat, sub = area_upkeep.classifyEdgeObject(oinfo.isStation)
				area_upkeep.addBuilding(acc, town, cat, sub, oinfo.upkeep)
				st.objects = st.objects + 1
			end
		end
	end

	-- works until the budget is spent or the scan is done; true exactly on the
	-- step that completed a scan
	function S.step(budgetUs)
		if scan == nil then return false end
		local t0 = env.now()
		local st = scan.stats
		st.steps = st.steps + 1
		local function over()
			return env.now() - t0 >= budgetUs
		end
		while true do
			if scan.phase == 1 then
				local town = scan.towns[scan.ti]
				if town == nil then
					scan.phase = 2
				else
					if scan.cons == nil then
						scan.cons = env.constructionsOf(town) or {}
						scan.ci = 1
						st.towns = st.towns + 1
					end
					local c = scan.cons[scan.ci]
					if c == nil then
						scan.cons = nil
						scan.ti = scan.ti + 1
					else
						doConstruction(scan.acc, town, c, st)
						scan.ci = scan.ci + 1
						if over() then return false end
					end
				end
			elseif scan.phase == 2 then
				-- one call that may overrun the budget once
				scan.edges = env.edges() or {}
				scan.ei = 1
				scan.phase = 3
				if over() then return false end
			elseif scan.phase == 3 then
				local e = scan.edges[scan.ei]
				if e == nil then
					scan.phase = 4
				else
					doEdge(scan.acc, e, st)
					scan.ei = scan.ei + 1
					if over() then return false end
				end
			else
				local now = env.now()
				st.durationUs = now - scan.startedAt
				result = { at = now, acc = scan.acc }
				stats = st
				scan = nil
				return true
			end
		end
	end

	-- drop a running scan (the caller does this when a step raised); the
	-- previous result stays readable
	function S.abort()
		scan = nil
	end

	function S.result()
		return result
	end

	function S.rows(town)
		if result == nil then return nil end
		return area_upkeep.rows(result.acc, town, env.templateLabel)
	end

	-- towns present in the result (nil without a result)
	function S.towns()
		if result == nil then return nil end
		local towns = {}
		for town in pairs(result.acc.towns) do towns[#towns + 1] = town end
		table.sort(towns)
		return towns
	end

	-- sum over all towns (nil without a result), for the log line / cross-checks
	function S.grandTotal()
		if result == nil then return nil end
		local sum = 0
		for town in pairs(result.acc.towns) do
			sum = sum + area_upkeep.rows(result.acc, town, env.templateLabel).total
		end
		return sum
	end

	function S.ageUs(nowUs)
		if result == nil then return nil end
		return nowUs - result.at
	end

	-- age of the result by the environment's own clock
	function S.age()
		if result == nil then return nil end
		return env.now() - result.at
	end

	function S.stats()
		return stats
	end

	return S
end

return M
