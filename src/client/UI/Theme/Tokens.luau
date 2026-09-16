--!strict
-- Token desain UI: SATU tempat untuk warna, ukuran, font, animasi.
-- Komponen UI tidak boleh menulis angka/warna sendiri; ambil dari sini.
--   local T = require(script.Parent.Theme.Tokens)
--   frame.BackgroundColor3 = T.Color.Panel

local Tokens = {}

Tokens.Color = {
	Background = Color3.fromRGB(18, 18, 22), -- latar panel utama
	Panel = Color3.fromRGB(28, 28, 34),
	PanelRaised = Color3.fromRGB(40, 40, 48), -- kartu item, input
	Stroke = Color3.fromRGB(255, 255, 255),
	Text = Color3.fromRGB(255, 255, 255),
	TextMuted = Color3.fromRGB(170, 170, 180),
	Accent = Color3.fromRGB(0, 162, 255), -- tab aktif, tombol utama
	AccentText = Color3.fromRGB(255, 255, 255),
	Robux = Color3.fromRGB(0, 200, 120), -- harga
	Danger = Color3.fromRGB(235, 70, 70),
	Warning = Color3.fromRGB(255, 180, 40),
}

Tokens.Transparency = {
	Panel = 0.15,
	PanelRaised = 0.05,
	Stroke = 0.85, -- garis tepi tipis
	Overlay = 0.4,
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
