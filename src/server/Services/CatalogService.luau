--!strict
-- Layanan katalog: validasi permintaan client -> RobloxApi.searchCatalog/nextPage,
-- cache hasil per halaman (dibagi antar pemain), ringkas item jadi DTO kecil.
--   local catalog = CatalogService.new({ api = api })
--   local res = catalog:search({ categoryId = "hats", keyword = "", sort = "Relevance", page = 1 })
--   res = { ok = true, items = { ItemDto }, page = 1, hasMore = true }
--       | { ok = false, code = "BAD_ARG" | "FAILED", message = string }
-- Tidak memanggil API Roblox langsung (lewat `api`). `toEnum` bisa diganti saat test (Lune tanpa Enum).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Categories = require(Shared.Config.Categories)
local Limits = require(Shared.Config.Limits)
local Cache = require(Shared.Util.Cache)
local Log = require(Shared.Util.Log)

local log = Log.new("CatalogService")

local PAGE_LIMIT = 30 -- item per halaman (nilai valid RobloxApi: 10/28/30/60/120)
local MAX_PAGE = 20 -- cegah client merayapi katalog terlalu dalam
local MAX_KEYWORD = 50
local CACHE_SIZE = 300 -- jumlah kombinasi (kategori+keyword+sort) yang disimpan
local BUSY_TIMEOUT = 15 -- detik menunggu permintaan lain pada kunci yang sama

-- Urutan yang diizinkan (nama Enum.CatalogSortType).
local SORTS: { [string]: boolean } = {
	Relevance = true,
	PriceLowToHigh = true,
	PriceHighToLow = true,
	MostFavorited = true,
	RecentlyCreated = true,
}

export type Request = {
	categoryId: string,
	keyword: string?,
	sort: string?,
	page: number?,
}

export type ItemDto = {
	id: number,
	itemType: string, -- "Asset" | "Bundle"
	assetType: string?,
	bundleType: string?,
	name: string,
	creatorName: string?,
	price: number?, -- nil = tidak dijual / gratis tidak diketahui
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
	return {
		id = raw.Id,
		itemType = if type(raw.ItemType) == "string" then raw.ItemType else "Asset",
		assetType = if type(raw.AssetType) == "string" then raw.AssetType else nil,
		bundleType = if type(raw.BundleType) == "string" then raw.BundleType else nil,
		name = if type(raw.Name) == "string" then raw.Name else "",
		creatorName = if type(raw.CreatorName) == "string" then raw.CreatorName else nil,
		price = price,
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
	if type(raw.categoryId) ~= "string" or Categories.byId[raw.categoryId] == nil then
		return nil, "kategori tidak dikenal"
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
	return { categoryId = raw.categoryId, keyword = keyword, sort = sort, page = page }, nil
end

local function cacheKey(req: Request): string
	return ("%s|%s|%s"):format(req.categoryId, string.lower(req.keyword or ""), req.sort or "Relevance")
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

-- Halaman pertama: bangun opsi dari Categories lalu panggil api.searchCatalog.
local function firstPage(self: CatalogService, req: Request): (boolean, any)
	local cat = Categories.byId[req.categoryId]
	local assetTypes, e1 = enumList(self, "AvatarAssetType", cat.assetTypes)
	local bundleTypes, e2 = enumList(self, "BundleType", cat.bundleTypes)
	if e1 or e2 then
		return false, { code = "FAILED", message = e1 or e2 }
	end
	local sortType = self._toEnum("CatalogSortType", req.sort or "Relevance")
	if sortType == nil then
		return false, { code = "FAILED", message = "CatalogSortType." .. tostring(req.sort) .. " tidak ada" }
	end
	return self._api:searchCatalog({
		keyword = if req.keyword ~= "" then req.keyword else nil,
		assetTypes = assetTypes,
		bundleTypes = bundleTypes,
		sortType = sortType,
		limit = PAGE_LIMIT,
	})
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
		local dtos = toDtos(page.items or {})
		if #dtos == 0 and #entry.pages > 0 then
			entry.finished = true -- halaman kosong: anggap habis
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

return CatalogService
