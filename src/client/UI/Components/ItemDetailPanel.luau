--!strict
-- Panel detail item: MENUTUPI isi panel katalog (anak dari CatalogPanel.instance).
-- Hanya menampilkan state DetailController; aksi diteruskan lewat props (App yang memutuskan).
--   local detail = ItemDetailPanel.new({
--   	parent = catalogPanel.instance, controller = detailController,
--   	isWorn = function(d) ... end, isPartWorn = function(assetId) ... end,
--   	onToggle = function(d) ... end, onPartActivated = function(part, d) ... end,
--   })
--   detail:refreshWorn()   -- outfit berubah -> teks tombol & sorotan part
--   detail:refreshCart()   -- keranjang berubah -> tombol 🛒
--   detail:destroy()
-- Isi: Back + judul; thumbnail; nama; creator (+verified); tipe; harga; Try On/Remove + Buy + 🛒;
-- deskripsi; "Included Items" (part bundle, tap -> onPartActivated).
-- #17d: nama creator BISA DIKLIK (teks biasa, emas saat disentuh) -> onCreator; sisa stok item
-- limited; baris "Recommended" geser mendatar di bawah tombol beli -> onRecommended.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemDetail = require(Shared.Domain.ItemDetail)
local AssetTypeMap = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Domain.AssetTypeMap)
local Tokens = require(script.Parent.Parent.Theme.Tokens)
local CartIcon = require(script.Parent.Parent.Util.CartIcon)

local THUMB_SIZE = 420 -- rbxthumb besar untuk panel detail
local HEADER_H = 36
local BUTTON_H = 40
local CART_W = 56 -- tombol 🛒 di kanan Buy
local PART_MIN = 84 -- lebar minimum tile part
local PART_TEXT = 28 -- tinggi nama di bawah gambar part
local REC_W = 96 -- lebar kartu Recommended
local REC_H = 130 -- tinggi baris Recommended (gambar + nama + harga)
local REC_TEXT = 34 -- tinggi nama + harga di bawah gambar
local ROBUX = utf8.char(0xE002) -- ikon Robux bawaan font Roblox
local VERIFIED = utf8.char(0xE000) -- lencana verified bawaan font Roblox

local ERROR_TEXT: { [string]: string } = {
	NOT_FOUND = "Item not found",
	RATE_LIMITED = "Slow down a little",
	BAD_ARG = "Invalid item",
	NETWORK = "Couldn't reach the server",
	FAILED = "Couldn't load details",
}

export type Props = {
	parent: GuiObject, -- CatalogPanel.instance
	controller: any, -- DetailController
	isWorn: (detail: any) -> boolean,
	isPartWorn: (assetId: number) -> boolean,
	onToggle: (detail: any) -> (), -- tombol Try On / Remove
	onBuy: ((detail: any) -> ())?, -- tombol Buy (nil = tombol disembunyikan)
	onCart: ((detail: any) -> ())?, -- tombol 🛒 tambah / buang dari keranjang (nil = disembunyikan)
	isInCart: ((detail: any) -> boolean)?,
	onPartActivated: (part: any, detail: any) -> (),
	onCreator: ((detail: any) -> ())?, -- nama creator diklik (nil = tidak bisa diklik)
	onRecommended: ((item: any) -> ())?, -- kartu di baris Recommended diklik
	onBack: (() -> ())?, -- default: controller:close()
}

type Tile = { button: ImageButton, stroke: UIStroke, part: any, conn: RBXScriptConnection? }
type RecTile = { button: ImageButton, conn: RBXScriptConnection? }

local ItemDetailPanel = {}
ItemDetailPanel.__index = ItemDetailPanel

