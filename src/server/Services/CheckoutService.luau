--!strict
-- Checkout keranjang (server): validasi daftar -> MarketplaceService:PromptBulkPurchase.
--   local checkout = CheckoutService.new({ onResult = function(player, summary) ... end })
--   local ok, err = checkout:prompt(player, { { id = 1, itemType = "Asset" }, ... })  -- err = { code }
--   checkout:release(player)  -- saat pemain keluar
-- Docs (Creator Hub, 17 Sep 2026): PromptBulkPurchase HANYA dari server, maks 20 item, `options` belum dipakai.
-- PromptBulkPurchaseFinished(player, status, results) dengan
--   results = { RobuxSpent = number, Items = { { type, id = "<string>", status = MarketplaceItemPurchaseStatus } } }
-- Event itu "not a trusted event from the client" -> hasil hanya untuk UI (bersihkan cart, toast), BUKAN bukti kepemilikan.
-- Tidak memakai Retry: prompt pembelian tidak boleh diulang otomatis.
-- `marketplace` & `toEnum` bisa diganti saat test.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Cart = require(Shared.Domain.Cart)
local Log = require(Shared.Util.Log)

local log = Log.new("CheckoutService")

-- Prompt dianggap macet bila event Finished tidak datang selama ini (detik) -> boleh prompt lagi.
local PENDING_TIMEOUT = 300

export type LineRef = { id: number, itemType: string }
export type Failed = { id: number, itemType: string, reason: string }
export type Summary = {
	status: string, -- "Completed" | "Aborted" | "Error"
	robuxSpent: number,
	purchased: { LineRef }, -- Success
	owned: { LineRef }, -- AlreadyOwned (boleh dibuang dari cart juga)
	failed: { Failed }, -- status lain
}

export type Deps = {
	marketplace: any?, -- MarketplaceService
	toEnum: ((enumName: string, itemName: string) -> any)?,
	clock: (() -> number)?,
	maxItems: number?, -- default Cart.DEFAULT_MAX (20, batas docs)
	onResult: ((player: any, summary: Summary) -> ())?,
}

local CheckoutService = {}
CheckoutService.__index = CheckoutService

export type CheckoutService = typeof(setmetatable(
	{} :: {
		_market: any,
		_clock: () -> number,
		_max: number,
		_types: { [string]: any }, -- "Asset" -> Enum.MarketplaceProductType.AvatarAsset
		_pending: { [any]: number }, -- player -> waktu prompt
		_onResult: ((player: any, summary: Summary) -> ())?,
		_conn: any,
	},
	CheckoutService
))

local function defaultToEnum(enumName: string, itemName: string): any
	local ok, item = pcall(function()
		return (Enum :: any)[enumName][itemName]
	end)
	return if ok then item else nil
end

local function enumName(v: any): string
	if type(v) == "string" then
		return v
	end
	local ok, name = pcall(function()
		return v.Name
	end)
	return if ok and type(name) == "string" then name else tostring(v)
end

local function fail(code: string): (boolean, any)
	return false, { code = code }
end

function CheckoutService.new(deps: Deps?): CheckoutService
	local d = deps or {}
	local toEnum = d.toEnum or defaultToEnum
	local types: { [string]: any } = {
		Asset = toEnum("MarketplaceProductType", "AvatarAsset"),
		Bundle = toEnum("MarketplaceProductType", "AvatarBundle"),
	}
	assert(types.Asset ~= nil and types.Bundle ~= nil, "Enum.MarketplaceProductType.AvatarAsset/AvatarBundle tidak ada")
	local max = if type(d.maxItems) == "number" and d.maxItems >= 1 then math.floor(d.maxItems) else Cart.DEFAULT_MAX
	local self = setmetatable({
		_market = d.marketplace or game:GetService("MarketplaceService"),
		_clock = d.clock or os.clock,
		_max = max,
		_types = types,
		_pending = {},
		_onResult = d.onResult,
		_conn = nil,
	}, CheckoutService)
	self._conn = self._market.PromptBulkPurchaseFinished:Connect(function(player, status, results)
		self:_finish(player, status, results)
	end)
	return self
end

