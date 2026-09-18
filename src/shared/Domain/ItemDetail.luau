--!strict
-- DOMAIN MURNI: ubah respons mentah GetItemDetailsAsync (aset ATAU bundle) menjadi Detail untuk panel detail.
--   local detail = ItemDetail.fromRaw(raw, "Asset")   -- nil jika respons tidak dikenali
--   detail.parts = bundleInfo.parts                    -- (server) bundle: daftar part untuk "Linked Items"
-- Hanya field yang aman & berguna untuk client. Teks dipotong supaya paket remote tetap kecil.

local Map = require(script.Parent.AssetTypeMap)
local Types = require(script.Parent.Types)

export type Detail = {
	id: number,
	itemType: string, -- "Asset" | "Bundle"
	name: string,
	description: string,
	creatorName: string,
	creatorType: string?, -- "User" | "Group"
	creatorVerified: boolean,
	price: number?, -- nil = tidak dijual
	lowestResalePrice: number?, -- limited/koleksi
	isForSale: boolean,
	favoriteCount: number?,
	assetType: string?, -- aset: nama tipe, mis. "Hat"
	bundleType: string?, -- bundle: mis. "BodyParts", "Animations"
	isLimited: boolean,
	unitsLeft: number?, -- limited: sisa stok; 0 = habis terjual (spike 19 Sep 2026)
	totalQuantity: number?, -- limited: stok awal
	parts: { Types.BundlePart }?, -- bundle: diisi server dari BundleService
}

local ItemDetail = {}

ItemDetail.MAX_NAME = 100
ItemDetail.MAX_DESCRIPTION = 1000

local function isId(v: any): boolean
	return type(v) == "number" and v > 0 and v % 1 == 0 and v <= 2 ^ 53
end

local function text(v: any, maxLen: number): string
	if type(v) ~= "string" then
		return ""
	end
	if #v > maxLen then
		-- potong di batas karakter UTF-8 yang valid
		local cut = utf8.offset(v, maxLen + 1)
		local s = if cut then string.sub(v, 1, cut - 1) else string.sub(v, 1, maxLen)
		while #s > 0 and utf8.len(s) == nil do
			s = string.sub(s, 1, #s - 1)
		end
		return s .. "…"
	end
	return v
end

local function nonNegative(v: any): number?
	if type(v) == "number" and v == v and v >= 0 and v < 2 ^ 53 then
		return v
	end
	return nil
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- itemType: tipe yang DIMINTA ("Asset" | "Bundle"); dipakai bila respons tidak menyebutkannya.
function ItemDetail.fromRaw(raw: any, itemType: string): Detail?
	if type(raw) ~= "table" or not isId(raw.Id) then
		return nil
	end
	local kind = str(raw.ItemType) or itemType
	if kind ~= "Asset" and kind ~= "Bundle" then
		return nil
	end

	local price = nonNegative(raw.Price)
	local resale = nonNegative(raw.LowestResalePrice)
	local restrictions = raw.ItemRestrictions
	local isLimited = false
	if type(restrictions) == "table" then
		for _, r in restrictions do
			if r == "Limited" or r == "LimitedUnique" or r == "Collectible" then
				isLimited = true
			end
		end
	end
	-- Stok limited. `units = 0` dengan TotalQuantity besar berarti SOLD OUT, jadi nol TIDAK dibuang;
	-- yang dibuang hanya angka untuk item non-limited (di sana 0/0 memang berarti 'tidak berlaku').
	local unitsLeft: number? = nil
	local totalQuantity: number? = nil
	if isLimited then
		unitsLeft = nonNegative(raw.UnitsAvailableForConsumption)
		local total = nonNegative(raw.TotalQuantity)
		totalQuantity = if total ~= nil and total > 0 then total else nil
	end
	-- IsPurchasable hanya ada di GetItemDetailsAsync; bila tidak ada, anggap dijual jika ada harga.
	local purchasable = if type(raw.IsPurchasable) == "boolean" then raw.IsPurchasable else price ~= nil

	return {
		id = raw.Id,
		itemType = kind,
		name = text(raw.Name, ItemDetail.MAX_NAME),
		description = text(raw.Description, ItemDetail.MAX_DESCRIPTION),
		creatorName = str(raw.CreatorName) or "Unknown",
		creatorType = str(raw.CreatorType),
		creatorVerified = raw.CreatorHasVerifiedBadge == true,
		price = price,
		lowestResalePrice = resale,
		isForSale = purchasable and (price ~= nil or resale ~= nil),
		favoriteCount = nonNegative(raw.FavoriteCount),
		assetType = if kind == "Asset" then Map.normalize(raw.AssetType) else nil,
		bundleType = if kind == "Bundle" then str(raw.BundleType) else nil,
		isLimited = isLimited,
		unitsLeft = unitsLeft,
		totalQuantity = totalQuantity,
		parts = nil,
	}
end

-- Label tipe untuk ditampilkan: "Hat" -> "Hat", "BodyParts" -> "Body Bundle".
local BUNDLE_LABEL: { [string]: string } = {
	BodyParts = "Body Bundle",
	Animations = "Animation Bundle",
	Shoes = "Shoes Bundle",
	DynamicHead = "Head Bundle",
	DynamicHeadAvatar = "Avatar Bundle",
}

function ItemDetail.typeLabel(detail: Detail): string
	if detail.itemType == "Bundle" then
		return BUNDLE_LABEL[detail.bundleType or ""] or "Bundle"
	end
	local t = detail.assetType
	if t == nil then
		return "Item"
	end
	local base = t:gsub("Accessory$", "")
	if base == "" then
		base = t
	end
	local spaced = base:gsub("(%l)(%u)", "%1 %2")
	return spaced
end

return ItemDetail