export type ItemDetailPanel = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_title: TextLabel,
		_scroll: ScrollingFrame,
		_status: TextLabel,
		_retry: TextButton,
		_statusRow: Frame,
		_top: Frame,
		_thumb: ImageLabel,
		_name: TextLabel,
		_creator: TextButton,
		_stock: TextLabel,
		_recHeader: TextLabel,
		_recRow: ScrollingFrame,
		_recTiles: { RecTile },
		_recKey: string?,
		_type: TextLabel,
		_price: TextLabel,
		_favorites: TextLabel,
		_toggle: TextButton,
		_buy: TextButton,
		_cart: TextButton,
		_actions: Frame,
		_descHeader: TextLabel,
		_desc: TextLabel,
		_partsHeader: TextLabel,
		_parts: Frame,
		_partsLayout: UIGridLayout,
		_tiles: { Tile },
		_tilesKey: string?,
		_detail: any?,
		_conns: { RBXScriptConnection },
		_unsubscribe: () -> (),
	},
	ItemDetailPanel
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
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
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
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextButton", base, { corner(Tokens.Radius.Pill) })
end

local function thumbnail(kind: string, id: number, size: number): string
	return ("rbxthumb://type=%s&id=%d&w=%d&h=%d"):format(kind, id, size, size)
end

local function shortNumber(n: number): string
	if n >= 1e9 then
		return ("%.1fB"):format(n / 1e9)
	elseif n >= 1e6 then
		return ("%.1fM"):format(n / 1e6)
	elseif n >= 1e3 then
		return ("%.1fK"):format(n / 1e3)
	end
	return tostring(math.floor(n))
end

local function priceText(d: any): (string, Color3)
	local text: string
	local color = Tokens.Color.Robux
	if d.price ~= nil and d.isForSale then
		text = if d.price <= 0 then "Free" else ROBUX .. " " .. tostring(d.price)
	elseif d.lowestResalePrice ~= nil then
		text = ROBUX .. " " .. tostring(d.lowestResalePrice) .. "  (resale)"
	else
		text = "Off Sale"
		color = Tokens.Color.TextMuted
	end
	if d.isLimited then
		text ..= "  ·  Limited"
	end
	return text, color
end

