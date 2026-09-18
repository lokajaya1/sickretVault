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

	-- 3b. emote (PR #28): kind animation, TANPA slot -> tidak pernah masuk description
	local emoteKind, emoteSlot = AssetTypeMap.classify("EmoteAnimation")
	eq(emoteKind, "animation", "emote punya kind animation")
	eq(emoteSlot, nil, "emote TANPA slot -> OutfitState.wear menolaknya")
	eq(AssetTypeMap.Emote.EmoteAnimation, true, "daftar Emote berisi EmoteAnimation")
	eq(AssetTypeMap.focusRegion("EmoteAnimation"), "full", "emote: seluruh badan")
	eq((AssetTypeMap.classify("IdleAnimation")), "animation", "animasi biasa tetap animation")

	-- 4. focusRegion: bagian tubuh yang dibidik kamera preview kartu (PR #28)
	for _, name in { "Hat", "HairAccessory", "FaceAccessory", "EyelashAccessory", "LipMakeup", "DynamicHead" } do
		eq(AssetTypeMap.focusRegion(name), "head", name .. ": bidik kepala")
	end
	for _, name in { "ShirtAccessory", "JacketAccessory", "BackAccessory", "Shirt", "Torso" } do
		eq(AssetTypeMap.focusRegion(name), "torso", name .. ": bidik badan")
	end
	for _, name in { "PantsAccessory", "LeftShoeAccessory", "DressSkirtAccessory", "Pants" } do
		eq(AssetTypeMap.focusRegion(name), "legs", name .. ": bidik kaki")
	end
	eq(AssetTypeMap.focusRegion(nil), "full", "bundle tanpa assetType: seluruh badan")
	eq(AssetTypeMap.focusRegion("IdleAnimation"), "full", "animasi: seluruh badan")
	eq(AssetTypeMap.focusRegion("AvatarBackground"), "full", "latar: seluruh badan")
	eq(AssetTypeMap.focusRegion("TipeNgawur"), "full", "tipe tak dikenal: seluruh badan")

	print("PASS AssetTypeMap.spec")
end
