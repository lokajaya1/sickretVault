--!strict
-- Kartu item katalog: thumbnail + nama + harga + pil "Worn" + pita "LIMITED". Ukuran dari UIGridLayout.
-- AvatarBackground bukan barang yang menempel di avatar: pilnya "IN USE" dan tombolnya "USE",
-- supaya tidak terbaca seolah-olah latar itu dipakai seperti topi.
-- Harga mengikuti data katalog (spike 18 Sep 2026, tests/ItemPrice.studio):
--   resalePrice ada  -> harga pasar item limited (ada penjual ulang)
--   offSale true     -> "Off Sale" (harganya datang sebagai 0 — spike 19 Sep 2026 putaran 5b)
--   price 0          -> "Free"; price nil -> "Not for sale" (mis. bekas 999999999)
--   priceStatus "No Resellers" tanpa resale -> "No Sellers" (tidak bisa dibeli sekarang)
-- card:setDisplay({ name = false, price = false }) -- sakelar dari popover gear (#28). Nama &
-- harga yang dimatikan MENGEMBALIKAN ruangnya ke gambar: kartu jadi gambar penuh (mode padat CAC),
-- bukan gambar lama dengan area kosong di bawahnya.
-- Tap kartu -> onActivated (CatalogPanel lalu memanggil setArmed(true)).
-- Kartu "armed" menampilkan overlay di atas gambar: TRY/REMOVE, BUY, tombol ⓘ (detail),
-- bintang favorit (bila props.onFavorite ada), dan tombol keranjang 🛒 (bila props.onCart ada
-- & item dijual). Ketiga tombol bulat itu dihitung dalam PIKSEL dari lebar kartu: kartu compact
-- cuma ~76 px dan ukuran tetap tidak muat bertiga (UIAspectRatioConstraint TIDAK dipakai — di dalam
-- layout ia membuat lebar nol, temuan #25 no. 2).
-- Bintang punya TIGA tampilan, karena status favorit MAHAL dibaca (416 ms/item, kuota habis di ~26
-- bacaan -> HTTP 429; spike #28). Kartu tidak pernah menebak:
--   ☆ redup  = belum diketahui (belum pernah dibaca)
--   ☆ terang = bukan favorit
--   ★ emas   = favorit
-- Bintang menempel di KARTU (bukan di overlay) dan HANYA tampil saat kursor lewat: begitu overlay
-- dibuka ia disembunyikan supaya tidak menimpa tombol 🛒 / ⓘ (dinilai di Studio 19 Sep 2026).
-- Roblox mobile tidak punya kursor -> MouseEnter TIDAK PERNAH menyala di sana, jadi di HP bintang
-- kartu tidak bisa disentuh sama sekali; jalur favorit untuk HP adalah bintang di HALAMAN DETAIL
-- (tombol ⓘ / tahan kartu).
-- props.onHover(item, masuk) dipanggil saat kursor masuk/keluar kartu.
-- props.onPreview(item, viewport) -> fungsi pembatal: kursor DIAM di kartu selama HOVER_DELAY ->
-- thumbnail diganti avatar pemain yang memakai item itu. Jedanya WAJIB: spike 19 Sep 2026 mengukur
-- satu model butuh 425 ms (terlama 700 ms) dan engine TIDAK menyimpan cache, jadi kursor yang
-- menyapu 8 kartu tanpa jeda = 8 pembuatan model beruntun. Kursor pergi sebelum jeda habis ->
-- tidak ada yang dibangun sama sekali.
-- Thumbnail TETAP terlihat sampai avatarnya benar-benar muncul di viewport (ditunggu lewat
-- DescendantAdded). Dua alasan, dua-duanya kelihatan di Studio 19 Sep 2026: (a) item yang tidak
-- bisa dipreview (animasi, bundle Body) membuat onPreview mengembalikan nil -> kartu jadi HITAM
-- kalau thumbnail sudah kadung disembunyikan; (b) model butuh ~0,5 detik, dan selama itu kartunya
-- kosong. Item yang sekali gagal dipreview ditandai supaya hover berikutnya tidak mencoba lagi.
-- Tap bagian kosong overlay -> onDismiss. Klik kanan (PC) / tahan (HP) di kartu -> onInfo (detail).
--   local card = ItemCard.new({ item = item, onActivated = fn, onTry = fn, onBuy = fn, onInfo = fn, onDismiss = fn })
--   card.instance.Parent = grid
--   card:setItem(itemLain)   card:setSelected(true)   card:setArmed(true)   card:setInCart(true)   card:destroy()

local SharedRoot = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local AssetTypeMap = require(SharedRoot.Domain.AssetTypeMap)
local Log = require(SharedRoot.Util.Log)

local log = Log.new("ItemCard")
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
	offSale: boolean?, -- ditarik dari penjualan; `price` 0 di sini BUKAN "gratis"
	unitsLeft: number?, -- sisa stok limited (dipakai halaman detail)
	assetType: string?,
	bundleType: string?,
	creatorName: string?,
}

type Callback = ((Item) -> ())?

-- Sakelar tampilan kartu; field yang tidak diisi dianggap TRUE (tampil).
export type Display = { name: boolean?, price: boolean?, limited: boolean? }

export type Props = {
	item: Item,
	layoutOrder: number?,
	onActivated: Callback, -- tap kartu (belum armed)
	onTry: Callback,
	onBuy: Callback,
	onInfo: Callback,
	onCart: Callback, -- tombol 🛒 (tambah / buang dari keranjang); nil = tombol disembunyikan
	onFavorite: Callback, -- bintang favorit; nil = bintang disembunyikan
	onHover: ((Item, boolean) -> ())?, -- kursor masuk (true) / keluar (false) kartu; PC saja
	-- Pasang preview avatar memakai item ini ke viewport kartu; kembalikan fungsi pembatalnya.
	onPreview: ((Item, ViewportFrame) -> (() -> ())?)?,
	onDismiss: Callback, -- tap bagian kosong overlay
}

local TEXT_AREA = 34 -- nama + harga di bawah gambar
local INFO_SIZE = 26 -- ruang yang disisakan di atas stack TRY/BUY untuk baris tombol bulat
local CART_W = 36
local BTN_MIN = 14 -- kartu compact: tiga tombol bulat harus tetap muat
local BTN_MAX = 22 -- 19 Sep 2026: 26 px terlihat kegedean di kartu (dinilai di Studio)
local BTN_RATIO = 0.19 -- ukuran tombol = lebar kartu x ini, dijepit BTN_MIN..BTN_MAX
local LEAVE_GRACE = 0.2 -- detik: kursor yang keluar sebentar (melintas celah antar kartu) TIDAK
-- langsung membatalkan preview. Tanpa ini, log 19 Sep 2026 penuh "batal=true" padahal datanya
-- sudah lengkap: satu getaran kursor membuang model yang sedang dibangun.
local HOVER_DELAY = 0.3 -- detik kursor harus DIAM di kartu sebelum model preview dibangun
local STAR_FILLED = utf8.char(0x2605) -- ★ ada di BuilderSans (diuji di Studio 19 Sep 2026)
local STAR_HOLLOW = utf8.char(0x2606) -- ☆

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
		_isBackground: boolean, -- latar area preview: istilah tombol & pil berbeda
		_limited: TextLabel,
		_overlay: TextButton,
		_try: TextButton,
		_buy: TextButton,
		_cart: TextButton,
		_hasCart: boolean,
		_info: TextButton,
		_star: TextButton,
		_hasFav: boolean,
		_favorite: boolean?, -- nil = belum diketahui (BUKAN "bukan favorit")
		_hover: boolean, -- kursor sedang di atas kartu (PC)
		_display: Display,
		_preview: ViewportFrame,
		_onPreview: ((Item, ViewportFrame) -> (() -> ())?)?,
		_previewStop: (() -> ())?, -- pembatal dari layanan preview; nil = tidak ada yang terpasang
		_previewPending: boolean, -- jeda hover sedang berjalan
		_previewToken: number, -- membatalkan jeda yang sudah tidak relevan
		_previewNone: boolean, -- item ini tidak bisa dipreview (animasi / bundle) -> jangan coba lagi
		_leaveToken: number, -- membatalkan jeda maaf saat kursor kembali
		_previewConn: RBXScriptConnection?, -- menunggu avatar muncul di viewport
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

-- Teks harga, warnanya, dan apakah tombol BUY aktif. Dibuka (ItemCard.priceOf) supaya kartu hero
-- di CatalogPanel memakai aturan yang SAMA — dua salinan aturan harga pasti akan berbeda suatu hari.
local function priceOf(item: Item): (string, Color3, boolean)
	if item.resalePrice then
		return ROBUX .. " " .. tostring(item.resalePrice), Tokens.Color.Accent, true -- harga pasar
	end
	-- Item yang ditarik dari penjualan datang dengan harga 0, jadi pemeriksaan ini WAJIB berada
	-- DI ATAS cabang `price <= 0`; kalau tidak, kartunya menulis "Free" (spike 19 Sep 2026 "5b").
	if item.offSale then
		return "Off Sale", Tokens.Color.TextMuted, false
	end
	if item.price == nil then
		-- Harga 999999999 sudah dibuang CatalogService: bukan off-sale, tapi juga tidak bisa dibeli.
		return "Not for sale", Tokens.Color.TextMuted, false
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
	b.Size = UDim2.new(1, 0, 0.28, 0) -- 0.36 membuat TRY/BUY memenuhi kartu (dinilai di Studio)
	b.ZIndex = Tokens.ZIndex.Panel + 3

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Small
	corner.Parent = b

	local limit = Instance.new("UITextSizeConstraint")
	limit.MinTextSize = 9
	limit.MaxTextSize = Tokens.TextSize.Body
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
	list.Padding = UDim.new(0.05, 0)
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

	-- Preview avatar memakai item: menempati kotak yang SAMA dengan thumbnail, dan thumbnail
	-- disembunyikan selama ia tampil (dua gambar bertumpuk tidak terbaca di kartu sekecil ini).
	local preview = Instance.new("ViewportFrame")
	preview.Name = "Preview"
	-- Dua sumber garis putih, dimatikan dua-duanya:
	--   1. LAMPU BERARAH -> LightColor dinolkan, tinggal Ambient rata (dinaikkan supaya avatarnya
	--      tetap terbaca). Diukur 19 Sep 2026: menolkan LightColor lewat Command Bar membuat
	--      garisnya hilang seketika.
	--   2. LATAR TEMBUS -> piksel tepi model dicampur ke latar transparan dan menyisakan
	--      pinggiran terang. Latarnya dipekatkan, tapi SEWARNA PERMUKAAN KARTU: kartu memakai
	--      PanelRaised pada transparansi 0,02, jadi selisihnya di bawah 1/255 -- tidak ada kotak
	--      hitam seperti percobaan sebelumnya yang memakai Color.Background (10,10,12).
	preview.BackgroundColor3 = Tokens.Color.PanelRaised
	preview.BackgroundTransparency = 0
	preview.Ambient = Color3.fromRGB(190, 190, 195)
	preview.LightColor = Color3.fromRGB(0, 0, 0)
	preview.AnchorPoint = image.AnchorPoint
	preview.Position = image.Position
	preview.Size = image.Size
	preview.ZIndex = Tokens.ZIndex.Panel + 1
	preview.Visible = false
	-- Preview mengisi KOTAK GAMBAR, bukan latar kartu: apa pun yang melimpah dipotong.
	preview.ClipsDescendants = true
	preview.Parent = button

	local previewCorner = Instance.new("UICorner")
	previewCorner.CornerRadius = Tokens.Radius.Medium
	previewCorner.Parent = preview

	-- Bintang favorit (pojok KIRI ATAS overlay, pola CAC). Posisi & ukurannya diatur _layoutButtons.
	local star = Instance.new("TextButton")
	star.Name = "Favorite"
	star.Text = STAR_HOLLOW
	star.FontFace = Tokens.Font.Bold
	star.TextScaled = true
	star.TextColor3 = Tokens.Color.TextMuted
	star.TextTransparency = 0.35
	star.BackgroundColor3 = Tokens.Color.PanelRaised
	star.BorderSizePixel = 0
	star.AutoButtonColor = true
	star.Position = UDim2.fromOffset(4, 4)
	star.Size = UDim2.fromOffset(BTN_MAX, BTN_MAX)
	star.ZIndex = Tokens.ZIndex.Panel + 4
	star.Visible = false -- muncul saat hover (PC) atau overlay terbuka (HP)
	star.Parent = button

	local starPad = Instance.new("UIPadding")
	starPad.PaddingTop = UDim.new(0, 2)
	starPad.PaddingBottom = UDim.new(0, 2)
	starPad.Parent = star

	local starCorner = Instance.new("UICorner")
	starCorner.CornerRadius = Tokens.Radius.Pill
	starCorner.Parent = star

	local starStroke = Instance.new("UIStroke")
	starStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	starStroke.Color = Tokens.Color.Stroke
	starStroke.Transparency = 0.5
	starStroke.Parent = star

	local self = setmetatable({
		instance = button,
		item = props.item,
		_image = image,
		_name = name,
		_price = price,
		_stroke = stroke,
		_badge = badge,
		_isBackground = AssetTypeMap.Background[props.item.assetType] == true,
		_limited = limitedBand,
		_overlay = overlay,
		_try = try,
		_buy = buy,
		_cart = cart,
		_hasCart = props.onCart ~= nil,
		_info = info,
		_star = star,
		_hasFav = props.onFavorite ~= nil,
		_favorite = nil,
		_hover = false,
		_display = { name = true, price = true, limited = true },
		_preview = preview,
		_onPreview = props.onPreview,
		_previewStop = nil,
		_previewPending = false,
		_previewToken = 0,
		_previewNone = false,
		_leaveToken = 0,
		_previewConn = nil,
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
		return self.item.price ~= nil and not self.item.offSale
	end)
	hook(info, props.onInfo)
	hook(cart, props.onCart, function()
		return self.item.price ~= nil and not self.item.offSale
	end)
	hook(star, props.onFavorite)

	-- Kursor masuk/keluar kartu (PC). Di HP tidak pernah menyala -> bintang di sana ikut overlay.
	table.insert(
		self._conns,
		button.MouseEnter:Connect(function()
			self:_setHover(true)
			if props.onHover then
				props.onHover(self.item, true)
			end
		end)
	)
	table.insert(
		self._conns,
		button.MouseLeave:Connect(function()
			self:_setHover(false)
			if props.onHover then
				props.onHover(self.item, false)
			end
		end)
	)

	-- Lebar kartu berubah (grid dihitung ulang / zoom) -> ukuran tombol bulat ikut dihitung ulang.
	table.insert(
		self._conns,
		button:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_layoutButtons()
		end)
	)

	self:setItem(props.item)
	self:_layoutButtons()
	return self
end

-- Tiga tombol bulat overlay diukur dari LEBAR KARTU, dalam piksel: bintang di kiri, keranjang di
-- sebelahnya (kalau tampil), ⓘ menempel kanan. Kartu compact ~76 px masih memuat ketiganya.
function ItemCard._layoutButtons(self: ItemCard)
	local width = self.instance.AbsoluteSize.X
	if width <= 0 then
		return -- kartu belum punya ukuran (belum masuk grid)
	end
	local size = math.clamp(math.floor(width * BTN_RATIO), BTN_MIN, BTN_MAX)
	local x = 4
	self._star.Size = UDim2.fromOffset(size, size)
	self._star.Position = UDim2.fromOffset(x, 4)
	if self._star.Visible then
		x += size + 4
	end
	self._cart.Size = UDim2.fromOffset(size + 6, size)
	self._cart.Position = UDim2.fromOffset(x, 4)
	self._info.Size = UDim2.fromOffset(size, size)
end

-- Nama/harga/pita dimatikan -> area teks di bawah gambar DIKEMBALIKAN ke gambar, jadi tidak ada
-- pita kosong. Gambar, viewport preview, overlay, dan pita LIMITED semuanya ikut dihitung ulang.
function ItemCard.setDisplay(self: ItemCard, display: Display)
	self._display = display
	self._name.Visible = display.name ~= false
	self._price.Visible = display.price ~= false
	self._limited.Visible = display.limited ~= false and self.item.limited == true
	local pad = Tokens.Space.S
	local area = if self._name.Visible or self._price.Visible then TEXT_AREA else 0
	self._image.Size = UDim2.new(1, -pad * 2, 1, -pad * 2 - area)
	self._preview.Size = self._image.Size
	self._overlay.Size = UDim2.new(1, 0, 1, -area)
	self._limited.Position = UDim2.new(0, pad, 1, -pad - area)
	self:_layoutButtons()
end

function ItemCard._setHover(self: ItemCard, hover: boolean)
	self._hover = hover
	self._leaveToken += 1 -- kursor bergerak: jeda maaf yang sedang berjalan tidak berlaku lagi
	self:_syncStar()
	if hover then
		self:_syncPreview()
		return
	end
	-- Kursor keluar: beri jeda maaf. Kalau ia kembali ke kartu ini sebelum jedanya habis, preview
	-- yang sedang dibangun TIDAK jadi dibuang -- inilah yang membuat kartu bundle & animasi tadi
	-- selalu "batal" (kursor cuma melintas celah 8 px antar kartu).
	local token = self._leaveToken
	task.delay(LEAVE_GRACE, function()
		if token == self._leaveToken and not self._hover then
			self:_syncPreview()
		end
	end)
end

-- Lepas preview yang sedang tampil / batalkan jeda yang sedang berjalan.
-- `reason` dicatat karena log 19 Sep 2026 menunjukkan preview dibatalkan (batal=true) padahal
-- kursor masih menempel di kartu -- alasannya harus kelihatan, bukan ditebak.
function ItemCard._stopPreview(self: ItemCard, reason: string?)
	if self._previewPending or self._previewStop ~= nil then
		log.debug("preview dibatalkan", self.item.id, reason or "?")
	end
	self._previewToken += 1
	self._previewPending = false
	local conn = self._previewConn
	self._previewConn = nil
	if conn then
		conn:Disconnect()
	end
	local stop = self._previewStop
	self._previewStop = nil
	if stop then
		stop() -- layanan preview membereskan isi viewport-nya sendiri
	end
	self._preview.Visible = false
	self._image.Visible = true
	self.instance.AutoButtonColor = true
	self:setSelected(self._selected) -- kembalikan warna & transparansi tepi kartu
end

-- Preview tampil kalau kursor diam di kartu dan overlay tertutup (aturan yang sama dengan bintang).
function ItemCard._syncPreview(self: ItemCard)
	if self._onPreview == nil then
		return
	end
	local want = self._hover and not self._overlay.Visible
	if not want then
		self:_stopPreview(if self._overlay.Visible then "overlay-dibuka" else "hover-lepas")
		return
	end
	if self._previewPending or self._previewStop ~= nil or self._previewNone then
		return -- sudah tampil, sedang ditunggu, atau item ini memang tidak bisa dipreview
	end
	self._previewToken += 1
	self._previewPending = true
	local token = self._previewToken
	task.delay(HOVER_DELAY, function()
		if token ~= self._previewToken then
			return -- kursor keburu pergi / kartu dipakai ulang
		end
		self._previewPending = false
		local fn = self._onPreview
		if fn == nil or not self._hover or self._overlay.Visible then
			return
		end
		-- Viewport dinyalakan TANPA menyembunyikan thumbnail: ia masih kosong sampai modelnya jadi.
		self._preview.Visible = true
		-- Sinyalnya dipasang SEBELUM model ditempel: model yang sudah ada di cache tempel
		-- SEKETIKA, jadi DescendantAdded yang dipasang belakangan tidak pernah berbunyi dan
		-- thumbnail tetap tampil di balik avatar (dinilai di Studio 19 Sep 2026).
		self._previewConn = self._preview.DescendantAdded:Connect(function(child: Instance)
			if child:IsA("BasePart") and self._previewStop ~= nil then
				self._image.Visible = false
			end
		end)
		local stop = fn(self.item, self._preview)
		if stop == nil then
			-- Item ini tidak bisa dipreview (animasi, bundle, tipe yang tidak menempel di avatar).
			self._preview.Visible = false
			self._previewNone = true
			local c = self._previewConn
			self._previewConn = nil
			if c then
				c:Disconnect()
			end
			return
		end
		self._previewStop = stop
		-- Kilau bawaan ImageButton mencerahkan seluruh kartu saat kursor menempel; di atas
		-- viewport itu terbaca sebagai kabut. Tepi kartu TIDAK ikut disembunyikan (dugaan lama
		-- bahwa tepi kartu itu sumber garis putihnya meleset -- sumbernya lampu berarah).
		self.instance.AutoButtonColor = false
		-- Model dari cache sudah menempel sebelum baris ini: diperiksa sekali supaya thumbnail
		-- tetap disembunyikan walau sinyalnya tidak berbunyi.
		if self._preview:FindFirstChildWhichIsA("BasePart", true) ~= nil then
			self._image.Visible = false
		end
	end)
end

-- Bintang tampil HANYA saat kursor di atas kartu dan overlay tertutup.
function ItemCard._syncStar(self: ItemCard)
	self._star.Visible = self._hasFav and self._hover and not self._overlay.Visible
end

-- nil = BELUM DIKETAHUI, dan itu SENGAJA dibedakan dari "bukan favorit": status favorit hanya
-- diambil untuk item yang benar-benar dibuka pemain (lihat DetailController bagian FAVORIT).
function ItemCard.setFavorite(self: ItemCard, value: boolean?)
	self._favorite = value
	self._star.Text = if value == true then STAR_FILLED else STAR_HOLLOW
	self._star.TextColor3 = if value == true
		then Tokens.Color.Accent
		elseif value == false then Tokens.Color.Text
		else Tokens.Color.TextMuted
	self._star.TextTransparency = if value == nil then 0.35 else 0
end

-- Permintaan rbxthumb yang JATUH tidak pernah dicoba ulang oleh engine: ImageLabel-nya diam
-- kosong selamanya, dan itu yang terlihat sebagai "dua baris kartu tanpa gambar" setelah
-- menggulir cepat (puluhan kartu lahir sekaligus, sebagian permintaannya tidak terlayani).
-- Menyetel Image ke "" lalu kembali ke URL yang sama memicu permintaan BARU.
-- Berhenti kalau kartunya sudah dipakai ulang untuk item lain (self.item berganti) atau dibuang.
function ItemCard._loadThumb(self: ItemCard, item: Item)
	local url = thumbnail(item)
	self._image.Image = url
	task.spawn(function()
		for _ = 1, 4 do
			task.wait(1.5)
			if self.item ~= item or self._image.Parent == nil or self._image.IsLoaded then
				return
			end
			self._image.Image = ""
			task.wait()
			if self.item ~= item then
				return
			end
			self._image.Image = url
		end
	end)
end

function ItemCard.setItem(self: ItemCard, item: Item)
	self.item = item
	self.instance.Name = "ItemCard_" .. tostring(item.id)
	self:_loadThumb(item)
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
	self._isBackground = AssetTypeMap.Background[item.assetType] == true
	self._badge.Text = if self._isBackground then "IN USE" else "Worn"
	self._cart.Visible = self._hasCart and forSale
	self._hover = false -- kartu dipakai ulang saat digulir: kursor dianggap keluar
	self:_stopPreview("kartu-dipakai-ulang") -- preview item LAMA tidak boleh terbawa ke item baru
	self._previewNone = false -- item baru: boleh dicoba lagi
	self:_syncStar()
	self:setFavorite(nil) -- kartu dipakai ulang untuk item lain: statusnya belum diketahui lagi
	self:_layoutButtons() -- keranjang bisa muncul/hilang -> posisi bintang & keranjang berubah
	self:setDisplay(self._display) -- item baru, sakelar tampilan yang sama
	self:setInCart(false) -- pemanggil (CatalogPanel) mengatur ulang sesudah setItem
	self:setArmed(false) -- kartu dipakai ulang untuk item lain
end

function ItemCard.setSelected(self: ItemCard, selected: boolean)
	self._selected = selected
	self._badge.Visible = selected
	self._stroke.Color = if selected then Tokens.Color.Accent else Tokens.Color.Stroke
	self._stroke.Transparency = if selected then 0.4 else Tokens.Transparency.Stroke
	self._try.Text = if selected then "REMOVE" elseif self._isBackground then "USE" else "TRY"
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
	self:_syncStar()
	self:_syncPreview()
end

function ItemCard.isArmed(self: ItemCard): boolean
	return self._overlay.Visible
end

function ItemCard.destroy(self: ItemCard)
	self:_stopPreview("kartu-dibuang")
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

ItemCard.priceOf = priceOf

return ItemCard