function ItemDetailPanel.new(props: Props): ItemDetailPanel
	local pad = Tokens.Space.M
	local ctl = props.controller

	-- Menutupi seluruh panel katalog (termasuk padding induk), latar penuh supaya isi katalog tidak tembus.
	local root: Frame = make("Frame", {
		Name = "ItemDetailPanel",
		Active = true, -- tahan klik ke kartu/kotak cari di bawahnya
		BackgroundColor3 = Tokens.Color.Panel,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(-pad, -pad),
		Size = UDim2.new(1, pad * 2, 1, pad * 2),
		Visible = false,
		ZIndex = Tokens.ZIndex.Panel + 5,
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

	-- Header: Back + judul (tipe item)
	local back = button("‹ Back", {
		Name = "Back",
		Size = UDim2.fromOffset(84, HEADER_H),
		Parent = root,
	})
	local title = label({
		Name = "Title",
		Text = "Item Details",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextYAlignment = Enum.TextYAlignment.Center,
		AutomaticSize = Enum.AutomaticSize.None,
		Position = UDim2.fromOffset(84 + Tokens.Space.M, 0),
		Size = UDim2.new(1, -(84 + Tokens.Space.M), 0, HEADER_H),
		Parent = root,
	})

	local scroll: ScrollingFrame = make("ScrollingFrame", {
		Name = "Content",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, HEADER_H + Tokens.Space.S),
		Size = UDim2.new(1, 0, 1, -(HEADER_H + Tokens.Space.S)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Tokens.Color.TextMuted,
		Parent = root,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.M),
		}),
		make("UIPadding", { PaddingRight = UDim.new(0, Tokens.Space.S) }),
	})

	-- Status (memuat / error + Coba lagi)
	local statusRow: Frame = make("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, BUTTON_H),
		Visible = false,
		Parent = scroll,
	})
	local status = label({
		Name = "Text",
		TextColor3 = Tokens.Color.TextMuted,
		TextYAlignment = Enum.TextYAlignment.Center,
		AutomaticSize = Enum.AutomaticSize.None,
		Size = UDim2.new(1, -96, 1, 0),
		Parent = statusRow,
	})
	local retry = button("Retry", {
		Name = "Retry",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(88, BUTTON_H - 8),
		Visible = false,
		Parent = statusRow,
	})

	-- Atas: thumbnail kiri + info kanan
	local top: Frame = make("Frame", {
		Name = "Top",
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 120),
		Parent = scroll,
	})
	local thumb: ImageLabel = make("ImageLabel", {
		Name = "Thumbnail",
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		ScaleType = Enum.ScaleType.Fit,
		Size = UDim2.fromOffset(120, 120),
		Parent = top,
	}, { corner(Tokens.Radius.Medium) })
	local info: Frame = make("Frame", {
		Name = "Info",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(120 + Tokens.Space.M, 0),
		Size = UDim2.new(1, -(120 + Tokens.Space.M), 0, 0),
		Parent = top,
	}, {
		make("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.XS),
		}),
	})
	local name = label({
		Name = "ItemName",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		LayoutOrder = 1,
		Parent = info,
	})
	-- Nama creator: tetap terlihat seperti teks biasa, tapi bisa diklik (emas saat disentuh).
	local creator: TextButton = make("TextButton", {
		Name = "Creator",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = 2,
		Parent = info,
	})
	local typeLabel = label({
		Name = "Type",
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		LayoutOrder = 3,
		Parent = info,
	})
	local price = label({
		Name = "Price",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Button,
		LayoutOrder = 4,
		Parent = info,
	})
	local favorites = label({
		Name = "Favorites",
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		LayoutOrder = 5,
		Parent = info,
	})
	local stock = label({
		Name = "Stock",
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		LayoutOrder = 6,
		Parent = info,
	})

	-- Baris aksi: Try On/Remove (kiri) + Buy (kanan)
	local actions: Frame = make("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, BUTTON_H),
		Parent = scroll,
	})
	local hasBuy = props.onBuy ~= nil
	local hasCart = props.onCart ~= nil
	local half = Tokens.Space.S / 2
	-- ruang kanan untuk tombol 🛒 (dibagi rata ke Try On & Buy)
	local cartSpace = if hasCart then CART_W + Tokens.Space.S else 0
	local toggle = button("Try On", {
		Name = "Toggle",
		Size = if hasBuy then UDim2.new(0.5, -(half + cartSpace / 2), 1, 0) else UDim2.new(1, -cartSpace, 1, 0),
		TextSize = Tokens.TextSize.Button,
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		Parent = actions,
	})
	local buy = button("Buy", {
		Name = "Buy",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -cartSpace, 0, 0),
		Size = UDim2.new(0.5, -(half + cartSpace / 2), 1, 0),
		TextSize = Tokens.TextSize.Button,
		BackgroundColor3 = Tokens.Color.Robux,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		Visible = hasBuy,
		Parent = actions,
	})
	local cart = button("", {
		Name = "Cart",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, CART_W, 1, 0),
		Visible = hasCart,
		Parent = actions,
	})

	-- Baris Recommended: geser MENDATAR, tepat di bawah tombol beli (keputusan UX 19 Sep 2026).
	local recHeader = label({
		Name = "RecommendedHeader",
		Text = "Recommended",
		FontFace = Tokens.Font.Bold,
		LayoutOrder = 3,
		Visible = false,
		Parent = scroll,
	})
	local recRow: ScrollingFrame = make("ScrollingFrame", {
		Name = "Recommended",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 4,
		Visible = false,
		Size = UDim2.new(1, 0, 0, REC_H),
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ScrollBarThickness = 0,
		Parent = scroll,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.S),
		}),
	})

	local descHeader = label({
		Name = "DescriptionHeader",
		Text = "Description",
		FontFace = Tokens.Font.Bold,
		LayoutOrder = 5,
		Parent = scroll,
	})
	local desc = label({
		Name = "Description",
		TextColor3 = Tokens.Color.TextMuted,
		LayoutOrder = 6,
		Parent = scroll,
	})

	local partsHeader = label({
		Name = "PartsHeader",
		Text = "Included Items",
		FontFace = Tokens.Font.Bold,
		LayoutOrder = 7,
		Parent = scroll,
	})
	local partsLayout: UIGridLayout = make("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		CellPadding = UDim2.fromOffset(Tokens.Space.S, Tokens.Space.S),
		CellSize = UDim2.fromOffset(PART_MIN, PART_MIN + PART_TEXT),
	})
	local parts: Frame = make("Frame", {
		Name = "Parts",
		BackgroundTransparency = 1,
		LayoutOrder = 8,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Parent = scroll,
	}, { partsLayout })

	local conns: { RBXScriptConnection } = {}
	local self: ItemDetailPanel = setmetatable({
		instance = root,
		_props = props,
		_title = title,
		_scroll = scroll,
		_status = status,
		_retry = retry,
		_statusRow = statusRow,
		_top = top,
		_thumb = thumb,
		_name = name,
		_creator = creator,
		_stock = stock,
		_recHeader = recHeader,
		_recRow = recRow,
		_recTiles = {},
		_recKey = nil,
		_type = typeLabel,
		_price = price,
		_favorites = favorites,
		_toggle = toggle,
		_buy = buy,
		_cart = cart,
		_actions = actions,
		_descHeader = descHeader,
		_desc = desc,
		_partsHeader = partsHeader,
		_parts = parts,
		_partsLayout = partsLayout,
		_tiles = {},
		_tilesKey = nil,
		_detail = nil,
		_conns = conns,
		_unsubscribe = function() end,
	}, ItemDetailPanel)

	table.insert(
		conns,
		back.Activated:Connect(function()
			if props.onBack then
				props.onBack()
			else
				ctl:close()
			end
		end)
	)
	table.insert(
		conns,
		creator.Activated:Connect(function()
			local d = self._detail
			if d and props.onCreator then
				props.onCreator(d)
			end
		end)
	)
	table.insert(
		conns,
		creator.MouseEnter:Connect(function()
			if props.onCreator then
				creator.TextColor3 = Tokens.Color.Accent
			end
		end)
	)
	table.insert(
		conns,
		creator.MouseLeave:Connect(function()
			creator.TextColor3 = Tokens.Color.TextMuted
		end)
	)
	table.insert(
		conns,
		retry.Activated:Connect(function()
			task.spawn(ctl.retry, ctl) -- remote -> yield
		end)
	)
	table.insert(
		conns,
		toggle.Activated:Connect(function()
			local d = self._detail
			if d then
				props.onToggle(d)
			end
		end)
	)
	table.insert(
		conns,
		buy.Activated:Connect(function()
			local d = self._detail
			if d and d.isForSale and props.onBuy then
				props.onBuy(d)
			end
		end)
	)

	table.insert(
		conns,
		cart.Activated:Connect(function()
			local d = self._detail
			if d and props.onCart and ItemDetailPanel.canCart(d) then
				props.onCart(d)
				self:refreshCart()
			end
		end)
	)

	-- Ukuran thumbnail & kolom part mengikuti lebar panel
	local function applyLayout()
		local w = scroll.AbsoluteSize.X - Tokens.Space.S
		if w <= 0 then
			return
		end
		local t = math.clamp(math.floor(w * 0.38), 96, 180)
		top.Size = UDim2.new(1, 0, 0, t)
		thumb.Size = UDim2.fromOffset(t, t)
		info.Position = UDim2.fromOffset(t + Tokens.Space.M, 0)
		info.Size = UDim2.new(1, -(t + Tokens.Space.M), 0, 0)

		local gap = Tokens.Space.S
		local cols = math.max(3, math.floor((w + gap) / (PART_MIN + gap)))
		local cell = math.floor((w - gap * (cols - 1)) / cols)
		partsLayout.CellSize = UDim2.fromOffset(cell, cell + PART_TEXT)
	end
	applyLayout()
	table.insert(conns, scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout))

	self._unsubscribe = ctl:onChanged(function(state)
		self:_render(state)
	end)
	self:_render(ctl:getState())
	return self
