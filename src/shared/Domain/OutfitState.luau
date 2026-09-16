--!strict
-- DOMAIN MURNI (tanpa yield, tanpa Instance, tanpa service) untuk mengubah outfit.
-- Semua fungsi mengembalikan state BARU (immutable) -> undo/redo gratis & mudah di-test.

local Types = require(script.Parent.Types)
local Map = require(script.Parent.AssetTypeMap)
local LayerOrder = require(script.Parent.Parent.Config.LayerOrder)
local Limits = require(script.Parent.Parent.Config.Limits)

type OutfitState = Types.OutfitState
type Accessory = Types.Accessory
type BundlePart = Types.BundlePart

local OutfitState = {}

local function deepCopy<T>(t: T): T
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in t :: any do
		out[k] = deepCopy(v)
	end
	return out :: any
end
OutfitState.clone = deepCopy

function OutfitState.empty(): OutfitState
	local s: OutfitState = {
		rig = "R15",
		bodyParts = {},
		animations = {},
		classic = {},
		accessories = {},
		colors = {},
		scales = {
			HeightScale = 1,
			WidthScale = 1,
			DepthScale = 1,
			HeadScale = 1,
			BodyTypeScale = 0,
			ProportionScale = 0,
		},
	}
	for _, k in Map.BodyPartSlots do
		s.bodyParts[k] = { id = 0 }
	end
	for _, k in Map.AnimationSlots do
		s.animations[k] = { id = 0 }
	end
	for _, k in Map.ClassicSlots do
		s.classic[k] = { id = 0 }
	end
	for _, k in Map.ColorSlots do
		s.colors[k] = "A3A2A5"
	end
	return s
end

local function groupFor(state: OutfitState, kind: string): { [string]: Types.SlotValue }?
	if kind == "bodyPart" then
		return state.bodyParts
	end
	if kind == "animation" then
		return state.animations
	end
	if kind == "classic" then
		return state.classic
	end
	return nil
end

local function countAccessories(state: OutfitState): (number, number)
	local rigid, layered = 0, 0
	for _, a in state.accessories do
		if a.isLayered then
			layered += 1
		else
			rigid += 1
		end
	end
	return rigid, layered
end

local function maxOrder(state: OutfitState): number
	local m = 0
	for _, a in state.accessories do
		if a.isLayered and a.order and a.order > m then
			m = a.order
		end
	end
	return m
end

local function maxSeq(state: OutfitState): number
	local m = 0
	for _, a in state.accessories do
		if a.seq and a.seq > m then
			m = a.seq
		end
	end
	return m
end

-- Lepas aksesori tertua bertipe `typeName` sampai jumlahnya <= keep.
-- Tertua = seq terkecil (aksesori avatar asli tanpa seq dianggap paling tua).
local function dropOldestOfType(state: OutfitState, typeName: string, keep: number)
	local list: { Accessory } = {}
	for _, a in state.accessories do
		if a.assetType == typeName then
			table.insert(list, a)
		end
	end
	table.sort(list, function(a, b)
		if (a.seq or 0) ~= (b.seq or 0) then
			return (a.seq or 0) < (b.seq or 0)
		end
		return a.assetId < b.assetId
	end)
	for i = 1, #list - math.max(keep, 0) do
		state.accessories[tostring(list[i].assetId)] = nil
	end
end

-- Pakai satu aset. `source` = bundleId jika aset berasal dari bundle.
-- Return: (stateBaru, errorKode?)
-- `maxPerType` (opsional) = batas per tipe aksesori dari GetAvatarRulesAsync (mis. Hat=3).
-- Jika tipe sudah penuh, aksesori TERLAMA dari tipe itu dilepas (diganti), seperti editor avatar.
-- Batas 0 = tipe tidak boleh dipakai -> "LIMIT_TYPE".
function OutfitState.wear(
	state: OutfitState,
	assetId: number,
	assetTypeName: string,
	source: number?,
	maxPerType: { [string]: number }?
): (OutfitState, string?)
	local kind, slot = Map.classify(assetTypeName)
	if kind == "unknown" or not slot then
		return state, "UNSUPPORTED_TYPE"
	end
	local s = deepCopy(state)

	local group = groupFor(s, kind)
	if group then
		group[slot] = { id = assetId, source = source }
		return s, nil
	end

	-- accessory
	local key = tostring(assetId)
	if s.accessories[key] then
		return state, nil -- sudah dipakai
	end
	local layered = Map.isLayered(assetTypeName)
	local maxOfType = maxPerType and maxPerType[assetTypeName]
	if maxOfType ~= nil then
		if maxOfType <= 0 then
			return state, "LIMIT_TYPE"
		end
		dropOldestOfType(s, assetTypeName, maxOfType - 1)
	end
	local rigid, lay = countAccessories(s)
	if layered and lay >= Limits.MaxLayeredAccessories then
		return state, "LIMIT_LAYERED"
	elseif not layered and rigid >= Limits.MaxRigidAccessories then
		return state, "LIMIT_RIGID"
	end

	-- Sepatu: hanya satu kiri & satu kanan -> ganti yang lama.
	if assetTypeName == "LeftShoeAccessory" or assetTypeName == "RightShoeAccessory" then
		for k, a in s.accessories do
			if a.assetType == assetTypeName then
				s.accessories[k] = nil
			end
		end
	end

	local acc: Accessory = {
		assetId = assetId,
		assetType = assetTypeName,
		isLayered = layered,
		source = source,
		seq = maxSeq(s) + 1,
	}
	if layered then
		-- urutan default per tipe (kaos di dalam, jaket di luar). Pemain bisa ubah via setLayerOrder.
		acc.order = LayerOrder[assetTypeName] or (maxOrder(s) + 1)
		acc.puffiness = 1
	end
	s.accessories[key] = acc
	return s, nil
