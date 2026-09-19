--!strict
-- Validasi intent dari client SEBELUM menyentuh state. Data client tidak pernah dipercaya.
--   local intent, err = IntentValidator.validate(raw)
--   if not intent then log.warn("intent ditolak", err) return end
-- Return intent BARU yang bersih (hanya field yang dikenal), atau (nil, kodeError).
-- Murni: tanpa service, tanpa yield -> dites dengan Lune.
-- Catatan: tipe aset TIDAK dikirim client; server mencarinya lewat ItemInfoService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Domain.Types)
local OutfitState = require(Shared.Domain.OutfitState)
local GameConfig = require(Shared.Config.GameConfig)

type Intent = Types.Intent

local Cfg = GameConfig.Intent

-- op -> field yang diizinkan (selain `op`) dan apakah wajib
local KINDS: { [string]: boolean } = {}
for _, k in OutfitState.KINDS do
	KINDS[k] = true
end

local SCHEMA: {
	[string]: {
		[string]: "id" | "ids?" | "bool?" | "order" | "kinds" | "colorSlot" | "scaleSlot" | "hex" | "scale" | "rig",
	},
} =
	{
		wear = { assetId = "id" },
		remove = { assetId = "id" },
		wearBundle = { bundleId = "id", partIds = "ids?", useBundleScales = "bool?" },
		removeBundle = { bundleId = "id" },
		setLayerOrder = { assetId = "id", order = "order" },
		removeKind = { kinds = "kinds" },
		setColor = { slot = "colorSlot", hex = "hex" },
		setScale = { slot = "scaleSlot", value = "scale" },
		setRig = { rig = "rig" },
		undo = {},
		redo = {},
		reset = {},
	}

local IntentValidator = {}

IntentValidator.Errors = {
	NOT_TABLE = "NOT_TABLE",
	TOO_MANY_KEYS = "TOO_MANY_KEYS",
	BAD_OP = "BAD_OP",
	UNKNOWN_FIELD = "UNKNOWN_FIELD",
	BAD_ID = "BAD_ID",
	BAD_IDS = "BAD_IDS",
	BAD_BOOL = "BAD_BOOL",
	BAD_ORDER = "BAD_ORDER",
	BAD_KIND = "BAD_KIND",
	BAD_SLOT = "BAD_SLOT",
	BAD_HEX = "BAD_HEX",
	BAD_VALUE = "BAD_VALUE",
	BAD_RIG = "BAD_RIG",
}
local E = IntentValidator.Errors

local function isInt(n: any): boolean
	return type(n) == "number" and n == n and n % 1 == 0
end

local function isId(n: any): boolean
	return isInt(n) and n > 0 and n <= Cfg.MaxId
end

-- Array murni berisi id unik, panjang 1..MaxPartIds.
local function cleanIds(v: any): { number }?
	if type(v) ~= "table" then
		return nil
	end
	local n = #v
	if n < 1 or n > Cfg.MaxPartIds then
		return nil
	end
	local count = 0
	for _ in v do
		count += 1
		if count > n then
			return nil -- ada key non-array
		end
	end
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	for i = 1, n do
		local id = v[i]
		if not isId(id) or seen[id] then
			return nil
		end
		seen[id] = true
		out[i] = id
	end
	return out
end

-- Array murni berisi kategori sah yang unik, panjang 1..semua kategori. Urutannya dibiarkan
-- apa adanya: `removeKind` per kategori tidak saling bergantung, jadi hasilnya sama saja.
local function cleanKinds(v: any): { string }?
	if type(v) ~= "table" then
		return nil
	end
	local n = #v
	if n < 1 or n > #OutfitState.KINDS then
		return nil
	end
	local count = 0
	for _ in v do
		count += 1
		if count > n then
			return nil -- ada key non-array
		end
	end
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for i = 1, n do
		local k = v[i]
		if type(k) ~= "string" or not KINDS[k] or seen[k] then
			return nil
		end
		seen[k] = true
		out[i] = k
	end
	return out
end

function IntentValidator.validate(raw: any): (Intent?, string?)
	if type(raw) ~= "table" then
		return nil, E.NOT_TABLE
	end
	local keys = 0
	for k in raw do
		keys += 1
		if keys > Cfg.MaxKeys then
			return nil, E.TOO_MANY_KEYS
		end
		if type(k) ~= "string" then
			return nil, E.UNKNOWN_FIELD
		end
	end
	local op = raw.op
	local schema = if type(op) == "string" then SCHEMA[op] else nil
	if schema == nil then
		return nil, E.BAD_OP
	end
	for k in raw do
		if k ~= "op" and schema[k] == nil then
			return nil, E.UNKNOWN_FIELD
		end
	end

	local out: { [string]: any } = { op = op }
	for field, kind in schema do
		local v = raw[field]
		if kind == "id" then
			if not isId(v) then
				return nil, E.BAD_ID
			end
			out[field] = v
		elseif kind == "order" then
			if not isInt(v) or v < Cfg.MinLayerOrder or v > Cfg.MaxLayerOrder then
				return nil, E.BAD_ORDER
			end
			out[field] = v
		elseif kind == "kinds" then
			local kinds = cleanKinds(v)
			if not kinds then
				return nil, E.BAD_KIND
			end
			out[field] = kinds
		elseif kind == "bool?" then
			if v ~= nil and type(v) ~= "boolean" then
				return nil, E.BAD_BOOL
			end
			out[field] = v
		elseif kind == "colorSlot" or kind == "scaleSlot" then
			local known = if kind == "colorSlot" then OutfitState.isColorSlot(v) else OutfitState.isScaleSlot(v)
			if not known then
				return nil, E.BAD_SLOT
			end
			out[field] = v
		elseif kind == "hex" then
			-- Dinormalkan DI SINI ("#ff00aa" -> "FF00AA") supaya state, undo, dan DescriptionBuilder
			-- melihat satu bentuk saja; domain tidak perlu menebak bentuk kiriman client.
			local clean = OutfitState.cleanHex(v)
			if clean == nil then
				return nil, E.BAD_HEX
			end
			out[field] = clean
		elseif kind == "rig" then
			if not OutfitState.isRig(v) then
				return nil, E.BAD_RIG
			end
			out[field] = v
		elseif kind == "scale" then
			-- Angka terhingga saja. Penjepitan ke batas slot dilakukan domain, bukan di sini:
			-- nilai ujung slider HARUS diterima, bukan ditolak.
			if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
				return nil, E.BAD_VALUE
			end
			out[field] = v
		elseif kind == "ids?" then
			if v ~= nil then
				local ids = cleanIds(v)
				if not ids then
					return nil, E.BAD_IDS
				end
				out[field] = ids
			end
		end
	end
	return out :: any, nil
end

return IntentValidator
