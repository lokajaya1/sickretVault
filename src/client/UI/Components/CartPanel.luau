--!strict
-- Panel keranjang: MENUTUPI isi panel katalog (anak dari CatalogPanel.instance), di bawah panel detail.
-- Hanya menampilkan snapshot CartController; aksi diteruskan lewat props (App yang memutuskan).
--   local cartPanel = CartPanel.new({
--   	parent = catalogPanel.instance, controller = cartController,
--   	onItemActivated = function(item) ... end,  -- tap baris -> panel detail
--   	onCheckout = function() ... end,           -- tombol Buy All
--   })
--   cartPanel:setOpen(true)   cartPanel:isOpen()   cartPanel:destroy()
-- Isi: Back + judul "Cart (n/20)" + Clear; daftar (thumbnail, nama, tipe, harga, ✕); bawah: total + Buy All.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WornItems = require(Shared.Domain.WornItems)
local Tokens = require(script.Parent.Parent.Theme.Tokens)

local HEADER_H = 36
local FOOTER_H = 44
local ROW_H = 64
local THUMB = 52
local REMOVE_W = 36
local PRICE_W = 72
local ROBUX = utf8.char(0xE002) -- ikon Robux bawaan font Roblox
local Z = Tokens.ZIndex.Panel + 4 -- di atas isi katalog, di bawah ItemDetailPanel (+5)

export type Props = {
	parent: GuiObject, -- CatalogPanel.instance
	controller: any, -- CartController
	onItemActivated: ((item: any) -> ())?, -- tap baris
	onCheckout: () -> (), -- tombol Buy All
	onBack: (() -> ())?, -- default: setOpen(false)
}

type Row = { frame: Frame, conns: { RBXScriptConnection } }

local CartPanel = {}
CartPanel.__index = CartPanel

export type CartPanel = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_title: TextLabel,
		_clear: TextButton,
		_list: ScrollingFrame,
		_empty: TextLabel,
		_total: TextLabel,
		_buy: TextButton,
		_rows: { Row },
		_rowsKey: string,
		_snap: any?,
		_conns: { RBXScriptConnection },
		_unsubscribe: () -> (),
	},
	CartPanel
))

local function make(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(radius: UDim): UICorner
	return make("UICorner", { CornerRadius = radius })
end

local function label(props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = Z,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextLabel", base)
end

local function button(text: string, props: { [string]: any }): TextButton
	local base = {
		Text = text,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		ZIndex = Z,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextButton", base, { corner(Tokens.Radius.Pill) })
end

local function thumbnail(item: any): string
	local kind = if item.itemType == "Bundle" then "BundleThumbnail" else "Asset"
	return ("rbxthumb://type=%s&id=%d&w=150&h=150"):format(kind, item.id)
end

local function typeText(item: any): string
	if item.itemType == "Bundle" then
		return "Bundle"
	end
	return if item.assetType then WornItems.friendlyName(item.assetType) else "Item"
end

local function priceText(price: number): string
	return if price <= 0 then "Free" else ROBUX .. " " .. tostring(price)
end

function CartPanel.new(props: Props): CartPanel
	local pad = Tokens.Space.M
	local ctl = props.controller

	-- Menutupi seluruh panel katalog (termasuk padding induk), latar penuh.
	local root: Frame = make("Frame", {
		Name = "CartPanel",
		Active = true,
		BackgroundColor3 = Tokens.Color.Panel,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(-pad, -pad),
		Size = UDim2.new(1, pad * 2, 1, pad * 2),
		Visible = false,
		ZIndex = Z,
		Parent = props.parent,
	}, {
		corner(Tokens.Radius.Large),
		make("UIPadding", {
			PaddingTop = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, pad),
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
		}),
	})
	-- Penahan klik: tombol kosong di lapisan paling bawah supaya tap tidak tembus ke kartu katalog.
	make("TextButton", {
		Name = "InputBlocker",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z - 1,
		Parent = root,
	})

	-- Header: Back + judul + Clear
	local back = button("‹ Back", {
		Name = "Back",
		Size = UDim2.fromOffset(84, HEADER_H),
		Parent = root,
	})
	local title = label({
		Name = "Title",
		Text = "Cart",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		Position = UDim2.fromOffset(84 + Tokens.Space.M, 0),
		Size = UDim2.new(1, -(84 + Tokens.Space.M) - 72 - Tokens.Space.S, 0, HEADER_H),
		Parent = root,
	})
	local clear = button("Clear", {
		Name = "Clear",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(72, HEADER_H),
		TextColor3 = Tokens.Color.Danger,
		Parent = root,
	})

	-- Daftar item
	local list: ScrollingFrame = make("ScrollingFrame", {
		Name = "Items",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, HEADER_H + Tokens.Space.S),
		Size = UDim2.new(1, 0, 1, -(HEADER_H + FOOTER_H + Tokens.Space.S * 2)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Tokens.Color.TextMuted,
		ZIndex = Z,
		Parent = root,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.S),
		}),
		make("UIPadding", { PaddingRight = UDim.new(0, Tokens.Space.S) }),
	})
	local empty = label({
		Name = "Empty",
		Text = "Your cart is empty.\nTap 🛒 on an item to add it.",
		TextColor3 = Tokens.Color.TextMuted,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, HEADER_H + Tokens.Space.XL),
		Size = UDim2.new(1, 0, 0, 48),
		Visible = false,
		Parent = root,
	})

	-- Bawah: total + Buy All
	local footer: Frame = make("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		ZIndex = Z,
		Parent = root,
	})
	local total = label({
		Name = "Total",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Button,
		TextColor3 = Tokens.Color.Robux,
		Size = UDim2.new(0.45, 0, 1, 0),
		Parent = footer,
	})
	local buy = button("Buy All", {
		Name = "BuyAll",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.55, -Tokens.Space.S, 1, 0),
		TextSize = Tokens.TextSize.Button,
		BackgroundColor3 = Tokens.Color.Robux,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		Parent = footer,
	})

	local conns: { RBXScriptConnection } = {}
	local self: CartPanel = setmetatable({
		instance = root,
		_props = props,
		_title = title,
		_clear = clear,
		_list = list,
		_empty = empty,
		_total = total,
		_buy = buy,
		_rows = {},
		_rowsKey = "",
		_snap = nil,
		_conns = conns,
		_unsubscribe = function() end,
	}, CartPanel)

	table.insert(
		conns,
		back.Activated:Connect(function()
			if props.onBack then
				props.onBack()
			else
				self:setOpen(false)
			end
		end)
	)
	table.insert(
		conns,
		clear.Activated:Connect(function()
			local s = self._snap
			if s and s.count > 0 and not s.checkingOut then
				ctl:clear()
			end
		end)
	)
	table.insert(
		conns,
		buy.Activated:Connect(function()
			local s = self._snap
			if s and s.count > 0 and not s.checkingOut then
				props.onCheckout()
			end
		end)
	)

	self._unsubscribe = ctl:onChanged(function(snap)
		self:_render(snap)
	end)
	self:_render(ctl:getSnapshot())
	return self
