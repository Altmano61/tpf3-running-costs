-- Maintenance fee card of Running Cost Breakdown (0.3.0): turns one
-- building's pool entries (cost_history.windowPool in content/running_costs/:
-- { [vehicle] = { s, fee, gfee, ffee, c0, c1 } }) into the card's figures and rows.
--
-- Shares are fee-weighted: the ring records the fee charged while the
-- vehicle was at condition >= 0.8 ("Very good" in the game, gfee) and at 1.0
-- (ffee); the elsewhere share is the part of the good fee that went to
-- vehicles another building also maintained inside the window.
--
-- No game API, unit-tested with plain luajit (test/fee_rows_test.lua).
local M = {}

local function round(x)
	return math.floor(x + 0.5)
end

-- entries: windowPool result, building: the window's entity,
-- maintainedBy: { [vehicle] = { [building] = lastSeenMs } } or nil,
-- gone: set of entities that no longer exist (sold vehicles keep their fee
-- in the sum and the shares but get no row; demolished buildings are not
-- "elsewhere") ->
-- { fee, goodShare | nil, fullShare | nil, elsewhereShare | nil,
--   rows = { { v, seconds, fee, c0, c1, elsewhere = { other buildings } } },
--   sold = hidden rows, soldFee = their fee, empty }
function M.build(entries, building, maintainedBy, gone)
	local out = { fee = 0, goodShare = nil, fullShare = nil, elsewhereShare = nil, rows = {}, sold = 0, soldFee = 0, empty = true }
	if type(entries) ~= "table" then return out end
	gone = gone or {}
	local goodFee, fullFee, elsewhereGoodFee = 0, 0, 0
	local n = 0
	for v, e in pairs(entries) do
		if type(e) == "table" then
			n = n + 1
			local seconds = e.s or 0
			local fee = e.fee or 0
			local elsewhere = {}
			local mb = maintainedBy and maintainedBy[v]
			if type(mb) == "table" then
				for b in pairs(mb) do
					if b ~= building and not gone[b] then elsewhere[#elsewhere + 1] = b end
				end
				table.sort(elsewhere)
			end
			if gone[v] then
				out.sold = out.sold + 1
				out.soldFee = out.soldFee + fee
			else
				out.rows[#out.rows + 1] = { v = v, seconds = seconds, fee = fee, c0 = e.c0, c1 = e.c1, elsewhere = elsewhere }
			end
			out.fee = out.fee + fee
			if fee > 0 then
				local g = e.gfee or 0
				goodFee = goodFee + g
				fullFee = fullFee + (e.ffee or 0)
				if #elsewhere > 0 then elsewhereGoodFee = elsewhereGoodFee + g end
			end
		end
	end
	out.empty = n == 0
	table.sort(out.rows, function(a, b)
		if a.fee ~= b.fee then return a.fee > b.fee end
		return a.v < b.v
	end)
	if out.fee > 0 then
		out.goodShare = goodFee / out.fee
		out.fullShare = fullFee / out.fee
		if goodFee > 0 then out.elsewhereShare = elsewhereGoodFee / goodFee end
	end
	return out
end

-- the sampler stores maintainedBy as one flat table { ["<vehicle>:<building>"]
-- = lastSeenMs } (one table instead of one per vehicle) -> { [building] = ms }
function M.buildingsOf(flat, v)
	local out = {}
	if type(flat) ~= "table" then return out end
	local prefix = tostring(v) .. ":"
	local n = #prefix
	for k, t in pairs(flat) do
		if type(k) == "string" and k:sub(1, n) == prefix then
			local b = tonumber(k:sub(n + 1))
			if b then out[b] = t end
		end
	end
	return out
end

-- game-time ms -> whole minutes for the header, at least 1 when there is data
function M.minutes(ms)
	ms = ms or 0
	if ms <= 0 then return 0 end
	return math.max(1, round(ms / 60000))
end

return M
