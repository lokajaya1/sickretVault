--!strict
-- Panel review sebelum Save to Roblox (pola CAC "Owned Items / Unowned Items"):
--   local review = SaveReviewPanel.new({
--   	parent = gui, zIndex = Tokens.ZIndex.Popup + 5, previews = previews,
--   	onBuy = function(item) ... end,       -- tap kartu yang belum dimiliki -> prompt beli
--   	onBuyAll = function(items) ... end,   -- ubin "Buy all" (maks MAX_BULK item)
--   	onSave = function(kind) ... end,      -- tombol simpan
--   })
--   review:open("outfit", items)   review:setOwnership(unowned, details, bundleDetails)
--   review:close()   review:isOpen()   review:destroy()
-- `items` = daftar WornItems.Item (id, name, price, source); `details` = { [id] = { name, price } }
-- dari server, dipakai menimpa nama/harga karena item yang sedang dipakai sering tidak pernah
-- lewat katalog di client (mis. hasil restore saat join) -> tanpa ini semua kartu tertulis "N/A".
--
-- Tata letak mengikuti screenshot CAC: DUA kolom berdampingan (dimiliki kiri, belum dimiliki
-- kanan) dengan avatar di tengah -- bukan tab. Pemain butuh melihat keduanya sekaligus untuk
-- memutuskan, dan angka di kepala kanan adalah TOTAL HARGA yang belum dimiliki, bukan jumlah item.
--
-- LATAR: panel ini TIDAK memakai selubung hitam. Roblox tidak bisa mem-blur UI di belakang sebuah
-- frame (tidak ada backdrop blur); yang bisa di-blur hanya dunia 3D lewat Lighting. Jadi saat
-- panel terbuka dunia di belakangnya diburamkan dengan BlurEffect, dan selubungnya dibuang --
-- panel sendiri yang pekat, jadi ia tetap terbaca tanpa menggelapkan seluruh layar.
--
-- Kenapa panel ini ada (diukur 19 Sep 2026, bukan dugaan): `PromptCreateOutfit` GAGAL kalau look
-- memuat item yang belum dimiliki, sedangkan `PromptSaveAvatar` menerimanya.
--
-- Selama kepemilikan belum datang, kartunya tampil dengan status "checking" -- BUKAN "owned":
-- menebak "dimiliki" lalu meralat akan terlihat seperti item pemain hilang.

local Lighting = game:GetService("Lighting")

local Tokens = require(script.Parent.Parent.Theme.Tokens)
-- Aturan HARGA (harga pasar limited menang, off-sale bukan "Free", sentinel dibuang) dipinjam
-- dari kartu katalog: dua salinan aturan harga pasti akan berbeda suatu hari.
local ItemCard = require(script.Parent.ItemCard)

export type Item = {
	id: number,
	name: string,
	price: number?,
	bundle: boolean?, -- kartu ini mewakili SATU bundle (part-partnya sudah digabung App)
}

export type Detail = { name: string?, price: number? }

export type Props = {
	parent: Instance,
	zIndex: number,
	previews: any?, -- OutfitPreview; nil = kolom tengah tanpa avatar
	onBuy: (item: Item) -> (),
	onBuyAll: (items: { Item }) -> (),
	onSave: (kind: string) -> (),
	onClose: (() -> ())?, -- panel ditutup (tombol X, tap di luar, atau sesudah simpan)
}

-- Dua set ukuran. Ambangnya PanelLayout.COMPACT_HEIGHT (500 px) -- sama dengan panel katalog,
-- jadi "layar pendek" berarti hal yang sama di seluruh UI. iPhone 13 mendatar = 390 px.
local METRICS = {
	normal = {
		card = Vector2.new(104, 124),
		image = 80,
		head = 36,
		foot = 52,
		column = 0.29, -- lebar tiap kolom kartu (sisanya untuk avatar di tengah)
		title = Tokens.TextSize.Title,
		save = Vector2.new(150, 34),
		panel = Vector2.new(780, 470),
		scale = Vector2.new(0.94, 0.86),
	},
	compact = {
		card = Vector2.new(78, 94),
		image = 58,
		head = 28,
		foot = 40,
		column = 0.31,
		title = Tokens.TextSize.Button,
		save = Vector2.new(124, 28),
		panel = Vector2.new(640, 340),
		scale = Vector2.new(0.97, 0.94),
	},
}
local LINE_H = 16
local BLUR_SIZE = 18 -- dunia di belakang panel; UI di belakang TIDAK bisa diburamkan
-- Batas PromptBulkPurchase (server: Cart.DEFAULT_MAX). Lebih dari ini ditolak server, jadi ubin
-- "buy all" jujur menyebut berapa yang ikut terbeli.
local MAX_BULK = 20
-- Ikon Robux bawaan font Roblox -- sama dengan kartu katalog (ItemCard), bukan tulisan "R$".
local ROBUX = utf8.char(0xE002)

