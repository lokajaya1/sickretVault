--!strict
-- Batas per tipe aksesori dari AvatarEditorService:GetAvatarRulesAsync (WearableAssetTypes).
--   local rules = AvatarRules.new({ api = api })
--   local limits = rules:maxPerType()   -- { Hat = 3, HairAccessory = 1, ... } (tidak pernah yield lama berulang)
-- Nama tipe dari API berisi spasi ("Hair Accessory") -> pakai Id lalu AssetTypeMap.normalize(Id).
-- Gagal ambil rules -> pakai FALLBACK (dicoba lagi setelah RETRY_AFTER detik).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local AssetTypeMap = require(Shared.Domain.AssetTypeMap)
local Log = require(Shared.Util.Log)

local log = Log.new("AvatarRules")

local RETRY_AFTER = 60

-- Nilai Studio 16 Sep 2026 (docs/API_VERIFICATION.md) untuk tipe yang kita dukung.
local FALLBACK: { [string]: number } = {
	Hat = 3,
	HairAccessory = 1,
	FaceAccessory = 1,
	NeckAccessory = 1,
	ShoulderAccessory = 1,
	FrontAccessory = 1,
	BackAccessory = 1,
	WaistAccessory = 1,
	EyebrowAccessory = 1,
	EyelashAccessory = 1,
	TShirtAccessory = 1,
	ShirtAccessory = 1,
	PantsAccessory = 1,
	JacketAccessory = 1,
	SweaterAccessory = 1,
	ShortsAccessory = 1,
	LeftShoeAccessory = 1,
	RightShoeAccessory = 1,
	DressSkirtAccessory = 1,
}

export type Deps = {
	api: any, -- RobloxApi (getAvatarRules)
	toName: ((id: number) -> string?)?, -- default AssetTypeMap.normalize
	clock: (() -> number)?,
}

local AvatarRules = {}
AvatarRules.__index = AvatarRules
AvatarRules.FALLBACK = FALLBACK

export type AvatarRules = typeof(setmetatable(
	{} :: {
		_api: any,
		_toName: (number) -> string?,
		_clock: () -> number,
		_limits: { [string]: number }?,
		_failedAt: number?,
	},
	AvatarRules
))

function AvatarRules.new(deps: Deps): AvatarRules
	assert(deps and deps.api, "AvatarRules butuh deps.api")
	return setmetatable({
		_api = deps.api,
		_toName = deps.toName or function(id: number): string?
			return AssetTypeMap.normalize(id)
		end,
		_clock = deps.clock or os.clock,
		_limits = nil,
		_failedAt = nil,
	}, AvatarRules)
end

-- Ubah respons mentah -> { [namaTipe] = MaxNumber }. nil jika bentuknya tidak dikenal.
function AvatarRules.parse(raw: any, toName: (number) -> string?): { [string]: number }?
	local list = type(raw) == "table" and raw.WearableAssetTypes
	if type(list) ~= "table" then
		return nil
	end
	local out: { [string]: number } = {}
	local count = 0
	for _, entry in list do
		if type(entry) == "table" and type(entry.Id) == "number" and type(entry.MaxNumber) == "number" then
			local name = toName(entry.Id)
			if name then
				out[name] = math.max(0, math.floor(entry.MaxNumber))
				count += 1
			end
		end
	end
	return if count > 0 then out else nil
end

function AvatarRules.maxPerType(self: AvatarRules): { [string]: number }
	if self._limits then
		return self._limits
	end
	if self._failedAt and self._clock() - self._failedAt < RETRY_AFTER then
		return FALLBACK
	end
	local ok, raw = self._api:getAvatarRules()
	local parsed = if ok then AvatarRules.parse(raw, self._toName) else nil
	if parsed then
		-- tipe yang tidak disebut API tetap dibatasi fallback
		for k, v in FALLBACK do
			if parsed[k] == nil then
				parsed[k] = v
			end
		end
		self._limits = parsed
		return parsed
	end
	log.warn("rules avatar tidak didapat, pakai fallback")
	self._failedAt = self._clock()
	return FALLBACK
end

return AvatarRules
