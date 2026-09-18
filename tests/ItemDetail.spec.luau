--!strict
-- Studio: require(game.ReplicatedStorage.Tests["ItemDetail.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemDetail = require(Shared.Domain.ItemDetail)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	-- 1. aset biasa (bentuk respons GetItemDetailsAsync, lihat docs/API_VERIFICATION.md)
	local hat = ItemDetail.fromRaw({
		Id = 123,
		ItemType = "Asset",
		AssetType = "HairAccessory",
		Name = "Cool Hair",
		Description = "Rambut keren",
		CreatorName = "Studio X",
		CreatorType = "Group",
		CreatorHasVerifiedBadge = true,
		Price = 75,
		IsPurchasable = true,
		FavoriteCount = 1500,
		Owned = true, -- diabaikan (server tidak tahu pemainnya)
	}, "Asset")
	assert(hat, "hat terbaca")
	eq(hat.id, 123, "id")
	eq(hat.itemType, "Asset", "itemType")
	eq(hat.name, "Cool Hair", "nama")
	eq(hat.creatorName, "Studio X", "creator")
	eq(hat.creatorVerified, true, "verified")
	eq(hat.price, 75, "harga")
	eq(hat.isForSale, true, "dijual")
	eq(hat.assetType, "HairAccessory", "assetType")
	eq(hat.bundleType, nil, "aset tanpa bundleType")
	eq((hat :: any).Owned, nil, "Owned tidak ikut")
	eq(ItemDetail.typeLabel(hat), "Hair", "label tipe aset")

	-- 2. bundle: ItemType dari respons, label tipe bundle
	local anim = ItemDetail.fromRaw({
		Id = 226897222628299,
		ItemType = "Bundle",
		BundleType = "Animations",
		Name = "Chill Boy",
		CreatorName = "Someone",
		Price = 270,
	}, "Bundle")
	assert(anim, "bundle terbaca")
	eq(anim.itemType, "Bundle", "bundle")
	eq(anim.assetType, nil, "bundle tanpa assetType")
	eq(anim.description, "", "deskripsi kosong aman")
	eq(anim.isForSale, true, "tanpa IsPurchasable -> dijual bila ada harga")
	eq(ItemDetail.typeLabel(anim), "Animation Bundle", "label bundle")

	-- 3. tidak dijual / limited / field aneh
	local off = ItemDetail.fromRaw({ Id = 5, Name = 42, Price = -1, IsPurchasable = false }, "Asset")
	assert(off, "off-sale terbaca")
	eq(off.name, "", "nama bukan string -> kosong")
	eq(off.price, nil, "harga negatif dibuang")
	eq(off.isForSale, false, "tidak dijual")
	eq(off.creatorName, "Unknown", "creator cadangan")
	eq(ItemDetail.typeLabel(off), "Item", "label tanpa tipe")
	local lim = ItemDetail.fromRaw({
		Id = 6,
		AssetType = "Hat",
		ItemRestrictions = { "Collectible" },
		LowestResalePrice = 900,
		IsPurchasable = true,
	}, "Asset")
	assert(lim, "limited terbaca")
	eq(lim.isLimited, true, "limited")
	eq(lim.lowestResalePrice, 900, "harga resale")
	eq(lim.isForSale, true, "limited dijual lewat resale")

	-- 4. teks panjang dipotong (UTF-8 tetap valid)
	local long = string.rep("é", ItemDetail.MAX_DESCRIPTION + 50)
	local cut = ItemDetail.fromRaw({ Id = 7, Description = long }, "Asset")
	assert(cut, "teks panjang terbaca")
	assert(utf8.len(cut.description) ~= nil, "UTF-8 valid")
	eq(utf8.len(cut.description), ItemDetail.MAX_DESCRIPTION + 1, "dipotong + elipsis")

	-- 5. respons ditolak
	eq(ItemDetail.fromRaw(nil, "Asset"), nil, "nil")
	eq(ItemDetail.fromRaw({ Name = "x" }, "Asset"), nil, "tanpa Id")
	eq(ItemDetail.fromRaw({ Id = 1.5 }, "Asset"), nil, "Id pecahan")
	eq(ItemDetail.fromRaw({ Id = 1, ItemType = "Emote" }, "Asset"), nil, "itemType asing")

	-- 6. Stok limited (#17d): 0 = habis terjual, bukan "tidak ada data"
	local habis = ItemDetail.fromRaw({
		Id = 8,
		Name = "Yum Yum",
		ItemRestrictions = { "Collectible" },
		UnitsAvailableForConsumption = 0,
		TotalQuantity = 27999,
	}, "Asset")
	assert(habis, "limited habis terbaca")
	eq(habis.unitsLeft, 0, "sisa stok 0 dipertahankan")
	eq(habis.totalQuantity, 27999, "stok awal")

	local biasa = ItemDetail.fromRaw({
		Id = 9,
		Name = "Topi biasa",
		UnitsAvailableForConsumption = 0,
		TotalQuantity = 0,
	}, "Asset")
	assert(biasa, "item biasa terbaca")
	eq(biasa.unitsLeft, nil, "item biasa tidak punya sisa stok")
	eq(biasa.totalQuantity, nil, "item biasa tidak punya stok awal")

	print("PASS ItemDetail.spec")
end
