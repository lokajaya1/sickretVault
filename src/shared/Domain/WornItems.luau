--!strict
-- Ubah OutfitState menjadi daftar item untuk tab "Wearing" (urutan tetap, tanpa duplikat).
--   local list = WornItems.list(state, known)
--   -- known: { [assetId] = item katalog yang pernah dilihat client } (opsional, untuk nama/harga)
-- Urutan: aksesori terbaru dulu, lalu pakaian klasik, bagian tubuh, animasi.
-- Item yang tidak ada di `known` diberi nama slot/tipe (mis. "Shirt", "HatAccessory").
-- item.group: "accessory" | "classic" | "body" | "animation" (strip Wearing hanya menampilkan
-- accessory + classic, karena body/animation tidak bisa "dilepas", hanya kembali ke avatar asal).

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
}

local WornItems = {}

local function validId(v: any): boolean
	return type(v) == "number" and v > 0
end

local function makeItem(
	id: number,
	group: Group,
	fallbackName: string,
	assetType: string?,
	known: { [number]: any }?
): Item
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
		}
	end
	return { id = id, group = group, itemType = "Asset", name = fallbackName, assetType = assetType }
end

-- Hanya item yang bisa dilepas pemain (aksesori + pakaian klasik).
function WornItems.removable(items: { Item }): { Item }
	local out = {}
	for _, it in items do
		if it.group == "accessory" or it.group == "classic" then
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
		push(makeItem(a.assetId, "accessory", t, t, known))
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
					push(makeItem(v.id, groupName, slot, nil, known))
				end
			end
		end
	end

	return out
end

return WornItems
