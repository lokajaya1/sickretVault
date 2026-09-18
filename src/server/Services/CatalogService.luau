--!strict
-- Layanan katalog: validasi permintaan client -> RobloxApi.searchCatalog/nextPage,
-- cache hasil per halaman (dibagi antar pemain), ringkas item jadi DTO kecil.
--   local catalog = CatalogService.new({ api = api })
--   local res = catalog:search({ categoryId = "hats", keyword = "", sort = "Relevance", page = 1 })
--   local res = catalog:search({ groupId = "clothing", filter = "free", page = 1 })  -- chip baris kedua
--   local res = catalog:search({ creatorName = "94E", creatorType = "Group" })       -- klik nama creator
-- Pencarian creator boleh TANPA kategori/grup (semua tipe); spike 19 Sep 2026: nama ngawur -> 0 item,
-- bukan daftar item gratis bawaan seperti penyakit multi-tipe + Relevance di #17b.
-- Chip grup (Config/CatalogMenu.FILTERS): "all" (semua tipe grup), "free" (MaxPrice 0),
-- "limited" (SalesTypeFilter.Collectibles). Grup dengan categoryFilter (FEATURED) memakai
-- CatalogCategoryFilter dan TIDAK mengirim daftar tipe.
--   res = { ok = true, items = { ItemDto }, page = 1, hasMore = true }
--       | { ok = false, code = "BAD_ARG" | "FAILED", message = string }
-- Tidak memanggil API Roblox langsung (lewat `api`). `toEnum` bisa diganti saat test (Lune tanpa Enum).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Categories = require(Shared.Config.Categories)
local CatalogMenu = require(Shared.Config.CatalogMenu)
local Limits = require(Shared.Config.Limits)
local Cache = require(Shared.Util.Cache)
local Log = require(Shared.Util.Log)

local log = Log.new("CatalogService")

local PAGE_LIMIT = 30 -- item per halaman (nilai valid RobloxApi: 10/28/30/60/120)
local MAX_PAGE = 20 -- cegah client merayapi katalog terlalu dalam
local MAX_KEYWORD = 50
local MAX_CREATOR = 50
local CACHE_SIZE = 300 -- jumlah kombinasi (kategori+keyword+sort) yang disimpan
local BUSY_TIMEOUT = 15 -- detik menunggu permintaan lain pada kunci yang sama
-- Spike Studio 18 Sep 2026 (tests/CatalogFilter.studio): SearchCatalogAsync dengan BANYAK AssetTypes
-- + sort Relevance/Bestselling mengembalikan daftar item gratis bawaan Roblox. MostFavorited &
-- RecentlyCreated tetap memberi hasil wajar -> chip grup memakai MostFavorited.
local FILTER_SORT = "MostFavorited"
-- Item yang tidak bisa dipakai di avatar (muncul di CategoryFilter.Featured).
local BLOCKED_ASSET_TYPES: { [string]: boolean } = { Gear = true }
-- Nilai ItemRestrictions yang berarti "terbatas" (pita LIMITED + harga resale).
local LIMITED_RESTRICTIONS: { [string]: boolean } = {
	Collectible = true,
	Limited = true,
	LimitedUnique = true,
}

-- Urutan yang diizinkan (nama Enum.CatalogSortType).
local SORTS: { [string]: boolean } = {
	Relevance = true,
	PriceLowToHigh = true,
	PriceHighToLow = true,
	MostFavorited = true,
	RecentlyCreated = true,
}

export type Request = {
	categoryId: string?, -- salah satu: kategori tunggal ...
	groupId: string?, -- ... atau grup mozaik + chip filter
	filter: string?, -- "all" | "free" | "limited" (butuh groupId)
	keyword: string?,
	sort: string?,
	creatorName: string?, -- pencarian per pencipta (nama creator diklik)
	creatorType: string?, -- "User" | "Group"; butuh creatorName
	page: number?,
}

