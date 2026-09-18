--!strict
-- Gateway API Roblox: SATU-SATUNYA tempat yang memanggil API avatar/katalog yang yield.
-- Semua panggilan dibungkus Retry (pcall + backoff) dan, jika aman, Cache.
-- Semua fungsi return (true, data) atau (false, ApiError). Tidak pernah error().
--
--   local RobloxApi = require(ServerScriptService.Server.Gateways.RobloxApi)
--   local api = RobloxApi.new()                 -- pakai service asli
--   local ok, info = api:getItemDetails(123, Enum.AvatarItemType.Asset)
--
-- Nama API diverifikasi di Creator Hub (16 Sep 2026), lihat docs/API_VERIFICATION.md:
--   AvatarEditorService: SearchCatalogAsync, GetItemDetailsAsync, GetBatchItemDetailsAsync,
--                        GetAvatarRulesAsync, GetOutfitDetailsAsync,
--                        GetRecommendedAssetsAsync, GetRecommendedBundlesAsync (spike 19 Sep 2026)
--   AssetService:        GetBundleDetailsAsync
--   Players:             GetHumanoidDescriptionFromUserIdAsync, GetHumanoidDescriptionFromOutfitIdAsync
--   Humanoid:            ApplyDescriptionAsync (versi tanpa Async sudah deprecated)
-- Batas batch GetBatchItemDetailsAsync TIDAK tertulis di docs; Dev/Inspect (16 Sep 2026): maks 100
-- -> Limits.ItemBatchSize = 100.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Limits = require(Shared.Config.Limits)
local Cache = require(Shared.Util.Cache)
local Retry = require(Shared.Util.Retry)
local Log = require(Shared.Util.Log)

local log = Log.new("RobloxApi")

export type ErrorCode = "BAD_ARG" | "NOT_FOUND" | "FAILED"
export type ApiError = { code: ErrorCode, message: string, api: string }

export type Deps = {
	avatarEditorService: any?,
	assetService: any?,
	players: any?,
	retry: Retry.Options?, -- mis. { sleep = function() end } saat test
	clock: (() -> number)?,
	newSearchParams: (() -> any)?, -- default CatalogSearchParams.new
}

export type SearchOptions = {
	keyword: string?,
	assetTypes: { any }?, -- { Enum.AvatarAssetType }
	bundleTypes: { any }?, -- { Enum.BundleType }
	categoryFilter: any?, -- Enum.CatalogCategoryFilter
	sortType: any?, -- Enum.CatalogSortType
	salesTypeFilter: any?, -- Enum.SalesTypeFilter
	minPrice: number?,
	maxPrice: number?,
	includeOffSale: boolean?,
	creatorName: string?,
	creatorType: any?, -- Enum.CreatorType (User | Group); tidak diset = semua pencipta
	limit: number?, -- 10 | 28 | 30 | 60 | 120 (default 30)
}

export type SearchPage = { items: { any }, isFinished: boolean, pages: any }

local AVATAR_RULES_TTL = 6 * 3600
local VALID_LIMITS = { [10] = true, [28] = true, [30] = true, [60] = true, [120] = true }

-- Pesan error yang TIDAK perlu diulang (id salah / aset tidak ada / tidak diizinkan).
local PERMANENT_PATTERNS = {
	"[Nn]ot [Ff]ound",
	"HTTP 400",
	"HTTP 404",
	"[Ii]nvalid",
	"does not exist",
	"not allowed",
	"maximum of", -- mis. "A maximum of 100 item details can be requested at once"
}

local RobloxApi = {}
RobloxApi.__index = RobloxApi

export type RobloxApi = typeof(setmetatable(
	{} :: {
		_aes: any,
		_assets: any,
		_players: any,
		_retry: Retry.Options,
		_newSearchParams: () -> any,
		_items: Cache.Cache,
		_bundles: Cache.Cache,
		_outfits: Cache.Cache,
		_misc: Cache.Cache,
	},
	RobloxApi
))

function RobloxApi.isPermanentError(err: any): boolean
	local text = tostring(err)
	for _, pattern in PERMANENT_PATTERNS do
		if string.find(text, pattern) then
			return true
		end
	end
	return false
end

local function makeError(api: string, err: any): ApiError
	local code: ErrorCode = if RobloxApi.isPermanentError(err) then "NOT_FOUND" else "FAILED"
	return { code = code, message = tostring(err), api = api }
