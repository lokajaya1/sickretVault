--!strict
-- Hitung tata letak panel katalog dari ukuran layar (piksel GUI). Murni -> bisa dites di Lune.
--   local L = PanelLayout.compute(width, height)
--   L.mode      -- "side" (panel di kanan) | "sheet" (ponsel tegak: panel dari bawah)
--   L.compact   -- layar pendek (ponsel mendatar): header ringkas, panel setinggi layar, kartu lebih kecil
--   L.x, L.y, L.w, L.h           -- kotak panel
--   L.columns, L.cellW, L.cellH  -- ukuran kartu grid
--   PanelLayout.mosaicNarrow(innerW)              -- true = mozaik memakai susunan 2 kolom
--   PanelLayout.mosaic(innerW, innerH, cols, rows) -- ukuran satu unit kartu mozaik (menu kategori)
--   L.anchorX, L.anchorY         -- titik tengah area kosong (piksel) untuk kamera try-on
--   L.dockX, L.dockY, L.dockW, L.dockH -- area kiri bawah (di bawah avatar) untuk tombol aksi + strip Wearing
--   L.previewX, L.previewY, L.previewW, L.previewH -- kartu preview avatar (area kosong DI ATAS dock)
--   L.actionsH, L.stripH         -- tinggi baris tombol aksi & strip di dalam dock

export type Layout = {
	mode: "side" | "sheet",
	compact: boolean,
	x: number,
	y: number,
	w: number,
	h: number,
	columns: number,
	cellW: number,
	cellH: number,
	anchorX: number,
	anchorY: number,
	dockX: number,
	dockY: number,
	dockW: number,
	dockH: number,
	actionsH: number,
	stripH: number,
	previewX: number,
	previewY: number,
	previewW: number,
	previewH: number,
}

local PanelLayout = {}

PanelLayout.PHONE_WIDTH = 700 -- lebih sempit dari ini DAN tegak -> sheet
PanelLayout.COMPACT_HEIGHT = 500 -- lebih pendek dari ini -> compact (ponsel mendatar)
PanelLayout.MARGIN = 16
PanelLayout.COMPACT_MARGIN = 8
PanelLayout.TOP = 64 -- ruang tombol atas (Catalog/Stores)
PanelLayout.SIDE_RATIO = 0.55
PanelLayout.SIDE_RATIO_COMPACT = 0.6 -- ponsel mendatar: area aman lebih sempit (notch) -> panel sedikit lebih lebar
PanelLayout.SIDE_MIN = 360
PanelLayout.SIDE_MAX = 760
PanelLayout.SHEET_RATIO = 0.58
PanelLayout.PADDING = 12 -- padding dalam panel (kiri+kanan masing-masing)
PanelLayout.SCROLLBAR = 10 -- ruang scrollbar + padding kanan grid
PanelLayout.GAP = 8
PanelLayout.CARD_MIN = 104 -- lebar kartu minimum
PanelLayout.CARD_MIN_COMPACT = 76
PanelLayout.MIN_COLUMNS = 3
PanelLayout.MAX_COLUMNS = 6
PanelLayout.MOSAIC_GAP = 8 -- jarak antar kartu mozaik (halaman menu kategori)
PanelLayout.MOSAIC_COLUMNS = 4 -- susunan mozaik normal (Config/CatalogMenu)
PanelLayout.MOSAIC_MIN_CARD = 90 -- kartu 4 kolom lebih sempit dari ini -> pakai susunan 2 kolom
PanelLayout.MOSAIC_MIN_UNIT = 64 -- tinggi minimum satu unit kartu mozaik
PanelLayout.TEXT_AREA = 34 -- tinggi nama + harga di bawah gambar
PanelLayout.TEXT_AREA_COMPACT = 30
PanelLayout.ACTIONS_H = 44 -- tombol Undo/Redo/Reset
PanelLayout.ACTIONS_H_COMPACT = 40
PanelLayout.STRIP_H = 78 -- strip item yang dipakai (judul 18 + tombol 52 + padding)
PanelLayout.STRIP_H_COMPACT = 70 -- tombol 44 (batas nyaman sentuh)
PanelLayout.DOCK_GAP = 8
PanelLayout.DOCK_GAP_COMPACT = 6

local function clamp(v: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, v))
end

function PanelLayout.grid(innerWidth: number, compact: boolean?): (number, number, number)
	local P = PanelLayout
	local cardMin = if compact then P.CARD_MIN_COMPACT else P.CARD_MIN
	local textArea = if compact then P.TEXT_AREA_COMPACT else P.TEXT_AREA
	local usable = math.max(0, innerWidth - P.SCROLLBAR)
	local cols = math.floor((usable + P.GAP) / (cardMin + P.GAP))
	cols = clamp(cols, P.MIN_COLUMNS, P.MAX_COLUMNS)
	local cellW = math.floor((usable - P.GAP * (cols - 1)) / cols)
	cellW = math.max(cellW, 40)
	return cols, cellW, cellW + textArea
end

