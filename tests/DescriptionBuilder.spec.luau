--!strict
-- Test bagian MURNI DescriptionBuilder (toSpec/fromSpec/specEquals).
-- Studio: require(game.ReplicatedStorage.Tests["DescriptionBuilder.spec"])()
-- Lokal : lune run tools/run-tests.luau
-- Bagian ENGINE dites di Studio: tests/DescriptionBuilder.studio.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local DB = require(Shared.Avatar.DescriptionBuilder)
local OS = require(Shared.Domain.OutfitState)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	-- 1. peta AccessoryType dua arah konsisten & mencakup semua tipe aksesori di AssetTypeMap
	local Map = require(Shared.Domain.AssetTypeMap)
	for name in Map.Layered do
		assert(DB.AccessoryTypeOf[name], "layered tanpa AccessoryType: " .. name)
	end
	for name in Map.Rigid do
		assert(DB.AccessoryTypeOf[name], "rigid tanpa AccessoryType: " .. name)
	end
	for assetType, accType in DB.AccessoryTypeOf do
		eq(DB.AssetTypeOf[accType], assetType, "peta balik " .. accType)
	end

	-- 2. state -> spec
	local s = OS.empty()
	s.bodyParts.Head = { id = 111 }
	s.animations.RunAnimation = { id = 222, source = 9 }
	s.classic.Shirt = { id = 333 }
	s.colors.HeadColor = "#ff00aa"
	s.scales.HeightScale = 1.05
	s = OS.wear(s, 1, "JacketAccessory")
	s = OS.wear(s, 2, "TShirtAccessory")
	s = OS.wear(s, 3, "HairAccessory")
	local spec, skipped = DB.toSpec(s)
	eq(#skipped, 0, "tidak ada yang dilewati")
	eq(spec.props.Head, 111, "Head")
	eq(spec.props.RunAnimation, 222, "RunAnimation")
	eq(spec.props.Shirt, 333, "Shirt")
	eq(spec.props.Torso, 0, "Torso default")
	eq(spec.props.HeightScale, 1.05, "HeightScale")
	eq(spec.colors.HeadColor, "FF00AA", "hex dinormalisasi")
	eq(#spec.accessories, 3, "jumlah aksesori")
	-- urutan: rigid dulu, lalu layered dari dalam ke luar
	eq(spec.accessories[1].AccessoryType, "Hair", "rigid pertama")
	eq(spec.accessories[1].Order, nil, "rigid tanpa Order")
	eq(spec.accessories[2].AccessoryType, "TShirt", "kaos di dalam")
	eq(spec.accessories[3].AccessoryType, "Jacket", "jaket di luar")
	eq(spec.accessories[3].Puffiness, 1, "puffiness default")

	-- 3. round-trip: spec -> state -> spec identik
	local back = DB.fromSpec(spec)
	local spec2 = DB.toSpec(back)
	local same, diff = DB.specEquals(spec, spec2)
	assert(same, "round-trip beda: " .. tostring(diff))
	eq(back.accessories["1"].assetType, "JacketAccessory", "tipe aset kembali")
	eq(back.animations.RunAnimation.source, nil, "source tidak ikut (bukan properti description)")
	eq(back.rig, "R15", "rig default")
	eq(DB.fromSpec(spec, "R6").rig, "R6", "rig R6")

	-- 4. perbedaan terdeteksi
	local changed = DB.toSpec(OS.wear(back, 4, "Hat"))
	eq((DB.specEquals(spec, changed)), false, "aksesori tambahan terdeteksi")
	local other = DB.toSpec(back)
	other.colors.TorsoColor = "000000"
	local ok2, why = DB.specEquals(spec, other)
	eq(ok2, false, "warna beda terdeteksi")
	assert(why and string.find(why, "TorsoColor"), "keterangan menyebut TorsoColor")

	-- 5. data rusak disanitasi
	local bad = OS.empty()
	bad.bodyParts.Head = { id = -5 }
	bad.classic.Face = { id = 1.5 }
	bad.colors.LeftArmColor = "zzz"
	bad.scales.WidthScale = 0 / 0 -- NaN
	bad.accessories["77"] = { assetId = 77, assetType = "Gear", isLayered = false }
	bad.accessories["0"] = { assetId = 0, assetType = "Hat", isLayered = false }
	local bspec, bskipped = DB.toSpec(bad)
	eq(bspec.props.Head, 0, "id negatif -> 0")
	eq(bspec.props.Face, 0, "id pecahan -> 0")
	eq(bspec.colors.LeftArmColor, "A3A2A5", "hex rusak -> default")
	eq(bspec.props.WidthScale, 1, "NaN -> default")
	eq(#bspec.accessories, 0, "aksesori rusak dibuang")
	eq(#bskipped, 2, "dua aksesori dilewati")

	-- 6. fromSpec membuang AccessoryType tak dikenal
	local weird = DB.fromSpec({
		props = {},
		colors = {},
		accessories = {
			{ AssetId = 50, AccessoryType = "Unknown", IsLayered = false },
			{ AssetId = 51, AccessoryType = "Shorts", IsLayered = true },
		},
	})
	eq(weird.accessories["50"], nil, "Unknown dibuang")
	eq(weird.accessories["51"].order, 4, "Order default dari LayerOrder")
	eq(weird.bodyParts.Head.id, 0, "props kosong -> 0")

	print("PASS DescriptionBuilder.spec")
end
