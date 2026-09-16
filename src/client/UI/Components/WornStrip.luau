--!strict
-- WornStrip: deretan item yang sedang dipakai (di bawah avatar). Tap item -> popover "Remove".
--   local strip = WornStrip.new({ parent = screenGui, onRemove = function(item) ... end })
--   strip:setItems(items)              -- item: { id, name, ... } (lihat Shared/Domain/WornItems)
--   strip:setPlacement(x, y, w, h)     -- piksel GUI
--   strip:setVisible(true)   strip:destroy()

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local TITLE_H = 16
local POPOVER_W = 180
local POPOVER_H = 64

export type Item = { id: number, name: string }

export type Props = {
	parent: Instance,
	onRemove: (item: Item) -> (),
}

local WornStrip = {}
WornStrip.__index = WornStrip

export type WornStrip = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_title: TextLabel,
		_scroll: ScrollingFrame,
		_buttons: { ImageButton },
		_items: { Item },
		_popover: Frame,
		_popName: TextLabel,
		_selected: Item?,
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
	root.ZIndex = Tokens.ZIndex.Popup -- popover harus di atas tombol aksi (ZIndexBehavior Sibling)
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

	-- Popover: nama item + tombol Remove, muncul di atas item yang dipilih
	local popover = Instance.new("Frame")
	popover.Name = "Popover"
	popover.AnchorPoint = Vector2.new(0, 1)
	popover.Size = UDim2.fromOffset(POPOVER_W, POPOVER_H)
	popover.BackgroundColor3 = Tokens.Color.Background
	popover.BackgroundTransparency = 0.05
	popover.BorderSizePixel = 0
	popover.Visible = false
	popover.ZIndex = Tokens.ZIndex.Popup
	popover.Parent = root
	corner(popover, Tokens.Radius.Medium)

	local popPad = Instance.new("UIPadding")
	popPad.PaddingLeft = UDim.new(0, Tokens.Space.S)
	popPad.PaddingRight = UDim.new(0, Tokens.Space.S)
	popPad.PaddingTop = UDim.new(0, Tokens.Space.S)
	popPad.PaddingBottom = UDim.new(0, Tokens.Space.S)
	popPad.Parent = popover

	local popName = Instance.new("TextLabel")
	popName.Name = "ItemName"
	popName.BackgroundTransparency = 1
	popName.Size = UDim2.new(1, 0, 0, 16)
	popName.FontFace = Tokens.Font.Medium
	popName.TextSize = Tokens.TextSize.Caption
	popName.TextColor3 = Tokens.Color.Text
	popName.TextXAlignment = Enum.TextXAlignment.Left
	popName.TextTruncate = Enum.TextTruncate.AtEnd
	popName.ZIndex = Tokens.ZIndex.Popup
	popName.Parent = popover

	local remove = Instance.new("TextButton")
	remove.Name = "Remove"
	remove.Text = "Remove"
	remove.AnchorPoint = Vector2.new(0, 1)
	remove.Position = UDim2.fromScale(0, 1)
	remove.Size = UDim2.new(1, 0, 0, 26)
	remove.FontFace = Tokens.Font.Bold
	remove.TextSize = Tokens.TextSize.Body
	remove.TextColor3 = Tokens.Color.Text
	remove.BackgroundColor3 = Tokens.Color.Danger
	remove.BorderSizePixel = 0
	remove.AutoButtonColor = true
	remove.ZIndex = Tokens.ZIndex.Popup
	remove.Parent = popover
	corner(remove, Tokens.Radius.Pill)

	local self = setmetatable({
		instance = root,
		_props = props,
		_title = title,
		_scroll = scroll,
		_buttons = {},
		_items = {},
		_popover = popover,
		_popName = popName,
		_selected = nil,
		_btnSize = 48,
		_conns = {},
	}, WornStrip)

	table.insert(
		self._conns,
		remove.Activated:Connect(function()
			local item = self._selected
			self:_close()
			if item then
				props.onRemove(item)
			end
		end)
	)
	-- Menggulir strip -> popover tidak lagi sejajar item, tutup saja.
	table.insert(
		self._conns,
		scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			self:_close()
		end)
	)
	return self
end

function WornStrip._close(self: WornStrip)
	self._selected = nil
	self._popover.Visible = false
end

function WornStrip._open(self: WornStrip, index: number)
	local item = self._items[index]
	local button = self._buttons[index]
	if item == nil or button == nil then
		return
	end
	if self._selected and self._selected.id == item.id then
		self:_close() -- tap kedua pada item yang sama = tutup
		return
	end
	self._selected = item
	self._popName.Text = item.name
	local relX = button.AbsolutePosition.X - self.instance.AbsolutePosition.X
	local maxX = math.max(0, self.instance.AbsoluteSize.X - POPOVER_W)
	self._popover.Position = UDim2.fromOffset(math.clamp(relX, 0, maxX), -Tokens.Space.XS)
	self._popover.Visible = true
end

function WornStrip.setItems(self: WornStrip, items: { Item })
	self._items = items
	self._title.Text = if #items == 0 then "Wearing: nothing to remove" else ("Wearing (%d)"):format(#items)

	local buttons = self._buttons
	for i, item in items do
		local b = buttons[i]
		if b == nil then
			local nb = Instance.new("ImageButton")
			nb.Name = "Item"
			nb.LayoutOrder = i
			nb.BackgroundColor3 = Tokens.Color.PanelRaised
			nb.BackgroundTransparency = Tokens.Transparency.PanelRaised
			nb.BorderSizePixel = 0
			nb.ScaleType = Enum.ScaleType.Fit
			nb.AutoButtonColor = true
			nb.Size = UDim2.fromOffset(self._btnSize, self._btnSize)
			nb.ZIndex = Tokens.ZIndex.Hud
			nb.Parent = self._scroll
			corner(nb, Tokens.Radius.Small)
			local index = i
			table.insert(
				self._conns,
				nb.Activated:Connect(function()
					self:_open(index)
				end)
			)
			buttons[i] = nb
			b = nb
		end
		b.Image = thumbnail(item.id)
		b.Visible = true
	end
	for i = #items + 1, #buttons do
		buttons[i].Visible = false
	end

	-- Item terpilih sudah dilepas -> tutup popover
	local sel = self._selected
	if sel then
		local still = false
		for _, it in items do
			if it.id == sel.id then
				still = true
				self._popName.Text = it.name
			end
		end
		if not still then
			self:_close()
		end
	end
end

function WornStrip.setPlacement(self: WornStrip, x: number, y: number, w: number, h: number)
	self.instance.Position = UDim2.fromOffset(x, y)
	self.instance.Size = UDim2.fromOffset(w, h)
	-- tombol persegi = tinggi area item dikurangi padding atas-bawah
	local size = math.max(24, h - (TITLE_H + 2) - Tokens.Space.XS * 2)
	self._btnSize = size
	for _, b in self._buttons do
		b.Size = UDim2.fromOffset(size, size)
	end
end

function WornStrip.setVisible(self: WornStrip, visible: boolean)
	self.instance.Visible = visible
	if not visible then
		self:_close()
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