-- Harga (spike 18 Sep 2026, tests/ItemPrice.studio): SearchCatalogAsync SUDAH memberi angka yang
-- sama dengan GetItemDetailsAsync -> tidak perlu panggilan detail tambahan hanya untuk harga.
--   Price/LowestPrice    : harga jual penerbit (0 = gratis / tidak dijual lagi)
--   LowestResalePrice    : harga pasar item limited, hanya berarti bila HasResellers = true
--   ItemRestrictions     : { "Collectible", "Limited", "LimitedUnique", ... } -> pita LIMITED
--   PriceStatus          : "Free" | "No Resellers" | ... (teks dari Roblox)
--   UnitsAvailableForConsumption : sisa stok limited (0 = SOLD OUT, bukan 'tidak ada data')
--   TotalQuantity                : stok awal limited (spike 19 Sep 2026: mis. 28029 dari 64000)
export type ItemDto = {
	id: number,
	itemType: string, -- "Asset" | "Bundle"
	assetType: string?,
	bundleType: string?,
	name: string,
	creatorName: string?,
	creatorType: string?, -- "User" | "Group"; dipakai saat nama creator diklik
	price: number?, -- harga penerbit; nil = tidak dijual
	resalePrice: number?, -- harga pasar (limited yang punya penjual ulang)
	limited: boolean?, -- true = item terbatas (pita LIMITED di kartu)
	priceStatus: string?, -- mis. "Free", "No Resellers" (apa adanya dari Roblox)
	unitsLeft: number?, -- sisa stok limited; 0 = habis terjual
	totalQuantity: number?, -- stok awal limited
}

export type Response = {
	ok: boolean,
	items: { ItemDto }?,
	page: number?,
	hasMore: boolean?,
	code: string?,
	message: string?,
}

export type Deps = {
	api: any, -- RobloxApi
	toEnum: ((enumName: string, itemName: string) -> any)?,
	clock: (() -> number)?,
	wait: ((number) -> ())?,
}

type Entry = {
	pages: { { ItemDto } },
	cursor: any?, -- SearchPage terakhir (punya CatalogPages hidup)
	finished: boolean,
	busy: boolean,
}

local CatalogService = {}
CatalogService.__index = CatalogService

export type CatalogService = typeof(setmetatable(
	{} :: {
		_api: any,
		_toEnum: (string, string) -> any,
		_clock: () -> number,
		_wait: (number) -> (),
		_cache: Cache.Cache,
	},
	CatalogService
))

local function defaultToEnum(enumName: string, itemName: string): any
	local ok, item = pcall(function()
		return (Enum :: any)[enumName][itemName]
	end)
	return if ok then item else nil
end

function CatalogService.new(deps: Deps): CatalogService
	assert(deps and deps.api, "CatalogService butuh deps.api")
	local clock = deps.clock or os.clock
	return setmetatable({
		_api = deps.api,
		_toEnum = deps.toEnum or defaultToEnum,
		_clock = clock,
		_wait = deps.wait or function(s: number)
			task.wait(s)
		end,
		_cache = Cache.new({ ttl = Limits.SearchCacheTTL, maxSize = CACHE_SIZE, clock = clock }),
	}, CatalogService)
end

local function fail(code: string, message: string): Response
	return { ok = false, code = code, message = message }
end

