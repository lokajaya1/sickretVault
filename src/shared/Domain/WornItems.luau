--!strict
-- Ubah OutfitState menjadi daftar item untuk tab "Wearing" (urutan tetap, tanpa duplikat).
--   local list = WornItems.list(state, known)
--   -- known: { [assetId] = item katalog yang pernah dilihat client } (opsional, untuk nama/harga)
-- Urutan: aksesori terbaru dulu, lalu pakaian klasik, bagian tubuh, animasi.
-- Item yang tidak ada di `known` diberi nama ramah dari slot/tipe (mis. "Shirt", "Eyebrow", "T-Shirt").
-- item.group: "accessory" | "classic" | "body" | "animation". Strip Wearing menampilkan accessory + classic,
-- plus body/animation yang berasal dari BUNDLE (item.source = bundleId) supaya bisa dibongkar pasang
-- per part. Melepasnya (op remove) mengembalikan slot itu ke avatar asal; body/animation bawaan avatar
-- tidak ditampilkan karena tidak ada yang bisa dilepas.

local Map = require(script.Parent.AssetTypeMap)

export type Group = "accessory" | "classic" | "body" | "animation"

export type Item = {
	id: number,
	group: Group,
	itemType: string, -- selalu "Asset"
	name: string,
	assetType: string?,
	price: number?,
	creatorName: string?,
	source: number?, -- bundleId asal (bila dari bundle)
}

local WornItems = {}

local function validId(v: any): boolean
	return type(v) == "number" and v > 0
end

-- Nama cadangan yang enak dibaca: "EyebrowAccessory" -> "Eyebrow", "GraphicTShirt" -> "T-Shirt",
-- "LeftShoeAccessory" -> "Left Shoe", "Hat" -> "Hat".
local SPECIAL: { [string]: string } = {
	GraphicTShirt = "T-Shirt",
	TShirtAccessory = "T-Shirt",
	Face = "Face",
}

function WornItems.friendlyName(typeName: string): string
	local special = SPECIAL[typeName]
	if special then
		return special
	end
	local base = typeName:gsub("Accessory$", "")
	if base == "" then
		return "Accessory"
	end
	-- pisahkan CamelCase: "LeftShoe" -> "Left Shoe"
	local spaced = base:gsub("(%l)(%u)", "%1 %2")
	return spaced
end

local function makeItem(
	id: number,
	group: Group,
	fallbackName: string,
	assetType: string?,
	known: { [number]: any }?,
	source: number?
): Item
	local src = if validId(source) then source else nil
	local k = if known then known[id] else nil
	if type(k) == "table" and type(k.name) == "string" and k.name ~= "" then
		return {
			id = id,
			group = group,
			itemType = "Asset",
			name = k.name,
			assetType = k.assetType or assetType,
			price = k.price,
			creatorName = k.creatorName,
			source = src,
		}
	end
	return {
		id = id,
		group = group,
		itemType = "Asset",
		name = WornItems.friendlyName(fallbackName),
		assetType = assetType,
		source = src,
	}
end

-- Hanya item yang bisa dilepas pemain: aksesori, pakaian klasik, dan part tubuh/animasi dari bundle.
function WornItems.removable(items: { Item }): { Item }
	local out = {}
	for _, it in items do
		if it.group == "accessory" or it.group == "classic" or it.source ~= nil then
			table.insert(out, it)
		end
	end
	return out
end

function WornItems.list(state: any, known: { [number]: any }?): { Item }
	local out: { Item } = {}
	if type(state) ~= "table" then
		return out
	end
	local seen: { [number]: boolean } = {}
	local function push(item: Item)
		if not seen[item.id] then
			seen[item.id] = true
			table.insert(out, item)
		end
	end

	-- 1. Aksesori: terbaru (seq terbesar) dulu; seri -> assetId kecil dulu.
	local accs = {}
	if type(state.accessories) == "table" then
		for _, a in state.accessories do
			if type(a) == "table" and validId(a.assetId) then
				table.insert(accs, a)
			end
		end
	end
	table.sort(accs, function(a, b)
		local sa, sb = tonumber(a.seq) or 0, tonumber(b.seq) or 0
		if sa ~= sb then
			return sa > sb
		end
		return a.assetId < b.assetId
	end)
	for _, a in accs do
		local t = if type(a.assetType) == "string" then a.assetType else "Accessory"
		push(makeItem(a.assetId, "accessory", t, t, known, a.source))
	end

	-- 2. Slot: urutan tetap dari AssetTypeMap.
	local groups: { { any } } = {
		{ state.classic, Map.ClassicSlots, "classic" },
		{ state.bodyParts, Map.BodyPartSlots, "body" },
		{ state.animations, Map.AnimationSlots, "animation" },
	}
	for _, g in groups do
		local values, slots, groupName = g[1], g[2], g[3]
		if type(values) == "table" then
			for _, slot in slots do
				local v = values[slot]
				if type(v) == "table" and validId(v.id) then
					push(makeItem(v.id, groupName, slot, nil, known, v.source))
				end
			end
		end
	end

	return out
end

return WornItems
