--!strict
-- ADAPTER: OutfitState (plain table) <-> HumanoidDescription (Instance).
-- Tidak yield, tidak memanggil web API, TIDAK menerapkan ke karakter (itu tugas AvatarService).
--
-- Dua tahap supaya bisa dites di luar Studio:
--   MURNI  : toSpec(state) -> Spec      fromSpec(spec) -> OutfitState      specEquals(a, b)
--   ENGINE : toDescription(state)       fromDescription(desc)              sameAppearance(d1, d2)
-- "Spec" = salinan plain-table dari properti HumanoidDescription (nama properti asli Roblox).

local Types = require(script.Parent.Parent.Domain.Types)
local Map = require(script.Parent.Parent.Domain.AssetTypeMap)
local OutfitState = require(script.Parent.Parent.Domain.OutfitState)
local LayerOrder = require(script.Parent.Parent.Config.LayerOrder)

type OutfitState = Types.OutfitState

export type AccessorySpec = {
	AssetId: number,
	AccessoryType: string, -- nama Enum.AccessoryType ("Hat", "Jacket", ...)
	IsLayered: boolean,
	Order: number?,
	Puffiness: number?,
}

export type Spec = {
	props: { [string]: number }, -- Head, Shirt, IdleAnimation, HeightScale, ...
	colors: { [string]: string }, -- HeadColor.. -> "RRGGBB"
	accessories: { AccessorySpec }, -- urutan deterministik
}

local DEFAULT_COLOR = "A3A2A5"

local DescriptionBuilder = {}

-- Nama Enum.AvatarAssetType (dipakai OutfitState) -> nama Enum.AccessoryType (dipakai HumanoidDescription)
DescriptionBuilder.AccessoryTypeOf = {
	Hat = "Hat",
	HairAccessory = "Hair",
	FaceAccessory = "Face",
	NeckAccessory = "Neck",
	ShoulderAccessory = "Shoulder",
	FrontAccessory = "Front",
	BackAccessory = "Back",
	WaistAccessory = "Waist",
	EyebrowAccessory = "Eyebrow",
	EyelashAccessory = "Eyelash",
	TShirtAccessory = "TShirt",
	ShirtAccessory = "Shirt",
	PantsAccessory = "Pants",
	ShortsAccessory = "Shorts",
	DressSkirtAccessory = "DressSkirt",
	SweaterAccessory = "Sweater",
	JacketAccessory = "Jacket",
	LeftShoeAccessory = "LeftShoe",
	RightShoeAccessory = "RightShoe",
} :: { [string]: string }

-- Kebalikannya: AccessoryType -> AvatarAssetType
DescriptionBuilder.AssetTypeOf = {} :: { [string]: string }
for assetType, accType in DescriptionBuilder.AccessoryTypeOf do
	DescriptionBuilder.AssetTypeOf[accType] = assetType
end

---------------------------------------------------------------------------
-- Sanitasi (data bisa datang dari DataStore / remote / API)
---------------------------------------------------------------------------

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function cleanId(n: any): number
	if isFinite(n) and n >= 0 and n % 1 == 0 then
		return n
	end
	return 0
end

local function cleanHex(s: any): string
	if type(s) == "string" then
		local hex = string.upper((string.gsub(s, "^#", "")))
		if string.match(hex, "^%x%x%x%x%x%x$") then
			return hex
		end
	end
	return DEFAULT_COLOR
end

local function sortAccessories(list: { AccessorySpec })
	table.sort(list, function(a, b)
		if a.IsLayered ~= b.IsLayered then
			return not a.IsLayered -- rigid dulu, lalu layered
		end
		if a.IsLayered and a.Order ~= b.Order then
			return (a.Order or 0) < (b.Order or 0)
		end
		return a.AssetId < b.AssetId
	end)
end

---------------------------------------------------------------------------
-- MURNI
---------------------------------------------------------------------------

