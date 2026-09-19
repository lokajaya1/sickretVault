--!strict
-- Kolom tombol samping (tengah-vertikal layar), mengikuti pola layout CAC:
--   kiri  = Community Outfits, Outfit Loader (menyusul)
--   kanan = Saved Outfits, Emotes (menyusul)
--   bawah kiri = kluster ikon persegi: buat avatar, avatar di alas, Save to Roblox, tukar
-- Ikon digambar dari Frame (temuan #25 no. 3: glyph font tidak bisa diandalkan, dan tidak
-- perlu assetId yang belum terverifikasi). Nama tombol ikon muncul sebagai label di ATAS
-- kluster saat hover / ditekan (layar sentuh tidak punya hover).
-- Tampil saat katalog TERTUTUP (panel katalog menutupi sisi kanan saat terbuka).
--   local rail = SideRail.new({
--   	parent = gui, side = "right",
--   	items = { { key = "outfits", text = "Saved Outfits" }, { key = "emotes", text = "Emotes", muted = true } },
--   	onActivated = function(key) ... end,
--   })
--   rail:setVisible(true)   rail:setActive("outfits", true)   rail:setCompact(true)   rail:destroy()
-- Tombol teks 2 baris (TextWrapped), latar gelap transparan dari Tokens (identitas visual sendiri).

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local BUTTON = Vector2.new(128, 56)
local BUTTON_COMPACT = Vector2.new(108, 48)
local ICON_BUTTON = 64 -- tombol persegi kluster bawah
local ICON_BUTTON_COMPACT = 52
local LABEL_H = 18

-- icon = nama gambar bawaan (lihat drawIcon); diisi hanya untuk kluster ikon bawah.
export type Item = { key: string, text: string, muted: boolean?, icon: string? } -- muted = fitur belum aktif

export type Props = {
	parent: Instance,
	side: "left" | "right" | "bottomLeft",
	items: { Item },
	onActivated: (key: string) -> (),
}

local SideRail = {}
SideRail.__index = SideRail

export type SideRail = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_buttons: { [string]: TextButton },
		_order: { TextButton },
		_list: UIListLayout,
		_compact: boolean,
		_icons: boolean, -- kluster ikon persegi (bukan tombol teks)
		_label: TextLabel?, -- nama tombol ikon yang sedang disentuh
		_conns: { RBXScriptConnection },
	},
	SideRail
))

-- Satu batang/kotak untuk menyusun ikon. Semua ukuran dalam SKALA tombol supaya ikut mengecil
-- saat compact (tanpa UIAspectRatioConstraint — temuan #25 no. 2).
local function bar(parent: Instance, x: number, y: number, w: number, h: number, rot: number?): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(x, y)
	f.Size = UDim2.fromScale(w, h)
	f.Rotation = rot or 0
	f.BackgroundColor3 = Tokens.Color.Text
	f.BorderSizePixel = 0
	f.ZIndex = Tokens.ZIndex.Hud + 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 2)
	corner.Parent = f
	f.Parent = parent
	return f
end

local function dot(parent: Instance, x: number, y: number, d: number): Frame
	local f = bar(parent, x, y, d, d)
	local corner = f:FindFirstChildOfClass("UICorner")
	if corner then
		corner.CornerRadius = UDim.new(1, 0)
	end
	return f
end