local SaveReviewPanel = {}
SaveReviewPanel.__index = SaveReviewPanel

type Tile = { button: TextButton, conn: RBXScriptConnection? }

export type SaveReviewPanel = typeof(setmetatable(
	{} :: {
		instance: TextButton,
		_props: Props,
		_kind: string,
		_items: { Item },
		_details: { [number]: Detail },
		_bundleDetails: { [number]: Detail },
		_unowned: { [number]: boolean }?, -- nil = masih menunggu jawaban server
		_ownedTitle: TextLabel,
		_unownedTitle: TextLabel,
		_card: TextButton,
		_cardSize: UISizeConstraint,
		_head: Frame,
		_body: Frame,
		_middle: Frame,
		_metrics: any, -- METRICS.normal | METRICS.compact
		_compact: boolean,
		_ownedGrid: ScrollingFrame,
		_unownedGrid: ScrollingFrame,
		_note: TextLabel,
		_saveButton: TextButton,
		_message: TextLabel,
		_viewport: ViewportFrame,
		_handle: any?, -- pegangan OutfitPreview (dibuang saat close)
		_blur: BlurEffect?,
		_tiles: { Tile },
		_conns: { RBXScriptConnection },
	},
	SaveReviewPanel
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

local function thumbnail(id: number, bundle: boolean?): string
	local kind = if bundle then "BundleThumbnail" else "Asset"
	local size = Tokens.Size.Thumbnail
	return ("rbxthumb://type=%s&id=%d&w=%d&h=%d"):format(kind, id, size, size)
end

-- 1157 -> "1,157" (angka harga gampang salah baca tanpa pemisah).
local function grouped(n: number): string
	local out = tostring(math.floor(n))
	while true do
		local swapped: string, count: number = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		out = swapped
		if count == 0 then
			break
		end
	end
	return out
end

-- Item dianggap dimiliki lewat DIRINYA SENDIRI atau lewat bundle asalnya: part bundle tidak
-- punya baris kepemilikan sendiri (spike 19 Sep 2026 -> PlayerOwnsBundle).
local function isOwned(item: Item, unowned: { [number]: boolean }): boolean
	return not unowned[item.id]
end

local function newGrid(name: string, Z: number, parent: Instance): ScrollingFrame
	return make("ScrollingFrame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Tokens.Color.Stroke,
		ScrollBarImageTransparency = 0.4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = Z + 1,
		Parent = parent,
	}, {
		make("UIGridLayout", {
			CellPadding = UDim2.fromOffset(Tokens.Space.S, Tokens.Space.S),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
end

function SaveReviewPanel.new(props: Props): SaveReviewPanel
	local pad = Tokens.Space.L
	local Z = props.zIndex

	-- Tembus penuh: tidak ada selubung hitam (permintaan 19 Sep 2026). Tetap TextButton supaya
	-- klik di luar kartu menutup panel dan tidak tembus ke UI di bawahnya.
	local root: TextButton = make("TextButton", {
		Name = "SaveReview",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z,
		Parent = props.parent,
	})

	local cardSize: UISizeConstraint = make("UISizeConstraint", { MaxSize = METRICS.normal.panel })

	local card: TextButton = make("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Panel,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ZIndex = Z + 1,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Large }),
		cardSize,
		make("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Tokens.Color.Stroke,
			Transparency = 0.6,
		}),
		make("UIPadding", {
			PaddingTop = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, pad),
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
		}),
	})

	-- Kepala: judul kiri, judul + total harga kanan, tombol tutup.
	local head: Frame = make("Frame", {
		Name = "Head",
		BackgroundTransparency = 1,
		ZIndex = Z + 1,
		Parent = card,
	})
	local ownedTitle: TextLabel = make("TextLabel", {
		Name = "OwnedTitle",
		Text = "Owned",
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0.4, 0, 1, 0),
		ZIndex = Z + 2,
		Parent = head,
	})
	local unownedTitle: TextLabel = make("TextLabel", {
		Name = "UnownedTitle",
		Text = "Unowned",
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(Tokens.Space.XL + Tokens.Space.S), 0, 0),
		Size = UDim2.new(0.55, 0, 1, 0),
		ZIndex = Z + 2,
		Parent = head,
	})
	local closeButton: TextButton = make("TextButton", {
		Name = "Close",
		Text = "X",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Button,
		TextColor3 = Tokens.Color.Text,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		AutoButtonColor = true,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(28, 28),
		ZIndex = Z + 2,
		Parent = head,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	-- Badan: grid dimiliki | avatar | grid belum dimiliki.
	local body: Frame = make("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		ZIndex = Z + 1,
		Parent = card,
	})

	local ownedGrid = newGrid("OwnedGrid", Z, body)
	local unownedGrid = newGrid("UnownedGrid", Z, body)

	local middle: Frame = make("Frame", {
		Name = "Middle",
		BackgroundTransparency = 1,
		ZIndex = Z + 1,
		Parent = body,
	})

	local viewport: ViewportFrame = make("ViewportFrame", {
		Name = "Avatar",
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		Ambient = Color3.fromRGB(120, 120, 134),
		-- Lampu berarah menggambar garis putih di tepi avatar (temuan #28 no. 8) -> dinolkan.
		LightColor = Color3.fromRGB(0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, -Tokens.Space.M, 1, -26),
		ZIndex = Z + 1,
		Parent = middle,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Medium }) })

	local message: TextLabel = make("TextLabel", {
		Name = "Message",
		Text = "",
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Medium,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.TextMuted,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 22),
		ZIndex = Z + 2,
		Parent = middle,
	})

	-- Kaki: keterangan + tombol simpan.
	local note: TextLabel = make("TextLabel", {
		Name = "Note",
		Text = "",
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		ZIndex = Z + 1,
		Parent = card,
	})

	local saveButton: TextButton = make("TextButton", {
		Name = "Save",
		Text = "Save to Roblox",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Accent,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		ZIndex = Z + 2,
		Parent = card,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	local self: SaveReviewPanel = setmetatable({
		instance = root,
		_props = props,
		_kind = "avatar",
		_items = {},
		_details = {},
		_bundleDetails = {},
		_unowned = nil,
		_ownedTitle = ownedTitle,
		_unownedTitle = unownedTitle,
		_card = card,
		_cardSize = cardSize,
		_head = head,
		_body = body,
		_middle = middle,
		_metrics = METRICS.normal,
		_compact = false,
		_ownedGrid = ownedGrid,
		_unownedGrid = unownedGrid,
		_note = note,
		_saveButton = saveButton,
		_message = message,
		_viewport = viewport,
		_handle = nil,
		_blur = nil,
		_tiles = {},
		_conns = {},
	}, SaveReviewPanel)

	self:setCompact(false)

	self._conns = {
		root.Activated:Connect(function()
			self:close()
		end),
		closeButton.Activated:Connect(function()
			self:close()
		end),
		saveButton.Activated:Connect(function()
			local kind = self._kind
			self:close()
			props.onSave(kind)
		end),
	}
	return self
end

-- Layar pendek (ponsel mendatar) memakai kartu & kepala yang lebih kecil. Ambangnya sama dengan
-- panel katalog (PanelLayout.COMPACT_HEIGHT), jadi seluruh UI berganti bentuk pada titik yang sama.
function SaveReviewPanel.setCompact(self: SaveReviewPanel, compact: boolean)
	local m = if compact then METRICS.compact else METRICS.normal
	self._metrics = m
	self._compact = compact

	self._cardSize.MaxSize = m.panel
	self._card.Size = UDim2.fromScale(m.scale.X, m.scale.Y)
	local pad = if compact then Tokens.Space.M else Tokens.Space.L
	local padding = self._card:FindFirstChildOfClass("UIPadding")
	if padding then
		padding.PaddingTop = UDim.new(0, pad)
		padding.PaddingBottom = UDim.new(0, pad)
		padding.PaddingLeft = UDim.new(0, pad)
		padding.PaddingRight = UDim.new(0, pad)
	end

	self._head.Size = UDim2.new(1, 0, 0, m.head)
	self._ownedTitle.TextSize = m.title
	self._unownedTitle.TextSize = m.title

	local gap = Tokens.Space.S
	self._body.Position = UDim2.fromOffset(0, m.head + gap)
	self._body.Size = UDim2.new(1, 0, 1, -(m.head + m.foot + gap * 2))

	for _, grid in { self._ownedGrid, self._unownedGrid } do
		grid.Size = UDim2.new(m.column, 0, 1, 0)
		local layout = grid:FindFirstChildOfClass("UIGridLayout")
		if layout then
			layout.CellSize = UDim2.fromOffset(m.card.X, m.card.Y)
		end
	end
	self._ownedGrid.Position = UDim2.fromScale(0, 0)
	self._unownedGrid.Position = UDim2.fromScale(1 - m.column, 0)
	self._middle.Position = UDim2.fromScale(m.column, 0)
	self._middle.Size = UDim2.new(1 - m.column * 2, 0, 1, 0)

	self._note.Size = UDim2.new(1, -(m.save.X + Tokens.Space.XL), 0, m.foot - gap)
	self._saveButton.Size = UDim2.fromOffset(m.save.X, m.save.Y)
	self:_refresh()
end

-- Nama & harga: jawaban server menang atas tebakan client (nama slot seperti "Shirt").
function SaveReviewPanel._labels(self: SaveReviewPanel, item: Item): (string, any)
	local detail = if item.bundle then self._bundleDetails[item.id] else self._details[item.id]
	local name = item.name
	if detail and type(detail.name) == "string" and detail.name ~= "" then
		name = detail.name
	end
	-- Yang dipakai menghitung & menggambar harga adalah DETAIL dari server (punya resalePrice,
	-- limited, offSale); tebakan client dipakai hanya sampai jawaban itu datang.
	local info = detail or { price = item.price }
	return name, info
end

-- Harga EFEKTIF untuk dijumlahkan di kepala: item limited dibayar di harga pasarnya.
local function effectivePrice(info: any): number?
	if type(info) ~= "table" then
		return nil
	end
	if type(info.resalePrice) == "number" and info.resalePrice > 0 then
		return info.resalePrice
	end
	if info.offSale then
		return nil
	end
	if type(info.price) == "number" and info.price > 0 then
		return info.price
	end
	return nil
end

-- Satu kartu item: gambar (+ harga di sudutnya), nama, status.
function SaveReviewPanel._tile(self: SaveReviewPanel, item: Item, order: number, owned: boolean?)
	local Z = self._props.zIndex
	local m = self._metrics
	local imageH = m.image
	local grid = if owned == false then self._unownedGrid else self._ownedGrid
	local name, info = self:_labels(item)

	local button: TextButton = make("TextButton", {
		Name = tostring(item.id),
		Text = "",
		LayoutOrder = order,
		AutoButtonColor = owned == false,
		BackgroundTransparency = 1,
		ZIndex = Z + 2,
		Parent = grid,
	}, {
		make("ImageLabel", {
			Name = "Thumb",
			Image = thumbnail(item.id, item.bundle),
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BackgroundTransparency = Tokens.Transparency.PanelRaised,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, imageH),
			ZIndex = Z + 3,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Medium }) }),
		make("TextLabel", {
			Name = "ItemName",
			Text = name,
			BackgroundTransparency = 1,
			FontFace = Tokens.Font.Medium,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.Text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(0, imageH + Tokens.Space.XS),
			Size = UDim2.new(1, 0, 0, LINE_H),
			ZIndex = Z + 3,
		}),
		make("TextLabel", {
			Name = "Status",
			Text = if owned == nil then "checking..." elseif owned then "Owned" else "Not owned",
			BackgroundTransparency = 1,
			FontFace = Tokens.Font.Bold,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = if owned == false then Tokens.Color.Danger else Tokens.Color.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(0, imageH + Tokens.Space.XS + LINE_H),
			Size = UDim2.new(1, 0, 0, LINE_H),
			ZIndex = Z + 3,
		}),
	})

	-- Harga & warnanya memakai aturan kartu katalog: "Off Sale", "No Sellers", harga pasar limited.
	-- Kartu tanpa harga sama sekali dibiarkan polos daripada penuh tulisan "N/A".
	local priceText, priceColor = ItemCard.priceOf(info)
	if priceText ~= "Not for sale" then
		make("TextLabel", {
			Name = "Price",
			Text = priceText,
			BackgroundColor3 = Tokens.Color.Background,
			BackgroundTransparency = 0.2,
			FontFace = Tokens.Font.Bold,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = priceColor,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 0, imageH),
			Size = UDim2.new(1, 0, 0, LINE_H + 2),
			ZIndex = Z + 4,
			Parent = button,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })
	end

	-- Sambungan tap disimpan PER KARTU dan diputus saat grid digambar ulang: kartunya dibuang
	-- tiap refresh, jadi menumpuknya di daftar panel akan tumbuh terus selama panel hidup.
	local conn: RBXScriptConnection? = nil
	if owned == false then
		conn = button.Activated:Connect(function()
			self._props.onBuy(item)
		end)
	end
	table.insert(self._tiles, { button = button, conn = conn })
