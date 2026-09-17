--!strict
-- Validasi permintaan remote Wardrobe dari client SEBELUM menyentuh data. Data client tidak dipercaya.
--   local req, err = WardrobeValidator.validate(raw)
--   if not req then return { ok = false, code = err } end
-- Bentuk permintaan (satu RemoteFunction "Wardrobe"):
--   { op = "list" }
--   { op = "save", name = string? }          -- nil / kosong -> nama bawaan "Outfit N"
--   { op = "wear", id = number }
--   { op = "overwrite", id = number }        -- timpa slot dengan outfit sekarang
--   { op = "rename", id = number, name = string }
--   { op = "delete", id = number }
--   { op = "favorite", id = number, value = boolean }
--   { op = "items", id = number }        -- nama & harga item di dalam outfit
--   { op = "setSetting", key = string, value = any }  -- key & tipe harus ada di PlayerData.TEMPLATE.settings
--   { op = "folderAdd", name = string }              -- buat folder
--   { op = "folderRename", id = number, name = string }
--   { op = "folderDelete", id = number }             -- outfit di dalamnya tidak ikut terhapus
--   { op = "setFolders", id = number, folders = { number } } -- ganti total folder satu outfit (boleh kosong)
--   { op = "bulkDelete", ids = { number } }          -- hapus banyak outfit ("Select Outfits")
--   { op = "bulkFolder", ids = { number }, id = number, value = boolean } -- tambah/lepas 1 folder
-- Return permintaan BARU yang bersih (nama sudah dirapikan, BELUM difilter Roblox), atau (nil, kode).
-- Murni: tanpa service, tanpa yield -> dites dengan Lune.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Wardrobe = require(Shared.Domain.Wardrobe)
local OutfitFolders = require(Shared.Domain.OutfitFolders)
local PlayerData = require(Shared.Domain.PlayerData)
local GameConfig = require(Shared.Config.GameConfig)

export type Request =
	{ op: "list" }
	| { op: "save", name: string? }
	| { op: "wear", id: number }
	| { op: "overwrite", id: number }
	| { op: "rename", id: number, name: string }
	| { op: "delete", id: number }
	| { op: "favorite", id: number, value: boolean }
	| { op: "items", id: number }
	| { op: "setSetting", key: string, value: any }
	| { op: "folderAdd", name: string }
	| { op: "folderRename", id: number, name: string }
	| { op: "folderDelete", id: number }
	| { op: "setFolders", id: number, folders: { number } }
	| { op: "bulkDelete", ids: { number } }
	| { op: "bulkFolder", ids: { number }, id: number, value: boolean }

-- op -> field yang diizinkan (selain `op`)
type Kind = "id" | "name" | "name?" | "fname" | "key" | "value" | "bool" | "ids" | "folders"

local SCHEMA: { [string]: { [string]: Kind } } = {
	list = {},
	save = { name = "name?" },
	wear = { id = "id" },
	overwrite = { id = "id" },
	rename = { id = "id", name = "name" },
	delete = { id = "id" },
	favorite = { id = "id", value = "bool" },
	items = { id = "id" },
	setSetting = { key = "key", value = "value" },
	folderAdd = { name = "fname" },
	folderRename = { id = "id", name = "fname" },
	folderDelete = { id = "id" },
	setFolders = { id = "id", folders = "folders" },
	bulkDelete = { ids = "ids" },
	bulkFolder = { ids = "ids", id = "id", value = "bool" },
}

local MAX_KEYS = 4
local MAX_BULK = Wardrobe.MAX_SLOTS -- tidak mungkin memilih lebih banyak dari jumlah slot

local WardrobeValidator = {}

WardrobeValidator.Errors = {
	NOT_TABLE = "BAD_ARG",
	TOO_MANY_KEYS = "BAD_ARG",
	UNKNOWN_FIELD = "BAD_ARG",
	BAD_OP = "BAD_ARG",
	BAD_ID = "BAD_ARG",
	BAD_LIST = "BAD_ARG",
	BAD_SETTING = "BAD_ARG",
	BAD_BOOL = "BAD_ARG",
	-- nama: dikirim balik ke UI supaya pesannya jelas
	BAD_NAME = "BAD_NAME",
	EMPTY = "EMPTY",
	TOO_LONG = "TOO_LONG",
}
local E = WardrobeValidator.Errors

local function isId(n: any): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and n > 0 and n <= GameConfig.Intent.MaxId
end

-- Daftar id dari client: tabel array rapat, jumlah min..max, semuanya id sah. Salinan baru.
-- `min` 0 dipakai untuk setFolders (mengosongkan folder sebuah outfit).
local function cleanIds(v: any, min: number, max: number): { number }?
	if type(v) ~= "table" then
		return nil
	end
	local n = 0
	for _ in v do
		n += 1
	end
	if n ~= #v or n < min or n > max then
		return nil -- key asing / bukan array rapat / jumlah di luar batas
	end
	local out: { number } = {}
	for _, id in ipairs(v) do
		if not isId(id) then
			return nil
		end
		table.insert(out, id)
	end
	return out
end

function WardrobeValidator.validate(raw: any): (Request?, string?)
	if type(raw) ~= "table" then
		return nil, E.NOT_TABLE
	end
	local keys = 0
	for k in raw do
		keys += 1
		if keys > MAX_KEYS then
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
		elseif kind == "name" or kind == "name?" then
			if kind == "name?" and (v == nil or (type(v) == "string" and string.match(v, "^%s*$"))) then
				continue -- kosong -> nama bawaan
			end
			local name, err = Wardrobe.cleanName(v)
			if name == nil then
				return nil, (E :: any)[err or "BAD_NAME"] or E.BAD_NAME
			end
			out[field] = name
		elseif kind == "fname" then
			local name, err = OutfitFolders.cleanName(v)
			if name == nil then
				return nil, (E :: any)[err or "BAD_NAME"] or E.BAD_NAME
			end
			out[field] = name
		elseif kind == "ids" or kind == "folders" then
			local folders = kind == "folders"
			local max = if folders then OutfitFolders.MAX_PER_OUTFIT else MAX_BULK
			local ids = cleanIds(v, if folders then 0 else 1, max)
			if ids == nil then
				return nil, E.BAD_LIST
			end
			out[field] = ids
		elseif kind == "key" then
			local default = if type(v) == "string" then (PlayerData.TEMPLATE.settings :: any)[v] else nil
			if default == nil then
				return nil, E.BAD_SETTING
			end
			out[field] = v
		elseif kind == "bool" then
			if type(v) ~= "boolean" then
				return nil, E.BAD_BOOL
			end
			out[field] = v
		elseif kind == "value" then
			out[field] = v -- dicek bersama key di bawah
		end
	end
	if op == "setSetting" then
		local default = (PlayerData.TEMPLATE.settings :: any)[out.key]
		if type(out.value) ~= type(default) then
			return nil, E.BAD_SETTING
		end
	end
	return out :: any, nil
end

return WardrobeValidator
