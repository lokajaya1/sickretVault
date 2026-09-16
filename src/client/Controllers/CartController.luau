--!strict
-- Keranjang belanja di client (Domain Cart) + checkout lewat server.
--   local cart = CartController.new()
--   cart:start()                               -- dengarkan CheckoutResult
--   cart:onChanged(function(snap) ... end)     -- snap = { items, count, total, isFull, checkingOut }
--   cart:onResult(function(summary) ... end)   -- hasil PromptBulkPurchase (untuk toast)
--   local ok, reason = cart:toggle(item)       -- tombol 🛒 di kartu/detail/strip
--   local ok, code = cart:checkout()           -- YIELD (InvokeServer) -> panggil dari task.spawn
-- Isi keranjang hanya di memori (hilang saat rejoin). Item yang terbeli / sudah dimiliki dibuang otomatis.
-- `deps` bisa diganti saat test (tanpa remote).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cart = require(Shared.Domain.Cart)
local Log = require(Shared.Util.Log)

local log = Log.new("CartController")

-- Sama dengan server: bila CheckoutResult tidak datang selama ini, izinkan checkout lagi.
local CHECKOUT_TIMEOUT = 300

export type Snapshot = {
	items: { Cart.Item },
	count: number,
	total: number,
	max: number,
	isFull: boolean,
	checkingOut: boolean, -- prompt pembelian sedang terbuka / menunggu server
}

export type Deps = {
	invoke: ((request: any) -> any)?, -- Checkout:InvokeServer
	onResult: ((fn: (summary: any) -> ()) -> any)?, -- CheckoutResult.OnClientEvent:Connect
	clock: (() -> number)?,
	max: number?,
}

local CartController = {}
CartController.__index = CartController

export type CartController = typeof(setmetatable(
	{} :: {
		_deps: Deps,
		_clock: () -> number,
		_cart: Cart.Cart,
		_checkoutAt: number?,
		_listeners: { (Snapshot) -> () },
		_resultListeners: { (any) -> () },
		_conns: { any },
		_started: boolean,
	},
	CartController
))

local function remotes()
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes, RemoteNames
end

local function defaultDeps(): Deps
	return {
		invoke = function(request)
			local Remotes, Names = remotes()
			return Remotes.func(Names.Functions.Checkout):InvokeServer(request)
		end,
		onResult = function(fn)
			local Remotes, Names = remotes()
			return Remotes.event(Names.Events.CheckoutResult).OnClientEvent:Connect(fn)
		end,
	}
end

function CartController.new(deps: Deps?): CartController
	local d = defaultDeps()
	for k, v in (deps or {}) :: any do
		(d :: any)[k] = v
	end
	return setmetatable({
		_deps = d,
		_clock = d.clock or os.clock,
		_cart = Cart.new(d.max),
		_checkoutAt = nil,
		_listeners = {},
		_resultListeners = {},
		_conns = {},
		_started = false,
	}, CartController)
end

local function emit(list: { any }, value: any)
	for _, fn in table.clone(list) do
		local ok, err = pcall(fn, value)
		if not ok then
			log.warn("listener error", err)
		end
	end
end

local function subscribe(list: { any }, fn: any): () -> ()
	table.insert(list, fn)
	return function()
		local i = table.find(list, fn)
		if i then
			table.remove(list, i)
		end
	end
end

function CartController.isCheckingOut(self: CartController): boolean
	local at = self._checkoutAt
	if at == nil then
		return false
	end
	if self._clock() - at > CHECKOUT_TIMEOUT then
		self._checkoutAt = nil
		return false
	end
	return true
end

function CartController.getSnapshot(self: CartController): Snapshot
	local c = self._cart
	return {
		items = Cart.list(c),
		count = Cart.count(c),
		total = Cart.total(c),
		max = c.max,
		isFull = Cart.isFull(c),
		checkingOut = self:isCheckingOut(),
	}
end

function CartController._emit(self: CartController)
	emit(self._listeners, self:getSnapshot())
end

