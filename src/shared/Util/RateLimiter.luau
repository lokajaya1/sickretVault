--!strict
-- Token bucket per kunci (biasanya player.UserId).
--   local rl = RateLimiter.new({ capacity = 20, refillPerSec = 8 })
--   if not rl:take(player.UserId) then return end   -- ditolak (spam)
--   Players.PlayerRemoving -> rl:reset(player.UserId)
-- Atau pakai preset dari Limits.Rate: RateLimiter.fromLimits("AvatarIntent")

local Limits = require(script.Parent.Parent.Config.Limits)

export type Options = {
	capacity: number,
	refillPerSec: number,
	clock: (() -> number)?,
}

type Bucket = { tokens: number, at: number }

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: {
		_capacity: number,
		_refill: number,
		_clock: () -> number,
		_buckets: { [any]: Bucket },
	},
	RateLimiter
))

function RateLimiter.new(opts: Options): RateLimiter
	assert(opts.capacity > 0 and opts.refillPerSec >= 0, "opsi RateLimiter tidak valid")
	return setmetatable({
		_capacity = opts.capacity,
		_refill = opts.refillPerSec,
		_clock = opts.clock or os.clock,
		_buckets = {},
	}, RateLimiter)
end

-- Buat limiter dari Limits.Rate[name]; nama tak dikenal -> preset ketat.
function RateLimiter.fromLimits(name: string, clock: (() -> number)?): RateLimiter
	local preset = (Limits.Rate :: any)[name] or { capacity = 3, refillPerSec = 0.5 }
	return RateLimiter.new({ capacity = preset.capacity, refillPerSec = preset.refillPerSec, clock = clock })
end

local function refill(self: RateLimiter, key: any): Bucket
	local now = self._clock()
	local b = self._buckets[key]
	if b == nil then
		b = { tokens = self._capacity, at = now }
		self._buckets[key] = b
		return b
	end
	local elapsed = math.max(0, now - b.at)
	b.tokens = math.min(self._capacity, b.tokens + elapsed * self._refill)
	b.at = now
	return b
end

-- true = boleh (token dikurangi), false = ditolak.
function RateLimiter.take(self: RateLimiter, key: any, cost: number?): boolean
	local c = cost or 1
	local b = refill(self, key)
	if b.tokens >= c then
		b.tokens -= c
		return true
	end
	return false
end

function RateLimiter.peek(self: RateLimiter, key: any): number
	return refill(self, key).tokens
end

function RateLimiter.reset(self: RateLimiter, key: any)
	self._buckets[key] = nil
end

return RateLimiter
