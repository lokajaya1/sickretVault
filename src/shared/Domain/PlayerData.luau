--!strict
-- DOMAIN MURNI: skema data pemain (DataStore) + (de)serialisasi outfit ringkas.
--   local data, newer = PlayerData.migrate(profile.Data) -- isi field hilang, naikkan versi
--   data.lastOutfit = PlayerData.encodeOutfit(state)    -- simpan (ringkas, JSON-aman)
--   local state, err = PlayerData.decodeOutfit(data.lastOutfit) -- muat (divalidasi ulang)
-- Data dari DataStore TIDAK dipercaya penuh: skema bisa berubah / rusak -> decode memvalidasi semuanya.

local Types = require(script.Parent.Types)
local Map = require(script.Parent.AssetTypeMap)
local OutfitState = require(script.Parent.OutfitState)
local Wardrobe = require(script.Parent.Wardrobe)
local LayerOrder = require(script.Parent.Parent.Config.LayerOrder)
local Limits = require(script.Parent.Parent.Config.Limits)

type State = Types.OutfitState

local PlayerData = {}

PlayerData.VERSION = 2
PlayerData.OUTFIT_VERSION = 1

local MAX_ID = 2 ^ 53
local MAX_SCALE = 5 -- batas longgar; batas asli ditegakkan engine saat apply

export type Settings = {
	restoreOutfit: boolean, -- pakai outfit terakhir saat join
}

export type Data = {
	v: number,
	lastOutfit: any?, -- hasil encodeOutfit (nil = pakai avatar asli)
	settings: Settings,
	outfits: { Wardrobe.Entry }, -- slot wardrobe (v2)
	nextOutfitId: number, -- id slot berikutnya (v2)
}

-- Template untuk ProfileStore (Reconcile mengisi key yang hilang). Jangan diubah langsung.
PlayerData.TEMPLATE = table.freeze({
	v = PlayerData.VERSION,
	settings = table.freeze({ restoreOutfit = true }),
	outfits = table.freeze({}),
	nextOutfitId = 1,
})

local function isId(x: any): boolean
	return type(x) == "number" and x > 0 and x % 1 == 0 and x <= MAX_ID
end

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

-- ===== Skema =====

-- Lengkapi & naikkan versi data. Mengubah `data` di tempat (tabel profile) dan mengembalikannya.
-- newer = true -> data ditulis server versi LEBIH BARU: jangan ditimpa (hindari downgrade).
function PlayerData.migrate(data: any): (Data, boolean)
	if type(data) ~= "table" then
		data = {}
	end
	local v = if type(data.v) == "number" then data.v else 0
	if v > PlayerData.VERSION then
		return data, true
	end
	-- v0 -> v1: belum ada data apa pun (profil baru / sebelum skema)
	if type(data.settings) ~= "table" then
		data.settings = {}
	end
	if type(data.settings.restoreOutfit) ~= "boolean" then
		data.settings.restoreOutfit = PlayerData.TEMPLATE.settings.restoreOutfit
	end
	-- v1 -> v2: slot wardrobe (sanitize juga merapikan data rusak setiap load)
	Wardrobe.sanitize(data)
	-- (migrasi v2 -> v3 dst. ditambahkan di sini, berurutan)
	data.v = PlayerData.VERSION
	return data, false
end

-- ===== Outfit =====

local GROUPS = {
	{ key = "bp", field = "bodyParts", slots = Map.BodyPartSlots },
	{ key = "an", field = "animations", slots = Map.AnimationSlots },
	{ key = "cl", field = "classic", slots = Map.ClassicSlots },
}

