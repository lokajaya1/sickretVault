--!strict
-- Detail item di dalam satu outfit tersimpan (untuk halaman detail Saved Outfits).
--   local items = OutfitItemsService.new({ api = api })
--   local ok, res = items:list(state, makeupRows)  -- YIELD (GetBatchItemDetailsAsync lewat gateway)
--   res = { items = { { id, name, price, assetType, creator, isForSale } }, total = 123, missing = 1 }
-- Urutan: aksesori (urut dipakai) -> classic -> body part -> animasi -> makeup, supaya tampilan
-- stabil. Makeup ada di luar OutfitState, jadi barisnya ({ assetId, slot }) dikirim terpisah.
-- Harga mengikuti aturan katalog: Price, kalau nil pakai LowestPrice; keduanya nil = tidak dijual.
-- `total` hanya menjumlahkan item yang ada harganya (item tidak dijual tidak dihitung).
-- Tidak memanggil API Roblox langsung (lewat `api`); `toEnum` bisa diganti saat test.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Types = require(Shared.Domain.Types)
local Log = require(Shared.Util.Log)
local ItemDetail = require(Shared.Domain.ItemDetail)

local log = Log.new("OutfitItemsService")

type State = Types.OutfitState

export type Item = {
	id: number,
	name: string,
	assetType: string?,
	creator: string?, -- nama pembuat (CreatorName); nil = tidak diketahui
	price: number?, -- nil = tidak dijual / tidak diketahui
	resalePrice: number?, -- harga pasar item limited (hanya bila ada penjual ulang)
	limited: boolean?,
	offSale: boolean?,
	priceStatus: string?,
	isForSale: boolean,
}

export type Result = {
	items: { Item },
	total: number, -- jumlah harga item yang dijual
	missing: number, -- id yang tidak dikembalikan API (dilewati)
}

export type Deps = {
	api: any, -- RobloxApi (getBatchItemDetails)
	toEnum: ((enumName: string, itemName: string) -> any)?,
}

local OutfitItemsService = {}
OutfitItemsService.__index = OutfitItemsService

export type OutfitItemsService = typeof(setmetatable(
	{} :: {
		_api: any,
		_assetItemType: any,
	},
	OutfitItemsService
))

local function defaultToEnum(enumName: string, itemName: string): any
	local ok, item = pcall(function()
		return (Enum :: any)[enumName][itemName]
	end)
	return if ok then item else nil
end

function OutfitItemsService.new(deps: Deps): OutfitItemsService
	assert(deps and deps.api, "OutfitItemsService butuh deps.api")
	local toEnum = deps.toEnum or defaultToEnum
	return setmetatable({
		_api = deps.api,
		_assetItemType = toEnum("AvatarItemType", "Asset"),
	}, OutfitItemsService)
end

-- Kumpulkan assetId dari LOOK dengan urutan stabil (tanpa duplikat).
-- `makeupRows` = hasil PlayerData.makeupOf / MakeupService (urut face -> eye -> lip).
function OutfitItemsService.idsOf(state: State, makeupRows: any?): { number }
	local out: { number } = {}
	local seen: { [number]: boolean } = {}
	local function add(id: any)
		if type(id) == "number" and id > 0 and id % 1 == 0 and not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end

	local accessories = {}
	for _, a in state.accessories do
		table.insert(accessories, a)
	end
	table.sort(accessories, function(x, y)
		if (x.seq or 0) ~= (y.seq or 0) then
			return (x.seq or 0) < (y.seq or 0)
		end
		return x.assetId < y.assetId
	end)
	for _, a in accessories do
		add(a.assetId)
	end

	for _, group in { state.classic, state.bodyParts, state.animations } do
		local slots = {}
		for slot in group do
			table.insert(slots, slot)
		end
		table.sort(slots)
		for _, slot in slots do
			add(group[slot].id)
		end
	end

	if type(makeupRows) == "table" then
		for _, row in makeupRows :: any do
			if type(row) == "table" then
				add(row.assetId)
			end
		end
	end
	return out
end

local function toItem(id: number, raw: any): Item?
	if type(raw) ~= "table" then
		return nil
	end
	-- Aturan harga dipinjam dari ItemDetail (satu sumber): sentinel 999999999 dibuang, harga
	-- pasar limited dikenali, off-sale ditandai. `resalePrice` hanya diteruskan bila Roblox
	-- bilang ada penjual ulang -- sama dengan kartu katalog.
	local price, resale, limited, offSale, hasResellers = ItemDetail.priceFields(raw)
	local creator = if type(raw.CreatorName) == "string" and raw.CreatorName ~= "" then raw.CreatorName else nil
	return {
		id = id,
		name = if type(raw.Name) == "string" and raw.Name ~= "" then raw.Name else "Item " .. tostring(id),
		assetType = if type(raw.AssetType) == "string" then raw.AssetType else nil,
		creator = creator,
		price = price,
		resalePrice = if hasResellers and resale ~= nil and resale > 0 then resale else nil,
		limited = if limited then true else nil,
		offSale = if offSale then true else nil,
		priceStatus = if type(raw.PriceStatus) == "string" then raw.PriceStatus else nil,
		isForSale = price ~= nil,
	}
end

-- YIELD. Return (true, Result) | (false, { code = "BAD_ARG" | "FAILED" }).
function OutfitItemsService.list(self: OutfitItemsService, state: State, makeupRows: any?): (boolean, any)
	if type(state) ~= "table" or type(state.accessories) ~= "table" then
		return false, { code = "BAD_ARG" }
	end
	local ids = OutfitItemsService.idsOf(state, makeupRows)
	if #ids == 0 then
		return true, { items = {}, total = 0, missing = 0 }
	end
	local ok, details = self._api:getBatchItemDetails(ids, self._assetItemType)
	if not ok then
		log.debug("detail item gagal", details and details.code)
		return false, { code = "FAILED" }
	end

	local items: { Item } = {}
	local total, missing = 0, 0
	for _, id in ids do
		local item = toItem(id, details[id])
		if item == nil then
			missing += 1
		else
			table.insert(items, item)
			total += item.price or 0
		end
	end
	return true, { items = items, total = total, missing = missing }
end

return OutfitItemsService