end

local function badArg(api: string, message: string): ApiError
	return { code = "BAD_ARG", message = message, api = api }
end

local function isId(v: any): boolean
	return type(v) == "number" and v > 0 and v % 1 == 0 and v <= 2 ^ 53
end

function RobloxApi.new(deps: Deps?): RobloxApi
	local d = deps or {}
	local retry: Retry.Options = table.clone(d.retry or {})
	if retry.shouldRetry == nil then
		retry.shouldRetry = function(err)
			return not RobloxApi.isPermanentError(err)
		end
	end
	local clock = d.clock or os.clock
	return setmetatable({
		_aes = d.avatarEditorService or game:GetService("AvatarEditorService"),
		_assets = d.assetService or game:GetService("AssetService"),
		_players = d.players or game:GetService("Players"),
		_retry = retry,
		_newSearchParams = d.newSearchParams or function()
			return CatalogSearchParams.new()
		end,
		_items = Cache.new({ ttl = Limits.ItemCacheTTL, maxSize = Limits.ItemCacheSize, clock = clock }),
		_bundles = Cache.new({ ttl = Limits.ItemCacheTTL, maxSize = 1000, clock = clock }),
		_outfits = Cache.new({ ttl = Limits.ItemCacheTTL, maxSize = 500, clock = clock }),
		_misc = Cache.new({ ttl = AVATAR_RULES_TTL, maxSize = 10, clock = clock }),
	}, RobloxApi)
end

-- Panggil fn dengan Retry. Return (true, hasil) atau (false, ApiError).
function RobloxApi._call(self: RobloxApi, api: string, fn: () -> any): (boolean, any)
	local ok, result = Retry.run(fn, self._retry)
	if ok then
		return true, result
	end
	local e = makeError(api, result)
	log.warn(api, "gagal:", e.code, e.message)
	return false, e
end

local function itemKey(id: number, itemType: any): string
	return tostring(itemType) .. ":" .. tostring(id)
end

-- ===== Item =====

function RobloxApi.getItemDetails(self: RobloxApi, id: number, itemType: any): (boolean, any)
	if not isId(id) then
		return false, badArg("GetItemDetailsAsync", "id tidak valid")
	end
	local key = itemKey(id, itemType)
	local hit = self._items:get(key)
	if hit ~= nil then
		return true, hit
	end
	local ok, data = self:_call("GetItemDetailsAsync", function()
		return self._aes:GetItemDetailsAsync(id, itemType)
	end)
	if ok then
		self._items:set(key, data)
	end
	return ok, data
end

