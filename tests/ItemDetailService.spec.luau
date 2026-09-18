--!strict
-- Test ItemDetailService dengan RobloxApi & BundleService PALSU.
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["ItemDetailService.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local ItemDetailService = require(ServerScriptService:WaitForChild("Server").Services.ItemDetailService)
local Log = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function fakeEnum(enumName: string, itemName: string): any
	return enumName .. "." .. itemName
end

local DB: { [string]: any } = {
	["AvatarItemType.Asset:1"] = { Id = 1, ItemType = "Asset", AssetType = "Hat", Name = "Topi", Price = 10 },
	["AvatarItemType.Bundle:2"] = { Id = 2, ItemType = "Bundle", BundleType = "BodyParts", Name = "Badan" },
	["AvatarItemType.Bundle:3"] = { Id = 3, ItemType = "Bundle", BundleType = "BodyParts", Name = "Rusak" },
	["AvatarItemType.Asset:4"] = { Id = 99, ItemType = "Asset", Name = "Id beda" },
	["AvatarItemType.Asset:5"] = { Id = 5, ItemType = "Bundle", Name = "Tipe beda" },
}

local PARTS = { { assetId = 11, name = "Torso", assetType = "Torso", kind = "bodyPart" } }

local function setup()
	local state = { api = 0, bundles = 0, apiFail = false, bundleCode = nil :: string? }
	local api = {}
	function api.getItemDetails(_self: any, id: number, itemType: any)
		state.api += 1
		if state.apiFail then
			return false, { code = "FAILED", message = "HTTP 500" }
		end
		local raw = DB[tostring(itemType) .. ":" .. tostring(id)]
		if raw == nil then
			return false, { code = "NOT_FOUND", message = "HTTP 404" }
		end
		return true, raw
	end
	local bundles = {}
	function bundles.get(_self: any, id: number)
		state.bundles += 1
		if state.bundleCode then
			return false, { code = state.bundleCode, message = "x" }
		end
		return true, { bundleId = id, parts = PARTS }
	end
	local now = 0
	local svc = ItemDetailService.new({
		api = api,
		bundles = bundles,
		toEnum = fakeEnum,
		clock = function()
			return now
		end,
	})
	return svc, state, function(dt: number)
		now += dt
	end
end

return function()
	Log.setSink(function() end)

	-- 1. aset: enum benar, cache
	do
		local svc, st = setup()
		local ok, d = svc:get(1, "Asset")
		eq(ok, true, "aset ok")
		eq(d.name, "Topi", "nama")
		eq(d.parts, nil, "aset tanpa parts")
		eq(st.bundles, 0, "aset tidak memanggil BundleService")
		local ok2, d2 = svc:get(1, "Asset")
		eq(ok2 and d2 == d, true, "hit cache")
		eq(st.api, 1, "API sekali")
	end

	-- 2. bundle: parts diisi; FAILED -> tanpa parts & tidak di-cache; NOT_FOUND -> di-cache
	do
		local svc, st = setup()
		local ok, d = svc:get(2, "Bundle")
		eq(ok, true, "bundle ok")
		eq(d.parts, PARTS, "parts dari BundleService")
		eq(d.bundleType, "BodyParts", "bundleType")

		st.bundleCode = "FAILED"
		local okF, dF = svc:get(3, "Bundle")
		eq(okF, true, "part gagal -> detail tetap")
		eq(dF.parts, nil, "tanpa parts")
		svc:get(3, "Bundle")
		eq(st.api, 3, "FAILED tidak di-cache")

		st.bundleCode = "NOT_FOUND"
		st.api = 0
		svc:get(3, "Bundle")
		svc:get(3, "Bundle")
		eq(st.api, 1, "NOT_FOUND part -> detail di-cache")
	end

	-- 3. gagal & tidak ditemukan
	do
		local svc, st, advance = setup()
		local ok, e = svc:get(404, "Asset")
		eq(ok, false, "tidak ada")
		eq(e.code, "NOT_FOUND", "kode NOT_FOUND")
		svc:get(404, "Asset")
		eq(st.api, 1, "miss di-cache")
		advance(61)
		svc:get(404, "Asset")
		eq(st.api, 2, "miss kedaluwarsa")

		eq(select(2, svc:get(4, "Asset")).code, "NOT_FOUND", "Id respons beda")
		eq(select(2, svc:get(5, "Asset")).code, "NOT_FOUND", "ItemType respons beda")

		st.apiFail = true
		local okF, eF = svc:get(1, "Asset")
		eq(okF, false, "API gagal")
		eq(eF.code, "FAILED", "kode FAILED")
		st.apiFail = false
		eq((svc:get(1, "Asset")), true, "FAILED tidak di-cache")
	end

	-- 4. argumen buruk (tanpa panggil API)
	do
		local svc, st = setup()
		eq(select(2, svc:get(0, "Asset")).code, "BAD_ARG", "id 0")
		eq(select(2, svc:get(1.5, "Asset")).code, "BAD_ARG", "id pecahan")
		eq(select(2, svc:get(2 ^ 54, "Asset")).code, "BAD_ARG", "id terlalu besar")
		eq(select(2, svc:get(1, "Emote")).code, "BAD_ARG", "itemType asing")
		eq(select(2, (svc.get :: any)(svc, 1, nil)).code, "BAD_ARG", "itemType nil")
		eq(st.api, 0, "API tidak dipanggil")
	end

	-- 5. Baris Recommended (#17d): API rekomendasi memberi ID, datanya dari getBatchItemDetails
	do
		local calls = { asset = 0, bundle = 0, batch = 0 }
		local recApi = {}
		function recApi.getRecommendedAssetIds(_self: any, assetType: any, contextId: number, limit: number?)
			calls.asset += 1
			eq(assetType, "AvatarAssetType.Hat", "assetType jadi Enum")
			eq(contextId, 1, "id item yang sedang dibuka")
			eq(limit, 10, "satu baris geser = 10 item")
			return true, { 7, 8, 9 }
		end
		function recApi.getRecommendedBundleIds(_self: any, bundleId: number, _limit: number?)
			calls.bundle += 1
			eq(bundleId, 2, "id bundle yang sedang dibuka")
			return true, { 21 }
		end
		function recApi.getBatchItemDetails(_self: any, ids: { number }, _itemType: any)
			calls.batch += 1
			local map: { [number]: any } = {}
			for _, id in ids do
				if id ~= 8 then -- 8 sengaja tidak dikembalikan API
					map[id] = { Id = id, ItemType = "Asset", AssetType = "Hat", Name = "R" .. id, Price = id }
				end
			end
			return true, map
		end
		function recApi.getItemDetails(_self: any, _id: number, _itemType: any)
			return false, { code = "NOT_FOUND", message = "x" }
		end
		local svc = ItemDetailService.new({ api = recApi, bundles = {}, toEnum = fakeEnum })

		local ok, items = svc:getRecommended(1, "Asset", "Hat")
		eq(ok, true, "rekomendasi aset ok")
		eq(#items, 2, "id yang tidak dikembalikan batch dibuang")
		eq(items[1].id, 7, "urutan rekomendasi dipertahankan")
		eq(items[2].id, 9, "urutan rekomendasi dipertahankan")
		eq(items[1].name, "R7", "DTO sama persis dengan kartu katalog")

		svc:getRecommended(1, "Asset", "Hat")
		eq(calls.asset, 1, "hasil rekomendasi di-cache")

		eq((svc:getRecommended(2, "Bundle")), true, "bundle lewat jalur GetRecommendedBundles")
		eq(calls.bundle, 1, "jalur bundle dipakai")

		eq(select(2, svc:getRecommended(1, "Asset")).code, "BAD_ARG", "aset tanpa assetType ditolak")
		eq(select(2, svc:getRecommended(0, "Asset", "Hat")).code, "BAD_ARG", "id tidak valid")
		eq(select(2, svc:getRecommended(1, "Emote", "Hat")).code, "BAD_ARG", "itemType asing")
	end

	Log.setSink(nil)
	print("PASS ItemDetailService.spec")
end
