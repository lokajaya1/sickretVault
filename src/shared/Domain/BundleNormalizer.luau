--!strict
-- DOMAIN MURNI: tidak memanggil service Roblox, tidak yield, tidak membuat Instance.
-- Mengubah respons mentah bundle (AssetService:GetBundleDetailsAsync) menjadi Types.BundleInfo.
-- Jika bentuk respons Roblox berubah, cukup ubah file ini + tests/fixtures/BundleSamples.
--
-- Alur (dipanggil BundleService):
--   1. extract(raw)                 -> Extracted (assetIds + outfitId), tanpa tipe aset
--   2. ItemInfoService.getAssets    -> { [assetId] = assetType }   (tipe resmi, di server)
--   3. build(extracted, assetTypes) -> BundleInfo
--   4. enrich(info, enrichment)     -> BundleInfo + skala/MoodAnimation (opsional)

local Types = require(script.Parent.Types)
local Map = require(script.Parent.AssetTypeMap)

type BundleInfo = Types.BundleInfo
type BundlePart = Types.BundlePart
type OutfitEnrichment = Types.OutfitEnrichment

export type Extracted = {
	bundleId: number,
	name: string,
	bundleType: string?,
	outfitId: number?,
	assetIds: { number }, -- urutan sesuai respons, tanpa duplikat
	assetNames: { [number]: string },
	unknownItems: { { id: any, type: any } },
}

local BundleNormalizer = {}

-- Ambil field dengan beberapa kemungkinan nama (Id / id / ID).
local function field(t: { [any]: any }, ...: string): any
	for _, k in { ... } do
		local v = t[k]
		if v ~= nil then
			return v
		end
	end
	return nil
end

-- Id bisa angka atau string angka. Harus bilangan bulat positif.
local function toId(v: any): number?
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	if n and n > 0 and n == math.floor(n) and n < 2 ^ 53 then
		return n
	end
	return nil
end

local function toName(v: any, fallback: string): string
	if type(v) == "string" and v ~= "" then
		return v
	end
	return fallback
end

-- Return: (Extracted?, errorKode?)
function BundleNormalizer.extract(raw: any): (Extracted?, string?)
	if type(raw) ~= "table" then
		return nil, "BAD_RESPONSE"
	end
	local bundleId = toId(field(raw, "Id", "id", "ID"))
	if not bundleId then
		return nil, "BAD_BUNDLE_ID"
	end
	local items = field(raw, "Items", "items")
	if type(items) ~= "table" then
		return nil, "NO_ITEMS"
	end

	local bundleType = field(raw, "BundleType", "bundleType")
	local out: Extracted = {
		bundleId = bundleId,
		name = toName(field(raw, "Name", "name"), "Bundle " .. bundleId),
		bundleType = if type(bundleType) == "string" then bundleType else nil,
		outfitId = nil,
		assetIds = {},
		assetNames = {},
		unknownItems = {},
	}

	local seen: { [number]: boolean } = {}
	for _, item in items do
		if type(item) ~= "table" then
			table.insert(out.unknownItems, { id = nil, type = typeof(item) })
			continue
		end
		local rawId = field(item, "Id", "id", "ID")
		local rawType = field(item, "Type", "type")
		local id = toId(rawId)
		local kind = if type(rawType) == "string" then string.lower(rawType) else nil

		if id and kind == "asset" then
			if not seen[id] then
				seen[id] = true
				table.insert(out.assetIds, id)
				out.assetNames[id] = toName(field(item, "Name", "name"), "Asset " .. id)
			end
		elseif id and kind == "useroutfit" then
			out.outfitId = out.outfitId or id -- ambil yang pertama saja
		else
			table.insert(out.unknownItems, { id = rawId, type = rawType })
		end
	end

	if #out.assetIds == 0 then
		return nil, "NO_ASSETS"
	end
	return out, nil
end

-- assetTypes: { [assetId] = tipe } dari ItemInfoService (nama string / angka / EnumItem).
-- Aset tanpa tipe atau tipe tak didukung tetap masuk sebagai kind "unknown"
-- (UI bisa menampilkannya abu-abu; OutfitState.wearBundle mengabaikannya).
function BundleNormalizer.build(extracted: Extracted, assetTypes: { [number]: any }): BundleInfo
	local parts: { BundlePart } = {}
	for _, id in extracted.assetIds do
		local typeName = Map.normalize(assetTypes[id])
		local kind, slot
		if typeName then
			kind, slot = Map.classify(typeName)
		else
			kind, slot = "unknown", nil
		end
		table.insert(parts, {
			assetId = id,
			name = extracted.assetNames[id] or ("Asset " .. id),
			assetType = typeName or "Unknown",
			kind = kind,
			slot = slot,
		})
	end

	local unknownItems = table.clone(extracted.unknownItems)
	return {
		bundleId = extracted.bundleId,
		name = extracted.name,
		bundleType = extracted.bundleType,
		outfitId = extracted.outfitId,
		parts = parts,
		outfitScales = nil,
		unknownItems = unknownItems,
	}
end

function BundleNormalizer.hasHead(info: BundleInfo): boolean
	for _, p in info.parts do
		if p.kind == "bodyPart" and p.slot == "Head" then
			return true
		end
	end
	return false
end

-- Tambahkan data opsional dari UserOutfit bundle. Mengembalikan BundleInfo BARU.
--  * scales: hanya kunci yang dikenal (Map.ScaleSlots) dan bernilai angka wajar.
--  * moodAnimation: hanya jika bundle punya kepala dan belum punya MoodAnimation.
function BundleNormalizer.enrich(info: BundleInfo, enrichment: OutfitEnrichment?): BundleInfo
	local out = table.clone(info)
	out.parts = table.clone(info.parts)
	if not enrichment then
		return out
	end

	if type(enrichment.scales) == "table" then
		local scales: { [string]: number } = {}
		local any = false
		for _, key in Map.ScaleSlots do
			local v = (enrichment.scales :: any)[key]
			if type(v) == "number" and v == v and v >= 0 and v <= 10 then
				scales[key] = v
				any = true
			end
		end
		if any then
			out.outfitScales = scales
		end
	end

	local mood = toId(enrichment.moodAnimation)
	if mood and BundleNormalizer.hasHead(info) then
		local hasMood = false
		for _, p in out.parts do
			if p.slot == "MoodAnimation" or p.assetId == mood then
				hasMood = true
				break
			end
		end
		if not hasMood then
			table.insert(out.parts, {
				assetId = mood,
				name = "Mood",
				assetType = "MoodAnimation",
				kind = "animation",
				slot = "MoodAnimation",
			})
		end
	end
	return out
end

return BundleNormalizer