end

-- Lepas satu aset.
--   aksesori            -> dihapus
--   body part / animasi -> kembali ke baseline (avatar asal)
--   classic             -> kembali ke baseline; bila yang dilepas ADALAH item baseline -> kosong (id 0),
--                          jadi baju/wajah bawaan avatar juga bisa dilepas.
function OutfitState.remove(state: OutfitState, assetId: number, baseline: OutfitState?): OutfitState
	local s = deepCopy(state)
	local key = tostring(assetId)
	if s.accessories[key] then
		s.accessories[key] = nil
		return s
	end
	for _, pair in
		{
			{ s.bodyParts, baseline and baseline.bodyParts, false },
			{ s.animations, baseline and baseline.animations, false },
			{ s.classic, baseline and baseline.classic, true },
		}
	do
		local group, base, emptyIfBaseline = pair[1], pair[2], pair[3]
		for slot, v in group do
			if v.id == assetId then
				local b = if base then base[slot] else nil
				if b and not (emptyIfBaseline and b.id == assetId) then
					group[slot] = deepCopy(b)
				else
					group[slot] = { id = 0 }
				end
			end
		end
	end
	return s
end

-- Pakai sebagian / seluruh bagian bundle.
-- partIds = nil -> semua part. Part dengan kind "unknown" diabaikan.
function OutfitState.wearBundle(
	state: OutfitState,
	bundleId: number,
	parts: { BundlePart },
	partIds: { number }?,
	scales: { [string]: number }?,
	maxPerType: { [string]: number }?
): (OutfitState, { string })
	local wanted: { [number]: boolean }? = nil
	if partIds then
		local set: { [number]: boolean } = {}
		for _, id in partIds do
			set[id] = true
		end
		wanted = set
	end
	local s = state
	local errors = {}
	for _, p in parts do
		if p.kind ~= "unknown" and (wanted == nil or (wanted :: { [number]: boolean })[p.assetId]) then
			local nextState, err = OutfitState.wear(s, p.assetId, p.assetType, bundleId, maxPerType)
			s = nextState
			if err then
				table.insert(errors, err)
			end
		end
	end
	if scales then
		s = deepCopy(s)
		for k, v in scales do
			if s.scales[k] ~= nil then
				s.scales[k] = v
			end
		end
	end
	return s, errors
end

-- Lepas semua bagian yang berasal dari bundle tertentu.
function OutfitState.removeBundle(state: OutfitState, bundleId: number, baseline: OutfitState?): OutfitState
	local s = deepCopy(state)
	for k, a in s.accessories do
		if a.source == bundleId then
			s.accessories[k] = nil
		end
	end
	for _, pair in
		{
			{ s.bodyParts, baseline and baseline.bodyParts },
			{ s.animations, baseline and baseline.animations },
			{ s.classic, baseline and baseline.classic },
		}
	do
		local group, base = pair[1], pair[2]
		for slot, v in group do
			if v.source == bundleId then
				group[slot] = if base and base[slot] then deepCopy(base[slot]) else { id = 0 }
			end
		end
	end
	return s
end

function OutfitState.setLayerOrder(state: OutfitState, assetId: number, order: number): OutfitState
	local a = state.accessories[tostring(assetId)]
	if not a or not a.isLayered then
		return state
	end
	local s = deepCopy(state)
	s.accessories[tostring(assetId)].order = math.clamp(math.floor(order), 1, 100)
	return s
end

-- Daftar semua assetId yang sedang dipakai (untuk cek kepemilikan / Buy All).
function OutfitState.wornAssetIds(state: OutfitState): { number }
	local ids = {}
	for _, a in state.accessories do
		table.insert(ids, a.assetId)
	end
	for _, g in { state.bodyParts, state.animations, state.classic } do
		for _, v in g do
			if v.id ~= 0 then
				table.insert(ids, v.id)
			end
		end
	end
	return ids
end

-- Bundle apa saja yang sedang dipakai sebagian (untuk UI "sebagian dari bundle X").
function OutfitState.activeBundles(state: OutfitState): { [number]: number }
	local counts = {}
	local function add(src: number?)
		if src then
			counts[src] = (counts[src] or 0) + 1
		end
	end
	for _, a in state.accessories do
		add(a.source)
	end
	for _, g in { state.bodyParts, state.animations, state.classic } do
		for _, v in g do
			add(v.source)
		end
	end
	return counts
end

return OutfitState
