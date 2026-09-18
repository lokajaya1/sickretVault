--!strict
-- Studio (dari SERVER): require(game.ReplicatedStorage.Tests["OutfitItemsService.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Server = game:GetService("ServerScriptService"):WaitForChild("Server")
local OutfitItemsService = require(Server.Services.OutfitItemsService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local OS = require(Shared.Domain.OutfitState)
local Log = require(Shared.Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function setup(details: any, ok: boolean?)
	local t = { asked = {} :: { any } }
	local api: any = {}
	function api.getBatchItemDetails(_self: any, ids: { number }, itemType: any)
		t.asked = ids
		t.itemType = itemType
		if ok == false then
			return false, { code = "FAILED" }
		end
		return true, details
	end
	local svc = OutfitItemsService.new({
		api = api,
		toEnum = function(enumName: string, itemName: string)
			return enumName .. "." .. itemName
		end,
	})
	return svc, t
end

local function sample()
	local s = OS.empty()
	s.bodyParts.Head = { id = 111 }
	s.classic.Shirt = { id = 30 }
	s.classic.Pants = { id = 31 }
	s.animations.RunAnimation = { id = 40 }
	s = OS.wear(s, 20, "Hat", 900)
	s = OS.wear(s, 21, "HairAccessory", 900)
	return s
end

return function()
	Log.setSink(function() end)

	-- 1. urutan id: aksesori (urut dipakai) -> classic (A-Z) -> body part -> animasi
	local ids = OutfitItemsService.idsOf(sample())
	eq(table.concat(ids, ","), "20,21,31,30,111,40", "urutan id")
	eq(#OutfitItemsService.idsOf(OS.empty()), 0, "outfit kosong")

	-- 1b. makeup ikut PALING AKHIR (dan tidak menggeser urutan lama)
	local mkRows = { { assetId = 800, slot = "face" }, { assetId = 801, slot = "lip" } }
	eq(table.concat(OutfitItemsService.idsOf(sample(), mkRows), ","), "20,21,31,30,111,40,800,801", "urutan + makeup")
	eq(table.concat(OutfitItemsService.idsOf(OS.empty(), mkRows), ","), "800,801", "makeup saja")
	eq(#OutfitItemsService.idsOf(sample(), "rusak"), 6, "baris makeup rusak diabaikan")
	eq(#OutfitItemsService.idsOf(sample(), { "x", { assetId = 20 } }), 6, "id ganda/cacat diabaikan")

	-- 2. harga: Price, lalu LowestPrice, lalu tidak dijual
	local svc, t = setup({
		[20] = { Name = "Topi", AssetType = "Hat", Price = 50, CreatorName = "Roblox" },
		[21] = { Name = "Rambut", AssetType = "HairAccessory", LowestPrice = 25 },
		[31] = { Name = "Celana", AssetType = "Pants" },
		[30] = { Name = "", AssetType = "Shirt", Price = 0 },
		[111] = { Name = "Kepala", AssetType = "Head", Price = 5 },
		-- 40 sengaja tidak ada -> missing
	})
	local ok, res = svc:list(sample())
	assert(ok, "list ok")
	eq(#res.items, 5, "5 item")
	eq(res.missing, 1, "1 item hilang")
	eq(res.total, 80, "total harga")
	eq(res.items[1].name, "Topi", "urutan sama dengan idsOf")
	eq(res.items[1].creator, "Roblox", "nama pembuat ikut")
	eq(res.items[2].creator, nil, "tanpa CreatorName -> nil")
	eq(res.items[2].price, 25, "LowestPrice dipakai")
	eq(res.items[3].price, nil, "tanpa harga")
	eq(res.items[3].isForSale, false, "tidak dijual")
	eq(res.items[4].name, "Item 30", "nama kosong -> cadangan")
	eq(res.items[4].price, 0, "gratis tetap dijual")
	eq(t.itemType, "AvatarItemType.Asset", "tipe item dari toEnum")
	eq(#t.asked, 6, "6 id ditanyakan")

	-- 3. outfit kosong: tanpa panggilan API
	local svc2, t2 = setup({})
	local ok2, res2 = svc2:list(OS.empty())
	assert(ok2, "kosong ok")
	eq(#res2.items, 0, "tanpa item")
	eq(#t2.asked, 0, "API tidak dipanggil")

	-- 4. API gagal / state rusak
	local svc3 = setup({}, false)
	-- makeup masuk ke daftar & ikut dijumlahkan
	local svcM, tM = setup({
		[20] = { Name = "Topi", AssetType = "Hat", Price = 50 },
		[800] = { Name = "Blush", AssetType = "FaceMakeup", Price = 10 },
	})
	local okM, resM = svcM:list(OS.wear(OS.empty(), 20, "Hat"), { { assetId = 800, slot = "face" } })
	eq(okM, true, "list dengan makeup")
	eq(#resM.items, 2, "dua item")
	eq(resM.items[2].name, "Blush", "makeup di urutan terakhir")
	eq(resM.items[2].assetType, "FaceMakeup", "tipe makeup")
	eq(resM.total, 60, "harga makeup ikut dijumlahkan")
	eq(tM.asked[#tM.asked], 800, "id makeup ikut diminta ke API")

	eq(select(2, svc3:list(sample())).code, "FAILED", "api gagal")
	eq(select(2, svc3:list({} :: any)).code, "BAD_ARG", "state rusak")

	print("PASS OutfitItemsService.spec")
end
