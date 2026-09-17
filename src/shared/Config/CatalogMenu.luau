--!strict
-- Peta halaman MENU KATEGORI katalog (mozaik/bento) -> lihat claude/Pedoman_Layout_CAC.md "Layar KATALOG".
-- MURNI (tanpa service Roblox selain require) supaya bisa dites Lune.
--   for _, g in CatalogMenu.list do ... g.id, g.label, g.span ... end
--   CatalogMenu.categoryIds(g)     -- id kategori (Config/Categories) untuk tab daftar item
--   CatalogMenu.groupOf("hair")    -- grup pemilik sebuah kategori (nil bila tidak terdaftar)
--   CatalogMenu.span(g, narrow)    -- kotak kartu di grid mozaik (unit, bukan piksel)
-- `narrow` = panel terlalu SEMPIT untuk 4 kolom (PanelLayout.mosaicNarrow), bukan layar pendek:
-- ponsel mendatar panelnya pendek tapi lebar, jadi tetap memakai susunan 4 kolom.
-- Grup dengan categories kosong (FEATURED) = "semua kategori": daftar item memakai seluruh
-- Categories.list dan mulai dari kategori pertama. Pencarian featured asli menyusul di PR #17b.
--
-- Grid mozaik (unit): lebar 4 x tinggi 4 (normal), lebar 2 x tinggi 6 (panel sempit).
-- Susunan normal:
--   +-----------+-----+-----+
--   | FEATURED  |HAIR |     |
--   |           +-----+ CLO |
--   |           |ANIM |     |
--   +-----------+-----+-----+
--   | ACCESSORIES     |FACES|
--   |                 |     |
--   +-----------------+-----+

local Categories = require(script.Parent.Categories)

export type Box = { x: number, y: number, w: number, h: number }

export type Group = {
	id: string,
	label: string, -- HURUF BESAR (label kartu mozaik)
	categories: { string }, -- id Config/Categories; kosong = semua kategori
	span: Box, -- posisi kartu di grid normal (4 kolom)
	spanCompact: Box, -- posisi kartu di grid panel sempit (2 kolom)
	tone: number, -- 0..1 tingkat aksen kartu (warna dari Tokens, bukan pelangi CAC)
}

local CatalogMenu = {}

CatalogMenu.COLUMNS = 4
CatalogMenu.ROWS = 4
CatalogMenu.COLUMNS_COMPACT = 2
CatalogMenu.ROWS_COMPACT = 6

local list: { Group } = {
	{
		id = "featured",
		label = "FEATURED",
		categories = {},
		span = { x = 0, y = 0, w = 2, h = 2 },
		spanCompact = { x = 0, y = 0, w = 2, h = 2 },
		tone = 1,
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
		categories = { "tops", "bottoms", "classic" },
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
		-- "FACES" = aksesori wajah (alis/bulu mata/muka) + Heads & Bodies; classic face sudah off-sale.
		id = "faces",
		label = "FACES",
		categories = { "face_acc", "heads", "bodies" },
		span = { x = 3, y = 2, w = 1, h = 2 },
		spanCompact = { x = 1, y = 4, w = 1, h = 2 },
		tone = 0.85,
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
	if g == nil then
		return table.clone(allCategoryIds)
	end
	if #g.categories == 0 then
		return table.clone(allCategoryIds)
	end
	return table.clone(g.categories)
end

-- Kategori pertama sebuah grup (tab yang aktif saat daftar item dibuka).
function CatalogMenu.firstCategory(group: Group | string): string
	return CatalogMenu.categoryIds(group)[1]
end

-- Grup pemilik sebuah kategori (untuk tombol kembali / sorotan tab di PR #17b).
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
