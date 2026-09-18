--!strict
-- Studio: require(game.ReplicatedStorage.Tests["AssetTypeMap.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local AssetTypeMap = require(Shared.Domain.AssetTypeMap)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	-- 1. NotWearable sekarang KOSONG: makeup keluar di PR #18 (Decal di Head), AvatarBackground
	--    keluar di PR avatar-background (tombolnya memasang LATAR area preview, bukan item di avatar)
	eq(AssetTypeMap.NotWearable.AvatarBackground, nil, "background tidak lagi diblokir")
	eq(AssetTypeMap.isWearable("AvatarBackground"), true, "background isWearable true")

	-- 1b. makeup BISA dicoba sejak PR #18 (ditempel sebagai Decal, bukan lewat description)
	for _, name in { "FaceMakeup", "LipMakeup", "EyeMakeup" } do
		eq(AssetTypeMap.NotWearable[name], nil, name .. ": tidak lagi diblokir")
		eq(AssetTypeMap.isWearable(name), true, name .. ": isWearable true")
	end

	-- 2. yang TERBUKTI terpasang di avatar tetap bisa dicoba
	eq(AssetTypeMap.isWearable("EyelashAccessory"), true, "eyelash bisa dipakai")
	eq(AssetTypeMap.isWearable("EyebrowAccessory"), true, "eyebrow bisa dipakai")
	eq(AssetTypeMap.isWearable("Hat"), true, "topi bisa dipakai")
	eq(AssetTypeMap.isWearable(nil), true, "bundle (tanpa assetType) dianggap bisa dipakai")

	-- 3. daftar ini TIDAK ikut mengubah klasifikasi lama
	eq((AssetTypeMap.classify("Hat")), "accessory", "topi tetap accessory")
	local makeupKind, makeupSlot = AssetTypeMap.classify("FaceMakeup")
	eq(makeupKind, "makeup", "makeup punya kind sendiri")
	eq(makeupSlot, nil, "TANPA slot -> OutfitState.wear menolaknya")
	eq((AssetTypeMap.classify("EyeMakeup")), "makeup", "eye makeup")
	eq((AssetTypeMap.classify("LipMakeup")), "makeup", "lip makeup")
	local bgKind, bgSlot = AssetTypeMap.classify("AvatarBackground")
	eq(bgKind, "background", "background punya kind sendiri (kalau unknown, ItemInfoService membuangnya)")
	eq(bgSlot, nil, "TANPA slot -> OutfitState.wear menolaknya, tidak pernah masuk description")
	eq(AssetTypeMap.Background.AvatarBackground, true, "daftar Background berisi AvatarBackground")

	print("PASS AssetTypeMap.spec")
end