-- OutfitState -> Spec. Return kedua = assetId aksesori yang dilewati (tipe tak dikenal / id rusak).
function DescriptionBuilder.toSpec(state: OutfitState): (Spec, { number })
	local props: { [string]: number } = {}
	for _, pair in
		{
			{ Map.BodyPartSlots, state.bodyParts },
			{ Map.AnimationSlots, state.animations },
			{ Map.ClassicSlots, state.classic },
		}
	do
		local slots, group = pair[1] :: { string }, pair[2] :: { [string]: Types.SlotValue }
		for _, slot in slots do
			local v = group[slot]
			props[slot] = cleanId(v and v.id)
		end
	end
	local defaults = OutfitState.empty().scales
	for _, k in Map.ScaleSlots do
		local v = state.scales[k]
		props[k] = if isFinite(v) then v else defaults[k]
	end

	local colors: { [string]: string } = {}
	for _, k in Map.ColorSlots do
		colors[k] = cleanHex(state.colors[k])
	end

	local accessories: { AccessorySpec } = {}
	local skipped: { number } = {}
	for _, a in state.accessories do
		local accType = DescriptionBuilder.AccessoryTypeOf[a.assetType]
		local id = cleanId(a.assetId)
		if accType == nil or id == 0 then
			table.insert(skipped, a.assetId)
		else
			local layered = Map.isLayered(a.assetType)
			table.insert(accessories, {
				AssetId = id,
				AccessoryType = accType,
				IsLayered = layered,
				Order = if layered then (a.order or LayerOrder[a.assetType] or 1) else nil,
				Puffiness = if layered
					then math.clamp(if isFinite(a.puffiness) then a.puffiness :: number else 1, 0, 1)
					else nil,
			})
		end
	end
	sortAccessories(accessories)

	return { props = props, colors = colors, accessories = accessories }, skipped
end

-- Spec -> OutfitState baru. Batas aksesori TIDAK dicek di sini:
-- avatar asli pemain dipakai apa adanya (Roblox sudah memvalidasinya).
function DescriptionBuilder.fromSpec(spec: Spec, rig: string?): OutfitState
	local s = OutfitState.empty()
	s.rig = if rig == "R6" then "R6" else "R15"
	for _, pair in
		{
			{ Map.BodyPartSlots, s.bodyParts },
			{ Map.AnimationSlots, s.animations },
			{ Map.ClassicSlots, s.classic },
		}
	do
		local slots, group = pair[1] :: { string }, pair[2] :: { [string]: Types.SlotValue }
		for _, slot in slots do
			group[slot] = { id = cleanId(spec.props[slot]) }
		end
	end
	for _, k in Map.ScaleSlots do
		local v = spec.props[k]
		if isFinite(v) then
			s.scales[k] = v
		end
	end
	for _, k in Map.ColorSlots do
		s.colors[k] = cleanHex(spec.colors[k])
	end
	for _, a in spec.accessories do
		local assetType = DescriptionBuilder.AssetTypeOf[a.AccessoryType]
		local id = cleanId(a.AssetId)
		if assetType and id ~= 0 then
			local layered = Map.isLayered(assetType)
			s.accessories[tostring(id)] = {
				assetId = id,
				assetType = assetType,
				isLayered = layered,
				order = if layered then (a.Order or LayerOrder[assetType] or 1) else nil,
				puffiness = if layered then (a.Puffiness or 1) else nil,
			}
		end
	end
	return s
end

