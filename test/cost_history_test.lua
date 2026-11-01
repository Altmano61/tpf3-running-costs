-- run: luajit test/cost_history_test.lua  (from the repo root)
package.path = "kampfmoehre_running_costs_1/content/running_costs/?.lua;" .. package.path
local M = require "cost_history"

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

local Y = 1461000
check("constants: 6 buckets cover a default year, one spare", M.BUCKET_MS == 243500 and M.BUCKETS == 7 and 6 * M.BUCKET_MS == Y)
-- window() derives the cost per class from seconds × factor × the bucket's rate
local F = function(key) return key == "terminal" and 0.4 or (key == "depot" and 0.05 or 1.0) end
local function W(h, now, win) return M.window(h, now, win, F, Y) end

local h = M.new(0)
M.add(h, 2000, 2000, "driving", 1461000, 0, 1.0, Y)    -- 2 s at 1 461 000/yr = 2000 cost
local w = W(h, 2000, Y)
near("cost of 2 s driving", w.c.driving, 2000, 1e-6)
-- state diet (0.3.1): a bucket is one packed string (the game copies the
-- state per element, ~0.1-0.3 us each; a string counts as one)
check("head bucket is a table of flat fields", type(h.b[1]) == "table" and h.b[1].t == nil and h.b[1].t_driving == 2 and h.b[1].t0 == 0)
local rt = M.decode(M.encode({ t0 = 243500, n = 180.5, r = 123456.789, s = 0.1, t_driving = 100, [28] = 4, [29] = 1234.5 }))
check("encode/decode roundtrip", rt.t0 == 243500 and rt.n == 180.5 and rt.r == 123456.789 and rt.s == 0.1 and rt.t_driving == 100 and rt[28] == 4 and rt[29] == 1234.5)
check("decode of garbage", type(M.decode("")) == "table" and type(M.decode("x")) == "table" and M.decode(nil) == nil)
check("decode passes a legacy table bucket through", M.decode(rt) == rt)
near("window with an explicit key list", M.window(h, 2000, Y, F, Y, { "driving", "terminal" }).c.driving, 2000, 1e-6)
check("explicit key list ignores unknown fields", M.window(h, 2000, Y, F, Y, { "terminal" }).total == 0)
local flat = M.deflateSummary(w)
check("flat summary has no sub-tables", flat.t == nil and flat.c == nil and flat.t_driving == 2 and flat.c_driving == 2000 and flat.cov == w.cov)
local back = M.inflateSummary(flat)
check("inflated summary", back.t.driving == 2 and back.c.driving == 2000 and back.cov == w.cov and back.total == w.total)
check("inflate tolerates a plain summary", M.inflateSummary(w).t.driving == 2)
near("seconds", w.t.driving, 2, 1e-9)
near("coverage of a young history", w.cov, 2000, 1e-9)
M.add(h, 4000, 2000, "terminal", 1461000, 292200, 0.4, Y) -- 20 % surcharge at factor 0.4
near("terminal cost", W(h, 4000, Y).c.terminal, 800, 1e-6)
near("surcharge", W(h, 4000, Y).s, 160, 1e-6)
near("total", W(h, 4000, Y).total, 2960, 1e-6)
near("coverage grows", W(h, 4000, Y).cov, 4000, 1e-9)

-- static changes between buckets: the new bucket uses the new rate
local h2 = M.new(0)
M.add(h2, 1000, 1000, "driving", 1000 * Y / 1000, 0, 1.0, Y)              -- 1 s at 1000/s -> 1000
M.add(h2, M.BUCKET_MS + 1000, 1000, "driving", 2000 * Y / 1000, 0, 1.0, Y) -- 1 s at 2000/s -> 2000
near("static change", W(h2, M.BUCKET_MS + 1000, Y).c.driving, 3000, 1e-6)
check("two buckets open, each with its rate", h2.b[1] ~= nil and h2.b[2] ~= nil and M.decode(h2.b[2]).t0 == M.BUCKET_MS and M.decode(h2.b[1]).r == Y and M.decode(h2.b[2]).r == 2 * Y)
check("closed bucket packed, head a table", type(h2.b[1]) == "string" and type(h2.b[2]) == "table", type(h2.b[1]) .. "/" .. type(h2.b[2]))
check("t0 leads the string", h2.b[1]:sub(1, 3) == "t0=")
check("bucket holds no per-class cost table", M.decode(h2.b[1]).c == nil)
-- a ring whose head is still packed (older state) is unpacked on the next add
local hp = M.new(0); M.add(hp, 1000, 1000, "driving", Y, 0, 1.0, Y); hp.b[1] = M.encode(hp.b[1])
M.add(hp, 2000, 1000, "driving", Y, 0, 1.0, Y)
check("packed head unpacked and continued", type(hp.b[1]) == "table" and hp.b[1].t_driving == 2)

