--!strict
-- Checkout keranjang (server): validasi daftar -> MarketplaceService:PromptBulkPurchase.
--   local checkout = CheckoutService.new()
--   local ok, err = checkout:prompt(player, { { id = 1, itemType = "Asset" }, ... })  -- err = { code }
-- Docs (Creator Hub, 17 Sep 2026): PromptBulkPurchase HANYA dari server, maks 20 item, `options` belum dipakai.
-- Uji Studio (17 Sep 2026): PromptBulkPurchaseFinished "can only be subscribed to from a local script"
--   -> hasil pembelian didengarkan di CLIENT (CartController), bukan di sini.
-- Anti-spam cukup lewat Limits.Rate.Checkout di init.server.
-- Tidak memakai Retry: prompt pembelian tidak boleh diulang otomatis.
-- `marketplace` & `toEnum` bisa diganti saat test.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Cart = require(Shared.Domain.Cart)
local Log = require(Shared.Util.Log)

local log = Log.new("CheckoutService")

export type LineRef = { id: number, itemType: string }

export type Deps = {
	marketplace: any?, -- MarketplaceService
	toEnum: ((enumName: string, itemName: string) -> any)?,
	maxItems: number?, -- default Cart.DEFAULT_MAX (20, batas docs)
}

local CheckoutService = {}
CheckoutService.__index = CheckoutService

export type CheckoutService = typeof(setmetatable(
	{} :: {
		_market: any,
		_max: number,
		_types: { [string]: any }, -- "Asset" -> Enum.MarketplaceProductType.AvatarAsset
	},
	CheckoutService
))

local function defaultToEnum(enumName: string, itemName: string): any
	local ok, item = pcall(function()
		return (Enum :: any)[enumName][itemName]
	end)
	return if ok then item else nil
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
	return setmetatable({
		_market = d.marketplace or game:GetService("MarketplaceService"),
		_max = max,
		_types = types,
	}, CheckoutService)
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

-- Return true | (false, { code = "BAD_ARG" | "EMPTY" | "TOO_MANY" | "FAILED" }).
function CheckoutService.prompt(self: CheckoutService, player: any, raw: any): (boolean, any)
	local refs, code = self:parse(raw)
	if not refs then
		return fail(code or "BAD_ARG")
	end
	local lineItems = {}
	for _, r in refs do
		table.insert(lineItems, { Type = self._types[r.itemType], Id = tostring(r.id) })
	end
	local ok, err = pcall(function()
		self._market:PromptBulkPurchase(player, lineItems, {})
	end)
	if not ok then
		log.warn("PromptBulkPurchase gagal", err)
		return fail("FAILED")
	end
	log.info("prompt", #lineItems, "item")
	return true, nil
end

return CheckoutService
