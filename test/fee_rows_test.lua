-- run: luajit test/fee_rows_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/gui/kampfmoehre_running_costs/?.lua;" .. package.path
local M = require "fee_rows"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end
local function near(name, got, want, tol)
	check(name, type(got) == "number" and math.abs(got - want) <= tol, string.format("got %s, want %s", tostring(got), tostring(want)))
end

local E = {
	[7] = { s = 600, fee = 6000, gfee = 3000, ffee = 0, c0 = 0.5, c1 = 0.9 },  -- half the fee while good
	[8] = { s = 300, fee = 3000, gfee = 3000, ffee = 3000, c0 = 1.0 },        -- always full
	[9] = { s = 100, fee = 0, gfee = 0, ffee = 0, c0 = nil },                 -- zero fee vehicle
}
local MB = { [7] = { [1] = 1, [2] = 1 }, [8] = { [1] = 1 }, [9] = { [1] = 1 } }
local T = M.build(E, 1, MB)
near("fee", T.fee, 9000, 1e-9)
near("good share (fee-weighted)", T.goodShare, (6000 * 0.5 + 3000 * 1.0) / 9000, 1e-9)
near("full share", T.fullShare, 3000 / 9000, 1e-9)
near("elsewhere share of the good part", T.elsewhereShare, (6000 * 0.5) / (6000 * 0.5 + 3000 * 1.0), 1e-9)
check("rows sorted by fee, zero-fee vehicle last", #T.rows == 3 and T.rows[1].v == 7 and T.rows[3].v == 9)
check("row fields", T.rows[1].seconds == 600 and T.rows[1].fee == 6000 and T.rows[1].c0 == 0.5 and T.rows[1].c1 == 0.9)
check("elsewhere from maintainedBy", #T.rows[1].elsewhere == 1 and T.rows[1].elsewhere[1] == 2 and #T.rows[2].elsewhere == 0)
check("row without entry condition", T.rows[3].c0 == nil)
check("empty", M.build({}, 1, {}).empty == true and M.build({}, 1, {}).goodShare == nil)
check("zero fee only", M.build({ [9] = E[9] }, 1, MB).goodShare == nil and M.build({ [9] = E[9] }, 1, MB).empty == false)
check("young ring works like any", M.build({ [7] = { s = 3, fee = 30, gfee = 0, ffee = 0, c0 = 0.2 } }, 1, {}).goodShare == 0)
-- the share is fee-weighted per second: 200 charged while poor, 100 while good -> 1/3, not 1/2
near("good share from the fee charged while good", M.build({ [7] = { s = 2, fee = 300, gfee = 100, ffee = 0, c0 = 0.5 } }, 1, {}).goodShare, 1 / 3, 1e-9)
check("no maintainedBy entry at all", #M.build({ [7] = E[7] }, 1, nil).rows[1].elsewhere == 0)
check("minutes: at least 1 when there is data", M.minutes(0) == 0 and M.minutes(1000) == 1 and M.minutes(90000) == 2)
-- gone entities (sold vehicles, demolished buildings): the fee stays in the
-- sum and the shares, the row and the elsewhere marker go (review 0.3.0)
local TG = M.build(E, 1, MB, { [8] = true, [2] = true })
near("sold vehicle: fee kept", TG.fee, 9000, 1e-9)
check("sold vehicle: row hidden, counted", #TG.rows == 2 and TG.rows[1].v == 7 and TG.rows[2].v == 9 and TG.sold == 1)
near("sold vehicle: fee of hidden rows", TG.soldFee, 3000, 1e-9)
near("sold vehicle: good share unchanged", TG.goodShare, (6000 * 0.5 + 3000 * 1.0) / 9000, 1e-9)
check("demolished building not elsewhere", #TG.rows[1].elsewhere == 0 and TG.elsewhereShare == 0)
check("all rows sold: not empty", M.build({ [8] = E[8] }, 1, MB, { [8] = true }).empty == false)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
