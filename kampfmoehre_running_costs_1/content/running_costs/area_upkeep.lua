-- Infrastructure upkeep per town area (Running Cost Breakdown 0.6.0): the
-- formulas, the category mapping and the row builder of the town window's
-- "Infrastructure upkeep" card. The engine reads happen in the GUI
-- (gui/kampfmoehre_running_costs/area_env.lua), the sliced scan that drives
-- them is area_scan.lua; this module only computes.
--
-- Amounts are per default game year as the station windows show them:
--   construction: round(maintenanceCost × infrastructureMaintenanceScale × yearMult) + round(Σ accumulatedCost)
--   edge:         hermiteLength × (max(templateRate, 0) + bridgeOrTunnelRate)   (template rates are already scaled)
-- (verified against the game's windows and the finance table, docs/probes/area_probe/).
--
-- No game API, unit-tested with plain luajit (test/area_upkeep_test.lua).
local M = {}

local function round(x)
	return math.floor(x + 0.5)
end

-- Formulas -------------------------------------------------------------------

-- length of a cubic Hermite segment (points and tangents are {x, y, z} tables;
-- a tangent's magnitude is the segment length in the game's edges), 16 pieces
function M.hermiteLength(p0, t0, p1, t1)
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
end

-- the Hermite curve at t = 0.5
function M.midpoint(p0, t0, p1, t1)
	return 0.5 * (p0.x + p1.x) + 0.125 * (t0.x - t1.x),
	       0.5 * (p0.y + p1.y) + 0.125 * (t0.y - t1.y),
	       0.5 * (p0.z + p1.z) + 0.125 * (t0.z - t1.z)
end

function M.constructionUpkeep(maintenanceCost, accumulated, scale, yearMult, progression)
	local mult = (scale or 1) * (progression and (yearMult or 1) or 1)
	return round((maintenanceCost or 0) * mult) + round(accumulated or 0)
end

function M.edgeUpkeep(meters, rate, extra)
	return meters * (math.max(rate or 0, 0) + (extra or 0))
end

-- electrification variants have the same upkeep as their base template, so
-- they fold into one group; other variants (_barriers, _bus, _trees) stay apart
local GROUP_SUFFIXES = { "_tram_electrified", "_electrified", "_tram", "_catenary" }

function M.templateGroup(path)
	path = tostring(path or "")
	for __, suffix in ipairs(GROUP_SUFFIXES) do
		local stripped, n = path:gsub(suffix .. "%.street_template$", ".street_template")
		if n == 0 then stripped, n = path:gsub(suffix .. "$", "") end
		if n > 0 then return stripped end
	end
	return path
end

-- "::/infrastructure/track/simple/simple.street_template" -> "simple"
function M.templateBaseName(path)
	path = tostring(path or "")
	local name = path:match("([^/]+)$") or path
	return (name:gsub("%.street_template$", ""))
end

-- Classification -------------------------------------------------------------
-- Category and sub-row keys double as string ids (running_costs_area_<key>).

M.CATEGORY_ORDER = { "stations", "depots", "maintenance", "warehouses", "other_buildings", "tracks", "roads", "signals" }
M.STATION_SUBS = { "roadside_stops", "road_terminals", "rail_stations", "harbours", "airports", "heliports", "other_stations" }
M.DEPOT_SUBS = { "road_depots", "rail_depots", "ship_depots", "hangars", "heli_hangars" }

local function has(list, name)
	for __, v in ipairs(list or {}) do
		if v == name then return true end
	end
	return false
end

-- a heliport / helicopter hangar serves helicopters only
local function helicoptersOnly(modes)
	return has(modes, "HELICOPTER") and not has(modes, "AIRCRAFT") and not has(modes, "SMALL_AIRCRAFT")
end

-- carriers, modes: lists of enum names of the construction's station group.
-- A station with several carriers counts once, under the first found in the
-- order rail, air, water, road/tram (a rail station with a bus module is a
-- rail station).
function M.classifyStation(carriers, modes)
	if has(carriers, "RAIL") then return "rail_stations" end
	if has(carriers, "AIR") then return helicoptersOnly(modes) and "heliports" or "airports" end
	if has(carriers, "WATER") then return "harbours" end
	if has(carriers, "ROAD") or has(carriers, "TRAM") then return "road_terminals" end
	return "other_stations"
end

-- the carrier of a depot from its transport modes (VEHICLE_DEPOT.carrier is
-- nil in the GUI state although the type definition lists it, 2026-11-13)
local MODE_CARRIER = {
	TRAIN = "RAIL", ELECTRIC_TRAIN = "RAIL",
	SHIP = "WATER", SMALL_SHIP = "WATER",
	AIRCRAFT = "AIR", SMALL_AIRCRAFT = "AIR", HELICOPTER = "AIR",
	CAR = "ROAD", BUS = "ROAD", TRUCK = "ROAD", TRAM = "TRAM", ELECTRIC_TRAM = "TRAM",
}
local function carrierFromModes(modes)
	local found = nil
	for __, mode in ipairs(modes or {}) do
		local c = MODE_CARRIER[mode]
		-- rail, water and air win over road modes a mixed depot may also list
		if c == "RAIL" or c == "WATER" or c == "AIR" then return c end
		if c ~= nil then found = c end
	end
	return found
end

-- carrier: enum name of VEHICLE_DEPOT.carrier (nil in practice, then derived
-- from the modes), modes: its transportModes as names; nil for a carrier we
-- have no row for (counted in the Depots total only)
function M.classifyDepot(carrier, modes)
	if carrier == nil or carrier == "OTHER" then carrier = carrierFromModes(modes) end
	if carrier == "ROAD" or carrier == "TRAM" then return "road_depots" end
	if carrier == "RAIL" then return "rail_depots" end
	if carrier == "WATER" then return "ship_depots" end
	if carrier == "AIR" then return helicoptersOnly(modes) and "heli_hangars" or "hangars" end
	return nil
end

-- info = { fileName, nStations, nDepots, nTownBuildings, carriers, modes,
-- depotCarrier, depotModes, upkeep } -> category, sub (nil = not counted)
function M.classifyConstruction(info)
	if (info.nTownBuildings or 0) > 0 then return nil end
	local fileName = string.lower(tostring(info.fileName or ""))
	if (info.nStations or 0) > 0 then
		return "stations", M.classifyStation(info.carriers, info.modes)
	end
	if (info.nDepots or 0) > 0 then
		if fileName:find("maint", 1, true) then return "maintenance", nil end
		return "depots", M.classifyDepot(info.depotCarrier, info.depotModes)
	end
	if fileName:find("warehouse", 1, true) then return "warehouses", nil end
	if (info.upkeep or 0) > 0 then return "other_buildings", nil end
	return nil
end

-- edge objects: roadside stops carry a STATION component, signals do not
function M.classifyEdgeObject(isStation)
	if isStation then return "stations", "roadside_stops" end
	return "signals", nil
end

-- Accumulator ------------------------------------------------------------------
-- acc.towns[town].cats[cat] = { amount, meters, subs = { [sub] = amount },
--   groups = { [group] = { amount, meters } }, bridges | tunnels = { meters, extra } }

local EDGE_CATEGORY = { TRACK = "tracks", STREET = "roads" }
local EDGE_EXTRA = { BRIDGE = "bridges", TUNNEL = "tunnels" }

function M.newAcc()
	return { towns = {} }
end

local function category(acc, town, cat)
	local t = acc.towns[town]
	if t == nil then
		t = { cats = {} }
		acc.towns[town] = t
	end
	local c = t.cats[cat]
	if c == nil then
		c = { amount = 0, meters = 0, subs = {}, groups = {} }
		t.cats[cat] = c
	end
	return c
end

function M.addBuilding(acc, town, cat, sub, amount)
	amount = amount or 0
	local c = category(acc, town, cat)
	c.amount = c.amount + amount
	if sub ~= nil then c.subs[sub] = (c.subs[sub] or 0) + amount end
end

-- kind: "TRACK" | "STREET" (others ignored); group: template group path;
-- etype: "NORMAL" | "BRIDGE" | "TUNNEL"; extraAmount: the bridge/tunnel
-- surcharge part of amount (what the structure costs on top of plain track)
function M.addEdge(acc, town, kind, group, meters, amount, etype, extraAmount)
	local cat = EDGE_CATEGORY[kind]
	if cat == nil then return end
	local c = category(acc, town, cat)
	c.amount = c.amount + amount
	c.meters = c.meters + meters
	local g = c.groups[group]
	if g == nil then
		g = { amount = 0, meters = 0 }
		c.groups[group] = g
	end
	g.amount = g.amount + amount
	g.meters = g.meters + meters
	local extraKey = EDGE_EXTRA[etype]
	if extraKey then
		local x = c[extraKey]
		if x == nil then
			x = { meters = 0, extra = 0 }
			c[extraKey] = x
		end
		x.meters = x.meters + meters
		x.extra = x.extra + (extraAmount or 0)
	end
end

-- Rows -----------------------------------------------------------------------------

local SUB_ORDER = { stations = M.STATION_SUBS, depots = M.DEPOT_SUBS }

local function visible(amount)
	return amount >= 0.5
end

-- row children of a station / depot category in the fixed sub order
local function subChildren(c, order)
	local children = {}
	for __, sub in ipairs(order) do
		local amount = c.subs[sub]
		if amount ~= nil and visible(amount) then
			children[#children + 1] = { key = sub, amount = amount }
		end
	end
	return children
end

-- row children of a track / road category: templates by amount, descending;
-- groups with the same display name (street variants with a bus lane, trees
-- or barriers) merge into one child
local function groupChildren(c, labelOf)
	local children, byLabel = {}, {}
	for group, g in pairs(c.groups) do
		if visible(g.amount) then
			local label = labelOf(group)
			local child = byLabel[label]
			if child == nil then
				child = { label = label, group = group, amount = 0, meters = 0 }
				byLabel[label] = child
				children[#children + 1] = child
			end
			child.amount = child.amount + g.amount
			child.meters = child.meters + g.meters
		end
	end
	table.sort(children, function(a, b)
		if a.amount ~= b.amount then return a.amount > b.amount end
		return a.label < b.label
	end)
	return children
end

-- labelOf(groupPath) -> display name of a template group.
-- -> { total, rows = { { key, amount, meters?, children?, bridges?, tunnels? } } }
-- in CATEGORY_ORDER, rows and children below half a unit omitted
function M.rows(acc, town, labelOf)
	local out = { total = 0, rows = {} }
	local t = acc.towns[town]
	if t == nil then return out end
	for __, cat in ipairs(M.CATEGORY_ORDER) do
		local c = t.cats[cat]
		if c ~= nil and visible(c.amount) then
			local row = { key = cat, amount = c.amount }
			out.total = out.total + c.amount
			local children
			if SUB_ORDER[cat] then
				children = subChildren(c, SUB_ORDER[cat])
			elseif EDGE_CATEGORY.TRACK == cat or EDGE_CATEGORY.STREET == cat then
				row.meters = c.meters
				row.bridges = c.bridges
				row.tunnels = c.tunnels
				children = groupChildren(c, labelOf)
			end
			if children ~= nil and #children > 0 then row.children = children end
			out.rows[#out.rows + 1] = row
		end
	end
	return out
end

-- Overview over all towns (finance window tab, 0.6.0 part 2) ---------------------

-- towns: the scanned town list; -> { rows = { { town, total, cats = { [cat] = amount },
-- meters = { tracks, roads } } … } sorted by total desc (ties: town asc), sum = { total, cats } }
function M.overview(acc, towns, labelOf)
	local out = { rows = {}, sum = { total = 0, cats = {} } }
	for __, cat in ipairs(M.CATEGORY_ORDER) do out.sum.cats[cat] = 0 end
	for __, town in ipairs(towns or {}) do
		local R = M.rows(acc, town, labelOf)
		local row = { town = town, total = R.total, cats = {}, meters = { tracks = 0, roads = 0 } }
		for ___, r in ipairs(R.rows) do
			row.cats[r.key] = r.amount
			if r.key == "tracks" or r.key == "roads" then row.meters[r.key] = r.meters or 0 end
			out.sum.cats[r.key] = (out.sum.cats[r.key] or 0) + r.amount
		end
		out.sum.total = out.sum.total + R.total
		out.rows[#out.rows + 1] = row
	end
	table.sort(out.rows, function(a, b)
		if a.total ~= b.total then return a.total > b.total end
		return a.town < b.town
	end)
	return out
end

-- the game's treeCostYearMultipliers in whatever Lua shape it arrives: a map
-- { [year] = factor }, a list of pairs { {year, factor} } or a list of records
-- { year = y, multiplier|factor|value = f }; anything else -> {}.
-- -> sorted list { {year, factor}, … }
function M.normaliseSteps(t)
	local out = {}
	if type(t) ~= "table" then return out end
	local function add(y, f)
		y, f = tonumber(y), tonumber(f)
		if y ~= nil and f ~= nil then out[#out + 1] = { y, f } end
	end
	for k, v in pairs(t) do
		if type(v) == "table" then
			if v.year ~= nil then
				add(v.year, v.multiplier or v.factor or v.value)
			else
				add(v[1], v[2])
			end
		else
			add(k, v)
		end
	end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	return out
end

-- keys: localKeys of a TabWidget's children in order (nil holes allowed);
-- -> the position to append our tab at when `marker` is among them, else nil
function M.tabInjectionIndex(keys, marker)
	local n = table.maxn(keys or {})
	for i = 1, n do
		if keys[i] == marker then return n + 1 end
	end
	return nil
end

-- steps: sorted { {year, factor}, … } (the game's treeCostYearMultipliers);
-- -> { year, percent } of the first step after `year`, nil after the last one
function M.nextPriceStep(steps, year)
	local current = 1
	for __, step in ipairs(steps or {}) do
		if step[1] <= year then
			current = step[2]
		else
			return { year = step[1], percent = round((step[2] / current - 1) * 100) }
		end
	end
	return nil
end

return M