end

function ItemDetailPanel._clearTiles(self: ItemDetailPanel)
	for _, tile in self._tiles do
		if tile.conn then
			tile.conn:Disconnect()
		end
		tile.button:Destroy()
	end
	table.clear(self._tiles)
	self._tilesKey = nil
end

function ItemDetailPanel._buildTiles(self: ItemDetailPanel, d: any)
	local key = d.itemType .. ":" .. tostring(d.id)
	if self._tilesKey == key then
		return
	end
	self:_clearTiles()
	self._tilesKey = key
	for i, part in (d.parts or {}) :: { any } do
		local b: ImageButton = make("ImageButton", {
			Name = "Part_" .. tostring(part.assetId),
			AutoButtonColor = true,
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BackgroundTransparency = Tokens.Transparency.PanelRaised,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Parent = self._parts,
		}, { corner(Tokens.Radius.Medium) })
		local stroke: UIStroke = make("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Tokens.Color.Stroke,
			Transparency = Tokens.Transparency.Stroke,
			Thickness = 1,
			Parent = b,
		})
		make("ImageLabel", {
			Name = "Thumbnail",
			BackgroundTransparency = 1,
			Image = thumbnail("Asset", part.assetId, 150),
			ScaleType = Enum.ScaleType.Fit,
			Position = UDim2.fromOffset(Tokens.Space.XS, Tokens.Space.XS),
			Size = UDim2.new(1, -Tokens.Space.XS * 2, 1, -PART_TEXT - Tokens.Space.XS),
			Parent = b,
		})
		label({
			Name = "PartName",
			Text = if type(part.name) == "string" and part.name ~= "" then part.name else "Part",
			TextSize = Tokens.TextSize.Caption,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			AutomaticSize = Enum.AutomaticSize.None,
			Position = UDim2.new(0, Tokens.Space.XS, 1, -PART_TEXT),
			Size = UDim2.new(1, -Tokens.Space.XS * 2, 0, PART_TEXT),
			Parent = b,
		})
		local tile: Tile = { button = b, stroke = stroke, part = part, conn = nil }
		tile.conn = b.Activated:Connect(function()
			local current = self._detail
			if current then
				self._props.onPartActivated(tile.part, current)
			end
		end)
		table.insert(self._tiles, tile)
	end
