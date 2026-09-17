--!strict
-- Studio: require(game.ReplicatedStorage.Tests["OutfitSort.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local OutfitSort = require(Shared.Domain.OutfitSort)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function ids(rows: { any }): string
	local out = {}
	for _, r in rows do
		table.insert(out, tostring(r.id))
	end
	return table.concat(out, ",")
end

local ROWS = {
	{ id = 1, name = "beach", createdAt = 10, updatedAt = 50, favorite = false, folders = { 7 } },
	{ id = 2, name = "Party Night", createdAt = 20, updatedAt = 20, favorite = true, folders = { 7, 8 } },
	{ id = 3, name = "casual", createdAt = 30, updatedAt = 40, favorite = false, folders = {} },
	{ id = 4, name = "Party", createdAt = 30, updatedAt = 50, favorite = true, folders = { 8 } },
	{ id = 5, name = "a.b%c", createdAt = 5, updatedAt = 5, favorite = false },
}

return function()
	-- 1. urutan per pilihan (seri -> id)
	eq(ids(OutfitSort.apply(ROWS, "recent")), "4,1,3,2,5", "recent")
	eq(ids(OutfitSort.apply(ROWS, "favorited")), "4,2,1,3,5", "favorited")
	eq(ids(OutfitSort.apply(ROWS, "oldest")), "5,1,2,3,4", "oldest")
	eq(ids(OutfitSort.apply(ROWS, "newest")), "4,3,2,1,5", "newest")
	eq(ids(OutfitSort.apply(ROWS, "az")), "5,1,3,4,2", "az (huruf besar/kecil sama)")
	eq(ids(OutfitSort.apply(ROWS, "za")), "2,4,3,1,5", "za")
	eq(ids(OutfitSort.apply(ROWS, "hack")), "4,1,3,2,5", "key asing -> recent")
	eq(ids(OutfitSort.apply(ROWS, nil)), "4,1,3,2,5", "nil -> recent")

	-- 2. pencarian: tanpa beda huruf, spasi dirapikan, tanpa pola Lua
	eq(ids(OutfitSort.apply(ROWS, "az", "PARTY")), "4,2", "cari party")
	eq(ids(OutfitSort.apply(ROWS, "az", "  party   night ")), "2", "spasi dirapikan")
	eq(ids(OutfitSort.apply(ROWS, "az", "b%c")), "5", "karakter pola aman")
	eq(ids(OutfitSort.apply(ROWS, "az", ".")), "5", "titik literal")
	eq(ids(OutfitSort.apply(ROWS, "az", "zzz")), "", "tidak ada")
	eq(#OutfitSort.apply(ROWS, "az", "   "), 5, "spasi saja = semua")

	-- 3. tidak mengubah masukan
	eq(ROWS[1].id, 1, "masukan tetap")
	eq(OutfitSort.apply(ROWS) ~= ROWS, true, "salinan baru")

	-- 4. opsi & label
	eq(#OutfitSort.OPTIONS, 6, "6 pilihan")
	eq(OutfitSort.OPTIONS[1].key, OutfitSort.DEFAULT, "default di urutan pertama")
	eq(OutfitSort.labelOf("za"), "Alphabetical (Z-A)", "label")
	eq(OutfitSort.labelOf("x"), "Recently Updated", "label key asing")
	eq(OutfitSort.normalizeQuery(nil), "", "query nil")

	-- 5. tab folder
	eq(ids(OutfitSort.apply(ROWS, "az", nil, OutfitSort.ALL)), "5,1,3,4,2", "tab All")
	eq(ids(OutfitSort.apply(ROWS, "az", nil, 7)), "1,2", "folder 7")
	eq(ids(OutfitSort.apply(ROWS, "az", nil, 8)), "4,2", "folder 8")
	eq(ids(OutfitSort.apply(ROWS, "az", nil, OutfitSort.NONE)), "5,3", "Not In Any Folders")
	eq(ids(OutfitSort.apply(ROWS, "az", "party", 8)), "4,2", "folder + cari")
	eq(ids(OutfitSort.apply(ROWS, "az", "beach", 8)), "", "folder + cari tanpa hasil")
	eq(ids(OutfitSort.apply(ROWS, "az", nil, 99)), "", "folder kosong")

	-- 6. normalizeFolder: nilai asing / folder terhapus -> All
	eq(OutfitSort.normalizeFolder(nil), OutfitSort.ALL, "nil")
	eq(OutfitSort.normalizeFolder("hack"), OutfitSort.ALL, "string asing")
	eq(OutfitSort.normalizeFolder(2.5), OutfitSort.ALL, "pecahan")
	eq(OutfitSort.normalizeFolder(-3), OutfitSort.ALL, "negatif")
	eq(OutfitSort.normalizeFolder(OutfitSort.NONE), OutfitSort.NONE, "none")
	eq(OutfitSort.normalizeFolder(7), 7, "id folder")
	eq(OutfitSort.normalizeFolder(7, { [7] = true }), 7, "id dikenal")
	eq(OutfitSort.normalizeFolder(9, { [7] = true }), OutfitSort.ALL, "folder sudah dihapus")

	print("PASS OutfitSort.spec")
end