-- static changes inside one bucket: the bucket's rate is the seconds-weighted
-- mean, so the pre-change seconds keep their old rate in the total
local h2b = M.new(0)
M.add(h2b, 1000, 1000, "driving", 1000 * Y / 1000, 0, 1.0, Y)   -- 1 s at 1000/s
M.add(h2b, 2000, 1000, "driving", 2000 * Y / 1000, 0, 1.0, Y)   -- 1 s at 2000/s, same bucket
near("rate change inside a bucket", W(h2b, 2000, Y).c.driving, 3000, 1e-6)
M.add(h2b, 3000, 1000, "terminal", 4000 * Y / 1000, 0, 0.4, Y)  -- 1 s at 4000/s, factor 0.4
near("mean rate spans all classes of the bucket", W(h2b, 3000, Y).total, 2 * (7000 / 3) + 0.4 * (7000 / 3), 1e-6)

-- rollover: 8 buckets written, the ring keeps 7; the window = 6 full buckets
-- plus the oldest one pro rata (here 10 ms short of full), bucket 0 is gone
local h3 = M.new(0)
for i = 0, 7 do M.add(h3, i * M.BUCKET_MS + 10, 1000, "driving", Y, 0, 1.0, Y) end
local w3 = W(h3, 7 * M.BUCKET_MS + 10, Y)
near("window keeps 7 buckets, oldest pro rata", w3.c.driving, 7 * 1000 - 1000 * 10 / M.BUCKET_MS, 1e-3)
near("coverage capped at the window", w3.cov, Y, 1e-9)
-- pro rata: a window ending mid-bucket counts the oldest bucket by its overlap
local h7 = M.new(0)
M.add(h7, 10, 1000, "driving", Y, 0, 1.0, Y)                       -- bucket 0: 1000
M.add(h7, M.BUCKET_MS + 10, 1000, "driving", Y, 0, 1.0, Y)         -- bucket 1: 1000
local w7 = W(h7, M.BUCKET_MS + 10, M.BUCKET_MS / 2 + 10)           -- window starts at half of bucket 0
near("oldest bucket weighted by overlap", w7.c.driving, 1500, 1e-6)
near("pro rata seconds too", w7.t.driving, 1.5, 1e-9)
near("coverage of a pro rata window", w7.cov, M.BUCKET_MS / 2 + 10, 1e-9)
local n = 0
for __ in pairs(h3.b) do n = n + 1 end
check("ring never exceeds BUCKETS", n == M.BUCKETS, tostring(n))

-- a shorter window only sums recent buckets: 2 full ones + the oldest pro rata
local w3s = W(h3, 7 * M.BUCKET_MS + 10, 2 * M.BUCKET_MS)
near("short window", w3s.c.driving, 3 * 1000 - 1000 * 10 / M.BUCKET_MS, 1e-3)

-- unknown keys and sparse buckets tolerated
local h4 = M.new(0); M.add(h4, 500, 500, "speed_bucket_90", Y, 0, 1.0, Y)
local b4 = M.decode(h4.b[h4.head]); b4.r = nil; h4.b[h4.head] = M.encode(b4)
check("unknown key, missing rate", W(h4, 500, Y).t.speed_bucket_90 == 0.5 and W(h4, 500, Y).total == 0)
b4.t_speed_bucket_90 = nil; b4.s = nil; h4.b[h4.head] = M.encode(b4)
check("missing t and s", W(h4, 500, Y).total == 0 and next(W(h4, 500, Y).t) == nil)