-- Ikon digambar dari Frame (temuan #25 no. 3). Semua memakai warna teks; "lubang" memakai warna
-- latar supaya terbaca seperti potongan, bukan kotak lain.
local function drawIcon(kind: string, parent: Instance)
	if kind == "roblox" then
		-- kotak miring dengan lubang kotak di tengah (tanda platform)
		local outer = bar(parent, 0.5, 0.5, 0.56, 0.56, 18)
		local hole = Instance.new("Frame")
		hole.AnchorPoint = Vector2.new(0.5, 0.5)
		hole.Position = UDim2.fromScale(0.5, 0.5)
		hole.Size = UDim2.fromScale(0.36, 0.36)
		hole.BackgroundColor3 = Tokens.Color.Background
		hole.BorderSizePixel = 0
		hole.ZIndex = outer.ZIndex + 1
		hole.Parent = outer
	elseif kind == "avatarAdd" then
		dot(parent, 0.4, 0.3, 0.22)
		bar(parent, 0.4, 0.66, 0.36, 0.3)
		bar(parent, 0.76, 0.28, 0.24, 0.08) -- tanda +
		bar(parent, 0.76, 0.28, 0.08, 0.24)
	elseif kind == "avatarStand" then
		dot(parent, 0.5, 0.26, 0.22)
		bar(parent, 0.5, 0.58, 0.36, 0.3)
		bar(parent, 0.5, 0.82, 0.62, 0.08) -- alas
	elseif kind == "swap" then
		bar(parent, 0.5, 0.36, 0.5, 0.08)
		bar(parent, 0.28, 0.45, 0.16, 0.08, 45)
		bar(parent, 0.5, 0.64, 0.5, 0.08)
		bar(parent, 0.72, 0.55, 0.16, 0.08, 45)
	elseif kind == "reset" then
		-- Sosok berdiri + panah memutar ke kiri: "kembalikan avatar". Ikon `avatarStand` sudah
		-- dipakai baris "My Avatar" di kluster yang sama, jadi reset butuh ikonnya sendiri --
		-- dua tombol bersebelahan dengan gambar sama tidak bisa dibedakan.
		dot(parent, 0.6, 0.3, 0.2)
		bar(parent, 0.6, 0.64, 0.34, 0.3)
		bar(parent, 0.24, 0.46, 0.34, 0.09, -62)
		bar(parent, 0.3, 0.22, 0.18, 0.09, 24)
	elseif kind == "close" then
		-- Silang DIGAMBAR, bukan huruf. Karakter silang (U+2715) tidak ada di font kita: di
		-- Studio ia keluar sebagai kotak kosong (19 Sep 2026). Dua batang miring selalu jadi.
		bar(parent, 0.5, 0.5, 0.86, 0.13, 45)
		bar(parent, 0.5, 0.5, 0.86, 0.13, -45)
	elseif kind == "cart" then
		bar(parent, 0.26, 0.26, 0.24, 0.08, -50) -- gagang
		bar(parent, 0.54, 0.52, 0.62, 0.34) -- keranjang
		dot(parent, 0.36, 0.84, 0.13)
		dot(parent, 0.7, 0.84, 0.13)
	elseif kind == "trash" then
		bar(parent, 0.5, 0.12, 0.24, 0.08) -- pegangan tutup
		bar(parent, 0.5, 0.26, 0.68, 0.09) -- tutup
		local body = bar(parent, 0.5, 0.62, 0.5, 0.6)
		for _, x in { 0.32, 0.68 } do
			local slot = Instance.new("Frame") -- "lubang" = warna latar, terbaca sebagai potongan
			slot.AnchorPoint = Vector2.new(0.5, 0.5)
			slot.Position = UDim2.fromScale(x, 0.5)
			slot.Size = UDim2.fromScale(0.12, 0.66)
			slot.BackgroundColor3 = Tokens.Color.Background
			slot.BorderSizePixel = 0
			slot.ZIndex = body.ZIndex + 1
			slot.Parent = body
		end
	end
end
SideRail.drawIcon = drawIcon -- dipakai ulang ActionBar: satu kosakata ikon untuk seluruh UI

local function iconButton(item: Item, order: number, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Name = item.key
	b.Text = ""
	b.LayoutOrder = order
	b.BackgroundColor3 = Tokens.Color.Panel
	b.BackgroundTransparency = Tokens.Transparency.Panel
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.ZIndex = Tokens.ZIndex.Hud
	b.Size = UDim2.fromOffset(ICON_BUTTON, ICON_BUTTON)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Medium
	corner.Parent = b

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Tokens.Color.Stroke
	stroke.Transparency = Tokens.Transparency.Stroke
	stroke.Parent = b

	local art = Instance.new("Frame")
	art.Name = "Icon"
	art.BackgroundTransparency = 1
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.5)
	art.Size = UDim2.fromScale(0.62, 0.62)
	art.ZIndex = b.ZIndex + 1
	art.Parent = b
	drawIcon(item.icon or "", art)
	if item.muted then
		for _, part in art:GetChildren() do
			if part:IsA("Frame") then
				part.BackgroundTransparency = 0.55
			end
		end
	end

	b.Parent = parent
	return b
end

local function railButton(item: Item, order: number, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Name = item.key
	b.Text = item.text
	b.LayoutOrder = order
	b.FontFace = Tokens.Font.Bold
	b.TextSize = Tokens.TextSize.Button
	b.TextColor3 = if item.muted then Tokens.Color.TextMuted else Tokens.Color.Text
	b.TextWrapped = true
	b.BackgroundColor3 = Tokens.Color.Panel
	b.BackgroundTransparency = Tokens.Transparency.Panel
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.ZIndex = Tokens.ZIndex.Hud

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Medium
	corner.Parent = b

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Tokens.Color.Stroke
	stroke.Transparency = Tokens.Transparency.Stroke
	stroke.Parent = b

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Tokens.Space.S)
	pad.PaddingRight = UDim.new(0, Tokens.Space.S)
	pad.Parent = b

	b.Parent = parent
	return b
end

function SideRail.new(props: Props): SideRail
	local icons = props.side == "bottomLeft"
	local isLeft = props.side ~= "right"
	local frame = Instance.new("Frame")
	frame.Name = if icons then "BottomRail" elseif isLeft then "LeftRail" else "RightRail"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = if icons then Vector2.new(0, 1) else Vector2.new(if isLeft then 0 else 1, 0.5)
	frame.Position = if icons
		then UDim2.new(0, Tokens.Space.M, 1, -Tokens.Space.M)
		elseif isLeft then UDim2.new(0, Tokens.Space.M, 0.5, 0)
		else UDim2.new(1, -Tokens.Space.M, 0.5, 0)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.new()
	frame.ZIndex = Tokens.ZIndex.Hud
	frame.Parent = props.parent

	-- Nama tombol ikon: label melayang DI ATAS kluster. Ia SAUDARA kluster, bukan anaknya:
	-- anak frame ber-UIListLayout pasti ikut dibariskan (bentuk lain dari temuan #25 no. 2).
	local label: TextLabel? = nil
	if icons then
		local l = Instance.new("TextLabel")
		l.Name = "IconLabel"
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0, 1)
		l.Position = UDim2.new(0, Tokens.Space.M, 1, -(Tokens.Space.M + ICON_BUTTON + 4))
		l.Size = UDim2.fromOffset(200, LABEL_H)
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.FontFace = Tokens.Font.Bold
		l.TextSize = Tokens.TextSize.Body
		l.TextColor3 = Tokens.Color.Text
		l.Text = ""
		l.Visible = false
		l.ZIndex = Tokens.ZIndex.Hud + 2
		l.Parent = props.parent
		label = l
	end

	local list = Instance.new("UIListLayout")
	list.FillDirection = if icons then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.HorizontalAlignment = if isLeft then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Right
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Tokens.Space.S)
	list.Parent = frame

	local buttons: { [string]: TextButton } = {}
	local order: { TextButton } = {}
	local conns: { RBXScriptConnection } = {}
	for i, item in props.items do
		local b = if icons then iconButton(item, i, frame) else railButton(item, i, frame)
		buttons[item.key] = b
		table.insert(order, b)
		local key = item.key
		table.insert(
			conns,
			b.Activated:Connect(function()
				if label then
					label.Text = item.text -- layar sentuh: nama muncul saat ditekan
					label.Visible = true
				end
				props.onActivated(key)
			end)
		)
		if label then
			local l = label
			table.insert(
				conns,
				b.MouseEnter:Connect(function()
					l.Text = item.text
					l.Visible = true
				end)
			)
			table.insert(
				conns,
				b.MouseLeave:Connect(function()
					if l.Text == item.text then
						l.Visible = false
					end
				end)
			)
		end
	end

	local self = setmetatable({
		instance = frame,
		_buttons = buttons,
		_order = order,
		_list = list,
		_compact = false,
		_icons = icons,
		_label = label,
		_conns = conns,
	}, SideRail)
	self:setCompact(false)
	return self
