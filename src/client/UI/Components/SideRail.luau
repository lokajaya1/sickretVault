--!strict
-- Kolom tombol samping (tengah-vertikal layar), mengikuti pola layout CAC:
--   kiri  = Community Outfits, Outfit Loader (menyusul)
--   kanan = Saved Outfits, Emotes (menyusul)
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

export type Item = { key: string, text: string, muted: boolean? } -- muted = fitur belum aktif

export type Props = {
	parent: Instance,
	side: "left" | "right",
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
		_conns: { RBXScriptConnection },
	},
	SideRail
))

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
	local isLeft = props.side == "left"
	local frame = Instance.new("Frame")
	frame.Name = if isLeft then "LeftRail" else "RightRail"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(if isLeft then 0 else 1, 0.5)
	frame.Position = if isLeft then UDim2.new(0, Tokens.Space.M, 0.5, 0) else UDim2.new(1, -Tokens.Space.M, 0.5, 0)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.new()
	frame.ZIndex = Tokens.ZIndex.Hud
	frame.Parent = props.parent

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = if isLeft then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Right
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Tokens.Space.S)
	list.Parent = frame

	local buttons: { [string]: TextButton } = {}
	local order: { TextButton } = {}
	local conns: { RBXScriptConnection } = {}
	for i, item in props.items do
		local b = railButton(item, i, frame)
		buttons[item.key] = b
		table.insert(order, b)
		local key = item.key
		table.insert(
			conns,
			b.Activated:Connect(function()
				props.onActivated(key)
			end)
		)
	end

	local self = setmetatable({
		instance = frame,
		_buttons = buttons,
		_order = order,
		_list = list,
		_compact = false,
		_conns = conns,
	}, SideRail)
	self:setCompact(false)
	return self
end

-- Layar pendek (ponsel mendatar): tombol lebih kecil & teks lebih kecil.
function SideRail.setCompact(self: SideRail, compact: boolean)
	self._compact = compact
	local size = if compact then BUTTON_COMPACT else BUTTON
	for _, b in self._order do
		b.Size = UDim2.fromOffset(size.X, size.Y)
		b.TextSize = if compact then Tokens.TextSize.Body else Tokens.TextSize.Button
	end
	self._list.Padding = UDim.new(0, if compact then Tokens.Space.XS else Tokens.Space.S)
end

function SideRail.setVisible(self: SideRail, visible: boolean)
	self.instance.Visible = visible
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
	self.instance:Destroy()
end

return SideRail