end

function CartPanel._clearRows(self: CartPanel)
	for _, row in self._rows do
		for _, c in row.conns do
			c:Disconnect()
		end
		row.frame:Destroy()
	end
	table.clear(self._rows)
end

function CartPanel._buildRow(self: CartPanel, item: any, order: number): Row
	local frame: Frame = make("Frame", {
		Name = "Item_" .. item.itemType .. "_" .. tostring(item.id),
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, ROW_H),
		ZIndex = Z,
		Parent = self._list,
	}, { corner(Tokens.Radius.Medium) })
	-- Area tap (thumbnail + teks) -> detail
	local open: TextButton = make("TextButton", {
		Name = "Open",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(REMOVE_W + Tokens.Space.S), 1, 0),
		ZIndex = Z,
		Parent = frame,
	})
	make("ImageLabel", {
		Name = "Thumbnail",
		BackgroundTransparency = 1,
		Image = thumbnail(item),
		ScaleType = Enum.ScaleType.Fit,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, Tokens.Space.S, 0.5, 0),
		Size = UDim2.fromOffset(THUMB, THUMB),
		ZIndex = Z,
		Parent = frame,
	})
	local textX = Tokens.Space.S * 2 + THUMB
	local textW = -(textX + PRICE_W + REMOVE_W + Tokens.Space.S * 2)
	label({
		Name = "ItemName",
		Text = item.name,
		FontFace = Tokens.Font.Bold,
		Position = UDim2.new(0, textX, 0, Tokens.Space.S),
		Size = UDim2.new(1, textW, 0, 22),
		Parent = frame,
	})
	label({
		Name = "Type",
		Text = typeText(item),
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		Position = UDim2.new(0, textX, 0, Tokens.Space.S + 24),
		Size = UDim2.new(1, textW, 0, 18),
		Parent = frame,
	})
	label({
		Name = "Price",
		Text = priceText(item.price),
		FontFace = Tokens.Font.Bold,
		TextColor3 = Tokens.Color.Robux,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(REMOVE_W + Tokens.Space.S * 2), 0.5, 0),
		Size = UDim2.fromOffset(PRICE_W, 22),
		Parent = frame,
	})
	local remove = button("✕", {
		Name = "Remove",
		TextColor3 = Tokens.Color.Danger,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -Tokens.Space.S, 0.5, 0),
		Size = UDim2.fromOffset(REMOVE_W, REMOVE_W),
		Parent = frame,
	})

	local id, itemType = item.id, item.itemType
	local conns = {
		remove.Activated:Connect(function()
			local s = self._snap
			if s and not s.checkingOut then
				self._props.controller:remove(id, itemType)
			end
		end),
		open.Activated:Connect(function()
			if self._props.onItemActivated then
				self._props.onItemActivated(item)
			end
		end),
	}
	return { frame = frame, conns = conns }
end

function CartPanel._render(self: CartPanel, snap: any)
	self._snap = snap
	local keys = {}
	for i, item in snap.items do
		keys[i] = item.itemType .. ":" .. tostring(item.id)
	end
	local key = table.concat(keys, ",")
	if key ~= self._rowsKey then
		self._rowsKey = key
		self:_clearRows()
		for i, item in snap.items do
			table.insert(self._rows, self:_buildRow(item, i))
		end
	end

	local n = snap.count
	self._title.Text = ("Cart (%d/%d)"):format(n, snap.max)
	self._empty.Visible = n == 0
	self._clear.Visible = n > 0
	self._total.Text = if n > 0 then "Total " .. priceText(snap.total) else ""

	local canBuy = n > 0 and not snap.checkingOut
	self._buy.Text = if snap.checkingOut then "Opening…" elseif n > 0 then ("Buy All (%d)"):format(n) else "Buy All"
	self._buy.BackgroundColor3 = if canBuy then Tokens.Color.Robux else Tokens.Color.PanelRaised
	self._buy.TextColor3 = if canBuy then Tokens.Color.AccentText else Tokens.Color.TextMuted
	self._buy.AutoButtonColor = canBuy
end

function CartPanel.setOpen(self: CartPanel, open: boolean)
	self.instance.Visible = open
	if open then
		self._list.CanvasPosition = Vector2.zero
	end
end

function CartPanel.isOpen(self: CartPanel): boolean
	return self.instance.Visible
end

function CartPanel.destroy(self: CartPanel)
	self._unsubscribe()
	self:_clearRows()
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return CartPanel