-- time jump backwards (before the history's first bucket) resets
local h5 = M.new(500000); M.add(h5, 500500, 500, "terminal", Y, 0, 0.4, Y)
M.add(h5, 100, 100, "driving", Y, 0, 1.0, Y)
check("reset on backwards time", W(h5, 100, Y).t.terminal == nil and W(h5, 100, Y).t.driving == 0.1)

-- pro rata with a history that starts mid-bucket: the oldest bucket's data
-- spans [first, bucket end], and the window cut is measured against that span
local h9 = M.new(M.BUCKET_MS / 2)                               -- first sample at half of bucket 0
M.add(h9, M.BUCKET_MS / 2 + 1000, 1000, "driving", Y, 0, 1.0, Y) -- 1 s -> 1000
M.add(h9, M.BUCKET_MS + 10, 10, "driving", 0, 0, 1.0, Y)       -- bucket 1 exists, no cost
local w9 = W(h9, M.BUCKET_MS + 10, M.BUCKET_MS / 4 + 10)        -- window starts at 3/4 of bucket 0
near("first mid-bucket: half of the data span is inside the window", w9.c.driving, 500, 1e-6)
near("first mid-bucket: coverage from the window start", w9.cov, M.BUCKET_MS / 4 + 10, 1e-9)
local w9b = W(h9, M.BUCKET_MS + 10, M.BUCKET_MS + 10)           -- window starts at 0, before first
near("window before first: full weight", w9b.c.driving, 1000, 1e-6)

-- coverage starts at the first sample, not at the start of its bucket
local h8 = M.new(100000)                                   -- bucket 0 starts at 0
M.add(h8, 100000, 1000, "driving", Y, 0, 1.0, Y)
near("coverage from the first sample", W(h8, 160000, Y).cov, 60000, 1e-9)
h8.first = nil                                             -- state written by an older version
near("without first: falls back to the bucket start", W(h8, 160000, Y).cov, 160000, 1e-9)

-- empty history
local e = W(M.new(0), 0, Y)
check("empty history", e.cov == 0 and e.total == 0 and next(e.t) == nil)

-- a long gap (paused game, big dt) lands in the current bucket only
local h6 = M.new(0)
M.add(h6, 10, 10, "driving", Y, 0, 1.0, Y)
M.add(h6, 5 * M.BUCKET_MS, 3 * M.BUCKET_MS, "driving", Y, 0, 1.0, Y)
local n6 = 0
for __ in pairs(h6.b) do n6 = n6 + 1 end
check("gap: buckets in between are not created", n6 == 2 and M.decode(h6.b[2]).t0 == 5 * M.BUCKET_MS, tostring(n6))

-- shared ring: income without time accumulation
local r = M.newRing(0)
check("ring has no first", r.first == nil and r.head == 0)
M.addIncome(r, 1000, 7, 500, true)
M.addIncome(r, 2000, 7, 300, false)
M.addIncome(r, 3000, 9, 100, nil)                     -- passengers: no quality
local I = M.windowIncome(r, 3000, Y, nil)
near("items", I[7].n, 2, 1e-9); near("base", I[7].base, 800, 1e-9)
check("on time 1 of 2 with quality", I[7].ok == 1 and I[7].q == 2)
check("no quality counted", I[9].n == 1 and I[9].q == 0 and I[9].ok == 0)
-- the window cut uses the cost history's first, pro rata like the costs
local r2 = M.newRing(0)
M.addIncome(r2, M.BUCKET_MS / 2 + 1000, 7, 1000, true)                  -- bucket 0, data from first = B/2
local I2 = M.windowIncome(r2, M.BUCKET_MS + 10, M.BUCKET_MS / 4 + 10, M.BUCKET_MS / 2)
near("income pro rata against first", I2[7].base, 500, 1e-6)
near("items pro rata too", I2[7].n, 0.5, 1e-9)
check("empty ring", next(M.windowIncome(M.newRing(0), 0, Y, nil)) == nil and next(M.windowIncome(nil, 0, Y, nil)) == nil)
-- bucketWeight is the single rule both windows use
near("weight: full bucket", M.bucketWeight(0, 2 * M.BUCKET_MS, 3 * M.BUCKET_MS, nil), 1, 1e-9)
near("weight: outside", M.bucketWeight(0, 10 * M.BUCKET_MS, M.BUCKET_MS, nil), 0, 1e-9)
near("weight: half cut, first mid-bucket", M.bucketWeight(0, M.BUCKET_MS + 10, M.BUCKET_MS / 4 + 10, M.BUCKET_MS / 2), 0.5, 1e-9)
-- exported bucketFor keeps the ring bounded and resets on backwards time
local r3 = M.newRing(0)
for i = 0, 9 do M.bucketFor(r3, i * M.BUCKET_MS) end
local n3 = 0; for __ in pairs(r3.b) do n3 = n3 + 1 end
check("ring bounded", n3 == M.BUCKETS)
M.bucketFor(r3, 5); check("reset on backwards time without first", r3.head == 1 and r3.first == nil)

-- buffered income: counts arrive late (up to a flush interval after the
-- events) and must land in the bucket of their event time, never reset the ring
local r4 = M.newRing(0)
M.addIncomeCounts(r4, 1000, 7, 3, 300, 2, 3)                 -- 3 items at t=1 s
local I4 = M.windowIncome(r4, 2000, Y, nil)
check("counts added", I4[7].n == 3 and I4[7].base == 300 and I4[7].ok == 2 and I4[7].q == 3)
M.addIncomeCounts(r4, M.BUCKET_MS + 500, 7, 1, 100, 1, 1)    -- bucket 1 opens
M.addIncomeCounts(r4, M.BUCKET_MS - 500, 7, 1, 50, 0, 1)     -- late item of bucket 0
check("late item lands in its own bucket", M.decode(r4.b[1])[28] == 4 and M.decode(r4.b[2])[28] == 1 and r4.head == 2)   -- [cargo 7 × 4 + 0] = n
check("late item's bucket stays packed", type(r4.b[1]) == "string" and type(r4.b[2]) == "table")
M.addIncomeCounts(r4, -5000, 7, 1, 10, 0, 0)                 -- older than the ring start: head bucket, no reset
check("too-old item goes to the newest bucket, ring kept", r4.head == 2 and M.decode(r4.b[2])[28] == 2 and M.decode(r4.b[1])[28] == 4)

-- income before the cost history's first sample must not count (review 0.2.0 #1)
near("weight: bucket entirely before first is 0", M.bucketWeight(0, 3 * M.BUCKET_MS, 6 * M.BUCKET_MS, 2 * M.BUCKET_MS), 0, 1e-9)
local r5 = M.newRing(0)
M.addIncomeCounts(r5, 100, 7, 1, 10, 0, 0)
M.addIncomeCounts(r5, 2 * M.BUCKET_MS + 100, 7, 1, 10, 0, 0)
near("items before first are dropped", M.windowIncome(r5, 2 * M.BUCKET_MS + 200, Y, 2 * M.BUCKET_MS)[7].n, 1, 1e-9)

-- income queue: the collector appends compact records per batch to a tiny
-- state, the sampler consumes new ones (by id) into the rings
local buf = M.newBuffer()
check("empty buffer", buf.items == 0 and buf.since == nil)
M.bufferAdd(buf, 25245, 7, 6 * M.BUCKET_MS + 10, 100, true)
M.bufferAdd(buf, 25245, 7, 6 * M.BUCKET_MS + 20, 50, nil)
M.bufferAdd(buf, "L9", 3, 6 * M.BUCKET_MS + 20, 7, false)
check("buffer counts, since = oldest item", buf.items == 3 and buf.since == 6 * M.BUCKET_MS + 10)
local q = {}
local added = M.queueAppend(q, buf, "t1", 6 * M.BUCKET_MS + 30)
check("one record per ring and cargo, ids from the tag", added == 2 and q["t1-1"] ~= nil and q["t1-2"] ~= nil)
local recs = { q["t1-1"], q["t1-2"] }
table.sort(recs, function(a, b) return tostring(a.rk) < tostring(b.rk) end)
check("record fields", recs[1].rk == 25245 and recs[1].key == 7 and recs[1].n == 2 and recs[1].base == 150 and recs[1].ok == 1 and recs[1].q == 1 and recs[1].t == 6 * M.BUCKET_MS + 10)
check("line-level record", recs[2].rk == "L9" and recs[2].n == 1 and recs[2].q == 1 and recs[2].ok == 0)
M.queueTrim(q, 6 * M.BUCKET_MS + 30 + 10000, 10000)
check("trim keeps records younger than the age", q["t1-1"] ~= nil)
M.queueTrim(q, 6 * M.BUCKET_MS + 30 + 10001, 10000)
check("trim drops old records", next(q) == nil)
-- consuming: every record once, even when read twice
local q2 = {}
M.queueAppend(q2, buf, "t2", 0)             -- buf was emptied by the first append
check("append of an empty buffer adds nothing", next(q2) == nil)
M.bufferAdd(buf, 25245, 7, 6 * M.BUCKET_MS + 40, 10, true)
M.queueAppend(q2, buf, "t2", 6 * M.BUCKET_MS + 40)
local rings, seen = {}, {}
check("consume adds once", M.queueConsume(q2, rings, seen, 6 * M.BUCKET_MS + 40) == 1 and M.queueConsume(q2, rings, seen, 6 * M.BUCKET_MS + 40) == 0)
check("consumed into the ring", M.windowIncome(rings[25245], 6 * M.BUCKET_MS + 50, Y, nil)[7].n == 1)
M.queueConsume(q2, rings, seen, 6 * M.BUCKET_MS + 40 + 120000)
check("seen set pruned after a while", next(seen) == nil)

-- maintenance pools (0.3.0): one entry per vehicle with a sliding span
-- [t0, t1], not buckets (7 buckets × ~1300 pairs per bucket on the big save
-- tripled the state copy time)
local pr = M.newPool(0)                                  -- building first seen at 0
M.addPool(pr, 3000, 3000, 7, 1461000, 0.5, Y, Y)         -- 3 s at 1 461 000/yr -> fee 0.25 × 3000 = 750
M.addPool(pr, 6000, 3000, 7, 1461000, 0.85, Y, Y)        -- good
M.addPool(pr, 9000, 3000, 7, 1461000, 1.0, Y, Y)         -- full
M.addPool(pr, 9000, 3000, 8, 0, nil, Y, Y)               -- unknown rc / condition
local P, cov = M.windowPool(pr, 9000, Y)
near("pool seconds", P[7].s, 9, 1e-9); near("pool fee", P[7].fee, 2250, 1e-6)
near("fee while good (exact share)", P[7].gfee, 1500, 1e-6); near("fee while full", P[7].ffee, 750, 1e-6)
near("entry condition", P[7].c0, 0.5, 1e-9)
near("exit condition = last seen in the pool", P[7].c1, 1.0, 1e-9)
check("zero fee vehicle counted", P[8].s == 3 and P[8].fee == 0 and P[8].gfee == 0 and P[8].c0 == nil)
near("pool coverage", cov, 9000, 1e-9)
-- the span is cut pro rata at the window
local pr2 = M.newPool(0)
for t = 1000, 10000, 1000 do M.addPool(pr2, t, 1000, 7, Y, 0.3, Y, Y) end   -- span 0..10000, 10 s
near("entry fully inside the window", M.windowPool(pr2, 10000, Y)[7].s, 10, 1e-9)
near("entry cut at the window start", M.windowPool(pr2, 10000, 5000)[7].s, 5, 1e-9)
check("entry that ended before the window is gone", M.windowPool(pr2, 20000, 5000)[7] == nil)
-- an entry older than the window is truncated before new data is added
M.addPool(pr2, 20000, 1000, 7, Y, 0.3, Y, 10000)       -- window 10 s: the old span 0..10000 ends at the new start
near("truncated span: only the new second counts", M.windowPool(pr2, 20000, 10000)[7].s, 1, 1e-9)
-- a new visit (gap > GAP_MS) restarts the entry condition
local pr3 = M.newPool(0)
M.addPool(pr3, 1000, 1000, 7, Y, 0.3, Y, Y)
M.addPool(pr3, 2000, 1000, 7, Y, 0.4, Y, Y)
near("c0 kept within a visit", M.windowPool(pr3, 2000, Y)[7].c0, 0.3, 1e-9)
M.addPool(pr3, 2000 + M.GAP_MS + 1, 1000, 7, Y, 0.9, Y, Y)
near("c0 of the latest visit", M.windowPool(pr3, 2000 + M.GAP_MS + 1, Y)[7].c0, 0.9, 1e-9)
near("c1 = last seen", M.windowPool(pr3, 2000 + M.GAP_MS + 1, Y)[7].c1, 0.9, 1e-9)
-- coverage counts from the first sight of the building, not from the data
local pr4 = M.newPool(0)
M.addPool(pr4, 600000, 3000, 7, Y, 1.0, Y, Y)             -- one drive-by, then nothing
near("sparse ring: coverage since the ring began", select(2, M.windowPool(pr4, 1000000, Y)), 1000000, 1e-9)
near("sparse ring: capped at the window", select(2, M.windowPool(pr4, 2 * Y, Y)), Y, 1e-9)
-- pruning (sampler sweep) drops entries that ended before the window
check("prune removes expired entries", M.prunePool(pr2, 40000, 10000) == 1 and next(pr2.v) == nil)
check("prune keeps live entries", M.prunePool(pr4, 601000, Y) == 0 and pr4.v[7] ~= nil)
check("empty pool ring", next((M.windowPool(M.newPool(0), 0, Y))) == nil and select(2, M.windowPool(nil, 0, Y)) == 0)

-- income buckets: one packed string per bucket with integer keys (cargo × 4 + field)
local ir = M.newRing(0)
M.addIncome(ir, 1000, 3, 100, true)
M.addIncomeCounts(ir, 1000, 3, 2, 200, 1, 2)
M.addIncomeCounts(ir, 1000, 5, 1, 50, 0, 0)
check("income head bucket is a table with integer keys", type(ir.b[ir.head]) == "table" and ir.b[ir.head][12] == 3)
-- a legacy table bucket (older state) is still read
local lr = M.newRing(0); lr.head = 1; lr.b[1] = { t0 = 0, [12] = 2, [13] = 20 }
check("legacy table bucket read", M.windowIncome(lr, 1000, Y, nil)[3].n == 2)
local wi = M.windowIncome(ir, 1000, Y, nil)
check("income decoded per cargo", wi[3].n == 3 and wi[3].base == 300 and wi[3].ok == 2 and wi[3].q == 3 and wi[5].n == 1 and wi[5].base == 50)

-- go-around counter (0.4.0): a plain bucket field summed pro rata like the seconds
local hg = M.new(0)
M.add(hg, 1000, 1000, "driving", Y, 0, 1.0, Y)
M.addCount(hg, 1000, "g", 1)
M.addCount(hg, 2000, "g", 1)
near("count summed", W(hg, 2000, Y).g, 2, 1e-9)
check("count is a bucket field", M.decode(hg.b[hg.head]).g == 2)
near("count absent is 0", W(h, 4000, Y).g, 0, 1e-9)
-- pro rata: a count in the oldest half-covered bucket counts half
local hg2 = M.new(0)
M.add(hg2, 1000, 1000, "driving", Y, 0, 1.0, Y)
M.addCount(hg2, 1000, "g", 2)
M.add(hg2, M.BUCKET_MS + 1000, 1000, "driving", Y, 0, 1.0, Y)
near("count weighted with the bucket", M.window(hg2, M.BUCKET_MS + 1000, M.BUCKET_MS / 2 + 1000, F, Y).g, 1, 1e-6)
local wg = W(hg, 2000, Y)
check("count survives deflate/inflate", M.inflateSummary(M.deflateSummary(wg)).g == 2 and M.deflateSummary(wg).g == 2)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all ok")
