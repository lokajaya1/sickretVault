--!strict
-- Studio: require(game.ReplicatedStorage.Tests["Wardrobe.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Wardrobe = require(Shared.Domain.Wardrobe)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function newData(): any
	local d: any = {}
	Wardrobe.sanitize(d)
	return d
end

local ENC = {
	ov = 1,
	r = "R15",
	bp = { Head = { i = 111 }, Torso = { i = 112 } },
	an = { RunAnimation = { i = 40 } },
	cl = { Shirt = { i = 30 }, Pants = { i = 31 } },
	ac = { { i = 5, t = "Hat" }, { i = 6, t = "Hat" }, { i = 7, t = "HairAccessory" } },
}

return function()
	-- 1. cleanName: rapikan spasi, buang kontrol, batas panjang
	eq(Wardrobe.cleanName("  Pesta   Malam "), "Pesta Malam", "trim + spasi")
	eq(Wardrobe.cleanName("A\nB\tC"), "A B C", "kontrol -> spasi")
	eq(select(2, Wardrobe.cleanName("   ")), "EMPTY", "kosong")
	eq(select(2, Wardrobe.cleanName(5)), "BAD_NAME", "bukan string")
	eq(select(2, Wardrobe.cleanName("\255\254")), "BAD_NAME", "utf8 rusak")
	eq(select(2, Wardrobe.cleanName(string.rep("a", Wardrobe.MAX_NAME + 1))), "TOO_LONG", "terlalu panjang")
	eq(
		Wardrobe.cleanName(string.rep("é", Wardrobe.MAX_NAME)),
		string.rep("é", Wardrobe.MAX_NAME),
		"utf8 dihitung karakter"
	)
	eq(select(2, Wardrobe.cleanName(string.rep("a", 1000))), "BAD_NAME", "sangat panjang ditolak cepat")

	-- 2. sanitize: data kosong
	local d = newData()
	eq(#d.outfits, 0, "outfits kosong")
	eq(d.nextOutfitId, 1, "id mulai 1")
	eq(Wardrobe.defaultName(d), "Outfit 1", "nama bawaan")

	-- 3. sanitize: buang rusak & ganda, nextOutfitId > id terbesar
	local dirty: any = {
		outfits = {
			{ id = 4, n = "A", t = 1, o = {} },
			{ id = 4, n = "dup", t = 1, o = {} },
			{ id = 2.5, n = "B", t = 1, o = {} },
			{ id = 9, n = 7, t = 1, o = {} },
			{ id = 10, n = "C", t = 0 / 0, o = {} },
			{ id = 11, n = "D", t = 1, o = "x" },
			"rusak",
			{ id = 7, n = "E", t = 2, o = {} },
		},
		nextOutfitId = 3,
	}
	Wardrobe.sanitize(dirty)
	eq(#dirty.outfits, 2, "2 entri valid")
	eq(dirty.outfits[1].n, "A", "yang pertama dipertahankan")
	eq(dirty.outfits[2].id, 7, "urutan tetap")
	eq(dirty.nextOutfitId, 8, "next > id terbesar")
	local keep: any = { outfits = { { id = 2, n = "A", t = 1, o = {} } }, nextOutfitId = 20 }
	Wardrobe.sanitize(keep)
	eq(keep.nextOutfitId, 20, "next yang valid dipertahankan")
	local bad: any = { outfits = "x", nextOutfitId = -1 }
	Wardrobe.sanitize(bad)
	eq(#bad.outfits, 0, "outfits bukan tabel")
	eq(bad.nextOutfitId, 1, "next rusak")

	-- 4. add / find / list (terbaru dulu)
	local e1 = Wardrobe.add(d, "Satu", ENC, 100)
	local e2 = Wardrobe.add(d, "Dua", {}, 200)
	assert(e1 and e2, "add")
	eq(e1.id, 1, "id 1")
	eq(e2.id, 2, "id 2")
	eq(Wardrobe.count(d), 2, "count")
	eq(Wardrobe.find(d, 2), e2, "find")
	eq(select(2, Wardrobe.find(d, 2)), 2, "index")
	eq(Wardrobe.find(d, 99), nil, "find tidak ada")
	eq(Wardrobe.find(d, "1"), nil, "find id string")
	local rows = Wardrobe.list(d)
	eq(#rows, 2, "list")
	eq(rows[1].name, "Dua", "terbaru dulu")
	eq(rows[2].createdAt, 100, "createdAt")

	-- 5. summarize: hitung item & thumbnail (aksesori dulu, lalu baju urut nama slot)
	local s = Wardrobe.summarize(e1)
	eq(s.count, 3 + 2 + 2 + 1, "count semua grup")
	eq(#s.thumbs, Wardrobe.MAX_THUMBS, "thumbnail dibatasi")
	eq(s.thumbs[1], 5, "aksesori pertama")
	eq(s.thumbs[4], 31, "Pants sebelum Shirt")
	eq(Wardrobe.summarize(e2).count, 0, "outfit kosong")
	eq(
		#Wardrobe.summarize({ id = 3, n = "x", t = 1, o = { ac = { "x", { i = -1 } }, cl = 5 } }).thumbs,
		0,
		"rusak aman"
	)

	-- 6. rename / overwrite / remove; id tidak dipakai ulang
	eq(Wardrobe.rename(d, 1, "Baru"), true, "rename")
	eq(e1.n, "Baru", "nama berubah")
	eq(select(2, Wardrobe.rename(d, 99, "x")), "NOT_FOUND", "rename tidak ada")
	eq(Wardrobe.overwrite(d, 2, ENC), true, "overwrite")
	eq(e2.o, ENC, "isi ditimpa")
	eq(e2.n, "Dua", "nama tetap")
	eq(Wardrobe.remove(d, 1), true, "remove")
	eq(select(2, Wardrobe.remove(d, 1)), "NOT_FOUND", "remove dua kali")
	eq(Wardrobe.count(d), 1, "sisa 1")
	local e3 = Wardrobe.add(d, "Tiga", {}, 300)
	assert(e3, "add lagi")
	eq(e3.id, 3, "id tidak dipakai ulang")

	-- 7. penuh
	local full = newData()
	for i = 1, Wardrobe.MAX_SLOTS do
		assert(Wardrobe.add(full, "x" .. i, {}, i), "isi slot " .. i)
	end
	eq(Wardrobe.isFull(full), true, "penuh")
	local none, err = Wardrobe.add(full, "lebih", {}, 0)
	eq(none, nil, "tidak ditambah")
	eq(err, "FULL", "FULL")
	eq(full.nextOutfitId, Wardrobe.MAX_SLOTS + 1, "id tidak naik saat gagal")

	print("PASS Wardrobe.spec")
end