end

function ItemDetailPanel._clearRecs(self: ItemDetailPanel)
	for _, tile in self._recTiles do
		if tile.conn then
			tile.conn:Disconnect()
		end
		tile.button:Destroy()
	end
	table.clear(self._recTiles)
	self._recKey = nil
end

-- Kartu Recommended memakai DTO yang sama dengan kartu katalog (id/itemType/name/price).
function ItemDetailPanel._buildRecs(self: ItemDetailPanel, key: string, items: { any })
	if self._recKey == key then
		return
	end
	self:_clearRecs()
	self._recKey = key
	for i, item in items do
		local kind = if item.itemType == "Bundle" then "BundleThumbnail" else "Asset"
		local b: ImageButton = make("ImageButton", {
			Name = "Rec_" .. tostring(item.id),
			AutoButtonColor = true,
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BackgroundTransparency = Tokens.Transparency.PanelRaised,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Size = UDim2.fromOffset(REC_W, REC_H),
			Parent = self._recRow,
		}, { corner(Tokens.Radius.Medium) })
		make("ImageLabel", {
			Name = "Thumbnail",
			BackgroundTransparency = 1,
			Image = thumbnail(kind, item.id, 150),
			ScaleType = Enum.ScaleType.Fit,
			Position = UDim2.fromOffset(Tokens.Space.XS, Tokens.Space.XS),
			Size = UDim2.new(1, -Tokens.Space.XS * 2, 1, -REC_TEXT - Tokens.Space.XS),
			Parent = b,
		})
		label({
			Name = "RecName",
			Text = if type(item.name) == "string" and item.name ~= "" then item.name else "Item",
			TextSize = Tokens.TextSize.Caption,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Center,
			AutomaticSize = Enum.AutomaticSize.None,
			Position = UDim2.new(0, Tokens.Space.XS, 1, -REC_TEXT),
			Size = UDim2.new(1, -Tokens.Space.XS * 2, 0, REC_TEXT / 2),
			Parent = b,
		})
		local price = item.resalePrice or item.price
		label({
			Name = "RecPrice",
			Text = if price == nil then "Off Sale" elseif price <= 0 then "Free" else ROBUX .. " " .. tostring(price),
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = if price == nil then Tokens.Color.TextMuted else Tokens.Color.Robux,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Center,
			AutomaticSize = Enum.AutomaticSize.None,
			Position = UDim2.new(0, Tokens.Space.XS, 1, -REC_TEXT / 2),
			Size = UDim2.new(1, -Tokens.Space.XS * 2, 0, REC_TEXT / 2),
			Parent = b,
		})
		local tile: RecTile = { button = b, conn = nil }
		tile.conn = b.Activated:Connect(function()
			if self._props.onRecommended then
				self._props.onRecommended(item)
			end
		end)
		table.insert(self._recTiles, tile)
	end
