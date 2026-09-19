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
	price: number?, -- nil = tidak dijual / harga tidak tersedia
	lowestResalePrice: number?, -- limited/koleksi
	isForSale: boolean,
	offSale: boolean?, -- true = ditarik dari penjualan; `price` 0 di sini BUKAN "gratis"
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
ItemDetail.PRICE_UNAVAILABLE = 999999999

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

-- Spike 19 Sep 2026 (tests/CatalogFilter.studio "5b"): 999999999 BUKAN harga — itu nilai isian
-- Roblox untuk "harga tidak tersedia" (27 dari 30 item halaman pertama PriceHighToLow bernilai
-- begitu). Panel tidak boleh mencetak angka itu, jadi diperlakukan sebagai tidak ada harga.
local function priceValue(v: any): number?
	local n = nonNegative(v)
	if n ~= nil and n >= ItemDetail.PRICE_UNAVAILABLE then
		return nil
	end
	return n
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- Aturan HARGA dari respons katalog Roblox, di SATU tempat supaya panel detail dan panel review
-- Save to Roblox tidak punya versi sendiri-sendiri:
--   * 999999999 bukan harga (spike 19 Sep 2026) -> nil
--   * harga pasar item limited hanya dipercaya bila HasResellers = true
--   * off-sale datang dengan Price = 0 -> tanpa penanda ini ia terbaca "Free"
-- Return (price, resalePrice, limited, offSale, hasResellers). `resalePrice` sengaja TIDAK
-- disaring HasResellers: panel detail menampilkannya apa adanya, sedangkan KARTU hanya boleh
-- memercayainya bila ada penjual ulang -- jadi penyaringnya ikut dikembalikan, bukan diputuskan
-- di sini.
function ItemDetail.priceFields(raw: any): (number?, number?, boolean, boolean, boolean)
	if type(raw) ~= "table" then
		return nil, nil, false, false, false
	end
	local price = priceValue(raw.Price)
	if price == nil then
		price = priceValue(raw.LowestPrice)
	end
	local resale = priceValue(raw.LowestResalePrice)
	local limited = false
	if type(raw.ItemRestrictions) == "table" then
		for _, r in raw.ItemRestrictions do
			if r == "Limited" or r == "LimitedUnique" or r == "Collectible" then
				limited = true
			end
		end
	end
	return price, resale, limited, raw.IsOffSale == true, raw.HasResellers == true
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

	local price, resale, isLimited, offSale = ItemDetail.priceFields(raw)
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
		isForSale = not offSale and purchasable and (price ~= nil or resale ~= nil),
		favoriteCount = nonNegative(raw.FavoriteCount),
		assetType = if kind == "Asset" then Map.normalize(raw.AssetType) else nil,
		bundleType = if kind == "Bundle" then str(raw.BundleType) else nil,
		isLimited = isLimited,
		unitsLeft = unitsLeft,
		totalQuantity = totalQuantity,
		offSale = if offSale then true else nil,
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