local function toDto(raw: any): ItemDto?
	if type(raw) ~= "table" or type(raw.Id) ~= "number" then
		return nil
	end
	local price = raw.Price
	if type(price) ~= "number" then
		price = if type(raw.LowestPrice) == "number" then raw.LowestPrice else nil
	end

	local limited = false
	if type(raw.ItemRestrictions) == "table" then
		for _, r in raw.ItemRestrictions do
			if LIMITED_RESTRICTIONS[tostring(r)] then
				limited = true
			end
		end
	end
	-- Harga pasar hanya dipercaya kalau Roblox bilang ada penjual ulang.
	local resale: number? = nil
	if raw.HasResellers == true and type(raw.LowestResalePrice) == "number" and raw.LowestResalePrice > 0 then
		resale = raw.LowestResalePrice
	end
	-- Spike 19 Sep 2026: units = 0 dengan TotalQuantity besar berarti SOLD OUT — itu informasi,
	-- bukan ketiadaan data. Karena itu 0 TIDAK dibuang (aturan `> 0` di #17c salah).
	local units: number? = nil
	local total: number? = nil
	if limited then
		if type(raw.UnitsAvailableForConsumption) == "number" and raw.UnitsAvailableForConsumption >= 0 then
			units = raw.UnitsAvailableForConsumption
		end
		if type(raw.TotalQuantity) == "number" and raw.TotalQuantity > 0 then
			total = raw.TotalQuantity
		end
	end
	if type(raw.AssetType) == "string" and BLOCKED_ASSET_TYPES[raw.AssetType] then
		return nil -- mis. Gear dari CategoryFilter.Featured: tidak bisa dipakai avatar
	end
	return {
		id = raw.Id,
		itemType = if type(raw.ItemType) == "string" then raw.ItemType else "Asset",
		assetType = if type(raw.AssetType) == "string" then raw.AssetType else nil,
		bundleType = if type(raw.BundleType) == "string" then raw.BundleType else nil,
		name = if type(raw.Name) == "string" then raw.Name else "",
		creatorName = if type(raw.CreatorName) == "string" then raw.CreatorName else nil,
		creatorType = if type(raw.CreatorType) == "string" then raw.CreatorType else nil,
		price = price,
		resalePrice = resale,
		limited = if limited then true else nil,
		priceStatus = if type(raw.PriceStatus) == "string" then raw.PriceStatus else nil,
		unitsLeft = units,
		totalQuantity = total,
	}
end

local function toDtos(items: { any }): { ItemDto }
	local out = {}
	for _, raw in items do
		local dto = toDto(raw)
		if dto then
			table.insert(out, dto)
		end
	end
	return out
end

-- Validasi + normalisasi permintaan mentah dari client.
-- Mengembalikan (req bersih, nil) atau (nil, pesan).
function CatalogService.normalize(raw: any): (Request?, string?)
	if type(raw) ~= "table" then
		return nil, "permintaan harus tabel"
	end
	local creatorName = raw.creatorName
	if creatorName ~= nil then
		if type(creatorName) ~= "string" then
			return nil, "creatorName harus string"
		end
		creatorName = string.gsub(creatorName, "%c", "")
		creatorName = string.match(creatorName, "^%s*(.-)%s*$") or ""
		if creatorName == "" or utf8.len(creatorName) == nil or #creatorName > MAX_CREATOR then
			return nil, "creatorName tidak valid"
		end
	end
	local creatorType = raw.creatorType
	if creatorType ~= nil then
		if creatorName == nil then
			return nil, "creatorType butuh creatorName"
		end
		if creatorType ~= "User" and creatorType ~= "Group" then
			return nil, "creatorType tidak dikenal"
		end
	end
	local categoryId, groupId, filter = raw.categoryId, raw.groupId, raw.filter
	if filter ~= nil then
		if type(filter) ~= "string" or not CatalogMenu.isFilter(filter) then
			return nil, "filter tidak dikenal"
		end
		if type(groupId) ~= "string" or CatalogMenu.byId[groupId] == nil then
			return nil, "grup tidak dikenal"
		end
		categoryId = nil
	elseif categoryId ~= nil or creatorName == nil then
		groupId = nil
		if type(categoryId) ~= "string" or Categories.byId[categoryId] == nil then
			return nil, "kategori tidak dikenal"
		end
	else
		groupId = nil -- pencarian per creator tanpa kategori: semua tipe
	end
	local keyword = raw.keyword
	if keyword == nil then
		keyword = ""
	end
	if type(keyword) ~= "string" then
		return nil, "keyword harus string"
	end
	keyword = string.gsub(keyword, "%c", "") -- buang karakter kontrol
	keyword = string.match(keyword, "^%s*(.-)%s*$") or ""
	if utf8.len(keyword) == nil or #keyword > MAX_KEYWORD then
		return nil, "keyword tidak valid"
	end
	local sort = raw.sort
	if sort == nil then
		sort = "Relevance"
	end
	if type(sort) ~= "string" or not SORTS[sort] then
		return nil, "sort tidak valid"
	end
	local page = raw.page
	if page == nil then
		page = 1
	end
	if type(page) ~= "number" or page ~= page or page % 1 ~= 0 or page < 1 or page > MAX_PAGE then
		return nil, "page tidak valid"
	end
	return {
		categoryId = categoryId,
		groupId = groupId,
		filter = filter,
		keyword = keyword,
		sort = sort,
		creatorName = creatorName,
		creatorType = creatorType,
		page = page,
	},
		nil
end

local function cacheKey(req: Request): string
	local what = if req.filter
		then ("g:%s:%s"):format(req.groupId or "?", req.filter)
		else ("c:%s"):format(req.categoryId or "?")
	local creator = if req.creatorName
		then ("|%s:%s"):format(string.lower(req.creatorName), req.creatorType or "*")
		else ""
	return ("%s|%s|%s%s"):format(what, string.lower(req.keyword or ""), req.sort or "Relevance", creator)
end

local function enumList(self: CatalogService, enumName: string, names: { string }?): ({ any }?, string?)
	if names == nil then
		return nil, nil
	end
	local out = {}
	for _, name in names do
		local item = self._toEnum(enumName, name)
		if item == nil then
			return nil, ("%s.%s tidak ada"):format(enumName, name)
		end
		table.insert(out, item)
	end
	return out, nil
end

-- Opsi pencarian untuk chip filter satu grup (all / free / limited).
local function groupOptions(self: CatalogService, req: Request): (any?, string?)
	local group = CatalogMenu.byId[req.groupId :: string]
	local opts: any = { limit = PAGE_LIMIT }
	if group.categoryFilter then
		-- FEATURED: biar Roblox yang memilih; daftar tipe TIDAK dikirim (semua kategori = hasil buruk).
		local cf = self._toEnum("CatalogCategoryFilter", group.categoryFilter)
		if cf == nil then
			return nil, "CatalogCategoryFilter." .. group.categoryFilter .. " tidak ada"
		end
		opts.categoryFilter = cf
	else
		local assetNames, bundleNames = CatalogMenu.searchTypes(group)
		local assetTypes, e1 = enumList(self, "AvatarAssetType", if #assetNames > 0 then assetNames else nil)
		local bundleTypes, e2 = enumList(self, "BundleType", if #bundleNames > 0 then bundleNames else nil)
		if e1 or e2 then
			return nil, e1 or e2
		end
		opts.assetTypes = assetTypes
		opts.bundleTypes = bundleTypes
	end
	if req.filter == "free" then
		opts.maxPrice = 0
	elseif req.filter == "limited" then
		local sales = self._toEnum("SalesTypeFilter", "Collectibles")
		if sales == nil then
			return nil, "SalesTypeFilter.Collectibles tidak ada"
		end
		opts.salesTypeFilter = sales
	end
	return opts, nil
end

-- Halaman pertama: bangun opsi dari Categories (kategori) atau CatalogMenu (chip grup).
local function firstPage(self: CatalogService, req: Request): (boolean, any)
	local opts: any
	if req.filter then
		local built, err = groupOptions(self, req)
		if built == nil then
			return false, { code = "FAILED", message = err or "opsi grup gagal" }
		end
		opts = built
	elseif req.categoryId then
		local cat = Categories.byId[req.categoryId]
		local assetTypes, e1 = enumList(self, "AvatarAssetType", cat.assetTypes)
		local bundleTypes, e2 = enumList(self, "BundleType", cat.bundleTypes)
		if e1 or e2 then
			return false, { code = "FAILED", message = e1 or e2 }
		end
		opts = { limit = PAGE_LIMIT, assetTypes = assetTypes, bundleTypes = bundleTypes }
	else
		opts = { limit = PAGE_LIMIT } -- pencarian per creator: semua tipe
	end
	if req.creatorName then
		opts.creatorName = req.creatorName
		if req.creatorType then
			-- Studio 19 Sep 2026: CatalogSearchParams.CreatorType menerima Enum.CreatorTypeFilter,
			-- BUKAN Enum.CreatorType ("Invalid type 'CreatorType' for enum 'CreatorTypeFilter'").
			-- Enumnya tidak ada -> tetap cari dengan NAMA saja, jangan gagalkan seluruh pencarian.
			local ct = self._toEnum("CreatorTypeFilter", req.creatorType)
			if ct ~= nil then
				opts.creatorType = ct
			else
				log.warn("CreatorTypeFilter", req.creatorType, "tidak ada; cari dengan nama saja")
			end
		end
	end
	-- Banyak tipe sekaligus + Relevance -> daftar item gratis bawaan Roblox (spike 18 Sep 2026).
	-- Berlaku untuk chip grup MAUPUN kategori bertipe banyak (mis. "Layered").
	local typeCount = #(opts.assetTypes or {}) + #(opts.bundleTypes or {})
	local sortName = req.sort or "Relevance"
	if sortName == "Relevance" and (req.filter ~= nil or typeCount > 1) then
		sortName = FILTER_SORT
	end
	local sortType = self._toEnum("CatalogSortType", sortName)
	if sortType == nil then
		return false, { code = "FAILED", message = "CatalogSortType." .. sortName .. " tidak ada" }
	end
	opts.sortType = sortType
	opts.keyword = if req.keyword ~= "" then req.keyword else nil
	return self._api:searchCatalog(opts)
end

-- Pastikan entry memuat halaman sampai `target` (atau katalog habis).
local function fill(self: CatalogService, entry: Entry, req: Request, target: number): (boolean, any)
	while #entry.pages < target and not entry.finished do
		local ok, page
		if entry.cursor == nil then
			ok, page = firstPage(self, req)
		else
			ok, page = self._api:nextPage(entry.cursor)
		end
		if not ok then
			return false, page
		end
		entry.cursor = page
		entry.finished = page.isFinished == true
		local rawItems = page.items or {}
		local dtos = toDtos(rawItems)
		if #dtos == 0 and #entry.pages > 0 then
			-- Halaman benar-benar kosong = katalog habis; kosong karena tersaring (mis. Gear) = lanjut.
			if #rawItems == 0 then
				entry.finished = true
			end
		else
			table.insert(entry.pages, dtos)
		end
	end
	return true, nil
end

function CatalogService.search(self: CatalogService, raw: any): Response
	local req, err = CatalogService.normalize(raw)
	if req == nil then
		return fail("BAD_ARG", err or "permintaan tidak valid")
	end
	local target = req.page :: number
	local key = cacheKey(req)

	local entry: Entry? = self._cache:get(key)
	if entry == nil then
		entry = { pages = {}, cursor = nil, finished = false, busy = false }
		self._cache:set(key, entry)
	end
	local e = entry :: Entry

	-- Tunggu permintaan lain pada kunci yang sama (CatalogPages tidak aman dipakai bersamaan).
	local started = self._clock()
	while e.busy do
		if self._clock() - started > BUSY_TIMEOUT then
			return fail("FAILED", "katalog sibuk, coba lagi")
		end
		self._wait(0.1)
	end

	if #e.pages < target and not e.finished then
		e.busy = true
		local pOk, fOk, fErr = pcall(fill, self, e, req, target)
		e.busy = false
		if not pOk or not fOk then
			local detail = if pOk then fErr else fOk
			log.warn("gagal memuat", key, "hal", target, type(detail) == "table" and detail.message or detail)
			if #e.pages == 0 then
				self._cache:delete(key) -- jangan simpan kegagalan
			end
			return fail("FAILED", "gagal memuat katalog, coba lagi")
		end
	end

	local items = e.pages[target]
	if items == nil then -- katalog habis sebelum halaman ini
		return { ok = true, items = {}, page = target, hasMore = false }
	end
	local hasMore = target < #e.pages or not e.finished
	return { ok = true, items = items, page = target, hasMore = hasMore and target < MAX_PAGE }
end

-- Dibuka untuk ItemDetailService (baris Recommended): hasil getBatchItemDetails berbentuk sama
-- dengan hasil pencarian, jadi kartunya memakai normalizer yang sama persis.
CatalogService.toDto = toDto

return CatalogService
