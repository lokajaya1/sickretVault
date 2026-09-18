--!strict
-- Peta halaman MENU KATEGORI katalog (mozaik/bento) + isi baris tab -> claude/Pedoman_Layout_CAC.md.
-- MURNI (tanpa service Roblox selain require) supaya bisa dites Lune.
--   for _, g in CatalogMenu.list do ... g.id, g.label, g.span ... end
--   CatalogMenu.categoryIds(g)     -- id kategori (Config/Categories) milik grup
--   CatalogMenu.chips(g)           -- isi baris kedua: All, Free, Limited, lalu kategori grup
--   CatalogMenu.searchTypes(g)     -- tipe aset/bundle gabungan untuk chip All/Free/Limited
--   CatalogMenu.groupOf("hair")    -- grup pemilik sebuah kategori (nil bila tidak terdaftar)
--   CatalogMenu.span(g, narrow)    -- kotak kartu di grid mozaik (unit, bukan piksel)
-- `narrow` = panel terlalu SEMPIT untuk 4 kolom (PanelLayout.mosaicNarrow), bukan layar pendek:
-- ponsel mendatar panelnya pendek tapi lebar, jadi tetap memakai susunan 4 kolom.
-- Grup dengan categories kosong (FEATURED) = "semua kategori" + CategoryFilter.Featured di server.
--
-- Grid mozaik (unit): lebar 4 x tinggi 8 (normal), lebar 2 x tinggi 14 (panel sempit).
-- Susunan normal:
--   +-----------+-----+-----+
--   | FEATURED  |HAIR |     |
--   |           +-----+ CLO |
--   |           |ANIM |     |
--   +-----------+-----+-----+
--   | ACCESSORIES     |FACES|
--   +-----------------+-----+
--   | MAKEUP    | BACKGROUNDS |
--   +-----------+-------------+
--   | CHARACTERS| BODY (soon) |
--   +-----------+-------------+
-- Grup dengan `soon = true` belum punya isi: kartunya redup dan hanya berkedip "Soon".

local Categories = require(script.Parent.Categories)

export type Box = { x: number, y: number, w: number, h: number }

export type Group = {
	id: string,
	label: string, -- HURUF BESAR (label kartu mozaik & tab grup)
	categories: { string }, -- id Config/Categories; kosong = semua kategori
	span: Box, -- posisi kartu di grid normal (4 kolom)
	spanCompact: Box, -- posisi kartu di grid panel sempit (2 kolom)
	tone: number, -- 0..1 tingkat aksen kartu (warna dari Tokens, bukan pelangi CAC)
	categoryFilter: string?, -- nama Enum.CatalogCategoryFilter untuk chip grup (mis. "Featured")
	soon: boolean?, -- true = belum ada isinya (kartu redup + flash "Soon", tidak bisa dibuka)
}

export type Chip = {
	id: string, -- "all" | "free" | "limited" | id kategori
	label: string,
	isFilter: boolean, -- true = filter se-grup, false = kategori
}

local CatalogMenu = {}

CatalogMenu.COLUMNS = 4
CatalogMenu.ROWS = 8
CatalogMenu.COLUMNS_COMPACT = 2
CatalogMenu.ROWS_COMPACT = 14

-- Chip filter yang berlaku untuk SEMUA grup (baris kedua, paling kiri).
--   all     : seluruh tipe grup, diurutkan MostFavorited (spike 18 Sep: Relevance + banyak tipe
--             -> hasilnya jatuh ke daftar item gratis bawaan Roblox)
--   free    : sama + MaxPrice = 0
--   limited : sama + SalesTypeFilter.Collectibles
CatalogMenu.FILTERS = {
	{ id = "all", label = "All", isFilter = true },
	{ id = "free", label = "Free", isFilter = true },
	{ id = "limited", label = "Limited", isFilter = true },
} :: { Chip }

local list: { Group } = {
	{
		id = "featured",
		label = "FEATURED",
		categories = {},
		span = { x = 0, y = 0, w = 2, h = 2 },
		spanCompact = { x = 0, y = 0, w = 2, h = 2 },
		tone = 1,
		categoryFilter = "Featured",
	},
	{
		id = "hair",
		label = "HAIR",
		categories = { "hair" },
		span = { x = 2, y = 0, w = 1, h = 1 },
		spanCompact = { x = 0, y = 2, w = 1, h = 1 },
		tone = 0.55,
	},
	{
		id = "animations",
		label = "ANIMATION PACKS",
		categories = { "animations", "emotes" },
		span = { x = 2, y = 1, w = 1, h = 1 },
		spanCompact = { x = 0, y = 3, w = 1, h = 1 },
		tone = 0.4,
	},
	{
		id = "clothing",
		label = "CLOTHING",
		categories = {
			"layered",
			"tshirts",
			"shirts",
			"jackets",
			"sweaters",
			"pants",
			"shorts",
			"skirts",
			"classic_shirts",
			"classic_pants",
			"classic_tshirts",
		},
		span = { x = 3, y = 0, w = 1, h = 2 },
		spanCompact = { x = 1, y = 2, w = 1, h = 2 },
		tone = 0.7,
	},
	{
		id = "accessories",
		label = "ACCESSORIES",
		categories = { "hats", "neck", "shoulder", "front", "back", "waist", "shoes" },
		span = { x = 0, y = 2, w = 3, h = 2 },
		spanCompact = { x = 0, y = 4, w = 1, h = 2 },
		tone = 0.25,
	},
	{
		-- "FACES" = aksesori wajah + kepala dinamis (classic face sudah off-sale).
		id = "faces",
		label = "FACES",
		categories = { "face_acc", "heads" },
		span = { x = 3, y = 2, w = 1, h = 2 },
		spanCompact = { x = 1, y = 4, w = 1, h = 2 },
		tone = 0.85,
	},
	{
		-- Tipe aset baru Roblox (EyeMakeup/LipMakeup/FaceMakeup) + alis & bulu mata, seperti CAC.
		id = "makeup",
		label = "MAKEUP",
		categories = { "eye_makeup", "lip_makeup", "face_makeup", "eyelashes", "eyebrows" },
		span = { x = 0, y = 4, w = 2, h = 2 },
		spanCompact = { x = 0, y = 6, w = 2, h = 2 },
		tone = 0.65,
	},
	{
		id = "backgrounds",
		label = "BACKGROUNDS",
		categories = { "backgrounds" },
		span = { x = 2, y = 4, w = 2, h = 2 },
		spanCompact = { x = 0, y = 8, w = 2, h = 2 },
		tone = 0.15,
	},
	{
		-- Bundle avatar lengkap (badan, atau kepala + badan).
		id = "characters",
		label = "CHARACTERS",
		categories = { "bodies" },
		span = { x = 0, y = 6, w = 2, h = 2 },
		spanCompact = { x = 0, y = 10, w = 2, h = 2 },
		tone = 0.45,
	},
	{
		-- Warna kulit, skala badan, bentuk kepala: bukan pencarian katalog -> PR editor tubuh.
		id = "body",
		label = "BODY",
		categories = {},
		span = { x = 2, y = 6, w = 2, h = 2 },
		spanCompact = { x = 0, y = 12, w = 2, h = 2 },
		tone = 0.3,
		soon = true,
	},
}