end

-- Teks stok item limited. units = 0 berarti habis terjual (spike 19 Sep 2026), bukan "tidak ada data".
local function stockText(d: any): string
	if not d.isLimited or type(d.unitsLeft) ~= "number" then
		return ""
	end
	if d.unitsLeft <= 0 then
		return if type(d.totalQuantity) == "number"
			then ("Sold out - %s made"):format(shortNumber(d.totalQuantity))
			else "Sold out"
	end
	if type(d.totalQuantity) == "number" then
		return ("%s of %s left"):format(shortNumber(d.unitsLeft), shortNumber(d.totalQuantity))
	end
	return ("%s left"):format(shortNumber(d.unitsLeft))
end

function ItemDetailPanel._render(self: ItemDetailPanel, state: any)
	self.instance.Visible = state.isOpen == true
	if not state.isOpen then
		self._detail = nil
		self:_clearTiles()
		return
	end

	local d = state.detail
	local changed = d ~= self._detail
	self._detail = d

	-- status
	local err = state.error
	self._statusRow.Visible = state.loading or err ~= nil
	self._status.Text = if state.loading then "Loading…" elseif err then (ERROR_TEXT[err] or ERROR_TEXT.FAILED) else ""
	self._retry.Visible = err ~= nil and err ~= "NOT_FOUND" and err ~= "BAD_ARG"

	-- thumbnail tetap tampil saat memuat (id sudah diketahui)
	if state.id then
		local kind = if state.itemType == "Bundle" then "BundleThumbnail" else "Asset"
		self._thumb.Image = thumbnail(kind, state.id, THUMB_SIZE)
	end
	self._top.Visible = true

	local has = d ~= nil
	self._name.Text = if has then d.name else ""
	self._actions.Visible = has
	self._descHeader.Visible = has
	self._desc.Visible = has
	if not has then
		self._title.Text = if state.itemType == "Bundle" then "Bundle Details" else "Item Details"
		self._creator.Text = ""
		self._stock.Text = ""
		self._recHeader.Visible = false
		self._recRow.Visible = false
		self:_clearRecs()
		self._type.Text = ""
		self._price.Text = ""
		self._favorites.Text = ""
		self._partsHeader.Visible = false
		self._parts.Visible = false
		self:_clearTiles()
		return
	end

	self._title.Text = if d.itemType == "Bundle" then "Bundle Details" else "Item Details"
	self._creator.Text = "By " .. d.creatorName .. (if d.creatorVerified then " " .. VERIFIED else "")
	self._type.Text = ItemDetail.typeLabel(d)
	local pText, pColor = priceText(d)
	self._price.Text = pText
	self._price.TextColor3 = pColor
	self._favorites.Text = if d.favoriteCount then "♥ " .. shortNumber(d.favoriteCount) else ""
	self._stock.Text = stockText(d)
	self._desc.Text = if d.description ~= "" then d.description else "No description."
	-- Buy: tidak dijual -> abu-abu & tidak bereaksi
	local forSale = d.isForSale == true
	self._buy.Text = if forSale then "Buy" else "Off Sale"
	self._buy.BackgroundColor3 = if forSale then Tokens.Color.Robux else Tokens.Color.PanelRaised
	self._buy.TextColor3 = if forSale then Tokens.Color.AccentText else Tokens.Color.TextMuted
	self._buy.AutoButtonColor = forSale
	self:refreshCart()

	local partCount = if type(d.parts) == "table" then #d.parts else 0
	self._partsHeader.Visible = partCount > 0
	self._parts.Visible = partCount > 0
	self._partsHeader.Text = ("Included Items (%d)"):format(partCount)
	if partCount > 0 then
		self:_buildTiles(d)
	else
		self:_clearTiles()
	end

	-- Baris Recommended menyusul sesudah detail; kosong / gagal -> barisnya disembunyikan saja.
	local recs = if type(state.recommended) == "table" then state.recommended else nil
	local hasRecs = recs ~= nil and #recs > 0
	self._recHeader.Visible = hasRecs
	self._recRow.Visible = hasRecs
	if hasRecs then
		self:_buildRecs(d.itemType .. ":" .. tostring(d.id), recs :: { any })
	else
		self:_clearRecs()
	end

	if changed then
		self._scroll.CanvasPosition = Vector2.zero
		self._recRow.CanvasPosition = Vector2.zero
	end
	self:refreshWorn()
