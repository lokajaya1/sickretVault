--!strict
-- Hitung tata letak panel katalog dari ukuran layar (piksel GUI). Murni -> bisa dites di Lune.
--   local L = PanelLayout.compute(width, height)
--   L.mode      -- "side" (panel di kanan) | "sheet" (ponsel tegak: panel dari bawah)
--   L.x, L.y, L.w, L.h           -- kotak panel
--   L.columns, L.cellW, L.cellH  -- ukuran kartu grid
--   L.anchorX, L.anchorY         -- titik tengah area kosong (piksel) untuk kamera try-on

export type Layout = {
	mode: "side" | "sheet",
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

PanelLayout.PHONE_WIDTH = 700 -- di bawah ini (tegak) -> sheet
PanelLayout.MARGIN = 16
PanelLayout.TOP = 64 -- ruang tombol atas (Catalog/Stores)
PanelLayout.SIDE_RATIO = 0.55
PanelLayout.SIDE_MIN = 360
PanelLayout.SIDE_MAX = 760
PanelLayout.SHEET_RATIO = 0.58
PanelLayout.PADDING = 12 -- padding dalam panel (kiri+kanan masing-masing)
PanelLayout.SCROLLBAR = 10 -- ruang scrollbar + padding kanan grid
PanelLayout.GAP = 8
PanelLayout.CARD_MIN = 104 -- lebar kartu minimum
PanelLayout.MIN_COLUMNS = 3
PanelLayout.MAX_COLUMNS = 6
PanelLayout.TEXT_AREA = 34 -- tinggi nama + harga di bawah gambar

local function clamp(v: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, v))
end

function PanelLayout.grid(innerWidth: number): (number, number, number)
	local P = PanelLayout
	local usable = math.max(0, innerWidth - P.SCROLLBAR)
	local cols = math.floor((usable + P.GAP) / (P.CARD_MIN + P.GAP))
	cols = clamp(cols, P.MIN_COLUMNS, P.MAX_COLUMNS)
	local cellW = math.floor((usable - P.GAP * (cols - 1)) / cols)
	cellW = math.max(cellW, 40)
	return cols, cellW, cellW + P.TEXT_AREA
end

function PanelLayout.compute(width: number, height: number): Layout
	local P = PanelLayout
	local mode: "side" | "sheet" = if width < P.PHONE_WIDTH then "sheet" else "side"
	local x, y, w, h, anchorX, anchorY
	if mode == "side" then
		w = math.floor(clamp(width * P.SIDE_RATIO, P.SIDE_MIN, P.SIDE_MAX))
		w = math.min(w, width - P.MARGIN * 2)
		x = width - w - P.MARGIN
		y = P.TOP
		h = math.max(0, height - P.TOP - P.MARGIN)
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
	local columns, cellW, cellH = PanelLayout.grid(w - P.PADDING * 2)
	return {
		mode = mode,
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
