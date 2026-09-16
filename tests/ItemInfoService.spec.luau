--!strict
-- Test ItemInfoService dengan RobloxApi PALSU (tanpa internet, tanpa Studio).
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["ItemInfoService.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local ItemInfoService = require(ServerScriptService:WaitForChild("Server").Services.ItemInfoService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Log = require(Shared.Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function fakeEnum(enumName: string, itemName: string): any
	return enumName .. "." .. itemName
end

-- Katalog palsu: id -> detail mentah
local DB: { [number]: any } = {
	[1] = { Id = 1, Name = "Topi", AssetType = "Hat" },
	[2] = { Id = 2, Name = "Jaket", AssetType = "JacketAccessory" },
	[3] = { Id = 3, Name = "Baju", AssetType = "Shirt" },
	[4] = { Id = 4, Name = "Kepala", AssetType = "DynamicHead" },
	[5] = { Id = 5, Name = "Model", AssetType = "Model" }, -- tidak didukung
	[6] = { Id = 6, Name = "Kaos", AssetType = "TShirt" },
}

local function fakeApi()
	local api = { calls = 0, lastIds = nil :: any, lastType = nil :: any, fail = false }
	function api.getBatchItemDetails(self: any, ids: { number }, itemType: any)
		self.calls += 1
		self.lastIds = ids
		self.lastType = itemType
		if self.fail then
			return false, { code = "FAILED", message = "HTTP 500", api = "GetBatchItemDetailsAsync" }
		end
		local out = {}
		for _, id in ids do
			out[id] = DB[id]
		end
		return true, out
	end
	return api
end

return function()
	Log.setSink(function() end)

	-- 1. fromDetail
	local F = ItemInfoService.fromDetail
	assert(F(nil) == nil, "nil -> nil")
	assert(F({ Id = 0, AssetType = "Hat" }) == nil, "id 0 ditolak")
	assert(F(DB[5]) == nil, "Model tidak didukung")
	local hat = F(DB[1]) :: any
	eq(hat.kind, "accessory", "Hat accessory")
	eq(hat.isLayered, false, "Hat rigid")
	eq(hat.slot, "Hat", "slot Hat")
	local jacket = F(DB[2]) :: any
	eq(jacket.isLayered, true, "Jacket layered")
	eq((F(DB[3]) :: any).slot, "Shirt", "slot Shirt")
	eq((F(DB[4]) :: any).kind, "bodyPart", "DynamicHead bodyPart")
	eq((F(DB[4]) :: any).slot, "Head", "DynamicHead -> Head")
	eq((F(DB[6]) :: any).slot, "GraphicTShirt", "TShirt -> GraphicTShirt")

	-- 2. getMany: dedupe, id rusak dibuang, enum Asset dipakai
	local api = fakeApi()
	local svc = ItemInfoService.new({ api = api, toEnum = fakeEnum })
	local ok, map = svc:getMany({ 1, 2, 2, -1, 1.5, 5, 99 })
	assert(ok, "getMany ok")
	eq(#api.lastIds, 4, "hanya id valid & unik dikirim")
	eq(api.lastType, "AvatarItemType.Asset", "itemType Asset")
	eq(map[1].name, "Topi", "map[1]")
	eq(map[2].assetType, "JacketAccessory", "map[2]")
	eq(map[5], nil, "Model tidak ada di map")
	eq(map[99], nil, "id hilang tidak ada di map")

	-- 3. miss di-cache: 5 & 99 tidak ditanya ulang
	svc:getMany({ 5, 99 })
	eq(api.calls, 1, "miss tidak memanggil API lagi")

	-- 4. get
	local ok1, one = svc:get(3)
	assert(ok1, "get ok")
	eq(one.kind, "classic", "get Shirt classic")
	local ok2, e2 = svc:get(99)
	eq(ok2, false, "get hilang gagal")
	eq(e2.code, "NOT_FOUND", "kode NOT_FOUND")
	local ok3, e3 = svc:get(0)
	eq(ok3, false, "id 0 gagal")
	eq(e3.code, "BAD_ARG", "kode BAD_ARG")

	-- 5. API gagal total -> FAILED diteruskan, tidak di-cache sebagai miss
	local api2 = fakeApi()
	api2.fail = true
	local svc2 = ItemInfoService.new({ api = api2, toEnum = fakeEnum })
	local ok4, e4 = svc2:get(1)
	eq(ok4, false, "api gagal")
	eq(e4.code, "FAILED", "kode FAILED")
	api2.fail = false
	local ok5 = svc2:get(1)
	assert(ok5, "setelah API pulih, id 1 berhasil")

	print("PASS ItemInfoService.spec")
end
