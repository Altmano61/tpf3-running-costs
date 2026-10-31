-- TEMPORARY probe: cost model of the game-script state copy (2026-10-31).
-- One shape per update tick; each shape is set() and get() three times, the
-- fastest run counts. Logs µs per table and per value. Deletes its state when done.
function data()
	local gameLog = log
	local function log(msg)
		local text = "[kampfmoehre_running_costs] state probe: " .. tostring(msg)
		if type(gameLog) == "table" and gameLog.message then gameLog.message(text) else print(text) end
	end
	local REPS = 3

	local function strOf(n, len)
		local s = tostring(n) .. ";"
		return s .. string.rep("x", len - #s)
	end

	local shapes = {
		{ name = "empty table", make = function() return {} end },
		{ name = "10000 tables x 1 number (array of {x})", make = function()
			local t = {}
			for i = 1, 10000 do t[i] = { x = i } end
			return t
		end },
		{ name = "1000 tables x 10 numbers (string keys)", make = function()
			local t = {}
			for i = 1, 1000 do t[i] = { a = i, b = i, c = i, d = i, e = i, f = i, g = i, h = i, i = i, j = i } end
			return t
		end },
		{ name = "1 table x 10000 numbers (array)", make = function()
			local t = {}
			for i = 1, 10000 do t[i] = i end
			return t
		end },
		{ name = "1 table x 10000 numbers (string keys)", make = function()
			local t = {}
			for i = 1, 10000 do t["k" .. i] = i end
			return t
		end },
		{ name = "1 table x 10000 numbers (integer keys, sparse)", make = function()
			local t = {}
			for i = 1, 10000 do t[i * 7] = i end
			return t
		end },
		{ name = "1000 tables x 10 short strings", make = function()
			local t = {}
			for i = 1, 1000 do t[i] = { a = "s1", b = "s2", c = "s3", d = "s4", e = "s5", f = "s6", g = "s7", h = "s8", i = "s9", j = "s10" } end
			return t
		end },
		{ name = "1 table x 1000 strings of 100 chars", make = function()
			local t = {}
			for i = 1, 1000 do t[i] = strOf(i, 100) end
			return t
		end },
		{ name = "1 table x 1000 strings of 1000 chars", make = function()
			local t = {}
			for i = 1, 1000 do t[i] = strOf(i, 1000) end
			return t
		end },
		{ name = "389 cost rings (7 buckets x 8 numbers, flat 0.3.1)", make = function()
			local t = {}
			for v = 1, 389 do
				local b = {}
				for i = 1, 7 do
					b[i] = { t0 = i * 243500, n = 180, t_driving = 100, t_waiting = 20, t_terminal = 50, t_depot = 10, r = 123456.7, s = 12.3 }
				end
				t[v * 13 + 100000] = { start = 0, head = 7, first = 0, b = b }
			end
			return t
		end },
		{ name = "389 cost rings as 7 packed strings (~70 chars)", make = function()
			local t = {}
			for v = 1, 389 do
				local b = {}
				for i = 1, 7 do
					b[i] = string.format("%d;%g;%g;%g;%g;%g;%g;%g", i * 243500, 180, 100, 20, 50, 10, 123456.7, 12.3)
				end
				t[v * 13 + 100000] = { start = 0, head = 7, first = 0, b = b }
			end
			return t
		end },
		{ name = "389 cost rings as ONE packed string each (~500 chars)", make = function()
			local t = {}
			for v = 1, 389 do
				local parts = {}
				for i = 1, 7 do
					parts[i] = string.format("%d;%g;%g;%g;%g;%g;%g;%g", i * 243500, 180, 100, 20, 50, 10, 123456.7, 12.3)
				end
				t[v * 13 + 100000] = table.concat(parts, "|")
			end
			return t
		end },
	}

	local function sizeOf(t, seen)
		seen = seen or {}
		if seen[t] then return 0, 0 end
		seen[t] = true
		local tables, values = 1, 0
		for __, v in pairs(t) do
			if type(v) == "table" then
				local tt, vv = sizeOf(v, seen)
				tables, values = tables + tt, values + vv
			else
				values = values + 1
			end
		end
		return tables, values
	end

	local M = {}
	function M.update(userParams, state, dt)
		local s = state:get()
		if type(s) ~= "table" then s = {} end
		if s.done then return end
		local step = (s.step or 0) + 1
		local shape = shapes[step]
		if not shape then
			state:set({ step = step, done = true })
			log("done")
			return
		end
		local t = shape.make()
		local tables, values = sizeOf(t)
		local clock = api.type.Clock.new()
		local bestSet, bestGet = math.huge, math.huge
		for __ = 1, REPS do
			local a = clock:getTime()
			state:set(t)
			local b = clock:getTime()
			local copy = state:get()
			local c = clock:getTime()
			if b - a < bestSet then bestSet = b - a end
			if c - b < bestGet then bestGet = c - b end
			if __ == 1 then
				local ct, cv = sizeOf(copy)
				if ct ~= tables or cv ~= values then log("copy differs: " .. ct .. "/" .. cv) end
			end
		end
		state:set({ step = step })
		log(string.format("%-56s %6d tables %7d values: set %7.0f us, get %7.0f us, set+get %6.2f us/table, %5.2f us/value",
			shape.name, tables, values, bestSet, bestGet, (bestSet + bestGet) / tables, (bestSet + bestGet) / values))
	end
	return M
end
