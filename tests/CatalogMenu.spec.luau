--!strict
-- Studio: require(game.ReplicatedStorage.Tests["CatalogMenu.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CatalogMenu = require(Shared.Config.CatalogMenu)
local Categories = require(Shared.Config.Categories)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

-- Isi grid dengan kartu; error bila ada unit tertimpa atau keluar batas.
local function fill(compact: boolean): number
	local cols, rows = CatalogMenu.grid(compact)
	local used: { [string]: string } = {}
	local count = 0
	for _, g in CatalogMenu.list do
		local s = CatalogMenu.span(g, compact)
		assert(s.w >= 1 and s.h >= 1, g.id .. ": ukuran kartu minimal 1x1")
		assert(s.x >= 0 and s.x + s.w <= cols, g.id .. ": keluar batas kolom")
		assert(s.y >= 0 and s.y + s.h <= rows, g.id .. ": keluar batas baris")
		for dx = 0, s.w - 1 do
			for dy = 0, s.h - 1 do
				local key = ("%d,%d"):format(s.x + dx, s.y + dy)
				assert(used[key] == nil, ("%s tumpang tindih dengan %s di %s"):format(g.id, used[key] or "?", key))
				used[key] = g.id
				count += 1
			end
		end
	end
	return count
end

return function()
	-- 1. setiap grup punya label HURUF BESAR & id kategori yang benar-benar ada
	local seen: { [string]: string } = {}
	for _, g in CatalogMenu.list do
		eq(g.label, string.upper(g.label), g.id .. ": label huruf besar")
		assert(CatalogMenu.byId[g.id] == g, g.id .. ": ada di byId")
		assert(g.tone >= 0 and g.tone <= 1, g.id .. ": tone 0..1")
		for _, catId in g.categories do
			assert(Categories.byId[catId] ~= nil, ("kategori asing di %s: %s"):format(g.id, catId))
			assert(
				seen[catId] == nil,
				("kategori %s dipakai dua grup (%s, %s)"):format(catId, seen[catId] or "?", g.id)
			)
			seen[catId] = g.id
		end
	end

	-- 2. semua kategori katalog punya rumah di mozaik (tidak ada yang tidak bisa dibuka)
	for _, c in Categories.list do
		assert(seen[c.id] ~= nil, "kategori tanpa grup: " .. c.id)
	end

	-- 3. mozaik menutupi grid penuh, tanpa tumpang tindih (normal & compact)
	eq(fill(false), CatalogMenu.COLUMNS * CatalogMenu.ROWS, "grid normal terisi penuh")
	eq(fill(true), CatalogMenu.COLUMNS_COMPACT * CatalogMenu.ROWS_COMPACT, "grid compact terisi penuh")

	-- 4. grup tanpa categories (FEATURED) = semua kategori, urutan mengikuti Config/Categories
	local all = CatalogMenu.categoryIds("featured")
	eq(#all, #Categories.list, "featured: semua kategori")
	eq(all[1], Categories.list[1].id, "featured: kategori pertama")
	eq(CatalogMenu.firstCategory("featured"), Categories.list[1].id, "featured: tab awal")

	-- 5. tabel yang dikembalikan selalu baru (pemanggil boleh mengubahnya)
	local a = CatalogMenu.categoryIds("clothing")
	local b = CatalogMenu.categoryIds("clothing")
	assert(a ~= b, "categoryIds mengembalikan tabel baru")
	table.remove(a)
	eq(#b, #CatalogMenu.byId.clothing.categories, "tabel asli tidak ikut berubah")
	eq(CatalogMenu.firstCategory("clothing"), "layered", "clothing: tab awal Layered")

	-- 6. grup asing / kategori asing
	eq(#CatalogMenu.categoryIds("tidak_ada"), #Categories.list, "grup asing -> semua kategori")
	eq(CatalogMenu.groupOf("tidak_ada"), nil, "kategori asing tidak punya grup")

	-- 7. kategori -> grup pemilik (dipakai tombol kembali & sorotan tab)
	eq((CatalogMenu.groupOf("hair") :: any).id, "hair", "hair -> HAIR")
	eq((CatalogMenu.groupOf("layered") :: any).id, "clothing", "layered -> CLOTHING")
	eq((CatalogMenu.groupOf("classic_pants") :: any).id, "clothing", "celana klasik -> CLOTHING")
	eq((CatalogMenu.groupOf("emotes") :: any).id, "animations", "emotes -> ANIMATION PACKS")
	eq((CatalogMenu.groupOf("shoes") :: any).id, "accessories", "shoes -> ACCESSORIES")
	eq((CatalogMenu.groupOf("heads") :: any).id, "faces", "heads -> FACES")
	eq((CatalogMenu.groupOf("bodies") :: any).id, "characters", "bundle badan -> CHARACTERS")
	eq(Categories.byId.moods, nil, "MoodAnimation tidak dijual di katalog -> bukan kategori")
	eq(Categories.byId.shoes_layered, nil, "sepatu layered dijual sebagai bundle -> bukan kategori")
	eq((CatalogMenu.groupOf("face_acc") :: any).id, "faces", "aksesori wajah -> FACES")
	eq(CatalogMenu.firstCategory("faces"), "face_acc", "FACES: tab awal aksesori wajah (ada isinya)")
	eq(Categories.byId.faces, nil, "classic face sudah off-sale -> tidak jadi tab")
	eq((CatalogMenu.groupOf("eye_makeup") :: any).id, "makeup", "riasan mata -> MAKEUP")
	eq((CatalogMenu.groupOf("emotes") :: any).id, "animations", "emote -> ANIMATION PACKS")
	eq((CatalogMenu.groupOf("shoes") :: any).id, "accessories", "sepatu -> ACCESSORIES")
	eq((CatalogMenu.groupOf("backgrounds") :: any).id, "backgrounds", "latar -> BACKGROUNDS")

	-- 8. baris kedua = chip filter (All, Free, Limited) lalu kategori grup
	local chips = CatalogMenu.chips("clothing")
	eq(#chips, 3 + 11, "CLOTHING: 3 filter + 11 kategori (satu chip per tipe)")
	eq(chips[1].id, "all", "chip pertama All")
	eq(chips[2].id, "free", "chip kedua Free")
	eq(chips[3].id, "limited", "chip ketiga Limited")
	assert(chips[1].isFilter and chips[2].isFilter and chips[3].isFilter, "tiga chip pertama = filter")
	eq(chips[4].id, "layered", "kategori pertama CLOTHING")
	eq(chips[4].label, Categories.byId.layered.label, "label kategori dari Config/Categories")
	eq(chips[4].isFilter, false, "kategori bukan filter")
	eq(#CatalogMenu.chips("featured"), 3 + #Categories.list, "FEATURED: filter + semua kategori")
	assert(CatalogMenu.isFilter("all") and CatalogMenu.isFilter("limited"), "id filter dikenali")
	eq(CatalogMenu.isFilter("tops"), false, "id kategori bukan filter")

	-- 9. searchTypes: gabungan tipe grup, TANPA duplikat, aset & bundle tidak dicampur
	local clothA, clothB = CatalogMenu.searchTypes("clothing")
	eq(#clothB, 0, "CLOTHING tidak punya bundle")
	eq(#clothA, 10, "CLOTHING: 7 tipe layered + 3 klasik, tanpa duplikat")
	eq(clothA[1], "TShirtAccessory", "urutan mengikuti kategori")
	local accA, accB = CatalogMenu.searchTypes("accessories")
	eq(#accB, 0, "grup campuran: bundle dilepas, aset yang dipakai")
	eq(#accA, 6, "ACCESSORIES: 6 tipe aset (bundle Shoes dilepas)")
	local seenType: { [string]: boolean } = {}
	for _, t in accA do
		assert(not seenType[t], "tipe ganda: " .. t)
		seenType[t] = true
	end
	local mkA = CatalogMenu.searchTypes("makeup")
	eq(#mkA, 5, "MAKEUP: eye/lip/face makeup + eyelash + eyebrow")

	-- 9b. grup "Soon" (BODY): tidak punya kategori & tidak punya chip
	local body = CatalogMenu.byId.body
	eq(body.soon, nil, "BODY tidak Soon lagi: sub-kategorinya nyata")
	eq(#CatalogMenu.categoryIds("body"), 6, "enam sub-kategori bagian tubuh")
	eq(#CatalogMenu.chips("body"), 8, "2 chip panel + 6 kategori")
	-- Grup berhalaman TIDAK memakai All/Free/Limited: chip pertamanya panel.
	eq(CatalogMenu.chips("body")[1].id, "color", "chip pertama Color")
	eq(CatalogMenu.chips("body")[2].id, "scale", "chip kedua Scale")
	eq(CatalogMenu.chips("hair")[1].id, "all", "grup biasa tetap All/Free/Limited")
	-- BODY tetap `soon` (tidak punya daftar item), tapi kartunya BISA diketuk: `page` menandai
	-- bahwa ia membuka halaman sendiri. Tanpa ini CategoryMenu menahannya di flash "Soon".
	eq(body.page, "body", "BODY membuka halaman sendiri")

	-- 10. FEATURED punya CategoryFilter sendiri; grup lain tidak
	eq(CatalogMenu.byId.featured.categoryFilter, "Featured", "FEATURED pakai CategoryFilter.Featured")
	eq(CatalogMenu.byId.clothing.categoryFilter, nil, "grup biasa tanpa CategoryFilter")

	print("PASS CatalogMenu.spec")
end
