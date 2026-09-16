--!strict
-- Detail item untuk panel detail (server): GetItemDetailsAsync -> ItemDetail.fromRaw (+ part bundle).
--   local details = ItemDetailService.new({ api = api, bundles = bundles })
--   local ok, d = details:get(123, "Asset")    -- d = ItemDetail.Detail | { code = "BAD_ARG" | "NOT_FOUND" | "FAILED" }
--   local ok, d = details:get(456, "Bundle")   -- d.parts = part bundle (nil jika BundleService gagal)
-- Part bundle gagal (FAILED) -> detail tetap dikirim tanpa part & TIDAK di-cache (dicoba lagi berikutnya).
-- Tidak memanggil API Roblox langsung (lewat `api`). `toEnum` bisa diganti saat test.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemDetail = require(Shared.Domain.ItemDetail)
local Limits = require(Shared.Config.Limits)
local Cache = require(Shared.Util.Cache)
local Log = require(Shared.Util.Log)

local log = Log.new("ItemDetailService")

local MISS_TTL = 60
local CACHE_SIZE = 500

export type Deps = {
	api: any, -- RobloxApi (getItemDetails)
	bundles: any, -- BundleService (get)
	toEnum: ((enumName: string, itemName: string) -> any)?,
	clock: (() -> number)?,
}

local ItemDetailService = {}
ItemDetailService.__index = ItemDetailService

export type ItemDetailService = typeof(setmetatable(
	{} :: {
		_api: any,
		_bundles: any,
		_enums: { [string]: any },
		_cache: Cache.Cache,
		_misses: Cache.Cache,
	},
	ItemDetailService
))

local function defaultToEnum(enumName: string, itemName: string): any
	local ok, item = pcall(function()
		return (Enum :: any)[enumName][itemName]
	end)
	return if ok then item else nil
end

local function isId(v: any): boolean
	return type(v) == "number" and v > 0 and v % 1 == 0 and v <= 2 ^ 53
end

local function fail(code: string, message: string): (boolean, any)
	return false, { code = code, message = message }
end

function ItemDetailService.new(deps: Deps): ItemDetailService
	assert(deps and deps.api and deps.bundles, "ItemDetailService butuh deps.api & deps.bundles")
	local toEnum = deps.toEnum or defaultToEnum
	local enums: { [string]: any } = {}
	for _, name in { "Asset", "Bundle" } do
		enums[name] = toEnum("AvatarItemType", name)
		assert(enums[name] ~= nil, "Enum.AvatarItemType." .. name .. " tidak ada")
	end
	return setmetatable({
		_api = deps.api,
		_bundles = deps.bundles,
		_enums = enums,
		_cache = Cache.new({ ttl = Limits.ItemCacheTTL, maxSize = CACHE_SIZE, clock = deps.clock }),
		_misses = Cache.new({ ttl = MISS_TTL, maxSize = CACHE_SIZE, clock = deps.clock }),
	}, ItemDetailService)
end

-- Return (true, Detail) | (false, { code, message }).
function ItemDetailService.get(self: ItemDetailService, id: number, itemType: string): (boolean, any)
	if not isId(id) then
		return fail("BAD_ARG", "id tidak valid")
	end
	local enum = if type(itemType) == "string" then self._enums[itemType] else nil
	if enum == nil then
		return fail("BAD_ARG", "itemType tidak valid")
	end

	local key = itemType .. ":" .. tostring(id)
	local hit = self._cache:get(key)
	if hit ~= nil then
		return true, hit
	end
	if self._misses:get(key) ~= nil then
		return fail("NOT_FOUND", "item tidak ditemukan")
	end

	local ok, raw = self._api:getItemDetails(id, enum)
	if not ok then
		if raw and raw.code == "FAILED" then
			return fail("FAILED", raw.message or "gagal")
		end
		self._misses:set(key, true)
		return fail("NOT_FOUND", raw and raw.message or "item tidak ditemukan")
	end

	local detail = ItemDetail.fromRaw(raw, itemType)
	if detail == nil or detail.id ~= id or detail.itemType ~= itemType then
		log.warn("respons detail tidak dikenali", itemType, id)
		self._misses:set(key, true)
		return fail("NOT_FOUND", "respons tidak dikenali")
	end

	local cacheable = true
	if itemType == "Bundle" then
		local bOk, info = self._bundles:get(id)
		if bOk then
			detail.parts = info.parts
		else
			log.warn("part bundle gagal", id, info and info.code)
			-- NOT_FOUND permanen -> cache tanpa part; FAILED -> coba lagi lain kali
			cacheable = not (info and info.code == "FAILED")
		end
	end

	if cacheable then
		self._cache:set(key, detail)
	end
	return true, detail
end

return ItemDetailService