-- Panel terlalu sempit untuk mozaik 4 kolom (label besar jadi tidak terbaca) -> susunan 2 kolom.
-- Patokannya LEBAR panel, bukan tinggi layar: ponsel mendatar panelnya pendek tapi lebar.
function PanelLayout.mosaicNarrow(innerWidth: number): boolean
	local P = PanelLayout
	local usable = math.max(0, innerWidth - P.SCROLLBAR)
	local cols = P.MOSAIC_COLUMNS
	return (usable - P.MOSAIC_GAP * (cols - 1)) / cols < P.MOSAIC_MIN_CARD
end

-- Ukuran satu unit kartu mozaik (halaman menu kategori). `cols`/`rows` dari Config/CatalogMenu.
-- Kembalian: lebar unit, tinggi unit, tinggi seluruh mozaik (canvas ScrollingFrame).
-- Unit dibuat selebar mungkin; tingginya mengisi ruang yang ada tapi tidak pernah lebih jangkung
-- dari lebarnya (kartu tetap proporsional) dan tidak lebih pendek dari MOSAIC_MIN_UNIT
-- (mozaik boleh lebih tinggi dari panel -> halaman menu digulir).
function PanelLayout.mosaic(
	innerWidth: number,
	innerHeight: number,
	cols: number,
	rows: number
): (number, number, number)
	local P = PanelLayout
	local gap = P.MOSAIC_GAP
	cols = math.max(1, math.floor(cols))
	rows = math.max(1, math.floor(rows))
	local usableW = math.max(0, innerWidth - P.SCROLLBAR)
	local unitW = math.max(math.floor((usableW - gap * (cols - 1)) / cols), 40)
	local fitH = math.floor((innerHeight - gap * (rows - 1)) / rows)
	local unitH = math.floor(clamp(fitH, P.MOSAIC_MIN_UNIT, unitW))
	return unitW, unitH, unitH * rows + gap * (rows - 1)
end

function PanelLayout.compute(width: number, height: number): Layout
	local P = PanelLayout
	-- Sheet hanya untuk ponsel TEGAK. Roblox mobile umumnya mendatar -> side + compact.
	local mode: "side" | "sheet" = if width < P.PHONE_WIDTH and height > width then "sheet" else "side"
	local compact = mode == "side" and height < P.COMPACT_HEIGHT
	local m = if compact then P.COMPACT_MARGIN else P.MARGIN
	local actionsH = if compact then P.ACTIONS_H_COMPACT else P.ACTIONS_H
	local stripH = if compact then P.STRIP_H_COMPACT else P.STRIP_H
	local dockH = actionsH + (if compact then P.DOCK_GAP_COMPACT else P.DOCK_GAP) + stripH
	local x, y, w, h, anchorX, anchorY, dockX, dockY, dockW, topY
	if mode == "side" then
		local ratio = if compact then P.SIDE_RATIO_COMPACT else P.SIDE_RATIO
		w = math.floor(clamp(width * ratio, P.SIDE_MIN, P.SIDE_MAX))
		w = math.min(w, width - P.MARGIN * 2)
		x = width - w - P.MARGIN
		-- compact: panel setinggi layar (tombol atas disembunyikan App selama katalog terbuka)
		y = if compact then P.COMPACT_MARGIN else P.TOP
		local bottom = if compact then P.COMPACT_MARGIN else P.MARGIN
		h = math.max(0, height - y - bottom)
		-- dock di kiri bawah (area kosong di kiri panel); avatar di tengah area di atasnya
		dockX = m
		dockW = math.max(0, x - m * 2)
		dockY = math.max(0, height - m - dockH)
		anchorX = x / 2 -- tengah area kosong di kiri panel
		topY = if compact then m else P.TOP
		anchorY = (topY + dockY) / 2
	else
		w = width
		x = 0
		h = math.floor(height * P.SHEET_RATIO)
		y = height - h
		-- dock tepat di atas sheet; avatar di antara tombol atas dan dock
		dockX = P.MARGIN
		dockW = math.max(0, width - P.MARGIN * 2)
		dockY = math.max(0, y - P.MARGIN - dockH)
		anchorX = width / 2
		topY = P.TOP
		anchorY = (topY + dockY) / 2
	end
	-- Kartu preview avatar mengisi area kosong yang sama dengan tempat karakter tadi berdiri:
	-- selebar dock, dari bawah tombol atas sampai tepat di atas dock.
	local gap = if compact then P.DOCK_GAP_COMPACT else P.DOCK_GAP
	local previewX = dockX
	local previewW = dockW
	local previewY = topY
	local previewH = math.max(0, dockY - topY - gap)
	local columns, cellW, cellH = PanelLayout.grid(w - P.PADDING * 2, compact)
	return {
		mode = mode,
		compact = compact,
		x = x,
		y = y,
		w = w,
		h = h,
		columns = columns,
		cellW = cellW,
		cellH = cellH,
		anchorX = anchorX,
		anchorY = anchorY,
		dockX = dockX,
		dockY = dockY,
		dockW = dockW,
		dockH = dockH,
		actionsH = actionsH,
		stripH = stripH,
		previewX = previewX,
		previewY = previewY,
		previewW = previewW,
		previewH = previewH,
	}
end

return PanelLayout
