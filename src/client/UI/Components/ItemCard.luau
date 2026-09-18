--!strict
-- Kartu item katalog: thumbnail + nama + harga + pil "Worn" + pita "LIMITED". Ukuran dari UIGridLayout.
-- Harga mengikuti data katalog (spike 18 Sep 2026, tests/ItemPrice.studio):
--   resalePrice ada  -> harga pasar item limited (ada penjual ulang)
--   price 0          -> "Free"; price nil -> "Off Sale"
--   priceStatus "No Resellers" tanpa resale -> "No Sellers" (tidak bisa dibeli sekarang)
-- Tap kartu -> onActivated (CatalogPanel lalu memanggil setArmed(true)).
-- Kartu "armed" menampilkan overlay di atas gambar: TRY/REMOVE, BUY, tombol ⓘ (detail),
-- dan tombol keranjang 🛒 di kiri atas (bila props.onCart ada & item dijual).
-- Tap bagian kosong overlay -> onDismiss. Klik kanan (PC) / tahan (HP) di kartu -> onInfo (detail).
--   local card = ItemCard.new({ item = item, onActivated = fn, onTry = fn, onBuy = fn, onInfo = fn, onDismiss = fn })
--   card.instance.Parent = grid
--   card:setItem(itemLain)   card:setSelected(true)   card:setArmed(true)   card:setInCart(true)   card:destroy()

local AssetTypeMap = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Domain.AssetTypeMap)
local Tokens = require(script.Parent.Parent.Theme.Tokens)
local SecondaryAction = require(script.Parent.Parent.Util.SecondaryAction)
local CartIcon = require(script.Parent.Parent.Util.CartIcon)

export type Item = {
	id: number,
	itemType: string, -- "Asset" | "Bundle"
	name: string,
	price: number?, -- harga penerbit
	resalePrice: number?, -- harga pasar (limited dengan penjual ulang)
	limited: boolean?, -- pita "LIMITED"
	priceStatus: string?, -- mis. "Free", "No Resellers"
	unitsLeft: number?, -- sisa stok limited (dipakai halaman detail)
	assetType: string?,
	bundleType: string?,
	creatorName: string?,
}

type Callback = ((Item) -> ())?

export type Props = {
	item: Item,
	layoutOrder: number?,
	onActivated: Callback, -- tap kartu (belum armed)
	onTry: Callback,
	onBuy: Callback,
	onInfo: Callback,
	onCart: Callback, -- tombol 🛒 (tambah / buang dari keranjang); nil = tombol disembunyikan
	onDismiss: Callback, -- tap bagian kosong overlay
}

local TEXT_AREA = 34 -- nama + harga di bawah gambar
local INFO_SIZE = 26
local CART_W = 36

local ItemCard = {}
ItemCard.__index = ItemCard

export type ItemCard = typeof(setmetatable(
	{} :: {
		instance: ImageButton,
		item: Item,
		_image: ImageLabel,
		_name: TextLabel,
		_price: TextLabel,
		_stroke: UIStroke,
		_badge: TextLabel,
		_limited: TextLabel,
		_overlay: TextButton,
		_try: TextButton,
		_buy: TextButton,
		_cart: TextButton,
		_hasCart: boolean,
		_selected: boolean,
		_conns: { RBXScriptConnection },
	},
	ItemCard
))

local function thumbnail(item: Item): string
	local size = Tokens.Size.Thumbnail
	local kind = if item.itemType == "Bundle" then "BundleThumbnail" else "Asset"
	return ("rbxthumb://type=%s&id=%d&w=%d&h=%d"):format(kind, item.id, size, size)
end

local ROBUX = utf8.char(0xE002) -- ikon Robux bawaan font Roblox

-- Teks harga, warnanya, dan apakah tombol BUY aktif.
local function priceOf(item: Item): (string, Color3, boolean)
	if item.resalePrice then
		return ROBUX .. " " .. tostring(item.resalePrice), Tokens.Color.Accent, true -- harga pasar
	end
	if item.price == nil then
		return "Off Sale", Tokens.Color.TextMuted, false
	end
	if item.price <= 0 then
		if item.priceStatus == "No Resellers" then
			return "No Sellers", Tokens.Color.TextMuted, false -- limited habis, belum ada penjual ulang
		end
		return "Free", Tokens.Color.Text, true
	end
	return ROBUX .. " " .. tostring(item.price), Tokens.Color.Robux, true
