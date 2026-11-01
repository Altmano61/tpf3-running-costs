-- TEMPORARY probe: logs OnCalcTicketPrice items with their SIM_CARGO.pickupPoints
-- (one entry per leg: vehicle, line, carrier, position) to find out whether the
-- game raises one event per delivered item (the legs' shares booked in C++) or
-- one event per leg, and where the current vehicle / line of the event point.
function data()
	local EVENT = "OnCalcTicketPrice"
	local LIFECYCLE = { initNewGame = true, initNewGameFromMap = true, initMission = true, handleLegacy = true }
	local MAX_MULTI = 40      -- detailed lines for multi-leg items per thread
	local MAX_SINGLE = 6      -- detailed lines for single-leg items per thread
	local P = "[kampfmoehre_running_costs] income probe: "
	local nMulti, nSingle, nBatches = 0, 0, 0
	local carrierName = nil

	local function carrierOf(c)
		if carrierName == nil then
			carrierName = {}
			for __, n in ipairs({ "ROAD", "RAIL", "TRAM", "WATER", "AIR" }) do
				local ok, val = pcall(function() return api.type.enum.Carrier[n] end)
				if ok and val ~= nil then carrierName[tostring(val)] = n end
			end
		end
		return carrierName[tostring(c)] or tostring(c)
	end

	local function pos(p)
		if p == nil then return nil end
		local ok, x, y, z = pcall(function() return p.x, p.y, p.z end)
		if ok and type(x) == "number" then return { x = x, y = y, z = z or 0 } end
		if type(p) == "table" and type(p[1]) == "number" then return { x = p[1], y = p[2], z = p[3] or 0 } end
		return nil
	end
	local function fmt(p) return p and string.format("(%.0f,%.0f,%.0f)", p.x, p.y, p.z) or "?" end
	local function dist(a, b)
		if not a or not b then return nil end
		return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
	end

	local function describe(id, e)
		local okC, sc = pcall(api.engine.getComponent, e.simEntity, api.type.ComponentType.SIM_CARGO)
		local okA, at = pcall(api.engine.getComponent, e.simEntity, api.type.ComponentType.SIM_ENTITY_AT_VEHICLE)
		local atV = (okA and at and at.vehicle) or -1
		local pts = (okC and sc and sc.pickupPoints) or {}
		local n = type(pts) == "table" and #pts or 0
		local from, to = pos(e.fromPos), pos(e.toPos)
		local legs = {}
		local prev = nil
		for i = 1, n do
			local pp = pts[i]
			local p = pos(pp.position)
			local d = prev and dist(prev, p)
			legs[#legs + 1] = string.format("[%d] v%s L%s %s %s%s", i, tostring(pp.vehicle), tostring(pp.line),
				carrierOf(pp.carrier), fmt(p), d and string.format(" +%.0f m", d) or "")
			prev = p
		end
		local lastLeg = (n > 0 and prev) and dist(prev, to) or nil
		return n, string.format("%s item %s cargo %s line %s base %.0f from %s to %s (%.0f m) atVehicle %s src %s dst %s | legs: %s%s",
			tostring(id), tostring(e.simEntity), tostring(okC and sc and sc.cargoType), tostring(e.lineEntity),
			tonumber(e.basePrice) or -1, fmt(from), fmt(to), dist(from, to) or -1, tostring(atV),
			tostring(okC and sc and sc.sourceEntity), tostring(okC and sc and sc.targetOrPickupEntity),
			table.concat(legs, "; "), lastLeg and string.format("; last leg to toPos %.0f m", lastLeg) or "")
	end

	local function handleBatch(id, param)
		if type(param) ~= "table" then return end
		nBatches = nBatches + 1
		local seen, dup, multi = {}, 0, 0
		for __, e in ipairs(param) do
			if type(e) == "table" and type(e.simEntity) == "number" then
				if seen[e.simEntity] then dup = dup + 1 end
				seen[e.simEntity] = (seen[e.simEntity] or 0) + 1
				local n, text = describe(id, e)
				if n >= 2 then
					multi = multi + 1
					if nMulti < MAX_MULTI then nMulti = nMulti + 1; log.message(P .. "MULTI " .. text) end
				elseif nSingle < MAX_SINGLE then
					nSingle = nSingle + 1; log.message(P .. "single " .. text)
				end
			end
		end
		if dup > 0 or multi > 0 or nBatches <= 3 then
			log.message(string.format(P .. "batch %s: %d events, %d repeated items, %d multi-leg items", tostring(id), #param, dup, multi))
		end
	end

	local function handleEvent(userParams, state, src, id, name, param)
		local ok, err = pcall(function()
			if id == "" and LIFECYCLE[name] and not state:hasEventSubscriptions() then
				state:subscribeToEvent(EVENT)
				log.message(P .. "subscribed")
			end
			if name == EVENT and id ~= "SimEntityAtVehicleSystem" then handleBatch(id, param) end
		end)
		if not ok then log.message(P .. "error: " .. tostring(err)) end
		-- never return a value: a returned table would change the prices
	end

	return { handleEvent = handleEvent }
end