end

-- Ubin "Buy all": kartu pertama di kolom kanan (pola CAC).
function SaveReviewPanel._buyAllTile(self: SaveReviewPanel, items: { Item })
	local Z = self._props.zIndex
	local capped = #items > MAX_BULK
	local button: TextButton = make("TextButton", {
		Name = "BuyAll",
		Text = "Buy all",
		LayoutOrder = 0,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Button,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Accent,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		ZIndex = Z + 2,
		Parent = self._unownedGrid,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Medium }),
		make("UIPadding", { PaddingBottom = UDim.new(0, LINE_H) }),
		make("TextLabel", {
			Name = "Hint",
			-- Batas 20 item itu milik PromptBulkPurchase, bukan pilihan kita -> disebut apa adanya.
			Text = if capped then ("first %d items"):format(MAX_BULK) else ("%d items"):format(#items),
			BackgroundTransparency = 1,
			FontFace = Tokens.Font.Regular,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.AccentText,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, LINE_H),
			Size = UDim2.new(1, 0, 0, LINE_H),
			ZIndex = Z + 3,
		}),
	})

	local list = items
	if capped then
		list = table.move(items, 1, MAX_BULK, 1, {})
	end
	local conn = button.Activated:Connect(function()
		self._props.onBuyAll(list)
	end)
	table.insert(self._tiles, { button = button, conn = conn })