-- OutfitState -> tabel ringkas (slot kosong dibuang, key pendek).
function PlayerData.encodeOutfit(state: State): any
	local out: { [string]: any } = { ov = PlayerData.OUTFIT_VERSION, r = state.rig }
	for _, g in GROUPS do
		local group = (state :: any)[g.field]
		local enc = {}
		for _, slot in g.slots do
			local v = group[slot]
			if v and v.id ~= 0 then
				enc[slot] = { i = v.id, s = v.source }
			end
		end
		out[g.key] = enc
	end

	-- aksesori: array urut seq (yang tanpa seq = milik avatar asli -> paling awal)
	local list = {}
	for _, a in state.accessories do
		table.insert(list, a)
	end
	table.sort(list, function(a, b)
		if (a.seq or 0) ~= (b.seq or 0) then
			return (a.seq or 0) < (b.seq or 0)
		end
		return a.assetId < b.assetId
	end)
	local acc = {}
	for _, a in list do
		table.insert(acc, {
			i = a.assetId,
			t = a.assetType,
			o = a.order,
			p = a.puffiness,
			s = a.source,
			q = a.seq ~= nil or nil, -- dipakai dari katalog (punya seq)
		})
	end
	out.ac = acc

	local co = {}
	for _, k in Map.ColorSlots do
		co[k] = state.colors[k]
	end
	out.co = co
	local sc = {}
	for _, k in Map.ScaleSlots do
		sc[k] = state.scales[k]
	end
	out.sc = sc
	return out
end

-- Tabel ringkas -> OutfitState. Return (state, nil) | (nil, alasan).
-- Entri rusak dibuang satu per satu; hanya bentuk dasar yang salah membuat decode gagal.
function PlayerData.decodeOutfit(raw: any): (State?, string?)
	if type(raw) ~= "table" then
		return nil, "missing"
	end
	if raw.ov ~= PlayerData.OUTFIT_VERSION then
		return nil, "version"
	end
	if raw.r ~= "R15" and raw.r ~= "R6" then
		return nil, "rig"
	end
	local s = OutfitState.empty()
	s.rig = raw.r

	for _, g in GROUPS do
		local enc = raw[g.key]
		if enc ~= nil and type(enc) ~= "table" then
			return nil, "shape"
		end
		local group = (s :: any)[g.field]
		for _, slot in g.slots do
			local v = enc and enc[slot]
			if type(v) == "table" and isId(v.i) then
				group[slot] = { id = v.i, source = if isId(v.s) then v.s else nil }
			end
		end
	end

	local ac = raw.ac
	if ac ~= nil and type(ac) ~= "table" then
		return nil, "shape"
	end
	local rigid, layered, seq = 0, 0, 0
	for _, a in ac or {} do
		if type(a) ~= "table" or not isId(a.i) or type(a.t) ~= "string" then
			continue
		end
		local kind = Map.classify(a.t)
		local key = tostring(a.i)
		if kind ~= "accessory" or s.accessories[key] then
			continue
		end
		local isLayered = Map.isLayered(a.t)
		if isLayered then
			if layered >= Limits.MaxLayeredAccessories then
				continue
			end
			layered += 1
		else
			if rigid >= Limits.MaxRigidAccessories then
				continue
			end
			rigid += 1
		end
		local item: Types.Accessory = {
			assetId = a.i,
			assetType = a.t,
			isLayered = isLayered,
			source = if isId(a.s) then a.s else nil,
		}
		if a.q == true then
			seq += 1
			item.seq = seq -- dinomori ulang 1..n sesuai urutan simpan
		end
		if isLayered then
			local order = if isFinite(a.o) then a.o else (LayerOrder[a.t] or 1)
			item.order = math.clamp(math.floor(order), 1, 100)
			item.puffiness = if isFinite(a.p) then math.clamp(a.p, 0, 1) else 1
		end
		s.accessories[key] = item
	end

	if type(raw.co) == "table" then
		for _, k in Map.ColorSlots do
			local hex = raw.co[k]
			if type(hex) == "string" and string.match(hex, "^%x%x%x%x%x%x$") then
				s.colors[k] = string.upper(hex)
			end
		end
	end
	if type(raw.sc) == "table" then
		for _, k in Map.ScaleSlots do
			local n = raw.sc[k]
			if isFinite(n) and n >= 0 and n <= MAX_SCALE then
				s.scales[k] = n
			end
		end
	end
	return s, nil
end

return PlayerData
