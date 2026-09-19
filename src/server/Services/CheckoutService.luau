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
	-- `spawn`/`wait` bisa diganti saat test: Lune tidak punya `task` sama sekali, jadi keduanya
	-- hanya disentuh di dalam owned() dan hanya kalau tidak disuntik.
	spawn: ((fn: () -> ()) -> ())?,
	wait: ((seconds: number) -> ())?,
}

local CheckoutService = {}
CheckoutService.__index = CheckoutService

export type CheckoutService = typeof(setmetatable(
	{} :: {
		_market: any,
		_max: number,
		_types: { [string]: any }, -- "Asset" -> Enum.MarketplaceProductType.AvatarAsset
		_spawn: ((fn: () -> ()) -> ())?,
		_wait: ((seconds: number) -> ())?,
		_owned: { [number]: { [string]: boolean } }, -- userId -> kunci item yang TERBUKTI dimiliki
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
		_spawn = d.spawn,
		_wait = d.wait,
		_owned = {},
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

-- Batas yang dijaga server sendiri: satu look tidak pernah sedekat ini pun ke batasnya, dan ini
-- yang menahan client meminta ratusan panggilan marketplace sekaligus.
CheckoutService.MAX_OWNED_ASSETS = 40
CheckoutService.MAX_OWNED_BUNDLES = 20
local OWNED_TIMEOUT = 10 -- detik; jauh di atas 876 ms yang terukur untuk 16 panggilan serentak

local function uniqueIds(raw: any, limit: number): { number }
	local out: { number } = {}
	if type(raw) ~= "table" then
		return out
	end
	local seen: { [number]: boolean } = {}
	for i = 1, math.min(#raw, limit) do
		local id = raw[i]
		if type(id) == "number" and id > 0 and id % 1 == 0 and id <= 2 ^ 53 and not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	return out
end

-- Kepemilikan item yang SEDANG dipakai, untuk panel "Owned / Unowned" sebelum Save to Roblox.
-- Diukur di Studio 19 Sep 2026: `PlayerOwnsAsset` ~515 ms per panggilan kalau berurutan (6 item =
-- 3,1 detik), tapi **16 panggilan SERENTAK selesai dalam 876 ms tanpa satu pun gagal** -> diambil
-- serentak. Jalur inventory client (`GetInventoryAsync`) sengaja TIDAK dipakai: ia minta izin per
-- sesi DAN hasilnya tidak lengkap (item yang jelas dimiliki dilaporkan tidak ada).
-- Yang TERBUKTI dimiliki di-cache per sesi (kepemilikan tidak hilang di tengah sesi); yang belum
-- sengaja TIDAK di-cache supaya item yang baru saja dibeli langsung terbaca benar.
-- Return dua peta { [id] = true/false }. Panggilan yang error dianggap "belum dimiliki" -- panel
-- boleh salah ke arah aman (item itu cuma tidak ikut tersimpan), tidak boleh salah ke arah
-- membuang item milik pemain diam-diam.
function CheckoutService.owned(
	self: CheckoutService,
	player: any,
	rawAssets: any,
	rawBundles: any
): ({ [number]: boolean }, { [number]: boolean })
	local assetIds = uniqueIds(rawAssets, CheckoutService.MAX_OWNED_ASSETS)
	local bundleIds = uniqueIds(rawBundles, CheckoutService.MAX_OWNED_BUNDLES)
	local assets: { [number]: boolean } = {}
	local bundles: { [number]: boolean } = {}

	local userId = if type(player) == "table" or typeof(player) == "Instance" then player.UserId else 0
	local cache = self._owned[userId]
	if cache == nil then
		cache = {}
		self._owned[userId] = cache
	end

	local pending = 0
	local function ask(id: number, isBundle: boolean)
		local key = (if isBundle then "b" else "a") .. tostring(id)
		if cache[key] then
			if isBundle then
				bundles[id] = true
			else
				assets[id] = true
			end
			return
		end
		pending += 1
		local run = function()
			local ok, result = pcall(function()
				if isBundle then
					return self._market:PlayerOwnsBundle(player, id)
				end
				return self._market:PlayerOwnsAsset(player, id)
			end)
			local has = ok and result == true
			if not ok then
				log.warn("cek kepemilikan gagal", id, result)
			end
			if has then
				cache[key] = true
			end
			if isBundle then
				bundles[id] = has
			else
				assets[id] = has
			end
			pending -= 1
		end
		local spawn = self._spawn or task.spawn
		spawn(run)
	end

	for _, id in assetIds do
		ask(id, false)
	end
	for _, id in bundleIds do
		ask(id, true)
	end

	local waitFor = self._wait or task.wait
	local waited = 0
	while pending > 0 and waited < OWNED_TIMEOUT do
		waitFor(0.05)
		waited += 0.05
	end
	if pending > 0 then
		log.warn("cek kepemilikan tidak selesai", pending, "sisa")
	end
	return assets, bundles
end

-- Pemain keluar -> cache kepemilikannya dibuang (dipanggil dari init.server, sejalan dengan
-- limiter:reset dan wardrobe:forget).
function CheckoutService.forget(self: CheckoutService, player: any)
	local userId = if type(player) == "table" or typeof(player) == "Instance" then player.UserId else 0
	self._owned[userId] = nil
end

return CheckoutService