-- Bandingkan dua Spec. Return (sama?, keterangan perbedaan pertama).
function DescriptionBuilder.specEquals(a: Spec, b: Spec): (boolean, string?)
	for k, v in a.props do
		local w = b.props[k]
		if type(w) ~= "number" or math.abs(v - w) > 1e-3 then
			return false, ("props.%s: %s vs %s"):format(k, tostring(v), tostring(w))
		end
	end
	for k, v in a.colors do
		if b.colors[k] ~= v then
			return false, ("colors.%s: %s vs %s"):format(k, v, tostring(b.colors[k]))
		end
	end
	if #a.accessories ~= #b.accessories then
		return false, ("jumlah aksesori: %d vs %d"):format(#a.accessories, #b.accessories)
	end
	for i, x in a.accessories do
		local y = b.accessories[i]
		if
			x.AssetId ~= y.AssetId
			or x.AccessoryType ~= y.AccessoryType
			or x.IsLayered ~= y.IsLayered
			or x.Order ~= y.Order
			or math.abs((x.Puffiness or 0) - (y.Puffiness or 0)) > 1e-3
		then
			return false,
				("aksesori #%d: %d(%s) vs %d(%s)"):format(i, x.AssetId, x.AccessoryType, y.AssetId, y.AccessoryType)
		end
	end
	return true, nil
end

---------------------------------------------------------------------------
-- ENGINE (hanya di Roblox: butuh Instance, Enum, Color3)
---------------------------------------------------------------------------

local function accessoryEnum(name: string): EnumItem?
	local ok, item = pcall(function()
		return (Enum.AccessoryType :: any)[name]
	end)
	return if ok then item else nil
end

-- OutfitState -> HumanoidDescription BARU (belum di-parent, belum diterapkan).
function DescriptionBuilder.toDescription(state: OutfitState): (HumanoidDescription, { number })
	local spec, skipped = DescriptionBuilder.toSpec(state)
	local desc = Instance.new("HumanoidDescription")
	for k, v in spec.props do
		(desc :: any)[k] = v
	end
	for k, hex in spec.colors do
		(desc :: any)[k] = Color3.fromHex(hex)
	end
	local list = {}
	for _, a in spec.accessories do
		local enum = accessoryEnum(a.AccessoryType)
		if enum then
			table.insert(list, {
				AssetId = a.AssetId,
				AccessoryType = enum,
				IsLayered = a.IsLayered,
				Order = a.Order,
				Puffiness = a.Puffiness,
			})
		else
			table.insert(skipped, a.AssetId)
		end
	end
	desc:SetAccessories(list, true) -- true = sertakan aksesori rigid
	return desc, skipped
end

-- HumanoidDescription -> Spec (baca properti apa adanya).
function DescriptionBuilder.specFromDescription(desc: HumanoidDescription): Spec
	local props: { [string]: number } = {}
	for _, list in { Map.BodyPartSlots, Map.AnimationSlots, Map.ClassicSlots, Map.ScaleSlots } do
		for _, k in list do
			props[k] = (desc :: any)[k]
		end
	end
	local colors: { [string]: string } = {}
	for _, k in Map.ColorSlots do
		colors[k] = cleanHex(((desc :: any)[k] :: Color3):ToHex())
	end
	local accessories: { AccessorySpec } = {}
	for _, a in desc:GetAccessories(true) do
		local accType = a.AccessoryType and a.AccessoryType.Name
		if type(accType) == "string" and DescriptionBuilder.AssetTypeOf[accType] then
			local layered = a.IsLayered == true
			table.insert(accessories, {
				AssetId = cleanId(a.AssetId),
				AccessoryType = accType,
				IsLayered = layered,
				Order = if layered then a.Order else nil,
				Puffiness = if layered then a.Puffiness else nil,
			})
		end
	end
	sortAccessories(accessories)
	return { props = props, colors = colors, accessories = accessories }
end

-- HumanoidDescription -> OutfitState baru (mis. avatar asli pemain = baseline).
function DescriptionBuilder.fromDescription(desc: HumanoidDescription, rig: string?): OutfitState
	return DescriptionBuilder.fromSpec(DescriptionBuilder.specFromDescription(desc), rig)
end

-- Apakah dua description menghasilkan tampilan yang sama (menurut properti yang kita kelola)?
function DescriptionBuilder.sameAppearance(a: HumanoidDescription, b: HumanoidDescription): (boolean, string?)
	return DescriptionBuilder.specEquals(
		DescriptionBuilder.specFromDescription(a),
		DescriptionBuilder.specFromDescription(b)
	)
end

return DescriptionBuilder