end

-- Layar pendek (ponsel mendatar): tombol lebih kecil & teks lebih kecil.
function SideRail.setCompact(self: SideRail, compact: boolean)
	self._compact = compact
	if self._icons then
		local side = if compact then ICON_BUTTON_COMPACT else ICON_BUTTON
		for _, b in self._order do
			b.Size = UDim2.fromOffset(side, side)
		end
		self._list.Padding = UDim.new(0, if compact then Tokens.Space.XS else Tokens.Space.S)
		if self._label then
			self._label.Position = UDim2.new(0, Tokens.Space.M, 1, -(Tokens.Space.M + side + 4))
		end
		return
	end
	local size = if compact then BUTTON_COMPACT else BUTTON
	for _, b in self._order do
		b.Size = UDim2.fromOffset(size.X, size.Y)
		b.TextSize = if compact then Tokens.TextSize.Body else Tokens.TextSize.Button
	end
	self._list.Padding = UDim.new(0, if compact then Tokens.Space.XS else Tokens.Space.S)
end

function SideRail.setVisible(self: SideRail, visible: boolean)
	self.instance.Visible = visible
	if not visible and self._label then
		self._label.Visible = false
	end
end

function SideRail.isVisible(self: SideRail): boolean
	return self.instance.Visible
end

-- Sorot tombol (mis. panelnya sedang terbuka).
function SideRail.setActive(self: SideRail, key: string, active: boolean)
	local b = self._buttons[key]
	if b == nil then
		return
	end
	b.BackgroundColor3 = if active then Tokens.Color.Accent else Tokens.Color.Panel
	b.BackgroundTransparency = if active then 0 else Tokens.Transparency.Panel
end

-- Teks sementara (mis. "Soon" untuk fitur yang belum ada), kembali setelah `seconds`.
function SideRail.flash(self: SideRail, key: string, text: string, seconds: number)
	local b = self._buttons[key]
	if b == nil then
		return
	end
	if self._icons then
		local l = self._label
		if l == nil then
			return
		end
		l.Text = text
		l.Visible = true
		task.delay(seconds, function()
			if l.Parent and l.Text == text then
				l.Visible = false
			end
		end)
		return
	end
	local original = b:GetAttribute("Label") or b.Text
	b:SetAttribute("Label", original)
	b.Text = text
	task.delay(seconds, function()
		if b.Parent and b.Text == text then
			b.Text = original
		end
	end)
end

function SideRail.destroy(self: SideRail)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	if self._label then
		self._label:Destroy() -- label melayang itu SAUDARA kluster, tidak ikut terbuang sendiri
		self._label = nil
	end
	self.instance:Destroy()
end

return SideRail
