--!strict
-- Kartu item katalog: thumbnail + nama + harga. Ukuran diatur UIGridLayout induknya.
--   local card = ItemCard.new({ item = item, onActivated = function(item) ... end })
--   card.instance.Parent = grid
--   card:setItem(itemLain)   card:setSelected(true)   card:destroy()

local Tokens = require(script.Parent.Parent.Theme.Tokens)

export type Item = {
	id: number,
	itemType: string, -- "Asset" | "Bundle"
	name: string,
	price: number?,
	assetType: string?,
	bundleType: string?,
	creatorName: string?,
}

export type Props = {
	item: Item,
	layoutOrder: number?,
	onActivated: ((Item) -> ())?,
}

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
		_conn: RBXScriptConnection,
	},
	ItemCard
))

local function thumbnail(item: Item): string
	local size = Tokens.Size.Thumbnail
	local kind = if item.itemType == "Bundle" then "BundleThumbnail" else "Asset"
	return ("rbxthumb://type=%s&id=%d&w=%d&h=%d"):format(kind, item.id, size, size)
end

local function priceText(price: number?): string
	if price == nil then
		return "Off Sale"
	elseif price <= 0 then
		return "Free"
	end
	return "R$ " .. tostring(price)
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
	image.Size = UDim2.new(1, -pad * 2, 1, -pad * 2 - 34)
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

	local self = setmetatable({
		instance = button,
		item = props.item,
		_image = image,
		_name = name,
		_price = price,
		_stroke = stroke,
		_conn = (nil :: any) :: RBXScriptConnection,
	}, ItemCard)

	local onActivated = props.onActivated
	self._conn = button.Activated:Connect(function()
		if onActivated then
			onActivated(self.item)
		end
	end)

	self:setItem(props.item)
	return self
end

function ItemCard.setItem(self: ItemCard, item: Item)
	self.item = item
	self.instance.Name = "ItemCard_" .. tostring(item.id)
	self._image.Image = thumbnail(item)
	self._name.Text = item.name
	self._price.Text = priceText(item.price)
	self._price.TextColor3 = if item.price and item.price > 0 then Tokens.Color.Robux else Tokens.Color.TextMuted
end

function ItemCard.setSelected(self: ItemCard, selected: boolean)
	self._stroke.Color = if selected then Tokens.Color.Accent else Tokens.Color.Stroke
	self._stroke.Transparency = if selected then 0 else Tokens.Transparency.Stroke
	self._stroke.Thickness = if selected then 2 else 1
end

function ItemCard.destroy(self: ItemCard)
	self._conn:Disconnect()
	self.instance:Destroy()
end

return ItemCard