end

-- Outfit berubah -> teks tombol Try On/Remove & sorotan part yang sedang dipakai.
function ItemDetailPanel.refreshWorn(self: ItemDetailPanel)
	local d = self._detail
	if d == nil then
		return
	end
	local worn = self._props.isWorn(d)
	self._toggle.Visible = AssetTypeMap.isWearable(d.assetType)
	-- Latar bukan barang yang dipakai avatar -> "Use", bukan "Try On".
	local isBackground = AssetTypeMap.Background[d.assetType] == true
	self._toggle.Text = if worn then "Remove" elseif isBackground then "Use" else "Try On"
	self._toggle.BackgroundColor3 = if worn then Tokens.Color.Danger else Tokens.Color.Accent
	for _, tile in self._tiles do
		local on = self._props.isPartWorn(tile.part.assetId)
		tile.stroke.Color = if on then Tokens.Color.Accent else Tokens.Color.Stroke
		tile.stroke.Transparency = if on then 0.2 else Tokens.Transparency.Stroke
		tile.stroke.Thickness = if on then 2 else 1
	end
end

-- Bisa masuk keranjang: dijual dengan harga normal (resale/limited tanpa harga -> tidak).
function ItemDetailPanel.canCart(d: any): boolean
	return d.isForSale == true and type(d.price) == "number"
end

-- Keranjang berubah -> tampilan tombol 🛒 (🛒+ tambah, 🛒✓ sudah di keranjang, abu-abu = tidak bisa).
function ItemDetailPanel.refreshCart(self: ItemDetailPanel)
	local d = self._detail
	if d == nil then
		return
	end
	local can = ItemDetailPanel.canCart(d)
	local isIn = self._props.isInCart ~= nil and (self._props.isInCart :: any)(d) == true
	local cart = self._cart
	local color = if not can then Tokens.Color.TextMuted elseif isIn then Tokens.Color.Accent else Tokens.Color.Text
	CartIcon.apply(cart, if isIn then "check" else "add", color)
	cart.AutoButtonColor = can
end

function ItemDetailPanel.isOpen(self: ItemDetailPanel): boolean
	return self.instance.Visible
end

function ItemDetailPanel.destroy(self: ItemDetailPanel)
	self._unsubscribe()
	self:_clearTiles()
	self:_clearRecs()
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return ItemDetailPanel
