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
	eq(list[1].name, "HairAccessory", "nama aksesori")
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

	print("PASS WornItems.spec")
end
