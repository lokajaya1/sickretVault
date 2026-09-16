--!strict
-- Test RobloxApi dengan service PALSU (tanpa internet, tanpa Studio).
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["RobloxApi.spec"])()  (butuh ServerScriptService -> jalankan dari server)
local ServerScriptService = game:GetService("ServerScriptService")
local RobloxApi = require(ServerScriptService:WaitForChild("Server").Gateways.RobloxApi)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Log = require(Shared.Util.Log)
local Limits = require(Shared.Config.Limits)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local ASSET = "Asset" -- pengganti Enum.AvatarItemType.Asset

return function()
	Log.setSink(function() end) -- bungkam log warn saat test

	local calls = { item = 0, batch = 0, bundle = 0, rules = 0, search = 0 }
	local batchSizes = {}
	local failNextItem = 0

	local fakeAes = {}
	function fakeAes.GetItemDetailsAsync(_, id: number, _t: any)
		calls.item += 1
		if id == 404 then
			error("HTTP 404 (Not Found)")
		end
		if failNextItem > 0 then
			failNextItem -= 1
			error("HTTP 429 (Too Many Requests)")
		end
		return { Id = id, Name = "Item " .. id }
	end
	function fakeAes.GetBatchItemDetailsAsync(_, ids: { number }, _t: any)
		calls.batch += 1
		table.insert(batchSizes, #ids)
		local out = {}
		for _, id in ids do
			if id ~= 999 then -- 999 = aset hilang, tidak dikembalikan
				table.insert(out, { Id = id, Name = "Item " .. id })
			end
		end
		return out
	end
	function fakeAes.GetAvatarRulesAsync(_)
		calls.rules += 1
		return { WearableAssetTypes = {} }
	end
	function fakeAes.SearchCatalogAsync(_, params: any)
		calls.search += 1
		local page = 1
		return {
			IsFinished = false,
			GetCurrentPage = function()
				return { { Id = page * 100, Keyword = params.SearchKeyword } }
			end,
			AdvanceToNextPageAsync = function(self)
				page += 1
				self.IsFinished = page >= 2
			end,
		}
	end
	local fakeAssets = {}
	function fakeAssets.GetBundleDetailsAsync(_, id: number)
		calls.bundle += 1
		return { Id = id, Items = {} }
	end

	local now = 0
	local api = RobloxApi.new({
		avatarEditorService = fakeAes,
		assetService = fakeAssets,
		players = {},
		retry = { sleep = function() end },
		clock = function()
			return now
		end,
		newSearchParams = function()
			return {}
		end,
	})

	-- 1. item + cache
	local ok, d = api:getItemDetails(5, ASSET)
	assert(ok and d.Id == 5, "item ok")
	api:getItemDetails(5, ASSET)
	eq(calls.item, 1, "item kedua dari cache")

	-- 2. retry error sementara (429) lalu berhasil
	failNextItem = 2
	ok = api:getItemDetails(6, ASSET)
	assert(ok, "berhasil setelah retry")
	eq(calls.item, 4, "3 percobaan untuk id 6")

	-- 3. error permanen (404) tidak diulang
	local before = calls.item
	local ok404, e = api:getItemDetails(404, ASSET)
	assert(not ok404, "404 gagal")
	eq(e.code, "NOT_FOUND", "kode 404")
	eq(calls.item - before, 1, "404 tidak di-retry")

	-- 4. argumen salah tidak memanggil API
	local okBad, eBad = api:getItemDetails(-1, ASSET)
	assert(not okBad and eBad.code == "BAD_ARG", "id negatif ditolak")
	eq(calls.item - before, 1, "BAD_ARG tanpa panggilan")

	-- 5. batch: dedupe, cache, potongan (sesuai Limits.ItemBatchSize), id hilang
	local size = Limits.ItemBatchSize
	local newCount = size * 2 + 20 -- 999 + id 1000.. -> pasti 3 potongan
	local ids = { 5, 5, 999 }
	for i = 1000, 1000 + newCount - 2 do
		table.insert(ids, i)
	end
	local lastId = 1000 + newCount - 2
	local okB, map = api:getBatchItemDetails(ids, ASSET)
	assert(okB, "batch ok")
	eq(map[5].Id, 5, "id 5 dari cache")
	eq(map[999], nil, "id hilang tidak ada")
	eq(map[lastId].Id, lastId, "id terakhir ada")
	eq(calls.batch, 3, "id baru -> 3 potongan")
	eq(batchSizes[1], size, "potongan pertama penuh")
	eq(batchSizes[3], 20, "potongan terakhir 20")
	for _, n in batchSizes do
		assert(n <= 100, "potongan melebihi batas API 100")
	end
	api:getBatchItemDetails({ 1000, lastId }, ASSET)
	eq(calls.batch, 3, "batch kedua dari cache")

	-- 6. bundle cache + TTL
	api:getBundleDetails(77)
	api:getBundleDetails(77)
	eq(calls.bundle, 1, "bundle dari cache")
	now = 3601
	api:getBundleDetails(77)
	eq(calls.bundle, 2, "bundle kedaluwarsa")

	-- 7. avatar rules cache
	api:getAvatarRules()
	api:getAvatarRules()
	eq(calls.rules, 1, "rules dari cache")

	-- 8. search + halaman berikut + validasi limit
	local okS, pg = api:searchCatalog({ keyword = "hat" })
	assert(okS, "search ok")
	eq(pg.items[1].Keyword, "hat", "keyword diteruskan")
	eq(pg.isFinished, false, "belum selesai")
	local okN, pg2 = api:nextPage(pg)
	assert(okN and pg2.items[1].Id == 200, "halaman 2")
	eq(pg2.isFinished, true, "selesai")
	local okL, eL = api:searchCatalog({ limit = 7 })
	assert(not okL and eL.code == "BAD_ARG", "limit 7 ditolak")
	eq(calls.search, 1, "limit salah tidak memanggil API")

	-- 9. klasifikasi error
	eq(RobloxApi.isPermanentError("HTTP 500 (Internal Server Error)"), false, "500 sementara")
	eq(RobloxApi.isPermanentError("Invalid bundle id"), true, "invalid permanen")
	eq(
		RobloxApi.isPermanentError("A maximum of 100 item details can be requested at once"),
		true,
		"batas batch permanen"
	)

	Log.setSink(nil)
	print("PASS RobloxApi.spec")
end
