--!strict
-- Test CatalogService dengan RobloxApi PALSU (tanpa internet, tanpa Studio).
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["CatalogService.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local CatalogService = require(ServerScriptService:WaitForChild("Server").Services.CatalogService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Log = require(Shared.Util.Log)
local Limits = require(Shared.Config.Limits)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

-- Enum palsu: kembalikan string "Enum.Nama" (Lune tidak punya Enum).
local function fakeEnum(enumName: string, itemName: string): any
	if itemName == "Hilang" then
		return nil
	end
	return enumName .. "." .. itemName
end

-- API palsu: `total` halaman, tiap halaman 2 item.
local function fakeApi(total: number)
	local api = { search = 0, next = 0, lastOpts = nil :: any, failNext = false }
	local function page(n: number)
		return {
			items = {
				{
					Id = n * 10 + 1,
					Name = "A" .. n,
					ItemType = "Asset",
					AssetType = "Hat",
					Price = 5,
					CreatorName = "Roblox",
				},
				{ Id = n * 10 + 2, Name = "B" .. n, ItemType = "Bundle", BundleType = "Shoes", LowestPrice = 7 },
				{ Name = "rusak tanpa Id" },
			},
			isFinished = n >= total,
			pages = n,
		}
	end
	function api.searchCatalog(self: any, opts: any)
		self.search += 1
		self.lastOpts = opts
		if self.failNext then
			self.failNext = false
			return false, { code = "FAILED", message = "HTTP 429" }
		end
		return true, page(1)
	end
	function api.nextPage(self: any, prev: any)
		self.next += 1
		if self.failNext then
			self.failNext = false
			return false, { code = "FAILED", message = "HTTP 429" }
		end
		return true, page(prev.pages + 1)
	end
	return api
end

return function()
	Log.setSink(function() end)

	-- 1. normalize: validasi input client
	local N = CatalogService.normalize
	assert(N(nil) == nil, "nil ditolak")
	assert(N({ categoryId = "tidak_ada" }) == nil, "kategori asing ditolak")
	assert(N({ categoryId = "hats", keyword = 5 }) == nil, "keyword angka ditolak")
	assert(N({ categoryId = "hats", keyword = string.rep("a", 51) }) == nil, "keyword > 50 ditolak")
	assert(N({ categoryId = "hats", sort = "Hacker" }) == nil, "sort asing ditolak")
	assert(N({ categoryId = "hats", page = 0 }) == nil, "page 0 ditolak")
	assert(N({ categoryId = "hats", page = 1.5 }) == nil, "page pecahan ditolak")
	assert(N({ categoryId = "hats", page = 21 }) == nil, "page > 20 ditolak")
	assert(N({ categoryId = "hats", page = 0 / 0 }) == nil, "page NaN ditolak")
	local r = N({ categoryId = "hats", keyword = "  cool\n hat  " }) :: any
	eq(r.keyword, "cool hat", "keyword dirapikan")
	eq(r.sort, "Relevance", "sort default")
	eq(r.page, 1, "page default")

	-- 2. halaman pertama + DTO + opsi ke API
	local api = fakeApi(3)
	local svc = CatalogService.new({ api = api, toEnum = fakeEnum })
	local res = svc:search({ categoryId = "tops", keyword = "Jacket" }) :: any
	assert(res.ok, "search ok")
	eq(#res.items, 2, "item rusak dibuang")
	eq(res.items[1].id, 11, "id dto")
	eq(res.items[1].assetType, "Hat", "assetType dto")
	eq(res.items[1].price, 5, "price dto")
	eq(res.items[2].bundleType, "Shoes", "bundleType dto")
	eq(res.items[2].price, 7, "LowestPrice sebagai cadangan")
	eq(res.hasMore, true, "masih ada halaman")
	eq(#api.lastOpts.assetTypes, 4, "tops = 4 tipe aset")
	eq(api.lastOpts.assetTypes[1], "AvatarAssetType.TShirtAccessory", "enum aset")
	eq(api.lastOpts.sortType, "CatalogSortType.Relevance", "enum sort")
	eq(api.lastOpts.keyword, "Jacket", "keyword diteruskan")
	eq(api.lastOpts.limit, 30, "limit halaman")

	-- 3. cache: permintaan sama (beda huruf) tidak memanggil API lagi
	svc:search({ categoryId = "tops", keyword = "jacket" })
	eq(api.search, 1, "hasil dari cache")

	-- 4. paging berurutan & lompat halaman
	res = svc:search({ categoryId = "tops", keyword = "jacket", page = 3 }) :: any
	eq(api.next, 2, "maju 2 halaman")
	eq(res.items[1].id, 31, "item halaman 3")
	eq(res.hasMore, false, "halaman terakhir")
	res = svc:search({ categoryId = "tops", keyword = "jacket", page = 2 }) :: any
	eq(api.next, 2, "halaman 2 dari cache")
	eq(res.items[1].id, 21, "item halaman 2")
	res = svc:search({ categoryId = "tops", keyword = "jacket", page = 5 }) :: any
	assert(res.ok and #res.items == 0 and res.hasMore == false, "lewat akhir -> kosong")
	eq(api.next, 2, "tidak memanggil API setelah habis")

	-- 5. bundle kategori & keyword kosong
	res = svc:search({ categoryId = "shoes" }) :: any
	assert(res.ok, "shoes ok")
	eq(api.lastOpts.bundleTypes[1], "BundleType.Shoes", "enum bundle")
	eq(api.lastOpts.keyword, nil, "keyword kosong tidak dikirim")

	-- 6. gagal di halaman pertama -> tidak di-cache, percobaan berikut memanggil API lagi
	api.failNext = true
	res = svc:search({ categoryId = "hair" }) :: any
	eq(res.ok, false, "gagal")
	eq(res.code, "FAILED", "kode FAILED")
	local before = api.search
	res = svc:search({ categoryId = "hair" }) :: any
	assert(res.ok, "percobaan ulang ok")
	eq(api.search, before + 1, "memanggil API lagi")

	-- 7. gagal di halaman berikut -> halaman 1 tetap tersimpan
	api.failNext = true
	res = svc:search({ categoryId = "hair", page = 2 }) :: any
	eq(res.ok, false, "halaman 2 gagal")
	before = api.search
	res = svc:search({ categoryId = "hair", page = 1 }) :: any
	assert(res.ok, "halaman 1 masih ada")
	eq(api.search, before, "halaman 1 dari cache")
	res = svc:search({ categoryId = "hair", page = 2 }) :: any
	assert(res.ok and res.items[1].id == 21, "halaman 2 berhasil diulang")

	-- 8. BAD_ARG tidak memanggil API
	before = api.search
	res = svc:search({ categoryId = "hats", page = -1 }) :: any
	eq(res.code, "BAD_ARG", "BAD_ARG")
	eq(api.search, before, "API tidak dipanggil")

	-- 9. TTL: setelah SearchCacheTTL, API dipanggil lagi
	local now = 0
	local api2 = fakeApi(1)
	local svc2 = CatalogService.new({
		api = api2,
		toEnum = fakeEnum,
		clock = function()
			return now
		end,
	})
	svc2:search({ categoryId = "hats" })
	now = Limits.SearchCacheTTL + 1
	svc2:search({ categoryId = "hats" })
	eq(api2.search, 2, "cache kedaluwarsa")

	-- 10. enum tidak ada -> FAILED, bukan crash
	local svc3 = CatalogService.new({
		api = fakeApi(1),
		toEnum = function(e: string, n: string)
			return if e == "CatalogSortType" then nil else fakeEnum(e, n)
		end,
	})
	res = svc3:search({ categoryId = "hats" }) :: any
	eq(res.code, "FAILED", "enum sort hilang")

	print("PASS CatalogService.spec")
end
