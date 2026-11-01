-- Per-vehicle cost history of Running Cost Breakdown: a ring of time buckets
-- holding, per cost class, the game seconds spent, plus the vehicle's static
-- (healthy) rate per year as seen in that bucket and the maintenance-state
-- surcharge charged in it. The cost per class is derived in window() as
-- seconds × factor × rate / year, so a bucket is small (the state is copied
-- on every get/set of the game script, ~400 vehicles × 13 buckets).
--
-- 7 buckets of 243 500 ms: 6 cover one default game year (1 461 000 ms of
-- game time, api.util.getDefaultYearDuration()), the 7th makes sure a full
-- window is always inside the ring. window() counts every bucket that
-- overlaps the window, the oldest one pro rata by its overlap (assuming the
-- time inside a bucket is spread evenly); coverage is the time span the
-- counted buckets stand for, capped at the window. Few, large buckets keep
-- the game-script state small: it is copied on every get/set of the
-- sampler (~400 vehicles).
--
-- The tables live in the game-script state (saved with the game), so every
-- function tolerates buckets without t/c/s and class keys it has never seen.
-- No game API, unit-tested with plain luajit (test/cost_history_test.lua).
local M = {}

M.BUCKET_MS = 243500
M.BUCKETS = 7

local function bucketStart(ms)
	return math.floor(ms / M.BUCKET_MS) * M.BUCKET_MS
end

-- Ring = { start = ms of the first bucket, head = slot of the newest bucket
-- (0 = none), b = { [slot] = packed Bucket } }. A Bucket is a table with t0
-- and the users' fields (costs: t_<key> = seconds per class, n = all seconds,
-- r = rate/year, s = surcharge; income: [cargo × 4 + field] = number), but it
-- a CLOSED bucket is STORED as one string "t0=...;n=...;t_driving=..."
-- (encode/decode): the game copies the whole state in and out on every
-- sample at ~0.1-0.3 µs per element (table, value or string-keyed field
-- alike, measured 2026-10-31 with a probe, docs/probes/state_probe/), so 389
-- rings cost 2.5 ms as tables of fields and 0.5 ms as 7 strings each. The
-- head bucket stays a table and is changed in place (packing it on every
-- sample cost more Lua time than the copy saved); it is packed when the
-- ring moves on. window() reads the strings through a small decode cache.
local encode, decode

