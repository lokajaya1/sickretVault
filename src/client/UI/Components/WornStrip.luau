--!strict
-- WornStrip: deretan item yang sedang dipakai (di bawah avatar).
-- Tap item -> lapisan merah "Remove" muncul DI ATAS item itu + nama item di judul.
-- Tap lapisan itu -> item dilepas. Tap item lain / geser strip / tunggu 3 detik -> batal.
--   local strip = WornStrip.new({ parent = screenGui, onRemove = function(item) ... end })
--   strip:setItems(items)              -- item: { id, name, ... } (lihat Shared/Domain/WornItems)
--   strip:setPlacement(x, y, w, h)     -- piksel GUI
--   strip:setVisible(true)   strip:destroy()

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local TITLE_H = 16
local ARM_SECONDS = 3 -- lapisan Remove hilang sendiri setelah ini

export type Item = { id: number, name: string }

export type Props = {
	parent: Instance,
	onRemove: (item: Item) -> (),
}

type Tile = {
	button: ImageButton,
	overlay: TextButton,
}

local WornStrip = {}
WornStrip.__index = WornStrip

export type WornStrip = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_title: TextLabel,
		_scroll: ScrollingFrame,
		_tiles: { Tile },
		_items: { Item },
		_armed: number?, -- index tile yang sedang menampilkan Remove
		_armToken: number,
		_btnSize: number,
		_conns: { RBXScriptConnection },
	},
	WornStrip
))

local function thumbnail(id: number): string
	return ("rbxthumb://type=Asset&id=%d&w=150&h=150"):format(id)
end

local function corner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

function WornStrip.new(props: Props): WornStrip
	local root = Instance.new("Frame")
	root.Name = "WornStrip"
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = props.parent

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, TITLE_H)
	title.FontFace = Tokens.Font.Bold
	title.TextSize = Tokens.TextSize.Caption
	title.TextColor3 = Tokens.Color.Text
	title.TextStrokeTransparency = 0.6 -- tetap terbaca di atas dunia yang terang
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = "Wearing"
	title.ZIndex = Tokens.ZIndex.Hud
	title.Parent = root

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Items"
	scroll.BackgroundColor3 = Tokens.Color.Panel
	scroll.BackgroundTransparency = Tokens.Transparency.Panel
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, TITLE_H + 2)
	scroll.Size = UDim2.new(1, 0, 1, -(TITLE_H + 2))
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.X
	scroll.ScrollingDirection = Enum.ScrollingDirection.X
	scroll.ScrollBarThickness = 2
	scroll.ZIndex = Tokens.ZIndex.Hud
	scroll.Parent = root
	corner(scroll, Tokens.Radius.Medium)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Tokens.Space.XS)
	pad.PaddingRight = UDim.new(0, Tokens.Space.XS)
	pad.PaddingTop = UDim.new(0, Tokens.Space.XS)
	pad.PaddingBottom = UDim.new(0, Tokens.Space.XS)
	pad.Parent = scroll

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Tokens.Space.XS)
	list.Parent = scroll

	local self = setmetatable({
		instance = root,
		_props = props,
		_title = title,
		_scroll = scroll,
		_tiles = {},
		_items = {},
		_armed = nil,
		_armToken = 0,
		_btnSize = 48,
		_conns = {},
	}, WornStrip)

	-- Menggulir strip -> batalkan Remove yang sedang tampil.
	table.insert(
		self._conns,
		scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			self:_disarm()
		end)
	)
	return self
end

