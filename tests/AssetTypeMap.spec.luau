--!strict
-- Studio: require(game.ReplicatedStorage.Tests["AssetTypeMap.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local AssetTypeMap = require(Shared.Domain.AssetTypeMap)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	-- 1. tipe yang tidak bisa dipakai lewat HumanoidDescription (spike 18 Sep 2026)
	for _, name in { "AvatarBackground", "FaceMakeup", "LipMakeup", "EyeMakeup" } do
		eq(AssetTypeMap.NotWearable[name], true, name .. ": ditandai tidak bisa dipakai")
		eq(AssetTypeMap.isWearable(name), false, name .. ": isWearable false")
	end

	-- 2. yang TERBUKTI terpasang di avatar tetap bisa dicoba
	eq(AssetTypeMap.isWearable("EyelashAccessory"), true, "eyelash bisa dipakai")
	eq(AssetTypeMap.isWearable("EyebrowAccessory"), true, "eyebrow bisa dipakai")
	eq(AssetTypeMap.isWearable("Hat"), true, "topi bisa dipakai")
	eq(AssetTypeMap.isWearable(nil), true, "bundle (tanpa assetType) dianggap bisa dipakai")

	-- 3. daftar ini TIDAK ikut mengubah klasifikasi lama
	eq((AssetTypeMap.classify("Hat")), "accessory", "topi tetap accessory")
	eq((AssetTypeMap.classify("FaceMakeup")), "unknown", "makeup memang bukan slot mana pun")

	print("PASS AssetTypeMap.spec")
end