-- Validasi payload client -> daftar LineRef unik. nil + kode bila ditolak.
function CheckoutService.parse(self: CheckoutService, raw: any): ({ LineRef }?, string?)
	if type(raw) ~= "table" then
		return nil, "BAD_ARG"
	end
	local n = #raw
	if n == 0 then
		return nil, "EMPTY"
	end
	if n > self._max then
		return nil, "TOO_MANY"
	end
	local out: { LineRef } = {}
	local seen: { [string]: boolean } = {}
	for i = 1, n do
		local e = raw[i]
		-- pakai sanitize Cart (harga dummy: server tidak memercayai harga dari client)
		local item = Cart.sanitize(if type(e) == "table" then { id = e.id, itemType = e.itemType, price = 0 } else nil)
		if not item then
			return nil, "BAD_ARG"
		end
		local k = Cart.key(item.id, item.itemType)
		if not seen[k] then
			seen[k] = true
			table.insert(out, { id = item.id, itemType = item.itemType })
		end
	end
	return out, nil
end

function CheckoutService.isBusy(self: CheckoutService, player: any): boolean
	local at = self._pending[player]
	if at == nil then
		return false
	end
	if self._clock() - at > PENDING_TIMEOUT then
		self._pending[player] = nil
		return false
	end
	return true
end

-- Return true | (false, { code = "BAD_ARG" | "EMPTY" | "TOO_MANY" | "BUSY" | "FAILED" }).
function CheckoutService.prompt(self: CheckoutService, player: any, raw: any): (boolean, any)
	local refs, code = self:parse(raw)
	if not refs then
		return fail(code or "BAD_ARG")
	end
	if self:isBusy(player) then
		return fail("BUSY")
	end
	local lineItems = table.create(#refs)
	for _, r in refs do
		table.insert(lineItems, { Type = self._types[r.itemType], Id = tostring(r.id) })
	end
	self._pending[player] = self._clock()
	local ok, err = pcall(function()
		self._market:PromptBulkPurchase(player, lineItems, {})
	end)
	if not ok then
		self._pending[player] = nil
		log.warn("PromptBulkPurchase gagal", err)
		return fail("FAILED")
	end
	log.info("prompt", #lineItems, "item")
	return true, nil
end

local function toRef(self: CheckoutService, line: any): LineRef?
	if type(line) ~= "table" then
		return nil
	end
	local id = tonumber(line.id)
	if id == nil or id <= 0 or id % 1 ~= 0 then
		return nil
	end
	local itemType = if line.type == self._types.Asset
		then "Asset"
		elseif line.type == self._types.Bundle then "Bundle"
		else nil
	if itemType == nil then
		return nil
	end
	return { id = id, itemType = itemType }
end

-- Ringkas `results` mentah menjadi Summary (murni, publik untuk test).
function CheckoutService.summarize(self: CheckoutService, status: any, results: any): Summary
	local summary: Summary = {
		status = enumName(status),
		robuxSpent = 0,
		purchased = {},
		owned = {},
		failed = {},
	}
	if type(results) ~= "table" then
		return summary
	end
	local spent = results.RobuxSpent
	if type(spent) == "number" and spent == spent and spent >= 0 then
		summary.robuxSpent = spent
	end
	if type(results.Items) ~= "table" then
		return summary
	end
	for _, line in results.Items do
		local ref = toRef(self, line)
		if ref then
			local s = enumName(line.status)
			if s == "Success" then
				table.insert(summary.purchased, ref)
			elseif s == "AlreadyOwned" then
				table.insert(summary.owned, ref)
			else
				table.insert(summary.failed, { id = ref.id, itemType = ref.itemType, reason = s })
			end
		end
	end
	return summary
end

function CheckoutService._finish(self: CheckoutService, player: any, status: any, results: any)
	if self._pending[player] == nil then
		-- prompt bukan dari service ini (atau sudah timeout) -> abaikan
		return
	end
	self._pending[player] = nil
	local summary = self:summarize(status, results)
	log.info("selesai", summary.status, #summary.purchased, #summary.owned, #summary.failed, summary.robuxSpent)
	if self._onResult then
		local ok, err = pcall(self._onResult, player, summary)
		if not ok then
			log.error("onResult error", err)
		end
	end
end

function CheckoutService.release(self: CheckoutService, player: any)
	self._pending[player] = nil
end

function CheckoutService.destroy(self: CheckoutService)
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
	table.clear(self._pending)
end

return CheckoutService