-- Listener dipanggil setiap isi/status berubah. Return fungsi untuk berhenti.
function CartController.onChanged(self: CartController, fn: (Snapshot) -> ()): () -> ()
	return subscribe(self._listeners, fn)
end

-- Listener hasil checkout: summary = { status, robuxSpent, purchased, owned, failed }.
function CartController.onResult(self: CartController, fn: (any) -> ()): () -> ()
	return subscribe(self._resultListeners, fn)
end

function CartController.has(self: CartController, id: number, itemType: string): boolean
	return Cart.has(self._cart, id, itemType)
end

function CartController.count(self: CartController): number
	return Cart.count(self._cart)
end

-- item = { id, itemType, name, price, ... }. Return (true) | (false, "invalid"|"notForSale"|"duplicate"|"full").
function CartController.add(self: CartController, item: any): (boolean, string?)
	local ok, reason = Cart.add(self._cart, item)
	if ok then
		self:_emit()
	end
	return ok, reason
end

function CartController.remove(self: CartController, id: number, itemType: string): boolean
	local ok = Cart.remove(self._cart, id, itemType)
	if ok then
		self:_emit()
	end
	return ok
end

-- Tombol 🛒: sudah ada -> buang; belum -> tambah. Return (true = sekarang di cart | false = dibuang, alasan gagal?).
function CartController.toggle(self: CartController, item: any): (boolean, string?)
	if type(item) == "table" and Cart.has(self._cart, item.id, item.itemType) then
		self:remove(item.id, item.itemType)
		return false, nil
	end
	local ok, reason = self:add(item)
	return ok, reason
end

function CartController.clear(self: CartController)
	if Cart.count(self._cart) == 0 then
		return
	end
	Cart.clear(self._cart)
	self:_emit()
end

-- YIELD. Return (true) = prompt tampil | (false, code) dengan code
-- "EMPTY" | "BUSY" | "NETWORK" | kode server ("RATE_LIMITED", "TOO_MANY", "BAD_ARG", "FAILED").
function CartController.checkout(self: CartController): (boolean, string?)
	if Cart.count(self._cart) == 0 then
		return false, "EMPTY"
	end
	if self:isCheckingOut() then
		return false, "BUSY"
	end
	self._checkoutAt = self._clock()
	self:_emit()

	local ok, res = pcall(self._deps.invoke :: any, Cart.toRequest(self._cart))
	local code: string? = nil
	if not ok or type(res) ~= "table" then
		log.warn("Checkout invoke gagal", res)
		code = "NETWORK"
	elseif not res.ok then
		code = if type(res.code) == "string" then res.code else "FAILED"
	end
	if code then
		-- BUSY dari server = prompt lama masih terbuka -> tetap tandai sedang checkout
		if code ~= "BUSY" then
			self._checkoutAt = nil
		end
		self:_emit()
		return false, code
	end
	return true, nil
end

local function eachRef(list: any, fn: (id: number, itemType: string) -> ())
	if type(list) ~= "table" then
		return
	end
	for _, r in list do
		if type(r) == "table" and type(r.id) == "number" and type(r.itemType) == "string" then
			fn(r.id, r.itemType)
		end
	end
end

function CartController._handleResult(self: CartController, summary: any)
	if type(summary) ~= "table" then
		return
	end
	self._checkoutAt = nil
	local c = self._cart
	eachRef(summary.purchased, function(id, itemType)
		Cart.remove(c, id, itemType)
	end)
	eachRef(summary.owned, function(id, itemType)
		Cart.remove(c, id, itemType)
	end)
	log.info("hasil checkout", summary.status, summary.robuxSpent)
	self:_emit()
	emit(self._resultListeners, summary)
end

-- Mulai mendengarkan CheckoutResult. Aman dipanggil dua kali.
function CartController.start(self: CartController)
	if self._started then
		return
	end
	self._started = true
	table.insert(
		self._conns,
		(self._deps.onResult :: any)(function(summary)
			self:_handleResult(summary)
		end)
	)
end

function CartController.stop(self: CartController)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self._started = false
end

return CartController
