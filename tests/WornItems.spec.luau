--!strict
-- Studio: require(game.ReplicatedStorage.Tests["WornItems.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local OS = require(Shared.Domain.OutfitState)
local WornItems = require(Shared.Domain.WornItems)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	-- 1. state kosong / bukan tabel -> daftar kosong
	eq(#WornItems.list(nil), 0, "nil")
	eq(#WornItems.list(OS.empty()), 0, "state kosong")

	-- 2. urutan: aksesori terbaru dulu, lalu klasik, tubuh, animasi
	local s = OS.empty()
	s.accessories["10"] = { assetId = 10, assetType = "HatAccessory", isLayered = false, seq = 1 }
	s.accessories["20"] = { assetId = 20, assetType = "HairAccessory", isLayered = false, seq = 3 }
	s.accessories["30"] = { assetId = 30, assetType = "FaceAccessory", isLayered = false } -- tanpa seq
	s.classic.Shirt = { id = 40 }
	s.classic.Face = { id = 41 }
	s.bodyParts.Head = { id = 50 }
	s.animations[next(s.animations) :: string] = { id = 60 }
	local list = WornItems.list(s)
	local ids = {}
	for i, it in list do
		ids[i] = it.id
		eq(it.itemType, "Asset", "itemType")
	end
	eq(table.concat(ids, ","), "20,10,30,40,41,50,60", "urutan")

	-- 3. nama cadangan = tipe / slot
	eq(list[1].name, "Hair", "nama aksesori ramah")
	eq(list[4].name, "Shirt", "nama slot")

	-- 4. known -> nama & harga dari katalog
	local known = { [10] = { id = 10, name = "Cool Hat", price = 50, creatorName = "Me" } }
	local named = WornItems.list(s, known)
	eq(named[2].name, "Cool Hat", "nama known")
	eq(named[2].price, 50, "harga known")
	eq(named[2].assetType, "HatAccessory", "assetType tetap")

	-- 5. id sama di dua tempat -> satu kartu; id 0 diabaikan
	s.classic.Pants = { id = 40 }
	s.classic.GraphicTShirt = { id = 0 }
	eq(#WornItems.list(s), 7, "tanpa duplikat")

	-- 6. group + removable: body & animasi tidak ikut strip
	local g = WornItems.list(s)
	eq(g[1].group, "accessory", "group aksesori")
	eq(g[4].group, "classic", "group klasik")
	eq(g[6].group, "body", "group tubuh")
	eq(g[7].group, "animation", "group animasi")
	local r = WornItems.removable(g)
	eq(#r, 5, "removable = 3 aksesori + 2 klasik")
	for _, it in r do
		assert(it.group == "accessory" or it.group == "classic", "hanya bisa dilepas")
	end
	eq(#WornItems.removable({}), 0, "kosong aman")

	-- 6b. part tubuh/animasi dari bundle bisa dilepas satu per satu; bawaan avatar tidak
	local b = OS.empty()
	b.bodyParts.Head = { id = 600 } -- bawaan avatar
	b.bodyParts.Torso = { id = 702, source = 700 }
	b.bodyParts.LeftArm = { id = 703, source = 700 }
	b.animations.RunAnimation = { id = 801, source = 800 }
	local bl = WornItems.list(b)
	eq(#bl, 4, "semua slot terisi tampil di list")
	local br = WornItems.removable(bl)
	eq(#br, 3, "removable = Torso + LeftArm + Run (Head bawaan tidak)")
	eq(br[1].name, "Torso", "nama slot Torso")
	eq(br[1].source, 700, "source bundle ikut")
	eq(br[2].name, "Left Arm", "nama ramah Left Arm")
	eq(br[3].group, "animation", "animasi bundle bisa dilepas")
	eq(br[3].name, "Run Animation", "nama ramah animasi")

	-- 7. nama ramah
	eq(WornItems.friendlyName("EyebrowAccessory"), "Eyebrow", "eyebrow")
	eq(WornItems.friendlyName("LeftShoeAccessory"), "Left Shoe", "sepatu kiri")
	eq(WornItems.friendlyName("GraphicTShirt"), "T-Shirt", "kaos grafis")
	eq(WornItems.friendlyName("Shirt"), "Shirt", "baju")
	eq(WornItems.friendlyName("Accessory"), "Accessory", "tanpa tipe")

	print("PASS WornItems.spec")
end
