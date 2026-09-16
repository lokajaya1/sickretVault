--!strict
-- Detail bundle (server): GetBundleDetailsAsync -> BundleNormalizer -> Types.BundleInfo.
--   local bundles = BundleService.new({ api = api, itemInfo = itemInfo })
--   local ok, info = bundles:get(104915988289001)  -- info = BundleInfo | { code = "BAD_ARG" | "NOT_FOUND" | "FAILED" }
-- Tipe aset: resmi dari ItemInfoService (batch); cadangan = Items[].AssetType dari respons bundle.
-- Skala: dari UserOutfit ber-OutfitType "Avatar" (GetOutfitDetailsAsync). Gagal -> tanpa skala (tidak fatal).
-- Tidak memanggil API Roblox langsung (lewat `api`).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Types = require(Shared.Domain.Types)
local BundleNormalizer = require(Shared.Domain.BundleNormalizer)
local Limits = require(Shared.Config.Limits)
local Cache = require(Shared.Util.Cache)
local Log = require(Shared.Util.Log)

local log = Log.new("BundleService")

type BundleInfo = Types.BundleInfo

local MAX_OUTFITS = 3 -- UserOutfit yang dicek untuk mencari OutfitType "Avatar"
local MISS_TTL = 60

-- Nama skala GetOutfitDetailsAsync -> nama properti HumanoidDescription (AssetTypeMap.ScaleSlots)
local SCALE_KEYS = {
	Height = "HeightScale",
	Width = "WidthScale",
	Depth = "DepthScale",
	Head = "HeadScale",
	BodyType = "BodyTypeScale",
	Proportion = "ProportionScale",
}

export type Deps = {
	api: any, -- RobloxApi (getBundleDetails, getOutfitDetails)
	itemInfo: any, -- ItemInfoService (getMany)
	clock: (() -> number)?,
}

local BundleService = {}
BundleService.__index = BundleService

export type BundleService = typeof(setmetatable(
	{} :: {
		_api: any,
		_itemInfo: any,
		_cache: Cache.Cache,
		_misses: Cache.Cache,
	},
	BundleService
))

local function isId(v: any): boolean
	return type(v) == "number" and v > 0 and v % 1 == 0 and v <= 2 ^ 53
end

function BundleService.new(deps: Deps): BundleService
	assert(deps and deps.api and deps.itemInfo, "BundleService butuh deps.api & deps.itemInfo")
	return setmetatable({
		_api = deps.api,
		_itemInfo = deps.itemInfo,
		_cache = Cache.new({ ttl = Limits.ItemCacheTTL, maxSize = 500, clock = deps.clock }),
		_misses = Cache.new({ ttl = MISS_TTL, maxSize = 500, clock = deps.clock }),
	}, BundleService)
end

-- Skala outfit mentah { Height = 1.05, ... } -> { HeightScale = 1.05, ... } (nil jika kosong).
function BundleService.adaptScales(raw: any): { [string]: number }?
	if type(raw) ~= "table" then
		return nil
	end
	local out: { [string]: number } = {}
	local any = false
	for from, to in SCALE_KEYS do
		local v = raw[from]
		if v == nil then
			v = raw[to] -- jaga-jaga bila API sudah memakai nama lengkap
		end
		if type(v) == "number" then
			out[to] = v
			any = true
		end
	end
	return if any then out else nil
end

-- Semua id UserOutfit di respons (urut), maksimal MAX_OUTFITS.
local function outfitIds(raw: any): { number }
	local ids: { number } = {}
	local items = type(raw) == "table" and (raw.Items or raw.items)
	if type(items) ~= "table" then
		return ids
	end
	for _, item in items do
		if type(item) == "table" then
			local kind = item.Type or item.type
			local id = tonumber(item.Id or item.id)
			if type(kind) == "string" and string.lower(kind) == "useroutfit" and isId(id) then
				table.insert(ids, id :: number)
				if #ids >= MAX_OUTFITS then
					break
				end
			end
		end
	end
	return ids
end

-- Tipe cadangan dari respons bundle: { [assetId] = "RightArm", ... }
local function rawAssetTypes(raw: any): { [number]: any }
	local out: { [number]: any } = {}
	local items = type(raw) == "table" and (raw.Items or raw.items)
	if type(items) ~= "table" then
		return out
	end
	for _, item in items do
		if type(item) == "table" then
			local id = tonumber(item.Id or item.id)
			local t = item.AssetType or item.assetType
			if isId(id) and t ~= nil then
				out[id :: number] = t
			end
		end
	end
	return out
end

-- Cari outfit "Avatar" -> (outfitId?, skala?). Kegagalan API diabaikan.
function BundleService._avatarOutfit(self: BundleService, raw: any): (number?, { [string]: number }?)
	local ids = outfitIds(raw)
	for _, id in ids do
		local ok, detail = self._api:getOutfitDetails(id)
		if ok and type(detail) == "table" and detail.OutfitType == "Avatar" then
			return id, BundleService.adaptScales(detail.Scale)
		end
	end
	return ids[1], nil
end

-- Return (true, BundleInfo) | (false, { code, message }).
function BundleService.get(self: BundleService, bundleId: number): (boolean, any)
	if not isId(bundleId) then
		return false, { code = "BAD_ARG", message = "bundleId tidak valid" }
	end
	local hit = self._cache:get(bundleId)
	if hit ~= nil then
		return true, hit
	end
	if self._misses:get(bundleId) ~= nil then
		return false, { code = "NOT_FOUND", message = "bundle tidak ditemukan" }
	end

	local ok, raw = self._api:getBundleDetails(bundleId)
	if not ok then
		local code = if raw and raw.code == "FAILED" then "FAILED" else "NOT_FOUND"
		if code == "NOT_FOUND" then
			self._misses:set(bundleId, true)
		end
		return false, { code = code, message = raw and raw.message or "gagal" }
	end

	local extracted, err = BundleNormalizer.extract(raw)
	if not extracted then
		log.warn("respons bundle tidak dikenali", bundleId, err)
		self._misses:set(bundleId, true)
		return false, { code = "NOT_FOUND", message = err or "respons tidak dikenali" }
	end

	-- tipe: cadangan dulu, lalu ditimpa tipe resmi
	local types = rawAssetTypes(raw)
	local infoOk, infos = self._itemInfo:getMany(extracted.assetIds)
	if infoOk then
		for id, info in infos do
			types[id] = info.assetType
		end
	else
		log.warn("tipe resmi gagal, pakai tipe dari bundle", bundleId)
	end

	local info = BundleNormalizer.build(extracted, types)
	local outfitId, scales = self:_avatarOutfit(raw)
	info.outfitId = outfitId
	info = BundleNormalizer.enrich(info, if scales then { scales = scales } else nil)

	self._cache:set(bundleId, info)
	return true, info
end

return BundleService
