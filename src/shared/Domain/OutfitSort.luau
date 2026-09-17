--!strict
-- DOMAIN MURNI: cari + urutkan daftar outfit tersimpan (Wardrobe.Summary) di client.
--   local rows = OutfitSort.apply(outfits, "recent", "pesta")
--   for _, opt in OutfitSort.OPTIONS do ... opt.key, opt.label ... end  -- isi dropdown sort
-- Pilihan mengikuti CAC (folder "Not In Any Folders" menyusul di PR folder).
-- Tidak mengubah tabel masukan; urutan selalu stabil (seri -> id).

export type Row = {
	id: number,
	name: string,
	createdAt: number,
	updatedAt: number,
	favorite: boolean,
}

export type Option = { key: string, label: string }

local OutfitSort = {}

OutfitSort.DEFAULT = "recent"

OutfitSort.OPTIONS = table.freeze({
	table.freeze({ key = "recent", label = "Recently Updated" }),
	table.freeze({ key = "favorited", label = "Favorited" }), -- favorit dulu, lalu terbaru diubah
	table.freeze({ key = "oldest", label = "Oldest to Newest" }),
	table.freeze({ key = "newest", label = "Newest to Oldest" }),
	table.freeze({ key = "az", label = "Alphabetical (A-Z)" }),
	table.freeze({ key = "za", label = "Alphabetical (Z-A)" }),
})

type Compare = (a: Row, b: Row) -> boolean

local function byRecent(a: Row, b: Row): boolean
	if a.updatedAt ~= b.updatedAt then
		return a.updatedAt > b.updatedAt
	end
	return a.id > b.id
end

local COMPARE: { [string]: Compare } = {
	recent = byRecent,
	favorited = function(a, b)
		if a.favorite ~= b.favorite then
			return a.favorite
		end
		return byRecent(a, b)
	end,
	oldest = function(a, b)
		if a.createdAt ~= b.createdAt then
			return a.createdAt < b.createdAt
		end
		return a.id < b.id
	end,
	newest = function(a, b)
		if a.createdAt ~= b.createdAt then
			return a.createdAt > b.createdAt
		end
		return a.id > b.id
	end,
	az = function(a, b)
		local la, lb = string.lower(a.name), string.lower(b.name)
		if la ~= lb then
			return la < lb
		end
		return a.id < b.id
	end,
	za = function(a, b)
		local la, lb = string.lower(a.name), string.lower(b.name)
		if la ~= lb then
			return la > lb
		end
		return a.id > b.id
	end,
}

function OutfitSort.labelOf(key: string): string
	for _, opt in OutfitSort.OPTIONS do
		if opt.key == key then
			return opt.label
		end
	end
	return OutfitSort.OPTIONS[1].label
end

-- Normalisasi kata kunci: huruf kecil, spasi dirapikan. "" = tanpa filter.
function OutfitSort.normalizeQuery(query: string?): string
	if type(query) ~= "string" then
		return ""
	end
	local q = string.lower(query)
	q = string.gsub(q, "%s+", " ")
	return string.match(q, "^%s*(.-)%s*$") or ""
end

-- Salinan baru: disaring (nama mengandung query, tanpa pola Lua) lalu diurutkan.
function OutfitSort.apply<T>(rows: { T }, sortKey: string?, query: string?): { T }
	local q = OutfitSort.normalizeQuery(query)
	local out: { T } = {}
	for _, row in rows do
		local name = (row :: any).name
		if q == "" or (type(name) == "string" and string.find(string.lower(name), q, 1, true) ~= nil) then
			table.insert(out, row)
		end
	end
	local compare = COMPARE[sortKey or ""] or COMPARE[OutfitSort.DEFAULT]
	table.sort(out, compare :: any)
	return out
end

return OutfitSort
