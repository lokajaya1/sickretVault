--!strict
-- Cache LRU + TTL (tanpa yield). Dipakai untuk hasil katalog & detail item.
--   local c = Cache.new({ ttl = 600, maxSize = 5000 })
--   c:set(key, value)   c:get(key) -> value?   c:delete(key)   c:clear()   c:size()
-- `clock` bisa diganti saat test (default os.clock).

export type Options = {
	ttl: number?, -- detik; nil = tidak kedaluwarsa
	maxSize: number?, -- nil = tanpa batas
	clock: (() -> number)?,
}

type Node = { key: any, value: any, expires: number, prev: Node?, next: Node? }

local Cache = {}
Cache.__index = Cache

export type Cache = typeof(setmetatable(
	{} :: {
		_ttl: number?,
		_max: number?,
		_clock: () -> number,
		_map: { [any]: Node },
		_count: number,
		_head: Node?, -- paling baru dipakai
		_tail: Node?, -- paling lama dipakai
	},
	Cache
))

function Cache.new(opts: Options?): Cache
	local o = opts or {}
	return setmetatable({
		_ttl = o.ttl,
		_max = o.maxSize,
		_clock = o.clock or os.clock,
		_map = {},
		_count = 0,
		_head = nil,
		_tail = nil,
	}, Cache)
end

local function unlink(self: Cache, n: Node)
	if n.prev then
		n.prev.next = n.next
	else
		self._head = n.next
	end
	if n.next then
		n.next.prev = n.prev
	else
		self._tail = n.prev
	end
	n.prev, n.next = nil, nil
end

local function pushFront(self: Cache, n: Node)
	n.next = self._head
	n.prev = nil
	if self._head then
		self._head.prev = n
	end
	self._head = n
	if self._tail == nil then
		self._tail = n
	end
end

function Cache.delete(self: Cache, key: any)
	local n = self._map[key]
	if n then
		unlink(self, n)
		self._map[key] = nil
		self._count -= 1
	end
end

function Cache.get(self: Cache, key: any): any
	local n = self._map[key]
	if n == nil then
		return nil
	end
	if n.expires <= self._clock() then
		self:delete(key)
		return nil
	end
	unlink(self, n)
	pushFront(self, n)
	return n.value
end

function Cache.set(self: Cache, key: any, value: any, ttl: number?)
	assert(key ~= nil, "key cache tidak boleh nil")
	if value == nil then
		self:delete(key)
		return
	end
	local life = ttl or self._ttl
	local expires = if life then self._clock() + life else math.huge
	local n = self._map[key]
	if n then
		n.value = value
		n.expires = expires
		unlink(self, n)
		pushFront(self, n)
		return
	end
	n = { key = key, value = value, expires = expires }
	self._map[key] = n
	self._count += 1
	pushFront(self, n :: Node)
	local max = self._max
	while max and self._count > max and self._tail do
		self:delete((self._tail :: Node).key)
	end
end

function Cache.size(self: Cache): number
	return self._count
end

function Cache.clear(self: Cache)
	self._map = {}
	self._count = 0
	self._head = nil
	self._tail = nil
end

return Cache
