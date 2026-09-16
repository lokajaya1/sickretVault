--!strict
-- Hitung tata letak panel katalog dari ukuran layar (piksel GUI). Murni -> bisa dites di Lune.
--   local L = PanelLayout.compute(width, height)
--   L.mode      -- "side" (panel di kanan) | "sheet" (ponsel tegak: panel dari bawah)
--   L.compact   -- layar pendek (ponsel mendatar): header ringkas, panel setinggi layar, kartu lebih kecil
--   L.x, L.y, L.w, L.h           -- kotak panel
--   L.columns, L.cellW, L.cellH  -- ukuran kartu grid
--   L.anchorX, L.anchorY         -- titik tengah area kosong (piksel) untuk kamera try-on

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
PanelLayout.TEXT_AREA = 34 -- tinggi nama + harga di bawah gambar
PanelLayout.TEXT_AREA_COMPACT = 30

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

function PanelLayout.compute(width: number, height: number): Layout
	local P = PanelLayout
	-- Sheet hanya untuk ponsel TEGAK. Roblox mobile umumnya mendatar -> side + compact.
	local mode: "side" | "sheet" = if width < P.PHONE_WIDTH and height > width then "sheet" else "side"
	local compact = mode == "side" and height < P.COMPACT_HEIGHT
	local x, y, w, h, anchorX, anchorY
	if mode == "side" then
		local ratio = if compact then P.SIDE_RATIO_COMPACT else P.SIDE_RATIO
		w = math.floor(clamp(width * ratio, P.SIDE_MIN, P.SIDE_MAX))
		w = math.min(w, width - P.MARGIN * 2)
		x = width - w - P.MARGIN
		-- compact: panel setinggi layar (tombol atas disembunyikan App selama katalog terbuka)
		y = if compact then P.COMPACT_MARGIN else P.TOP
		local bottom = if compact then P.COMPACT_MARGIN else P.MARGIN
		h = math.max(0, height - y - bottom)
		anchorX = x / 2 -- tengah area kosong di kiri panel
		anchorY = height / 2
	else
		w = width
		x = 0
		h = math.floor(height * P.SHEET_RATIO)
		y = height - h
		anchorX = width / 2
		anchorY = (P.TOP + y) / 2 -- tengah area kosong di atas panel
	end
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
	}
end

return PanelLayout
