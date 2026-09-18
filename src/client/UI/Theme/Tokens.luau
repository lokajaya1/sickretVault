--!strict
-- Token desain UI: SATU tempat untuk warna, ukuran, font, animasi.
-- Komponen UI tidak boleh menulis angka/warna sendiri; ambil dari sini.
--   local T = require(script.Parent.Theme.Tokens)
--   frame.BackgroundColor3 = T.Color.Panel
--
-- TEMA (18 Sep 2026): HITAM + EMAS + PUTIH.
--   latar hitam pekat, kartu abu gelap, aksen EMAS (tab aktif, tombol utama, harga),
--   teks putih hangat. Garis tepi memakai emas dengan transparansi tinggi supaya tipis.
--   Kontras yang dijaga: Text di Panel ~16:1, TextMuted di Panel ~7:1, AccentText di Accent ~9:1.

local Tokens = {}

Tokens.Color = {
	Background = Color3.fromRGB(10, 10, 12), -- latar paling gelap (dialog, overlay kartu)
	Panel = Color3.fromRGB(16, 16, 19), -- panel besar
	PanelRaised = Color3.fromRGB(26, 26, 30), -- kartu item, input, chip
	Stroke = Color3.fromRGB(226, 183, 77), -- garis tepi (emas, dipakai dengan Transparency.Stroke)
	Text = Color3.fromRGB(245, 245, 240), -- putih hangat
	TextMuted = Color3.fromRGB(156, 156, 150),
	Accent = Color3.fromRGB(226, 183, 77), -- EMAS: tab aktif, tombol utama, pita LIMITED
	AccentText = Color3.fromRGB(14, 14, 16), -- teks/ikon di ATAS emas (hitam)
	Robux = Color3.fromRGB(238, 206, 132), -- harga (emas muda, bukan hijau)
	Danger = Color3.fromRGB(226, 86, 86),
	Warning = Color3.fromRGB(240, 166, 60),
}

Tokens.Transparency = {
	Panel = 0.08, -- panel lebih pekat dari tema lama (0.15) supaya teks emas tetap terbaca
	PanelRaised = 0.02,
	Stroke = 0.85, -- garis tepi emas tipis
	Overlay = 0.35,
}

Tokens.Radius = {
	Small = UDim.new(0, 6),
	Medium = UDim.new(0, 10),
	Large = UDim.new(0, 16),
	Pill = UDim.new(1, 0),
}

Tokens.Space = {
	XS = 4,
	S = 8,
	M = 12,
	L = 16,
	XL = 24,
}

Tokens.Font = {
	Regular = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Regular),
	Medium = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
	Bold = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
}

Tokens.TextSize = {
	Caption = 12,
	Body = 14,
	Button = 16,
	Title = 20,
}

Tokens.Size = {
	TopButton = Vector2.new(120, 40), -- tombol atas (Catalog, Stores)
	IconButton = 44, -- tombol ikon bulat (min. target sentuh)
	PanelWidth = 0.42, -- lebar panel katalog (skala layar)
	PanelMinWidth = 320,
	PanelMaxWidth = 560,
	TabHeight = 32,
	SearchHeight = 36,
	Card = Vector2.new(110, 150), -- kartu item (gambar + nama + harga)
	CardImage = 100,
	Thumbnail = 150, -- ukuran rbxthumb (w=h): 150 atau 420
}

-- Lebar layar di bawah ini dianggap ponsel -> panel dibuat lebih lebar.
Tokens.Breakpoint = {
	Phone = 700,
}

Tokens.PanelWidthPhone = 0.9

Tokens.ZIndex = {
	Hud = 1,
	Panel = 10,
	Popup = 20,
	Toast = 30,
}

Tokens.Tween = {
	Fast = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Normal = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
}

-- Jarak piksel dari bawah daftar untuk memicu loadMore (infinite scroll).
Tokens.LoadMoreThreshold = 300

return Tokens