function WornStrip._updateTitle(self: WornStrip)
	local armed = self._armed
	local item = if armed then self._items[armed] else nil
	if item then
		self._title.Text = item.name
	elseif #self._items == 0 then
		self._title.Text = "Wearing: nothing to remove"
	else
		self._title.Text = ("Wearing (%d)"):format(#self._items)
	end
end

function WornStrip._disarm(self: WornStrip)
	local armed = self._armed
	if armed and self._tiles[armed] then
		self._tiles[armed].overlay.Visible = false
	end
	self._armed = nil
	self:_updateTitle()
end

function WornStrip._arm(self: WornStrip, index: number)
	if self._items[index] == nil then
		return
	end
	self:_disarm()
	self._armed = index
	self._tiles[index].overlay.Visible = true
	self:_updateTitle()

	self._armToken += 1
	local token = self._armToken
	task.delay(ARM_SECONDS, function()
		if self._armToken == token and self._armed == index then
			self:_disarm()
		end
	end)
end

function WornStrip._newTile(self: WornStrip, index: number): Tile
	local button = Instance.new("ImageButton")
	button.Name = "Item"
	button.LayoutOrder = index
	button.BackgroundColor3 = Tokens.Color.PanelRaised
	button.BackgroundTransparency = Tokens.Transparency.PanelRaised
	button.BorderSizePixel = 0
	button.ScaleType = Enum.ScaleType.Fit
	button.AutoButtonColor = true
	button.Size = UDim2.fromOffset(self._btnSize, self._btnSize)
	button.ZIndex = Tokens.ZIndex.Hud
	button.Parent = self._scroll
	corner(button, Tokens.Radius.Small)

	-- Lapisan Remove menutupi item (tap kedua = lepas)
	local overlay = Instance.new("TextButton")
	overlay.Name = "Remove"
	overlay.Text = "Remove"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Tokens.Color.Danger
	overlay.BackgroundTransparency = 0.15
	overlay.BorderSizePixel = 0
	overlay.AutoButtonColor = true
	overlay.FontFace = Tokens.Font.Bold
	overlay.TextColor3 = Tokens.Color.Text
	overlay.TextScaled = true -- muat di tombol 44 px (ponsel) maupun 52 px
	overlay.Visible = false
	overlay.ZIndex = Tokens.ZIndex.Hud + 1
	overlay.Parent = button
	corner(overlay, Tokens.Radius.Small)

	local sizeLimit = Instance.new("UITextSizeConstraint")
	sizeLimit.MaxTextSize = Tokens.TextSize.Caption
	sizeLimit.Parent = overlay

	local overlayPad = Instance.new("UIPadding")
	overlayPad.PaddingLeft = UDim.new(0, 2)
	overlayPad.PaddingRight = UDim.new(0, 2)
	overlayPad.Parent = overlay

	table.insert(
		self._conns,
		button.Activated:Connect(function()
			self:_arm(index)
		end)
	)
	table.insert(
		self._conns,
		overlay.Activated:Connect(function()
			local item = self._items[index]
			self:_disarm()
			if item then
				self._props.onRemove(item)
			end
		end)
	)
	return { button = button, overlay = overlay }
end

function WornStrip.setItems(self: WornStrip, items: { Item })
	-- item yang sedang dipilih: tetap dipilih bila masih ada (posisi bisa bergeser)
	local prev = self._armed
	local prevItem = if prev then self._items[prev] else nil
	local armedId = if prevItem then prevItem.id else nil
	self:_disarm()
	self._items = items

	local tiles = self._tiles
	for i, item in items do
		local tile = tiles[i]
		if tile == nil then
			tile = self:_newTile(i)
			tiles[i] = tile
		end
		tile.button.Image = thumbnail(item.id)
		tile.button.Visible = true
	end
	for i = #items + 1, #tiles do
		tiles[i].button.Visible = false
	end

	self:_updateTitle()
	if armedId then
		for i, item in items do
			if item.id == armedId then
				self:_arm(i)
			end
		end
	end
end

function WornStrip.setPlacement(self: WornStrip, x: number, y: number, w: number, h: number)
	self.instance.Position = UDim2.fromOffset(x, y)
	self.instance.Size = UDim2.fromOffset(w, h)
	-- tile persegi = tinggi area item dikurangi padding atas-bawah
	local size = math.max(24, h - (TITLE_H + 2) - Tokens.Space.XS * 2)
	self._btnSize = size
	for _, tile in self._tiles do
		tile.button.Size = UDim2.fromOffset(size, size)
	end
end

function WornStrip.setVisible(self: WornStrip, visible: boolean)
	self.instance.Visible = visible
	if not visible then
		self:_disarm()
	end
end

function WornStrip.destroy(self: WornStrip)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return WornStrip