end

local function label(name: string, parent: Instance, font: Font, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.FontFace = font
	l.TextSize = size
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = parent
	return l
end

-- Tombol besar di overlay (TRY / BUY): tinggi mengikuti ukuran kartu, teks menyesuaikan.
local function overlayButton(name: string, text: string, color: Color3, order: number, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = text
	b.FontFace = Tokens.Font.Bold
	b.TextScaled = true
	b.TextColor3 = Tokens.Color.AccentText
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.LayoutOrder = order
	b.Size = UDim2.new(1, 0, 0.36, 0)
	b.ZIndex = Tokens.ZIndex.Panel + 3

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Small
	corner.Parent = b

	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 10
	limit.MaxTextSize = Tokens.TextSize.Button
	limit.Parent = b

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = b

	b.Parent = parent
	return b
end

function ItemCard.new(props: Props): ItemCard
	local pad = Tokens.Space.S

	local button = Instance.new("ImageButton")
	button.Name = "ItemCard"
	button.AutoButtonColor = true
	button.BackgroundColor3 = Tokens.Color.PanelRaised
	button.BackgroundTransparency = Tokens.Transparency.PanelRaised
	button.BorderSizePixel = 0
	button.LayoutOrder = props.layoutOrder or 0
	button.ZIndex = Tokens.ZIndex.Panel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Medium
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Tokens.Color.Stroke
	stroke.Transparency = Tokens.Transparency.Stroke
	stroke.Thickness = 1
	stroke.Parent = button

	-- Gambar persegi di atas, lebar penuh dikurangi padding.
	local image = Instance.new("ImageLabel")
	image.Name = "Thumbnail"
	image.BackgroundTransparency = 1
	image.AnchorPoint = Vector2.new(0.5, 0)
	image.Position = UDim2.new(0.5, 0, 0, pad)
	image.Size = UDim2.new(1, -pad * 2, 1, -pad * 2 - TEXT_AREA)
	image.ScaleType = Enum.ScaleType.Fit
	image.ZIndex = Tokens.ZIndex.Panel
	image.Parent = button

	local name = label("ItemName", button, Tokens.Font.Medium, Tokens.TextSize.Caption, Tokens.Color.Text)
	name.Position = UDim2.new(0, pad, 1, -pad - 30)
	name.Size = UDim2.new(1, -pad * 2, 0, 15)
	name.ZIndex = Tokens.ZIndex.Panel

	local price = label("Price", button, Tokens.Font.Bold, Tokens.TextSize.Caption, Tokens.Color.Robux)
	price.Position = UDim2.new(0, pad, 1, -pad - 14)
	price.Size = UDim2.new(1, -pad * 2, 0, 14)
	price.ZIndex = Tokens.ZIndex.Panel

	-- Pita "LIMITED" (item terbatas / ada penjual ulang) di kiri bawah gambar.
	local limitedBand = Instance.new("TextLabel")
	limitedBand.Name = "LimitedBand"
	limitedBand.Text = "LIMITED"
	limitedBand.FontFace = Tokens.Font.Bold
	limitedBand.TextSize = 10
	limitedBand.TextColor3 = Tokens.Color.AccentText
	limitedBand.BackgroundColor3 = Tokens.Color.Accent
	limitedBand.BorderSizePixel = 0
	limitedBand.AutomaticSize = Enum.AutomaticSize.X
	limitedBand.AnchorPoint = Vector2.new(0, 1)
	limitedBand.Size = UDim2.fromOffset(0, 14)
	limitedBand.Position = UDim2.new(0, pad, 1, -pad - TEXT_AREA)
	limitedBand.ZIndex = Tokens.ZIndex.Panel + 1
	limitedBand.Visible = false
	limitedBand.Parent = button

	local limitedCorner = Instance.new("UICorner")
	limitedCorner.CornerRadius = Tokens.Radius.Small
	limitedCorner.Parent = limitedBand

	local limitedPad = Instance.new("UIPadding")
	limitedPad.PaddingLeft = UDim.new(0, Tokens.Space.XS + 1)
	limitedPad.PaddingRight = UDim.new(0, Tokens.Space.XS + 1)
	limitedPad.Parent = limitedBand

	-- Penanda "sedang dipakai": pil kecil di pojok kiri atas (bukan garis tepi penuh).
	local badge = Instance.new("TextLabel")
	badge.Name = "WornBadge"
	badge.Text = "Worn"
	badge.FontFace = Tokens.Font.Bold
	badge.TextSize = Tokens.TextSize.Caption
	badge.TextColor3 = Tokens.Color.AccentText
	badge.BackgroundColor3 = Tokens.Color.Accent
	badge.BorderSizePixel = 0
	badge.AutomaticSize = Enum.AutomaticSize.X
	badge.Size = UDim2.fromOffset(0, 18)
	badge.Position = UDim2.fromOffset(pad - 2, pad - 2)
	badge.ZIndex = Tokens.ZIndex.Panel + 1
	badge.Visible = false
	badge.Parent = button

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = Tokens.Radius.Pill
	badgeCorner.Parent = badge

	local badgePad = Instance.new("UIPadding")
	badgePad.PaddingLeft = UDim.new(0, Tokens.Space.S)
	badgePad.PaddingRight = UDim.new(0, Tokens.Space.S)
	badgePad.Parent = badge

	-- Overlay aksi (menutupi area gambar). TextButton kosong -> menahan tap ke kartu.
	local overlay = Instance.new("TextButton")
	overlay.Name = "Actions"
	overlay.Text = ""
	overlay.AutoButtonColor = false
	overlay.BackgroundColor3 = Tokens.Color.Background
	overlay.BackgroundTransparency = 0.5 -- gambar item tetap terlihat di balik tombol
	overlay.BorderSizePixel = 0
	overlay.Position = UDim2.fromOffset(0, 0)
	overlay.Size = UDim2.new(1, 0, 1, -TEXT_AREA)
	overlay.ZIndex = Tokens.ZIndex.Panel + 2
	overlay.Visible = false
	overlay.Parent = button

	local overlayCorner = Instance.new("UICorner")
	overlayCorner.CornerRadius = Tokens.Radius.Medium
	overlayCorner.Parent = overlay

	-- TRY / BUY ditumpuk di tengah, menyisakan ruang atas untuk tombol ⓘ.
	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.BackgroundTransparency = 1
	stack.AnchorPoint = Vector2.new(0.5, 1)
	stack.Position = UDim2.new(0.5, 0, 1, -pad)
	stack.Size = UDim2.new(1, -pad * 2, 1, -(INFO_SIZE + pad + 4))
	stack.ZIndex = Tokens.ZIndex.Panel + 2
	stack.Parent = overlay

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0.06, 0)
	list.Parent = stack

	local try = overlayButton("Try", "TRY", Tokens.Color.Accent, 1, stack)
	try.Visible = AssetTypeMap.isWearable(props.item.assetType)
	local buy = overlayButton("Buy", "BUY", Tokens.Color.Robux, 2, stack)

	local info = Instance.new("TextButton")
	info.Name = "Info"
	info.Text = "i"
	info.FontFace = Tokens.Font.Bold
	info.TextSize = Tokens.TextSize.Body
	info.TextColor3 = Tokens.Color.Text
	info.BackgroundColor3 = Tokens.Color.PanelRaised
	info.BorderSizePixel = 0
	info.AutoButtonColor = true
	info.AnchorPoint = Vector2.new(1, 0)
	info.Position = UDim2.new(1, -4, 0, 4)
	info.Size = UDim2.fromOffset(INFO_SIZE, INFO_SIZE)
	info.ZIndex = Tokens.ZIndex.Panel + 3
	info.Parent = overlay

	local infoCorner = Instance.new("UICorner")
	infoCorner.CornerRadius = Tokens.Radius.Pill
	infoCorner.Parent = info

	local infoStroke = Instance.new("UIStroke")
	infoStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	infoStroke.Color = Tokens.Color.Stroke
	infoStroke.Transparency = 0.5
	infoStroke.Parent = info

	-- Tombol keranjang (kiri atas overlay): ikon + = tambah, ikon ✓ biru = sudah di keranjang (tap -> buang)
	local cart = Instance.new("TextButton")
	cart.Name = "Cart"
	cart.Text = ""
	cart.FontFace = Tokens.Font.Bold
	cart.TextSize = Tokens.TextSize.Caption
	cart.TextColor3 = Tokens.Color.Text
	cart.BackgroundColor3 = Tokens.Color.PanelRaised
	cart.BorderSizePixel = 0
	cart.AutoButtonColor = true
	cart.Position = UDim2.fromOffset(4, 4)
	cart.Size = UDim2.fromOffset(CART_W, INFO_SIZE)
	cart.ZIndex = Tokens.ZIndex.Panel + 3
	cart.Visible = false
	cart.Parent = overlay

	local cartCorner = Instance.new("UICorner")
	cartCorner.CornerRadius = Tokens.Radius.Pill
	cartCorner.Parent = cart

	local cartStroke = Instance.new("UIStroke")
	cartStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	cartStroke.Color = Tokens.Color.Stroke
	cartStroke.Transparency = 0.5
	cartStroke.Parent = cart

	local self = setmetatable({
		instance = button,
		item = props.item,
		_image = image,
		_name = name,
		_price = price,
		_stroke = stroke,
		_badge = badge,
		_limited = limitedBand,
		_overlay = overlay,
		_try = try,
		_buy = buy,
		_cart = cart,
		_hasCart = props.onCart ~= nil,
		_selected = false,
		_conns = {},
	}, ItemCard)

	-- Klik kanan / tahan (kartu maupun overlay) -> detail
	local suppressors: { SecondaryAction.Suppressed } = {}
	for _, target in { button :: GuiButton, overlay } do
		local conns, suppressed = SecondaryAction.bind(target, function()
			if props.onInfo then
				props.onInfo(self.item)
			end
		end)
		for _, c in conns do
			table.insert(self._conns, c)
		end
		table.insert(suppressors, suppressed)
	end
	local function isSuppressed(): boolean
		for _, s in suppressors do
			if s() then
				return true
			end
		end
		return false
	end

	local function hook(b: GuiButton, fn: Callback, enabled: (() -> boolean)?)
		table.insert(
			self._conns,
			b.Activated:Connect(function()
				if isSuppressed() then
					return -- jari baru dilepas setelah long-press
				end
				if fn and (enabled == nil or enabled()) then
					fn(self.item)
				end
			end)
		)
	end
	hook(button, props.onActivated)
	hook(overlay, props.onDismiss)
	hook(try, props.onTry)
	hook(buy, props.onBuy, function()
		return self.item.price ~= nil
	end)
	hook(info, props.onInfo)
	hook(cart, props.onCart, function()
		return self.item.price ~= nil
	end)

	self:setItem(props.item)
	return self
end

function ItemCard.setItem(self: ItemCard, item: Item)
	self.item = item
	self.instance.Name = "ItemCard_" .. tostring(item.id)
	self._image.Image = thumbnail(item)
	self._name.Text = item.name
	local text, color, forSale = priceOf(item)
	self._price.Text = text
	self._price.TextColor3 = color
	self._limited.Visible = item.limited == true
	-- BUY: tidak dijual -> abu-abu & tidak bereaksi
	self._buy.Text = if forSale then "BUY" else "OFF SALE"
	self._buy.BackgroundColor3 = if forSale then Tokens.Color.Accent else Tokens.Color.PanelRaised
	self._buy.TextColor3 = if forSale then Tokens.Color.AccentText else Tokens.Color.TextMuted
	self._buy.AutoButtonColor = forSale
	self._try.Visible = AssetTypeMap.isWearable(item.assetType)
	self._cart.Visible = self._hasCart and forSale
	self:setInCart(false) -- pemanggil (CatalogPanel) mengatur ulang sesudah setItem
	self:setArmed(false) -- kartu dipakai ulang untuk item lain
end

function ItemCard.setSelected(self: ItemCard, selected: boolean)
	self._selected = selected
	self._badge.Visible = selected
	self._stroke.Color = if selected then Tokens.Color.Accent else Tokens.Color.Stroke
	self._stroke.Transparency = if selected then 0.4 else Tokens.Transparency.Stroke
	self._try.Text = if selected then "REMOVE" else "TRY"
	self._try.BackgroundColor3 = if selected then Tokens.Color.Danger else Tokens.Color.Accent
end

-- Tampilan tombol 🛒: sudah di keranjang -> ikon centang berwarna aksen.
function ItemCard.setInCart(self: ItemCard, inCart: boolean)
	CartIcon.apply(
		self._cart,
		if inCart then "check" else "add",
		if inCart then Tokens.Color.Accent else Tokens.Color.Text
	)
end

function ItemCard.setArmed(self: ItemCard, armed: boolean)
	self._overlay.Visible = armed
end

function ItemCard.isArmed(self: ItemCard): boolean
	return self._overlay.Visible
end

function ItemCard.destroy(self: ItemCard)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return ItemCard