function M.encode(b)
	local parts = { "t0=" .. string.format("%d", b.t0 or 0) }
	for k, v in pairs(b) do
		if k ~= "t0" and type(v) == "number" then
			parts[#parts + 1] = k .. "=" .. string.format("%.15g", v)
		end
	end
	return table.concat(parts, ";")
end
encode = M.encode

-- a fresh table from a packed bucket; a table (legacy bucket) passes through
function M.decode(str)
	if type(str) ~= "string" then return str end
	local b = {}
	for k, v in string.gmatch(str, "([^;=]+)=([^;]*)") do
		b[tonumber(k) or k] = tonumber(v) or 0
	end
	return b
end
decode = M.decode

-- read-only decode through a bounded per-Lua-state cache (window() decodes
-- all buckets of every ring on every sample, only the head changes). Two
-- generations: a full young generation becomes the old one, entries still
-- in use move back on their next hit, so the warm set survives the overflow.
local young, old, youngN = {}, {}, 0
local CACHE_GEN = 4096
local function remember(str, b)
	if youngN >= CACHE_GEN then
		old, young, youngN = young, {}, 0
	end
	young[str] = b
	youngN = youngN + 1
end
local function cached(x)
	if type(x) ~= "string" then return x end
	local b = young[x]
	if b ~= nil then return b end
	b = old[x]
	if b == nil then b = decode(x) end
	remember(x, b)
	return b
end

local function t0Of(x)
	if type(x) == "table" then return x.t0 end
	if type(x) ~= "string" then return nil end
	return tonumber(string.match(x, "^t0=(%-?%d+)"))
end

function M.newRing(nowMs)
	return { start = bucketStart(nowMs or 0), head = 0, b = {} }
end

-- History = Ring + first = ms of the first sample (coverage counts from
-- here, not from the bucket start)
function M.new(nowMs)
	local h = M.newRing(nowMs)
	h.first = nowMs or 0
	return h
end

-- the head bucket for nowMs (a table, changed in place) plus its slot,
-- opening it (reusing the oldest slot, packing the old head) when needed; a
-- step back in time starts the ring over.
function M.bucketFor(h, nowMs)
	local t0 = bucketStart(nowMs)
	local cur = h.head > 0 and h.b[h.head] or nil
	local curT0 = cur and t0Of(cur)
	if cur and curT0 == t0 then
		if type(cur) == "string" then   -- legacy / foreign: unpack it for good
			cur = decode(cur)
			h.b[h.head] = cur
		end
		return cur, h.head
	end
	if nowMs < h.start or (cur and curT0 and t0 < curT0) then
		h.start, h.head, h.b = t0, 0, {}
		if h.first ~= nil then h.first = nowMs end
	elseif type(cur) == "table" then
		h.b[h.head] = encode(cur)   -- close the old head
	end
	h.head = h.head % M.BUCKETS + 1
	local nb = { t0 = t0 }
	h.b[h.head] = nb
	return nb, h.head
end
local bucketFor = M.bucketFor

-- share of a bucket's data that lies inside the window [nowMs - windowMs, nowMs]:
-- 0 outside, 1 for a bucket fully inside, pro rata for the oldest one (its
-- data starts at `first` when the history began inside it)
function M.bucketWeight(t0, nowMs, windowMs, first)
	local from = nowMs - windowMs
	if t0 + M.BUCKET_MS <= from or t0 > nowMs then return 0 end
	-- nothing before the history began counts (an income ring may be older
	-- than the cost history whose `first` it is read with)
	if first and t0 + M.BUCKET_MS <= first then return 0 end
	local dataStart = t0
	if first and first > dataStart then dataStart = first end
	if from <= dataStart then return 1 end
	local span = t0 + M.BUCKET_MS - dataStart
	if span <= 0 then return 0 end
	return math.max(0, (t0 + M.BUCKET_MS - from) / span)
end

-- dtMs of game time spent in class `key` at costPerYearStatic (the healthy
-- rate; a consist change inside one bucket is attributed to the new rate)
-- with surchargePerYear on top, charged at `factor`
local fieldT, fieldC = {}, {}   -- "t_<key>" / "c_<key>", interned once
local function tField(key)
	local f = fieldT[key]
	if f == nil then
		f = "t_" .. key
		fieldT[key] = f
	end
	return f
end
local function cField(key)
	local f = fieldC[key]
	if f == nil then
		f = "c_" .. key
		fieldC[key] = f
	end
	return f
end
-- the class keys stored in a bucket or flat summary (fields "t_<key>")
local function flatKeys(t)
	local keys = {}
	for k in pairs(t) do
		if type(k) == "string" and k:byte(1) == 116 and k:byte(2) == 95 then keys[#keys + 1] = k:sub(3) end
	end
	return keys
end

function M.add(h, nowMs, dtMs, key, costPerYearStatic, surchargePerYear, factor, yearMs)
	local b, slot = bucketFor(h, nowMs)
	b.r = b.r or 0
	b.s = b.s or 0
	b.n = b.n or 0
	local before = b.n
	local dt = dtMs / 1000
	local f = tField(key)
	b[f] = (b[f] or 0) + dt
	b.n = b.n + dt
	-- the bucket's rate is the seconds-weighted mean, so a consist change
	-- inside a bucket keeps the old rate for the seconds before it
	if before + dt > 0 then
		b.r = ((b.r or 0) * before + (costPerYearStatic or 0) * dt) / (before + dt)
	end
	b.s = (b.s or 0) + (surchargePerYear or 0) * dtMs / yearMs * factor
end

-- n more of a plain counted event in the bucket for nowMs (0.4.0: field "g",
-- aborted approaches); window() sums it pro rata like the seconds
function M.addCount(h, nowMs, field, n)
	local b = bucketFor(h, nowMs)
	b[field] = (b[field] or 0) + (n or 1)
end

-- factorOf(key) -> the class factor, yearMs -> the default year, keys = the
-- class keys to read (optional; without it the bucket's fields are scanned) ->
-- Summary = { cov = covered ms (<= windowMs), t = {key = s}, c = {key = cost},
--   s = surcharge, total = sum of c + s, g = aborted approaches (0.4.0) }
function M.window(h, nowMs, windowMs, factorOf, yearMs, keys)
	local out = { cov = 0, t = {}, c = {}, s = 0, total = 0, g = 0 }
	if not h or type(h.b) ~= "table" then return out end
	local from = nowMs - windowMs
	local oldest = nil
	for __, packed in pairs(h.b) do
		local b = cached(packed)
		local weight = (type(b) == "table" and b.t0) and M.bucketWeight(b.t0, nowMs, windowMs, h.first) or 0
		if weight > 0 then
			if oldest == nil or b.t0 < oldest then oldest = b.t0 end
			local perSecond = (b.r or 0) / yearMs * 1000
			for __, k in ipairs(keys or flatKeys(b)) do
				local v = b[tField(k)]
				if v then
					local sec = v * weight
					out.t[k] = (out.t[k] or 0) + sec
					local cost = sec * factorOf(k) * perSecond
					out.c[k] = (out.c[k] or 0) + cost
					out.total = out.total + cost
				end
			end
			out.s = out.s + (b.s or 0) * weight
			out.g = out.g + (b.g or 0) * weight
		end
	end
	out.total = out.total + out.s
	if oldest ~= nil then
		local begin = math.max(oldest, from)
		if h.first and h.first > begin then begin = h.first end
		out.cov = math.min(windowMs, nowMs - begin)
	end
	return out
end

-- maintenance pools (0.3.0). Every depot / maintenance building charges 25 %
-- of the running-cost rate of each vehicle it lists, per second listed, also
-- at condition 1.0 (measured 2026-10-30). Not a bucket ring: on the big save
-- ~1300 (building, vehicle) pairs per 4-min bucket × 7 buckets tripled the
-- state copy time. Instead one entry per vehicle with a sliding span:
--   Pool = { first = ms the building was first seen, v = { [vehicle] = Entry } }
--   Entry = { t0, t1 = first / last sample ms of the span, s = seconds, fee,
--     gfee / ffee = fee charged while the condition was >= 0.8 / 1.0,
--     c0 / c1 = condition at the start of the latest visit / when last seen }
-- An entry older than the window is cut down pro rata to the window before
-- new data is added, so it never represents more than one window (assuming
-- its data is spread evenly over the span). A gap of more than GAP_MS between
-- samples starts a new visit (c0 restarts).
M.GAP_MS = 10000

function M.newPool(nowMs)
	return { first = nowMs or 0, v = {} }
end

-- cut the entry's span to [fromMs, t1] pro rata (nothing to cut if t0 >= fromMs)
local function cutEntry(e, fromMs)
	if e.t0 >= fromMs then return end
	local f = 0
	if e.t1 > fromMs and e.t1 > e.t0 then f = (e.t1 - fromMs) / (e.t1 - e.t0) end
	e.s, e.fee, e.gfee, e.ffee = e.s * f, e.fee * f, e.gfee * f, e.ffee * f
	e.t0 = math.min(fromMs, e.t1)
end

function M.addPool(pool, nowMs, dtMs, v, rcPerYear, cond, yearMs, windowMs)
	pool.v = pool.v or {}
	local e = pool.v[v]
	if e == nil then
		e = { t0 = nowMs - dtMs, t1 = nowMs, s = 0, fee = 0, gfee = 0, ffee = 0, c0 = cond }
		pool.v[v] = e
	else
		if nowMs < e.t1 then   -- time stepped back: start over
			e.t0, e.t1, e.s, e.fee, e.gfee, e.ffee, e.c0 = nowMs - dtMs, nowMs, 0, 0, 0, 0, cond
		elseif nowMs - e.t1 > M.GAP_MS then
			e.c0 = cond   -- a new visit
		end
		cutEntry(e, nowMs - windowMs)
	end
	local dt = dtMs / 1000
	local fee = 0.25 * (rcPerYear or 0) * dtMs / yearMs
	e.s = e.s + dt
	e.fee = e.fee + fee
	if cond ~= nil then
		if cond >= 0.8 then e.gfee = e.gfee + fee end
		if cond >= 1 - 1e-6 then e.ffee = e.ffee + fee end
		e.c1 = cond
	end
	e.t1 = nowMs
end

-- -> { [v] = { s, fee, gfee, ffee, c0, c1 } } cut to the window [nowMs - windowMs,
-- nowMs] (pro rata over the span), coverageMs counted from the building's first
-- sight: it is checked every sample once it exists, quiet spans are normal
function M.windowPool(pool, nowMs, windowMs)
	local out = {}
	if not pool or type(pool.v) ~= "table" then return out, 0 end
	local from = nowMs - windowMs
	for v, e in pairs(pool.v) do
		if type(e) == "table" and e.t1 ~= nil and e.t1 > from then
			local w = 1
			if e.t0 < from then
				w = (e.t1 > e.t0) and (e.t1 - from) / (e.t1 - e.t0) or 0
			end
			if w > 0 then
				out[v] = { s = (e.s or 0) * w, fee = (e.fee or 0) * w, gfee = (e.gfee or 0) * w, ffee = (e.ffee or 0) * w,
					c0 = e.c0, c1 = e.c1 }
			end
		end
	end
	local begin = math.max(from, pool.first or from)
	local cov = math.max(0, math.min(windowMs, nowMs - begin))
	return out, cov
end

-- drop entries that ended before the window (sampler sweep) -> number removed
function M.prunePool(pool, nowMs, windowMs)
	local n = 0
	if not pool or type(pool.v) ~= "table" then return n end
	local from = nowMs - windowMs
	for v, e in pairs(pool.v) do
		if type(e) ~= "table" or e.t1 == nil or e.t1 <= from then
			pool.v[v] = nil
			n = n + 1
		end
	end
	return n
end

-- the summary as stored in the state: t/c sub-tables flattened to t_<key> /
-- c_<key> fields (two tables per vehicle saved); inflate() reverses it
function M.deflateSummary(w)
	local out = {}
	for k, v in pairs(w) do
		if k == "t" then
			for key, sec in pairs(v) do out[tField(key)] = sec end
		elseif k == "c" then
			for key, cost in pairs(v) do out[cField(key)] = cost end
		else
			out[k] = v
		end
	end
	return out
end

function M.inflateSummary(flat)
	if type(flat) ~= "table" then return flat end
	if type(flat.t) == "table" and type(flat.c) == "table" then return flat end   -- already a summary
	local out = { t = {}, c = {} }
	for k, v in pairs(flat) do
		if type(k) == "string" and k:byte(2) == 95 and (k:byte(1) == 116 or k:byte(1) == 99) then
			if k:byte(1) == 116 then out.t[k:sub(3)] = v else out.c[k:sub(3)] = v end
		else
			out[k] = v
		end
	end
	return out
end

-- income bucket: [cargo × 4 + field] with fields 0 = n, 1 = base, 2 = ok,
-- 3 = q (cargo type ids are small non-negative integers)
local function incAdd(b, key, n, base, ok, q)
	key = tonumber(key)
	if key == nil then return end
	local k = key * 4
	b[k] = (b[k] or 0) + (n or 0)
	b[k + 1] = (b[k + 1] or 0) + (base or 0)
	b[k + 2] = (b[k + 2] or 0) + (ok or 0)
	b[k + 3] = (b[k + 3] or 0) + (q or 0)
end

-- one paid item: base = basePrice × distance, ok = true/false (delivery
-- quality) or nil (no quality, e.g. passengers)
function M.addIncome(ring, nowMs, key, base, ok)
	incAdd((bucketFor(ring, nowMs)), key, 1, base, ok == true and 1 or 0, ok ~= nil and 1 or 0)
end

-- the bucket for an event time that may lie behind the newest bucket (the
-- income collector flushes per-thread buffers up to a flush interval late):
-- the bucket holding tMs if it still exists, a new bucket when tMs is newer
-- than the head, else the head bucket (a few seconds misattributed instead
-- of resetting the ring). A closed (packed) bucket comes back decoded with
-- packed = true: the caller re-encodes it.
local function bucketAt(ring, tMs)
	local t0 = bucketStart(tMs)
	local cur = ring.head > 0 and ring.b[ring.head] or nil
	local curT0 = cur and t0Of(cur)
	if cur == nil or curT0 == nil or t0 >= curT0 then return bucketFor(ring, tMs) end
	for slot, b in pairs(ring.b) do
		if t0Of(b) == t0 then return decode(b), slot, type(b) == "string" end
	end
	return bucketFor(ring, curT0)   -- older than the ring: the head, no reset
end

-- n items of cargo `key` paid at tMs with Σ base, ok of them on time, q of
-- them with a known quality (buffered counts; see addIncome for single items)
function M.addIncomeCounts(ring, tMs, key, n, base, ok, q)
	local b, slot, packed = bucketAt(ring, tMs)
	incAdd(b, key, n, base, ok, q)
	if packed then ring.b[slot] = encode(b) end
end

-- income inside the window, weighted like the costs; `first` is the cost
-- history's first sample of the same vehicle -> { [key] = { n, base, ok, q } }
function M.windowIncome(ring, nowMs, windowMs, first)
	local out = {}
	if not ring or type(ring.b) ~= "table" then return out end
	for __, packed in pairs(ring.b) do
		local b = cached(packed)
		local weight = (type(b) == "table" and b.t0) and M.bucketWeight(b.t0, nowMs, windowMs, first) or 0
		if weight > 0 then
			for k, v in pairs(b) do
				if type(k) == "number" and type(v) == "number" then
					local key = math.floor(k / 4)
					local field = k - key * 4
					local o = out[key]
					if o == nil then
						o = { n = 0, base = 0, ok = 0, q = 0 }
						out[key] = o
					end
					if field == 0 then o.n = o.n + v * weight
					elseif field == 1 then o.base = o.base + v * weight
					elseif field == 2 then o.ok = o.ok + v * weight
					else o.q = o.q + v * weight end
				end
			end
		end
	end
	return out
end

-- Income queue -------------------------------------------------------------
-- The income collector (income.script.lua) aggregates one batch of paid items
-- into a Buffer, appends it as compact records to the tiny queue in its own
-- state and trims records older than a few seconds; the cost sampler reads
-- that state every sample and consumes the records it has not seen (by id)
-- into the rings of its own state. A per-batch write of a tiny state is
-- cheap; a per-batch write of the rings was not.
-- Buffer = { items, since = ms of the oldest item, batches,
--   byRing = { [ringKey] = { [bucketT0] = { [cargo] = { n, base, ok, q, t } } } } }
function M.newBuffer()
	return { items = 0, since = nil, batches = 0, byRing = {} }
end

function M.bufferAdd(buf, ringKey, key, tMs, base, ok)
	local perRing = buf.byRing[ringKey]
	if perRing == nil then
		perRing = {}
		buf.byRing[ringKey] = perRing
	end
	local t0 = bucketStart(tMs)
	local perBucket = perRing[t0]
	if perBucket == nil then
		perBucket = {}
		perRing[t0] = perBucket
	end
	local e = perBucket[key]
	if e == nil then
		e = { n = 0, base = 0, ok = 0, q = 0, t = tMs }
		perBucket[key] = e
	end
	e.n = e.n + 1
	e.base = e.base + (base or 0)
	if ok ~= nil then
		e.q = e.q + 1
		if ok == true then e.ok = e.ok + 1 end
	end
	buf.items = buf.items + 1
	if buf.since == nil or tMs < buf.since then buf.since = tMs end
end

-- appends the buffer's entries to the queue as records { rk, key, t, n, base,
-- ok, q } under ids "<tag>-<n>" (tag unique per Lua state), empties the
-- buffer; returns the number of records added
function M.queueAppend(queue, buf, tag, nowMs)
	if buf == nil or buf.items == 0 then return 0 end
	buf.seq = buf.seq or 0
	local added = 0
	for rk, perRing in pairs(buf.byRing) do
		for __, perBucket in pairs(perRing) do
			for key, e in pairs(perBucket) do
				buf.seq = buf.seq + 1
				queue[tag .. "-" .. buf.seq] = { rk = rk, key = key, t = e.t, n = e.n, base = e.base, ok = e.ok, q = e.q, at = nowMs }
				added = added + 1
			end
		end
	end
	buf.items, buf.since, buf.batches, buf.byRing = 0, nil, 0, {}
	return added
end

-- drops records appended more than maxAgeMs before nowMs
function M.queueTrim(queue, nowMs, maxAgeMs)
	for id, rec in pairs(queue) do
		if type(rec) ~= "table" or (rec.at or rec.t or 0) < nowMs - maxAgeMs then queue[id] = nil end
	end
end

M.SEEN_MS = 60000   -- how long consumed ids are remembered (> the collector's trim age)

-- moves every record not yet in `seen` into rings[rec.rk] (created when
-- missing); remembers the ids with their time and forgets ids older than
-- SEEN_MS; returns the number of records consumed
function M.queueConsume(queue, rings, seen, nowMs)
	local n = 0
	for id, rec in pairs(queue or {}) do
		if type(rec) == "table" and seen[id] == nil then
			local ring = rings[rec.rk]
			if ring == nil then
				ring = M.newRing(nowMs)
				rings[rec.rk] = ring
			end
			M.addIncomeCounts(ring, rec.t or nowMs, rec.key, rec.n, rec.base, rec.ok, rec.q)
			seen[id] = nowMs
			n = n + 1
		end
	end
	for id, t in pairs(seen) do
		if t < nowMs - M.SEEN_MS then seen[id] = nil end
	end
	return n
end

return M
