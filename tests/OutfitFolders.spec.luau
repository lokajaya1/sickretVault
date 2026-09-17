--!strict
-- Studio: require(game.ReplicatedStorage.Tests["OutfitFolders.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Wardrobe = require(Shared.Domain.Wardrobe)
local Folders = require(Shared.Domain.OutfitFolders)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function list(t: any): string
	local parts = {}
	for _, v in t or {} do
		table.insert(parts, tostring(v))
	end
	return table.concat(parts, ",")
end

local ENC = { ov = 1, r = "R15", ac = { { i = 5, t = "Hat" } } }

-- data dengan `n` outfit (id 1..n) dan folder sesuai `names`
local function newData(outfits: number, names: { string }): any
	local d: any = {}
	Wardrobe.sanitize(d)
	Folders.sanitize(d)
	for _ = 1, outfits do
		Wardrobe.add(d, "O", ENC, 100)
	end
	for _, name in names do
		assert(Folders.add(d, name, 100), "gagal membuat folder " .. name)
	end
	return d
end

return function()
	-- 1. cleanName: batas panjang sendiri (24), bukan batas nama outfit (32)
	eq(Folders.cleanName("  Pesta  Malam "), "Pesta Malam", "trim")
	eq(select(2, Folders.cleanName(string.rep("a", Folders.MAX_NAME + 1))), "TOO_LONG", "lebih dari 24")
	eq(Folders.cleanName(string.rep("a", Folders.MAX_NAME)), string.rep("a", Folders.MAX_NAME), "pas 24")
	eq(select(2, Folders.cleanName("   ")), "EMPTY", "kosong")
	eq(select(2, Folders.cleanName(7)), "BAD_NAME", "bukan string")

	-- 2. sanitize: data kosong
	local d = newData(0, {})
	eq(#d.folders, 0, "folders kosong")
	eq(d.nextFolderId, 1, "id folder mulai 1")
	eq(Folders.isFull(d), false, "belum penuh")

	-- 3. sanitize: buang folder rusak/ganda, nextFolderId > id terbesar, id mati dilepas dari outfit
	local dirty: any = {
		outfits = {
			{ id = 1, n = "A", t = 1, o = ENC, g = { 5, 5, 99, 2.5, "x", 2 } },
			{ id = 2, n = "B", t = 1, o = ENC, g = "rusak" },
			{ id = 3, n = "C", t = 1, o = ENC, g = { 9, 8, 7, 6, 5, 4, 3, 2, 1 } },
		},
		folders = {
			{ id = 5, n = "Lima", t = 10 },
			{ id = 5, n = "ganda", t = 10 },
			{ id = 2.5, n = "pecahan", t = 10 },
			{ id = 3, n = 7, t = 10 },
			{ id = 2, n = "Dua", t = 0 / 0 },
			"rusak",
			{ id = 9, n = "Sembilan", t = 10 },
			{ id = 1, n = "Satu", t = 10 },
			{ id = 4, n = "Empat", t = 10 },
			{ id = 6, n = "Enam", t = 10 },
			{ id = 7, n = "Tujuh", t = 10 },
			{ id = 8, n = "Delapan", t = 10 },
		},
		nextFolderId = 3,
	}
	Wardrobe.sanitize(dirty)
	Folders.sanitize(dirty)
	eq(#dirty.folders, 8, "folder rusak & ganda dibuang")
	eq(dirty.nextFolderId, 10, "nextFolderId > id terbesar")
	eq(dirty.folders[2].t, 0, "waktu rusak -> 0")
	eq(list(dirty.outfits[1].g), "2,5", "id mati dibuang, urut naik, tanpa ganda")
	eq(dirty.outfits[2].g, nil, "g rusak -> nil")
	eq(#dirty.outfits[3].g, Folders.MAX_PER_OUTFIT, "maks folder per outfit")

	-- 4. add: nama ganda (beda kapital) & batas jumlah
	d = newData(0, { "Pesta" })
	eq(select(2, Folders.add(d, "pesta", 100)), "DUPLICATE", "nama ganda ditolak")
	for i = 2, Folders.MAX_FOLDERS do
		assert(Folders.add(d, "F" .. i, 100), "folder ke-" .. i)
	end
	eq(Folders.isFull(d), true, "penuh")
	eq(select(2, Folders.add(d, "Lagi", 100)), "FULL", "lebih dari batas")
	eq(d.folders[1].id, 1, "id folder pertama")
	eq(d.nextFolderId, Folders.MAX_FOLDERS + 1, "id tidak dipakai ulang")

	-- 5. rename
	d = newData(0, { "Pesta", "Santai" })
	eq(select(2, Folders.rename(d, 99, "X")), "NOT_FOUND", "folder tidak ada")
	eq(select(2, Folders.rename(d, 1, "santai")), "DUPLICATE", "bentrok nama lain")
	eq(Folders.rename(d, 1, "PESTA"), true, "ganti kapital nama sendiri boleh")
	eq(d.folders[1].n, "PESTA", "nama berubah")

	-- 6. setFolders: ganti total folder satu outfit
	d = newData(2, { "A", "B", "C" })
	eq(select(2, Folders.setFolders(d, 99, { 1 })), "NOT_FOUND", "outfit tidak ada")
	eq(select(2, Folders.setFolders(d, 1, { 1, 99 })), "BAD_ARG", "folder tidak ada")
	eq(select(2, Folders.setFolders(d, 1, "x")), "BAD_ARG", "bukan tabel")
	eq(Folders.setFolders(d, 1, { 3, 1, 1 }), true, "set folder")
	eq(list(Folders.foldersOf(d, 1)), "1,3", "urut naik & tanpa ganda")
	eq(Folders.setFolders(d, 1, {}), true, "kosongkan")
	eq(d.outfits[1].g, nil, "kosong disimpan sebagai nil")

	-- 7. setFolders: lebih dari MAX_PER_OUTFIT
	d = newData(1, { "A", "B", "C", "D", "E", "F", "G", "H", "I" })
	eq(Folders.setFolders(d, 1, { 1, 2, 3, 4, 5, 6, 7, 8 }), true, "pas batas")
	eq(select(2, Folders.setFolders(d, 1, { 1, 2, 3, 4, 5, 6, 7, 8, 9 })), "TOO_MANY", "lebih dari batas")
	eq(#Folders.foldersOf(d, 1), 8, "isi lama tidak berubah saat gagal")

	-- 8. apply: tambah / lepas satu folder untuk banyak outfit
	d = newData(3, { "A", "B" })
	eq(select(2, Folders.apply(d, { 1, 2 }, 99, true)), "NOT_FOUND", "folder tidak ada")
	local res = Folders.apply(d, { 1, 2, 2, 999 }, 1, true)
	assert(res, "apply berhasil")
	eq(res.changed, 2, "2 outfit berubah (id ganda dihitung sekali)")
	eq(res.skipped, 1, "outfit tidak ada -> skipped")
	res = Folders.apply(d, { 1, 2 }, 1, true)
	assert(res, "apply kedua")
	eq(res.changed, 0, "sudah di folder -> tidak berubah")
	res = Folders.apply(d, { 1 }, 1, false)
	assert(res, "lepas")
	eq(res.changed, 1, "dilepas dari folder")
	eq(d.outfits[1].g, nil, "tanpa folder -> nil")
	eq(list(Folders.foldersOf(d, 2)), "1", "outfit lain tetap")

	-- 9. apply: outfit yang sudah penuh folder dilewati
	d = newData(1, { "A", "B", "C", "D", "E", "F", "G", "H", "I" })
	eq(Folders.setFolders(d, 1, { 1, 2, 3, 4, 5, 6, 7, 8 }), true, "isi penuh")
	res = Folders.apply(d, { 1 }, 9, true)
	assert(res, "apply saat penuh")
	eq(res.changed, 0, "tidak berubah")
	eq(res.skipped, 1, "dilewati")

	-- 10. remove: outfit tidak ikut terhapus, hanya dilepas
	d = newData(2, { "A", "B" })
	assert(Folders.apply(d, { 1, 2 }, 1, true), "isi folder A")
	assert(Folders.apply(d, { 1 }, 2, true), "isi folder B")
	eq(select(2, Folders.remove(d, 99)), "NOT_FOUND", "folder tidak ada")
	eq(Folders.remove(d, 1), true, "hapus folder A")
	eq(#d.outfits, 2, "outfit tetap ada")
	eq(list(Folders.foldersOf(d, 1)), "2", "id folder A dilepas")
	eq(d.outfits[2].g, nil, "outfit tanpa folder lain -> nil")

	-- 11. list: jumlah outfit per folder, urut dibuat
	d = newData(3, { "A", "B" })
	assert(Folders.apply(d, { 1, 2, 3 }, 2, true), "isi folder B")
	local rows = Folders.list(d)
	eq(#rows, 2, "2 folder")
	eq(rows[1].name, "A", "urut dibuat")
	eq(rows[1].count, 0, "folder A kosong")
	eq(rows[2].count, 3, "folder B berisi 3")

	-- 12. Wardrobe.summarize membawa id folder ke client
	local summary = Wardrobe.summarize(d.outfits[1])
	eq(list(summary.folders), "2", "summary.folders")
	eq(#Wardrobe.summarize(d.outfits[1]).folders, 1, "salinan, bukan referensi kosong")

	print("PASS OutfitFolders.spec")
end