-- Return (true, { [id] = detail }) — id yang tidak dikembalikan API tidak ada di map.
-- Hasil sebagian: jika satu potongan gagal, potongan lain tetap dipakai; ok=false hanya jika SEMUA gagal.
function RobloxApi.getBatchItemDetails(self: RobloxApi, ids: { number }, itemType: any): (boolean, any)
	local result: { [number]: any } = {}
	local missing: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, id in ids do
		if isId(id) and not seen[id] then
			seen[id] = true
			local hit = self._items:get(itemKey(id, itemType))
			if hit ~= nil then
				result[id] = hit
			else
				table.insert(missing, id)
			end
		end
	end
	if #missing == 0 then
		return true, result
	end

	local size = math.max(1, Limits.ItemBatchSize)
	local anyOk = false
	local lastErr: any = nil
	for start = 1, #missing, size do
		local chunk = table.move(missing, start, math.min(start + size - 1, #missing), 1, {})
		local ok, list = self:_call("GetBatchItemDetailsAsync", function()
			return self._aes:GetBatchItemDetailsAsync(chunk, itemType)
		end)
		if ok and type(list) == "table" then
			anyOk = true
			for _, detail in list do
				local id = type(detail) == "table" and detail.Id
				if isId(id) then
					result[id] = detail
					self._items:set(itemKey(id, itemType), detail)
				end
			end
		else
			lastErr = list
		end
	end
	if not anyOk and next(result) == nil then
		return false, lastErr
	end
	return true, result
end

-- ===== Katalog =====

local function buildParams(self: RobloxApi, o: SearchOptions): (any, string?)
	local params = self._newSearchParams()
	if o.keyword ~= nil then
		if type(o.keyword) ~= "string" or #o.keyword > 50 then
			return nil, "keyword tidak valid"
		end
		params.SearchKeyword = o.keyword
	end
	if o.assetTypes then
		params.AssetTypes = o.assetTypes
	end
	if o.bundleTypes then
		params.BundleTypes = o.bundleTypes
	end
	if o.categoryFilter then
		params.CategoryFilter = o.categoryFilter
	end
	if o.sortType then
		params.SortType = o.sortType
	end
	if o.salesTypeFilter then
		params.SalesTypeFilter = o.salesTypeFilter
	end
	if o.minPrice then
		params.MinPrice = o.minPrice
	end
	if o.maxPrice then
		params.MaxPrice = o.maxPrice
	end
	if o.includeOffSale ~= nil then
		params.IncludeOffSale = o.includeOffSale
	end
	if o.creatorName then
		params.CreatorName = o.creatorName
	end
	if o.creatorType then
		params.CreatorType = o.creatorType
	end
	local limit = o.limit or 30
	if not VALID_LIMITS[limit] then
		return nil, "limit harus 10/28/30/60/120"
	end
	params.Limit = limit
	return params, nil
end

-- Tidak di-cache di sini: CatalogPages punya state (halaman berjalan).
-- Cache hasil pencarian diurus layanan katalog (feature/catalog-browse).
function RobloxApi.searchCatalog(self: RobloxApi, opts: SearchOptions): (boolean, any)
	local params, perr = buildParams(self, opts)
	if params == nil then
		return false, badArg("SearchCatalogAsync", perr or "opsi tidak valid")
	end
	local ok, pages = self:_call("SearchCatalogAsync", function()
		return self._aes:SearchCatalogAsync(params)
	end)
	if not ok then
		return false, pages
	end
	local page: SearchPage = { items = pages:GetCurrentPage(), isFinished = pages.IsFinished, pages = pages }
	return true, page
end

-- Maju ke halaman berikutnya dari SearchPage sebelumnya.
function RobloxApi.nextPage(self: RobloxApi, prev: SearchPage): (boolean, any)
	if prev.isFinished then
		return true, { items = {}, isFinished = true, pages = prev.pages } :: SearchPage
	end
	local pages = prev.pages
	local ok, err = self:_call("AdvanceToNextPageAsync", function()
		pages:AdvanceToNextPageAsync()
		return true
	end)
	if not ok then
		return false, err
	end
	local page: SearchPage = { items = pages:GetCurrentPage(), isFinished = pages.IsFinished, pages = pages }
	return true, page
end

-- ===== Rekomendasi =====
-- Spike 19 Sep 2026 (tests/CatalogFilter.studio "4"): GetRecommendedAssetsAsync &
-- GetRecommendedBundlesAsync mengembalikan 50 entri berbentuk ASING —
--   aset  : { Creator = {...}, Item = { AssetId, Name, Price }, Product = {...} }  (TANPA AssetType)
--   bundle: { Id, Name, Creator = {...}, Items = {...}, Product = {...}, BundleType = 3 (ANGKA) }
-- Tiga bentuk berbeda, tanpa AssetType, dengan BundleType berupa angka. Jadi gateway hanya
-- mengambil DAFTAR ID; datanya diambil ulang lewat getBatchItemDetails yang bentuknya sama dengan
-- hasil pencarian -> satu normalizer (CatalogService.toDto) untuk semua kartu.
-- Tidak di-cache di sini (seperti searchCatalog); ItemDetailService yang menyimpan hasilnya.

local MAX_RECOMMENDED = 25

-- Ambil id dari daftar rekomendasi: buang yang bukan id dan buang item yang sedang dibuka.
local function pickIds(list: any, limit: number, skip: number, get: (any) -> any): { number }
	local out: { number } = {}
	if type(list) ~= "table" then
		return out
	end
	for _, entry in list do
		if #out >= limit then
			break
		end
		local id = get(entry)
		if isId(id) and id ~= skip then
			table.insert(out, id)
		end
	end
	return out
end

-- assetType: Enum.AvatarAssetType dari item yang sedang dibuka. Return (true, { id }).
function RobloxApi.getRecommendedAssetIds(
	self: RobloxApi,
	assetType: any,
	contextId: number,
	limit: number?
): (boolean, any)
	if not isId(contextId) then
		return false, badArg("GetRecommendedAssetsAsync", "contextId tidak valid")
	end
	if assetType == nil then
		return false, badArg("GetRecommendedAssetsAsync", "assetType tidak valid")
	end
	local ok, list = self:_call("GetRecommendedAssetsAsync", function()
		return self._aes:GetRecommendedAssetsAsync(assetType, contextId)
	end)
	if not ok then
		return false, list
	end
	return true,
		pickIds(list, math.clamp(limit or MAX_RECOMMENDED, 1, MAX_RECOMMENDED), contextId, function(entry)
			return if type(entry) == "table" and type(entry.Item) == "table" then entry.Item.AssetId else nil
		end)
end

function RobloxApi.getRecommendedBundleIds(self: RobloxApi, bundleId: number, limit: number?): (boolean, any)
	if not isId(bundleId) then
		return false, badArg("GetRecommendedBundlesAsync", "bundleId tidak valid")
	end
	local ok, list = self:_call("GetRecommendedBundlesAsync", function()
		return self._aes:GetRecommendedBundlesAsync(bundleId)
	end)
	if not ok then
		return false, list
	end
	return true,
		pickIds(list, math.clamp(limit or MAX_RECOMMENDED, 1, MAX_RECOMMENDED), bundleId, function(entry)
			return if type(entry) == "table" then entry.Id else nil
		end)
end

-- ===== Bundle & outfit =====

function RobloxApi.getBundleDetails(self: RobloxApi, bundleId: number): (boolean, any)
	if not isId(bundleId) then
		return false, badArg("GetBundleDetailsAsync", "bundleId tidak valid")
	end
	local hit = self._bundles:get(bundleId)
	if hit ~= nil then
		return true, hit
	end
	local ok, data = self:_call("GetBundleDetailsAsync", function()
		return self._assets:GetBundleDetailsAsync(bundleId)
	end)
	if ok then
		self._bundles:set(bundleId, data)
	end
	return ok, data
end

function RobloxApi.getOutfitDetails(self: RobloxApi, outfitId: number): (boolean, any)
	if not isId(outfitId) then
		return false, badArg("GetOutfitDetailsAsync", "outfitId tidak valid")
	end
	local hit = self._outfits:get(outfitId)
	if hit ~= nil then
		return true, hit
	end
	local ok, data = self:_call("GetOutfitDetailsAsync", function()
		return self._aes:GetOutfitDetailsAsync(outfitId)
	end)
	if ok then
		self._outfits:set(outfitId, data)
	end
	return ok, data
end

function RobloxApi.getAvatarRules(self: RobloxApi): (boolean, any)
	local hit = self._misc:get("avatarRules")
	if hit ~= nil then
		return true, hit
	end
	local ok, data = self:_call("GetAvatarRulesAsync", function()
		return self._aes:GetAvatarRulesAsync()
	end)
	if ok then
		self._misc:set("avatarRules", data)
	end
	return ok, data
end

-- ===== HumanoidDescription =====
-- Tidak di-cache: Instance bisa diubah pemanggil. Selalu instance baru.

function RobloxApi.getDescriptionFromUserId(self: RobloxApi, userId: number): (boolean, any)
	if not isId(userId) then
		return false, badArg("GetHumanoidDescriptionFromUserIdAsync", "userId tidak valid")
	end
	return self:_call("GetHumanoidDescriptionFromUserIdAsync", function()
		return self._players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
end

function RobloxApi.getDescriptionFromOutfitId(self: RobloxApi, outfitId: number): (boolean, any)
	if not isId(outfitId) then
		return false, badArg("GetHumanoidDescriptionFromOutfitIdAsync", "outfitId tidak valid")
	end
	return self:_call("GetHumanoidDescriptionFromOutfitIdAsync", function()
		return self._players:GetHumanoidDescriptionFromOutfitIdAsync(outfitId)
	end)
end

-- Terapkan description ke humanoid (server). Hanya 2 percobaan: apply berat.
function RobloxApi.applyDescription(self: RobloxApi, humanoid: any, description: any): (boolean, any)
	if humanoid == nil or description == nil then
		return false, badArg("ApplyDescriptionAsync", "humanoid/description nil")
	end
	local opts = table.clone(self._retry)
	opts.attempts = 2
	local ok, err = Retry.run(function()
		humanoid:ApplyDescriptionAsync(description)
		return true
	end, opts)
	if ok then
		return true, nil
	end
	local e = makeError("ApplyDescriptionAsync", err)
	log.warn("ApplyDescriptionAsync gagal:", e.code, e.message)
	return false, e
end

return RobloxApi
