--!strict
-- Test Util murni: Cache, Retry, RateLimiter, Log.
-- Studio: require(game.ReplicatedStorage.Tests["Util.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Cache = require(Shared.Util.Cache)
local Retry = require(Shared.Util.Retry)
local RateLimiter = require(Shared.Util.RateLimiter)
local Log = require(Shared.Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	-- jam palsu yang bisa dimajukan
	local now = 0
	local function clock(): number
		return now
	end

	-- 1. Cache: TTL
	local c = Cache.new({ ttl = 10, clock = clock })
	c:set("a", 1)
	eq(c:get("a"), 1, "cache hit")
	now = 9.9
	eq(c:get("a"), 1, "belum kedaluwarsa")
	now = 10
	eq(c:get("a"), nil, "kedaluwarsa")
	eq(c:size(), 0, "entri kedaluwarsa dihapus")
	c:set("b", 2, 100) -- ttl khusus
	now = 50
	eq(c:get("b"), 2, "ttl khusus")

	-- 2. Cache: LRU (maxSize 2) -> yang paling lama tak dipakai dibuang
	now = 0
	local lru = Cache.new({ maxSize = 2, clock = clock })
	lru:set("x", 1)
	lru:set("y", 2)
	lru:get("x") -- x jadi paling baru
	lru:set("z", 3) -- y dibuang
	eq(lru:get("y"), nil, "y dibuang")
	eq(lru:get("x"), 1, "x tetap")
	eq(lru:get("z"), 3, "z ada")
	eq(lru:size(), 2, "ukuran maks 2")
	lru:set("x", nil) -- set nil = hapus
	eq(lru:size(), 1, "set nil menghapus")
	lru:clear()
	eq(lru:size(), 0, "clear")

	-- 3. Retry: gagal 2x lalu berhasil, jeda 1 lalu 2
	local calls, slept = 0, {}
	local ok, value = Retry.run(function(x: number)
		calls += 1
		if calls < 3 then
			error("throttled")
		end
		return x * 2
	end, {
		attempts = 3,
		sleep = function(t: number)
			table.insert(slept, t)
		end,
	}, 21)
	eq(ok, true, "retry akhirnya berhasil")
	eq(value, 42, "hasil & argumen diteruskan")
	eq(calls, 3, "3 percobaan")
	eq(#slept, 2, "2 jeda")
	eq(slept[1], 1, "jeda 1")
	eq(slept[2], 2, "jeda 2 (eksponensial)")
	eq(Retry.delayFor(10, 1, 8), 8, "jeda dibatasi maxDelay")

	-- 4. Retry: shouldRetry=false -> berhenti langsung
	calls = 0
	local ok2, err2 = Retry.run(function()
		calls += 1
		error("invalid id")
	end, {
		sleep = function() end,
		shouldRetry = function(e: any)
			return not string.find(tostring(e), "invalid")
		end,
	})
	eq(ok2, false, "gagal")
	eq(calls, 1, "tidak diulang")
	assert(string.find(tostring(err2), "invalid id"), "pesan error diteruskan")

	-- 5. RateLimiter: token bucket
	now = 0
	local rl = RateLimiter.new({ capacity = 3, refillPerSec = 1, clock = clock })
	eq(rl:take(1), true, "token 1")
	eq(rl:take(1), true, "token 2")
	eq(rl:take(1), true, "token 3")
	eq(rl:take(1), false, "spam ditolak")
	eq(rl:take(2), true, "pemain lain tidak terpengaruh")
	now = 1
	eq(rl:take(1), true, "isi ulang 1 token/detik")
	eq(rl:take(1), false, "habis lagi")
	now = 100
	eq(rl:peek(1), 3, "tidak melebihi kapasitas")
	eq(rl:take(1, 5), false, "cost > kapasitas ditolak")
	rl:reset(1)
	eq(rl:peek(1), 3, "reset -> penuh")
	local fromLimits = RateLimiter.fromLimits("AvatarIntent", clock)
	eq(fromLimits:peek("p"), 20, "preset dari Limits.Rate")
	eq(RateLimiter.fromLimits("TidakAda", clock):peek("p"), 3, "preset ketat untuk nama tak dikenal")

	-- 6. Log: level & format
	local lines = {}
	Log.setSink(function(level: string, text: string)
		table.insert(lines, level .. "|" .. text)
	end)
	Log.setLevel("info")
	local log = Log.new("Test")
	log.debug("tidak tampil")
	log.info("halo", 1, nil)
	log.warn("awas")
	Log.setSink(nil)
	eq(#lines, 2, "debug disaring")
	eq(lines[1], "info|[INFO][Test] halo 1 nil", "format info")
	eq(lines[2], "warn|[WARN][Test] awas", "format warn")

	print("PASS Util.spec")
end
