--!strict
-- Studio: require(game.ReplicatedStorage.Tests["PanelLayout.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local P = require(Shared.Util.PanelLayout)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	-- 1. desktop 1920x1080: panel di kanan, 55% lebar, tidak keluar layar
	local d = P.compute(1920, 1080)
	eq(d.mode, "side", "desktop side")
	eq(d.compact, false, "desktop tidak compact")
	eq(d.w, 760, "lebar dibatasi SIDE_MAX")
	eq(d.x + d.w, 1920 - P.MARGIN, "menempel kanan")
	eq(d.y, P.TOP, "di bawah tombol atas")
	eq(d.y + d.h, 1080 - P.MARGIN, "sampai bawah")
	eq(d.anchorX, d.x / 2, "karakter di tengah area kiri")
	-- dock kiri bawah: tidak menabrak panel, menempel bawah, avatar di atasnya
	eq(d.dockX, P.MARGIN, "dock x")
	eq(d.dockX + d.dockW, d.x - P.MARGIN, "dock berhenti sebelum panel")
	eq(d.dockY + d.dockH, 1080 - P.MARGIN, "dock menempel bawah")
	eq(d.dockH, P.ACTIONS_H + P.DOCK_GAP + P.STRIP_H, "tinggi dock")
	assert(d.anchorY < d.dockY, "avatar di atas dock")
	assert(d.columns >= 4, "desktop minimal 4 kolom")

	-- 2. laptop 1280x720: 55%
	local l = P.compute(1280, 720)
	eq(l.w, math.floor(1280 * 0.55), "55%")
	assert(l.anchorX < l.x, "anchor di kiri panel")

	-- 3. ponsel tegak 390x844: sheet dari bawah, lebar penuh, 3 kolom
	local m = P.compute(390, 844)
	eq(m.mode, "sheet", "ponsel sheet")
	eq(m.compact, false, "sheet tidak compact")
	eq(m.x, 0, "sheet x")
	eq(m.w, 390, "sheet lebar penuh")
	eq(m.y + m.h, 844, "menempel bawah")
	eq(m.columns, 3, "ponsel 3 kolom")
	eq(m.anchorX, 195, "karakter di tengah horizontal")
	assert(m.anchorY > P.TOP and m.anchorY < m.dockY, "karakter di atas dock")
	eq(m.dockY + m.dockH, m.y - P.MARGIN, "dock tepat di atas sheet")
	eq(m.dockW, 390 - P.MARGIN * 2, "dock selebar layar")

	-- 4. ponsel mendatar 844x390: side + compact, panel setinggi layar, kartu lebih kecil
	local ls = P.compute(844, 390)
	eq(ls.mode, "side", "landscape side")
	eq(ls.compact, true, "landscape compact")
	eq(ls.y, P.COMPACT_MARGIN, "compact mulai dari atas")
	eq(ls.y + ls.h, 390 - P.COMPACT_MARGIN, "compact sampai bawah")
	assert(ls.x >= P.MARGIN, "tidak keluar kiri")
	eq(ls.cellH, ls.cellW + P.TEXT_AREA_COMPACT, "kartu compact")
	assert(ls.columns >= 4, "landscape minimal 4 kolom")
	eq(ls.stripH, P.STRIP_H_COMPACT, "strip compact")
	eq(ls.dockY + ls.dockH, 390 - P.COMPACT_MARGIN, "dock compact menempel bawah")
	assert(ls.dockX + ls.dockW <= ls.x, "dock compact tidak menabrak panel")
	assert(ls.anchorY > 0 and ls.anchorY < ls.dockY, "avatar compact di atas dock")

	-- 4b. ponsel kecil mendatar 667x375 (lebih sempit dari PHONE_WIDTH) tetap side, bukan sheet
	local se = P.compute(667, 375)
	eq(se.mode, "side", "ponsel kecil mendatar = side")
	eq(se.compact, true, "ponsel kecil compact")

	-- 5. grid: kartu persegi + area teks, tidak melebihi lebar
	local cols, cellW, cellH = P.grid(700)
	eq(cellH, cellW + P.TEXT_AREA, "tinggi kartu")
	assert(cols * cellW + (cols - 1) * P.GAP <= 700 - P.SCROLLBAR, "muat")
	assert(cols <= P.MAX_COLUMNS, "maks kolom")
	local c2 = P.grid(200)
	eq(c2, P.MIN_COLUMNS, "minimal 3 kolom walau sempit")

	-- 6. layar sangat kecil: aman (tanpa nilai negatif)
	local tiny = P.compute(300, 200)
	assert(tiny.w > 0 and tiny.h > 0 and tiny.cellW > 0, "layar kecil aman")
	assert(tiny.dockW >= 0 and tiny.dockY >= 0, "dock layar kecil aman")

	-- 7. mozaik menu kategori: 4 kolom bila panel cukup lebar, 2 kolom bila sempit
	local wide = 736 -- isi panel desktop (760 - PADDING*2)
	eq(P.mosaicNarrow(wide), false, "panel lebar = 4 kolom")
	eq(P.mosaicNarrow(393), true, "tepat di bawah ambang = 2 kolom")
	eq(P.mosaicNarrow(394), false, "tepat di ambang = 4 kolom")
	eq(P.mosaicNarrow(0), true, "lebar 0 = 2 kolom (tanpa error)")

	-- 8. unit mozaik: muat mendatar, tidak lebih jangkung dari lebarnya, canvas sesuai rumus
	local uw, uh, total = P.mosaic(wide, 900, 4, 4)
	assert(uw * 4 + P.MOSAIC_GAP * 3 <= wide - P.SCROLLBAR, "mozaik muat mendatar")
	eq(uh, uw, "panel tinggi: unit dibatasi lebarnya (kartu tidak jangkung)")
	eq(total, uh * 4 + P.MOSAIC_GAP * 3, "tinggi canvas mozaik")
	assert(total <= 900, "panel tinggi: mozaik tidak perlu digulir")

	-- 9. panel pendek: unit tidak lebih kecil dari batas minimum -> mozaik digulir
	local _, shortH, shortTotal = P.mosaic(376, 120, 2, 6)
	eq(shortH, P.MOSAIC_MIN_UNIT, "panel pendek: tinggi unit minimum")
	assert(shortTotal > 120, "panel pendek: mozaik lebih tinggi dari panel (digulir)")

	-- 10. ukuran aneh tidak bikin error / nilai negatif
	local tw, th, tt = P.mosaic(0, 0, 0, 0)
	assert(tw > 0 and th > 0 and tt > 0, "mozaik ukuran 0 aman")

	print("PASS PanelLayout.spec")
end