end

-- Gambar ulang kedua grid + teks kepala/kaki sesuai keadaan sekarang.
function SaveReviewPanel._refresh(self: SaveReviewPanel)
	for _, tile in self._tiles do
		if tile.conn then
			tile.conn:Disconnect()
		end
		tile.button:Destroy()
	end
	table.clear(self._tiles)

	local unowned = self._unowned
	local ownedCount, total, priced = 0, 0, 0
	local missing: { Item } = {}
	local order = 0
	for _, item in self._items do
		local owned: boolean? = if unowned == nil then nil else isOwned(item, unowned)
		order += 1
		self:_tile(item, order, owned)
		if owned == true then
			ownedCount += 1
		elseif owned == false then
			table.insert(missing, item)
			local _, info = self:_labels(item)
			local price = effectivePrice(info)
			if price ~= nil then
				total += price
				priced += 1
			end
		end
	end
	if #missing > 0 then
		self:_buyAllTile(missing)
	end

	if unowned == nil then
		self._unownedTitle.Text = "Unowned"
		self._message.Text = "Checking what you own..."
		self._note.Text = "Checking which items are already yours."
		self._saveButton.Visible = false
		return
	end

	-- Angka di kepala = TOTAL HARGA. Kalau harga sebagian item tidak diketahui, angkanya diberi
	-- "+"; kalau tidak ada satu pun yang diketahui, jumlah itemlah yang ditampilkan -- lebih jujur
	-- daripada menulis "0 R$" untuk barang yang jelas tidak gratis.
	if #missing == 0 then
		self._unownedTitle.Text = "Unowned (0)"
		self._message.Text = "You own everything you're wearing."
		self._note.Text = "All of it will be saved to Roblox."
	else
		local label
		if priced == 0 then
			label = ("%d items"):format(#missing)
		elseif priced < #missing then
			label = ("%s %s+"):format(ROBUX, grouped(total))
		else
			label = ("%s %s"):format(ROBUX, grouped(total))
		end
		self._unownedTitle.Text = ("Unowned (%s)"):format(label)
		self._message.Text = ("%d of %d items missing"):format(#missing, #self._items)
		-- Ini BUKAN basa-basi: PromptCreateOutfit menolak look dengan item tak dimiliki, jadi
		-- item itu memang dilepas dulu sebelum disimpan.
		self._note.Text = "Unowned items won't be saved to Roblox. Tap one to buy it."
	end
	self._saveButton.Text = if self._kind == "outfit" then "Save as new outfit" else "Save to my avatar"
	self._saveButton.Visible = ownedCount > 0
end

-- Dunia di belakang panel diburamkan. UI di belakang TIDAK bisa diburamkan di Roblox (tidak ada
-- backdrop blur untuk GuiObject), jadi ini sejauh yang bisa dilakukan tanpa selubung hitam.
function SaveReviewPanel._setBlur(self: SaveReviewPanel, on: boolean)
	if on then
		if self._blur == nil then
			local blur = Instance.new("BlurEffect")
			blur.Name = "SaveReviewBlur"
			blur.Size = BLUR_SIZE
			blur.Parent = Lighting
			self._blur = blur
		end
		return
	end
	if self._blur ~= nil then
		self._blur:Destroy()
		self._blur = nil
	end
end

-- kind = "outfit" | "avatar"; items = daftar item yang sedang dipakai (WornItems).
function SaveReviewPanel.open(self: SaveReviewPanel, kind: string, items: { Item }, compact: boolean?)
	if compact ~= nil and compact ~= self._compact then
		self:setCompact(compact)
	end
	self._kind = kind
	self._items = items
	self._details = {}
	self._bundleDetails = {}
	self._unowned = nil
	self.instance.Visible = true
	self:_setBlur(true)
	self:_refresh()

	local previews = self._props.previews
	if previews ~= nil and self._handle == nil then
		local ok, handle = pcall(function()
			return previews:mountCurrent(self._viewport, {})
		end)
		self._handle = if ok then handle else nil
	end
end

-- Jawaban server: peta yang BELUM dimiliki + detail nama/harga item yang dipakai.
function SaveReviewPanel.setOwnership(
	self: SaveReviewPanel,
	unowned: { [number]: boolean },
	details: { [number]: Detail }?,
	bundleDetails: { [number]: Detail }?
)
	self._unowned = unowned
	self._details = details or {}
	self._bundleDetails = bundleDetails or {}
	self:_refresh()
end

-- Kepemilikan tidak bisa diambil. Panel tidak boleh menebak "semua dimiliki": ia berkata apa
-- adanya dan tetap mengizinkan simpan (Roblox sendiri yang akan menolak bila perlu).
function SaveReviewPanel.fail(self: SaveReviewPanel, code: string?)
	self._unowned = {}
	self:_refresh()
	self._message.Text = "Couldn't check what you own"
	self._note.Text = ("Saving anyway may drop items you don't own (%s)."):format(code or "FAILED")
end

function SaveReviewPanel.isOpen(self: SaveReviewPanel): boolean
	return self.instance.Visible
end

function SaveReviewPanel.close(self: SaveReviewPanel)
	if not self.instance.Visible then
		return
	end
	self.instance.Visible = false
	self:_setBlur(false)
	local onClose = self._props.onClose
	if onClose then
		onClose()
	end
	if self._handle ~= nil then
		pcall(function()
			self._handle.cancel()
		end)
		self._handle = nil
	end
end

function SaveReviewPanel.destroy(self: SaveReviewPanel)
	self:close()
	self:_setBlur(false)
	for _, tile in self._tiles do
		if tile.conn then
			tile.conn:Disconnect()
		end
	end
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	table.clear(self._tiles)
	self.instance:Destroy()
end

return SaveReviewPanel
