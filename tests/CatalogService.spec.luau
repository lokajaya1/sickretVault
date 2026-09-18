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

	-- 1b. chip grup (baris kedua panel): groupId + filter
	assert(N({ filter = "free" }) == nil, "filter tanpa grup ditolak")
	assert(N({ groupId = "tidak_ada", filter = "free" }) == nil, "grup asing ditolak")
	assert(N({ groupId = "clothing", filter = "gratisan" }) == nil, "filter asing ditolak")
	local rg = N({ groupId = "clothing", filter = "free", categoryId = "hats" }) :: any
	eq(rg.groupId, "clothing", "grup disimpan")
	eq(rg.filter, "free", "filter disimpan")
	eq(rg.categoryId, nil, "filter grup mengalahkan categoryId")

	-- 2. halaman pertama + DTO + opsi ke API
	local api = fakeApi(3)
	local svc = CatalogService.new({ api = api, toEnum = fakeEnum })
	local res = svc:search({ categoryId = "layered", keyword = "Jacket" }) :: any
	assert(res.ok, "search ok")
	eq(#res.items, 2, "item rusak dibuang")
	eq(res.items[1].id, 11, "id dto")
	eq(res.items[1].assetType, "Hat", "assetType dto")
	eq(res.items[1].price, 5, "price dto")
	eq(res.items[2].bundleType, "Shoes", "bundleType dto")
	eq(res.items[2].price, 7, "LowestPrice sebagai cadangan")
	eq(res.hasMore, true, "masih ada halaman")
	eq(#api.lastOpts.assetTypes, 7, "layered = 7 tipe aset")
	eq(api.lastOpts.assetTypes[1], "AvatarAssetType.TShirtAccessory", "enum aset")
	eq(api.lastOpts.sortType, "CatalogSortType.MostFavorited", "banyak tipe -> MostFavorited")
	eq(api.lastOpts.keyword, "Jacket", "keyword diteruskan")
	eq(api.lastOpts.limit, 30, "limit halaman")

	-- 3. cache: permintaan sama (beda huruf) tidak memanggil API lagi
	svc:search({ categoryId = "layered", keyword = "jacket" })
	eq(api.search, 1, "hasil dari cache")

	-- 4. paging berurutan & lompat halaman
	res = svc:search({ categoryId = "layered", keyword = "jacket", page = 3 }) :: any
	eq(api.next, 2, "maju 2 halaman")
	eq(res.items[1].id, 31, "item halaman 3")
	eq(res.hasMore, false, "halaman terakhir")
	res = svc:search({ categoryId = "layered", keyword = "jacket", page = 2 }) :: any
	eq(api.next, 2, "halaman 2 dari cache")
	eq(res.items[1].id, 21, "item halaman 2")
	res = svc:search({ categoryId = "layered", keyword = "jacket", page = 5 }) :: any
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

	-- 7a2. field harga item limited diteruskan apa adanya (spike ItemPrice.studio)
	local priceApi = { search = 0, next = 0, lastOpts = nil :: any }
	function priceApi.searchCatalog(self: any, opts: any)
		self.search += 1
		self.lastOpts = opts
		return true,
			{
				items = {
					{
						Id = 1,
						Name = "Limited laku",
						ItemType = "Asset",
						AssetType = "Hat",
						Price = 95,
						LowestResalePrice = 105,
						HasResellers = true,
						ItemRestrictions = { "Collectible" },
						UnitsAvailableForConsumption = 12,
					},
					{
						Id = 2,
						Name = "Limited tanpa penjual",
						ItemType = "Asset",
						AssetType = "Hat",
						Price = 0,
						LowestResalePrice = 700,
						HasResellers = false,
						ItemRestrictions = { "Collectible" },
						PriceStatus = "No Resellers",
					},
					{ Id = 3, Name = "Biasa", ItemType = "Asset", AssetType = "Hat", Price = 50 },
				},
				isFinished = true,
				pages = 1,
			}
	end
	function priceApi.nextPage(_self: any, _prev: any)
		return true, { items = {}, isFinished = true, pages = 2 }
	end
	local psvc = CatalogService.new({ api = priceApi, toEnum = fakeEnum })
	local pres = psvc:search({ categoryId = "hats" }) :: any
	assert(pres.ok, "search harga ok")
	eq(pres.items[1].limited, true, "ItemRestrictions Collectible -> limited")
	eq(pres.items[1].resalePrice, 105, "harga pasar dipakai bila ada penjual ulang")
	eq(pres.items[1].unitsLeft, 12, "sisa stok limited")
	eq(pres.items[2].resalePrice, nil, "tanpa penjual ulang -> harga pasar diabaikan")
	eq(pres.items[2].priceStatus, "No Resellers", "status harga diteruskan apa adanya")
	eq(pres.items[3].limited, nil, "item biasa tidak ditandai limited")
	eq(pres.items[3].price, 50, "harga penerbit item biasa")

	-- 7b. chip "all": semua tipe grup + sort MostFavorited (hasil spike: Relevance -> daftar gratis)
	local capi = fakeApi(2)
	local csvc = CatalogService.new({ api = capi, toEnum = fakeEnum })
	local cres = csvc:search({ groupId = "clothing", filter = "all" }) :: any
	assert(cres.ok, "chip all ok")
	eq(#capi.lastOpts.assetTypes, 10, "CLOTHING: 10 tipe aset digabung (tanpa duplikat)")
	eq(capi.lastOpts.bundleTypes, nil, "aset & bundle tidak dicampur")
	eq(capi.lastOpts.sortType, "CatalogSortType.MostFavorited", "chip grup pakai MostFavorited")
	eq(capi.lastOpts.maxPrice, nil, "chip all tanpa batas harga")

	-- 7b2. kategori bertipe banyak ikut MostFavorited; kategori satu tipe tetap Relevance
	csvc:search({ categoryId = "layered" })
	eq(capi.lastOpts.sortType, "CatalogSortType.MostFavorited", "kategori Layered (7 tipe)")
	csvc:search({ categoryId = "hats" })
	eq(capi.lastOpts.sortType, "CatalogSortType.Relevance", "kategori satu tipe tetap Relevance")

	-- 7c. chip "free" -> MaxPrice 0; chip "limited" -> SalesTypeFilter.Collectibles
	csvc:search({ groupId = "clothing", filter = "free" })
	eq(capi.lastOpts.maxPrice, 0, "chip free: MaxPrice 0")
	csvc:search({ groupId = "clothing", filter = "limited" })
	eq(capi.lastOpts.salesTypeFilter, "SalesTypeFilter.Collectibles", "chip limited")
	eq(capi.search, 5, "tiap chip & kategori punya cache sendiri")

	-- 7d. grup FEATURED: CategoryFilter, tanpa daftar tipe
	csvc:search({ groupId = "featured", filter = "all" })
	eq(capi.lastOpts.categoryFilter, "CatalogCategoryFilter.Featured", "FEATURED pakai CategoryFilter")
	eq(capi.lastOpts.assetTypes, nil, "FEATURED tidak mengirim daftar tipe")

	-- 7e. sort pilihan pemain tetap dihormati (hanya Relevance yang diganti)
	csvc:search({ groupId = "clothing", filter = "all", sort = "RecentlyCreated" })
	eq(capi.lastOpts.sortType, "CatalogSortType.RecentlyCreated", "sort pemain dipakai apa adanya")

	-- 7f. item yang tidak bisa dipakai avatar (Gear) disaring, halaman tidak dianggap habis
	local gearApi = { search = 0, next = 0, lastOpts = nil :: any }
	function gearApi.searchCatalog(self: any, opts: any)
		self.search += 1
		self.lastOpts = opts
		return true,
			{
				items = {
					{ Id = 1, Name = "Gear", ItemType = "Asset", AssetType = "Gear", Price = 10 },
					{ Id = 2, Name = "Topi", ItemType = "Asset", AssetType = "Hat", Price = 10 },
				},
				isFinished = false,
				pages = 1,
			}
	end
	function gearApi.nextPage(self: any, _prev: any)
		self.next += 1
		return true,
			{
				items = { { Id = 3, Name = "Gear2", ItemType = "Asset", AssetType = "Gear", Price = 10 } },
				isFinished = true,
				pages = 2,
			}
	end
	local gsvc = CatalogService.new({ api = gearApi, toEnum = fakeEnum })
	local gres = gsvc:search({ groupId = "featured", filter = "all" }) :: any
	assert(gres.ok, "halaman dengan Gear tetap ok")
	eq(#gres.items, 1, "Gear dibuang dari hasil")
	eq(gres.items[1].name, "Topi", "sisanya item biasa")
	local gres2 = gsvc:search({ groupId = "featured", filter = "all", page = 2 }) :: any
	assert(gres2.ok, "halaman 2 ok")
	eq(gres2.hasMore, false, "halaman berisi Gear saja -> habis, tanpa halaman kosong")

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

	-- 11. Klik nama creator (#17d): boleh TANPA kategori, nama & tipe diteruskan ke API
	local crApi = fakeApi(1)
	local crSvc = CatalogService.new({ api = crApi, toEnum = fakeEnum })
	res = crSvc:search({ creatorName = "  94E  ", creatorType = "Group" }) :: any
	assert(res.ok, "pencarian creator tanpa kategori ok")
	eq(crApi.lastOpts.creatorName, "94E", "spasi di ujung nama creator dibuang")
	eq(crApi.lastOpts.creatorType, "CreatorTypeFilter.Group", "creatorType jadi Enum")
	eq(crApi.lastOpts.assetTypes, nil, "tanpa kategori -> tanpa saringan tipe")

	before = crApi.search
	crSvc:search({ creatorName = "94E", creatorType = "Group" })
	eq(crApi.search, before, "creator yang sama dilayani cache")
	crSvc:search({ creatorName = "94E", creatorType = "User" })
	eq(crApi.search, before + 1, "creatorType berbeda -> kunci cache berbeda")
	crSvc:search({ categoryId = "hats", creatorName = "94E" })
	eq(crApi.lastOpts.assetTypes ~= nil, true, "creator + kategori tetap menyaring tipe")

	-- 12. Tolakan jalur creator
	eq((crSvc:search({ creatorType = "Group" }) :: any).code, "BAD_ARG", "creatorType tanpa nama ditolak")
	eq((crSvc:search({ creatorName = "94E", creatorType = "Klan" }) :: any).code, "BAD_ARG", "creatorType ngawur")
	eq((crSvc:search({ creatorName = "   " }) :: any).code, "BAD_ARG", "nama creator kosong")
	eq((crSvc:search({}) :: any).code, "BAD_ARG", "tanpa kategori & tanpa creator ditolak")

	-- 13. Stok limited: units 0 = SOLD OUT (jangan dibuang), TotalQuantity ikut, CreatorType diteruskan
	local stockApi = fakeApi(1)
	function stockApi.searchCatalog(self: any, opts: any)
		self.search += 1
		self.lastOpts = opts
		return true,
			{
				items = {
					{
						Id = 1,
						Name = "Habis terjual",
						ItemType = "Asset",
						AssetType = "Hat",
						Price = 95,
						CreatorName = "USTA",
						CreatorType = "Group",
						ItemRestrictions = { "Collectible" },
						UnitsAvailableForConsumption = 0,
						TotalQuantity = 27999,
					},
					{
						Id = 2,
						Name = "Biasa",
						ItemType = "Asset",
						AssetType = "Hat",
						Price = 50,
						UnitsAvailableForConsumption = 0,
						TotalQuantity = 0,
					},
				},
				isFinished = true,
				pages = 1,
			}
	end
	local sres = CatalogService.new({ api = stockApi, toEnum = fakeEnum }):search({ categoryId = "hats" }) :: any
	assert(sres.ok, "pencarian stok ok")
	eq(sres.items[1].unitsLeft, 0, "limited habis -> unitsLeft 0, BUKAN nil")
	eq(sres.items[1].totalQuantity, 27999, "stok awal ikut")
	eq(sres.items[1].creatorType, "Group", "creatorType diteruskan ke kartu")
	eq(sres.items[2].unitsLeft, nil, "item biasa tidak punya sisa stok")
	eq(sres.items[2].totalQuantity, nil, "item biasa tidak punya stok awal")

	-- 14. Panel "Search Options" (#17e): validasi angka harga & sakelar off-sale
	assert(N({ categoryId = "hats", minPrice = -1 }) == nil, "minPrice negatif ditolak")
	assert(N({ categoryId = "hats", minPrice = 1.5 }) == nil, "minPrice pecahan ditolak")
	assert(N({ categoryId = "hats", minPrice = 0 / 0 }) == nil, "minPrice NaN ditolak")
	assert(N({ categoryId = "hats", maxPrice = "100" }) == nil, "maxPrice string ditolak")
	assert(N({ categoryId = "hats", maxPrice = 1000001 }) == nil, "maxPrice di atas batas ditolak")
	assert(N({ categoryId = "hats", includeOffSale = "ya" }) == nil, "includeOffSale bukan boolean ditolak")
	-- Rentang terbalik DITUKAR, bukan diteruskan: SearchCatalogAsync membalas HTTP 400
	-- (spike 19 Sep 2026 tes 21).
	local rp = N({ categoryId = "hats", minPrice = 200, maxPrice = 100 }) :: any
	eq(rp.minPrice, 100, "rentang terbalik: min jadi yang kecil")
	eq(rp.maxPrice, 200, "rentang terbalik: max jadi yang besar")
	eq((N({ categoryId = "hats", minPrice = 0, maxPrice = 0 }) :: any).minPrice, 0, "minPrice 0 sah")

	-- 14b. opsi diteruskan ke API, dan tiap kombinasi punya kunci cache sendiri
	local optApi = fakeApi(1)
	local optSvc = CatalogService.new({ api = optApi, toEnum = fakeEnum })
	optSvc:search({ categoryId = "hats", minPrice = 100, maxPrice = 500, includeOffSale = true })
	eq(optApi.lastOpts.minPrice, 100, "minPrice diteruskan ke API")
	eq(optApi.lastOpts.maxPrice, 500, "maxPrice diteruskan ke API")
	eq(optApi.lastOpts.includeOffSale, true, "includeOffSale diteruskan ke API")
	local optBefore = optApi.search
	optSvc:search({ categoryId = "hats", minPrice = 100, maxPrice = 500, includeOffSale = true })
	eq(optApi.search, optBefore, "rentang yang sama dilayani cache")
	optSvc:search({ categoryId = "hats", minPrice = 100, maxPrice = 400, includeOffSale = true })
	eq(optApi.search, optBefore + 1, "rentang berbeda -> kunci cache berbeda")
	optSvc:search({ categoryId = "hats", minPrice = 100, maxPrice = 500 })
	eq(optApi.search, optBefore + 2, "off-sale berbeda -> kunci cache berbeda")
	optSvc:search({ categoryId = "hats" })
	eq(optApi.lastOpts.minPrice, nil, "tanpa rentang, API tidak dikirimi batas harga")

	-- 14c. toDto: harga sentinel & penanda off-sale (spike 19 Sep 2026 putaran 5b)
	local oddApi = fakeApi(1)
	function oddApi.searchCatalog(self: any, opts: any)
		self.search += 1
		self.lastOpts = opts
		return true,
			{
				items = {
					{ Id = 1, Name = "Tak tersedia", ItemType = "Asset", AssetType = "Hat", Price = 999999999 },
					{
						Id = 2,
						Name = "Ditarik",
						ItemType = "Asset",
						AssetType = "Hat",
						Price = 0,
						IsOffSale = true,
						PriceStatus = "Off Sale",
					},
					{ Id = 3, Name = "Gratis sungguhan", ItemType = "Asset", AssetType = "Hat", Price = 0 },
				},
				isFinished = true,
				pages = 1,
			}
	end
	local oddSvc = CatalogService.new({ api = oddApi, toEnum = fakeEnum })
	local ores = oddSvc:search({ categoryId = "hats" }) :: any
	assert(ores.ok, "pencarian harga aneh ok")
	eq(ores.items[1].price, nil, "999999999 bukan harga -> price nil")
	eq(ores.items[2].price, 0, "off-sale: angka mentahnya tetap 0")
	eq(ores.items[2].offSale, true, "IsOffSale -> offSale")
	eq(ores.items[2].priceStatus, "Off Sale", "status harga ikut")
	eq(ores.items[3].offSale, nil, "gratis sungguhan TIDAK ditandai off-sale")
	eq(ores.items[3].price, 0, "gratis sungguhan tetap berharga 0")

	-- 14d. Janji rentang ditegakkan DI SINI: MinPrice API meleset ~10% (minta 100, dapat 90)
	local leakApi = fakeApi(1)
	function leakApi.searchCatalog(self: any, opts: any)
		self.search += 1
		self.lastOpts = opts
		return true,
			{
				items = {
					{ Id = 1, Name = "Bocor 90", ItemType = "Asset", AssetType = "Hat", Price = 90 },
					{ Id = 2, Name = "Pas 150", ItemType = "Asset", AssetType = "Hat", Price = 150 },
					{ Id = 3, Name = "Terlalu mahal", ItemType = "Asset", AssetType = "Hat", Price = 900 },
					{ Id = 4, Name = "Tak tersedia", ItemType = "Asset", AssetType = "Hat", Price = 999999999 },
				},
				isFinished = true,
				pages = 1,
			}
	end
	local leakSvc = CatalogService.new({ api = leakApi, toEnum = fakeEnum })
	local lres = leakSvc:search({ categoryId = "hats", minPrice = 100, maxPrice = 500 }) :: any
	assert(lres.ok, "pencarian rentang ok")
	eq(#lres.items, 1, "yang di luar rentang dibuang di sini, bukan dipercayakan ke API")
	eq(lres.items[1].id, 2, "hanya item 150 yang lolos")
	local lall = leakSvc:search({ categoryId = "hats" }) :: any
	eq(#lall.items, 4, "tanpa rentang, tidak ada yang disaring harga")

	-- 14e. Halaman pertama yang habis tersaring BUKAN berarti "tidak ada hasil"
	local lateApi = { search = 0, next = 0, lastOpts = nil :: any }
	function lateApi.searchCatalog(self: any, opts: any)
		self.search += 1
		self.lastOpts = opts
		return true,
			{
				items = { { Id = 1, Name = "Murah", ItemType = "Asset", AssetType = "Hat", Price = 5 } },
				isFinished = false,
				pages = 1,
			}
	end
	function lateApi.nextPage(self: any, _prev: any)
		self.next += 1
		return true,
			{
				items = { { Id = 2, Name = "Pas", ItemType = "Asset", AssetType = "Hat", Price = 150 } },
				isFinished = true,
				pages = 2,
			}
	end
	local lateSvc = CatalogService.new({ api = lateApi, toEnum = fakeEnum })
	local late = lateSvc:search({ categoryId = "hats", minPrice = 100 }) :: any
	assert(late.ok, "halaman 1 habis tersaring tetap ok")
	eq(#late.items, 1, "hasil dari halaman berikutnya tetap sampai ke pemain")
	eq(late.items[1].id, 2, "item 150 yang lolos")

	-- 14f. Penjaga 429: saringan ketat tidak boleh merayapi katalog tanpa batas
	local endlessApi = { search = 0, next = 0, lastOpts = nil :: any }
	function endlessApi.searchCatalog(self: any, opts: any)
		self.search += 1
		self.lastOpts = opts
		return true,
			{
				items = { { Id = 1, Name = "Murah", ItemType = "Asset", AssetType = "Hat", Price = 5 } },
				isFinished = false,
				pages = 1,
			}
	end
	function endlessApi.nextPage(self: any, prev: any)
		self.next += 1
		return true,
			{
				items = { { Id = 99, Name = "Murah", ItemType = "Asset", AssetType = "Hat", Price = 5 } },
				isFinished = false,
				pages = prev.pages + 1,
			}
	end
	local endlessSvc = CatalogService.new({ api = endlessApi, toEnum = fakeEnum })
	local eres = endlessSvc:search({ categoryId = "hats", minPrice = 100 }) :: any
	assert(eres.ok, "katalog yang selalu tersaring tetap menjawab")
	eq(#eres.items, 0, "jujur: tidak ada yang cocok")
	eq(eres.hasMore, false, "tidak menjanjikan halaman berikutnya")
	eq(endlessApi.next, 2, "berhenti setelah 3 halaman kosong berturut-turut")

	print("PASS CatalogService.spec")
end
