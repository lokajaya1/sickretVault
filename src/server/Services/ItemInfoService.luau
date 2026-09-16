--!strict
-- Info resmi aset (tipe, slot, layered) untuk dipakai AvatarService.
-- Client TIDAK dipercaya soal tipe aset: tipe selalu diambil dari API (GetBatchItemDetailsAsync).
--   local info = ItemInfoService.new({ api = api })
--   local ok, map = info:getMany({ 123, 456 })   -- map[id] = ItemInfo (id tak dikenal tidak ada)
--   local ok, one = info:get(123)                -- one = ItemInfo | { code = "NOT_FOUND" | ... }
-- Tidak memanggil API Roblox langsung (lewat `api`). `toEnum` bisa diganti saat test.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local AssetTypeMap = require(Shared.Domain.AssetTypeMap)
local Cache = require(Shared.Util.Cache)
local Log = require(Shared.Util.Log)

local log = Log.new("ItemInfoService")

local MISS_TTL = 60 -- detik; id yang tidak dikembalikan API / tipe tak didukung
local MISS_SIZE = 2000

export type ItemInfo = {
	assetId: number,
	assetType: string, -- nama tipe aset, mis. "Hat", "JacketAccessory"
	kind: AssetTypeMap.Kind, -- tidak pernah "unknown" (yang unknown dianggap tidak ada)
	slot: string?,
	isLayered: boolean,
	name: string,
}

export type Deps = {
	api: any, -- RobloxApi
	toEnum: ((enumName: string, itemName: string) -> any)?,
	clock: (() -> number)?,
}

local ItemInfoService = {}
ItemInfoService.__index = ItemInfoService

export type ItemInfoService = typeof(setmetatable(
	{} :: {
		_api: any,
		_assetItemType: any,
		_misses: Cache.Cache,
	},
	ItemInfoService
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

function ItemInfoService.new(deps: Deps): ItemInfoService
	assert(deps and deps.api, "ItemInfoService butuh deps.api")
	local toEnum = deps.toEnum or defaultToEnum
	local assetItemType = toEnum("AvatarItemType", "Asset")
	assert(assetItemType ~= nil, "Enum.AvatarItemType.Asset tidak ada")
	return setmetatable({
		_api = deps.api,
		_assetItemType = assetItemType,
		_misses = Cache.new({ ttl = MISS_TTL, maxSize = MISS_SIZE, clock = deps.clock }),
	}, ItemInfoService)
end

-- Ubah detail mentah API -> ItemInfo. nil jika tipe tidak dikenal/tidak didukung.
function ItemInfoService.fromDetail(detail: any): ItemInfo?
	if type(detail) ~= "table" or not isId(detail.Id) then
		return nil
	end
	local typeName = AssetTypeMap.normalize(detail.AssetType)
	if typeName == nil then
		return nil
	end
	local kind, slot = AssetTypeMap.classify(typeName)
	if kind == "unknown" then
		return nil
	end
	return {
		assetId = detail.Id,
		assetType = typeName,
		kind = kind,
		slot = slot,
		isLayered = AssetTypeMap.isLayered(typeName),
		name = if type(detail.Name) == "string" then detail.Name else "",
	}
end

-- Return (true, { [id] = ItemInfo }) atau (false, ApiError) jika API gagal total.
-- Id tidak valid / tidak ditemukan / tipe tak didukung -> tidak ada di map.
function ItemInfoService.getMany(self: ItemInfoService, ids: { number }): (boolean, any)
	local ask: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, id in ids do
		if isId(id) and not seen[id] and self._misses:get(id) == nil then
			seen[id] = true
			table.insert(ask, id)
		end
	end
	local out: { [number]: ItemInfo } = {}
	if #ask == 0 then
		return true, out
	end

	local ok, details = self._api:getBatchItemDetails(ask, self._assetItemType)
	if not ok then
		return false, details
	end
	for _, id in ask do
		local info = ItemInfoService.fromDetail(details[id])
		if info then
			out[id] = info
		else
			self._misses:set(id, true)
			if details[id] ~= nil then
				log.debug("tipe tidak didukung", id, details[id].AssetType)
			end
		end
	end
	return true, out
end

-- Return (true, ItemInfo) atau (false, { code = "BAD_ARG" | "NOT_FOUND" | "FAILED", message }).
function ItemInfoService.get(self: ItemInfoService, id: number): (boolean, any)
	if not isId(id) then
		return false, { code = "BAD_ARG", message = "assetId tidak valid" }
	end
	local ok, map = self:getMany({ id })
	if not ok then
		return false, map
	end
	local info = map[id]
	if info == nil then
		return false, { code = "NOT_FOUND", message = "aset tidak ditemukan / tipe tidak didukung" }
	end
	return true, info
end

return ItemInfoService