local byId: { [string]: Group } = {}
local ownerOf: { [string]: string } = {} -- id kategori -> id grup
for _, g in list do
	byId[g.id] = g
	for _, catId in g.categories do
		ownerOf[catId] = g.id
	end
end

-- Semua id kategori (urutan Config/Categories) -> dipakai grup "semua kategori".
local allCategoryIds: { string } = {}
for _, c in Categories.list do
	table.insert(allCategoryIds, c.id)
end

CatalogMenu.list = list
CatalogMenu.byId = byId

-- Id kategori untuk tab daftar item; grup tanpa categories -> seluruh kategori.
-- Selalu mengembalikan tabel BARU (pemanggil boleh mengubahnya).
function CatalogMenu.categoryIds(group: Group | string): { string }
	local g = if type(group) == "string" then byId[group] else group
	if g ~= nil and g.soon then
		return {} -- grup "Soon" belum punya isi
	end
	if g == nil or #g.categories == 0 then
		return table.clone(allCategoryIds)
	end
	return table.clone(g.categories)
end

-- Kategori pertama sebuah grup (dipakai bila kategori dibuka tanpa chip).
function CatalogMenu.firstCategory(group: Group | string): string
	return CatalogMenu.categoryIds(group)[1]
end

-- Isi baris kedua panel: chip filter (All, Free, Limited) lalu kategori grup.
function CatalogMenu.chips(group: Group | string): { Chip }
	local out: { Chip } = {}
	local g = if type(group) == "string" then byId[group] else group
	if g ~= nil and g.soon then
		return out
	end
	for _, f in CatalogMenu.FILTERS do
		table.insert(out, { id = f.id, label = f.label, isFilter = true })
	end
	for _, catId in CatalogMenu.categoryIds(group) do
		local cat = Categories.byId[catId]
		if cat then
			table.insert(out, { id = cat.id, label = cat.label, isFilter = false })
		end
	end
	return out
end

-- true = chip filter se-grup (bukan kategori).
function CatalogMenu.isFilter(chipId: string): boolean
	for _, f in CatalogMenu.FILTERS do
		if f.id == chipId then
			return true
		end
	end
	return false
end

-- Tipe untuk chip filter: gabungan tipe semua kategori grup.
-- Aset & bundle TIDAK dicampur (spike 18 Sep 2026: mencampurnya membuat hasil jatuh ke daftar item
-- gratis bawaan Roblox) -> kalau grup punya keduanya, yang dipakai assetTypes.
function CatalogMenu.searchTypes(group: Group | string): ({ string }, { string })
	local assetTypes: { string } = {}
	local bundleTypes: { string } = {}
	local seenAsset: { [string]: boolean } = {}
	local seenBundle: { [string]: boolean } = {}
	for _, catId in CatalogMenu.categoryIds(group) do
		local cat = Categories.byId[catId]
		if cat then
			for _, t in cat.assetTypes or {} do
				if not seenAsset[t] then
					seenAsset[t] = true
					table.insert(assetTypes, t)
				end
			end
			for _, t in cat.bundleTypes or {} do
				if not seenBundle[t] then
					seenBundle[t] = true
					table.insert(bundleTypes, t)
				end
			end
		end
	end
	if #assetTypes > 0 then
		return assetTypes, {}
	end
	return {}, bundleTypes
end

-- Grup pemilik sebuah kategori (untuk sorotan tab grup).
function CatalogMenu.groupOf(categoryId: string): Group?
	local id = ownerOf[categoryId]
	return if id then byId[id] else nil
end

-- Kotak kartu di grid mozaik (unit). narrow = panel sempit (2 kolom).
function CatalogMenu.span(group: Group, narrow: boolean?): Box
	return if narrow then group.spanCompact else group.span
end

-- Ukuran grid mozaik yang dipakai (kolom, baris).
function CatalogMenu.grid(narrow: boolean?): (number, number)
	if narrow then
		return CatalogMenu.COLUMNS_COMPACT, CatalogMenu.ROWS_COMPACT
	end
	return CatalogMenu.COLUMNS, CatalogMenu.ROWS
end

return CatalogMenu
