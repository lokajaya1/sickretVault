--!strict
-- Akar UI: ScreenGui + tombol atas (Catalog, Stores) + kolom samping kiri/kanan + panel katalog
-- + panel detail + panel keranjang + panel outfit tersimpan + dock (Undo/Redo/Reset + strip Wearing).
-- Tata letak layar utama mengikuti claude/Pedoman_Layout_CAC.md (kolom kanan: Saved Outfits, Emotes;
-- kolom kiri: Community Outfits, Outfit Loader). Kolom samping hanya tampil saat katalog tertutup.
--   local app = App.mount({ onItemActivated = function(item) ... end })  -- hook tambahan (log) saat kartu di-tap
-- Kartu: tap -> overlay TRY / BUY / ⓘ / 🛒. ⓘ & paste link -> panel detail. 🛒 di header -> panel keranjang.
--   app:toggleCatalog()   app:openDetail(id, "Asset")   app:openCart()   app:checkout()
--   app:openWardrobe()    app:closeWardrobe()
-- Kartu preview avatar (kolom kiri) punya kontrolnya sendiri, semuanya MELAYANG di atas kartu:
-- drag = putar + dongak, dua jari / klik kanan = geser avatar, cubit / scroll / tombol bulat
-- "+" & "-" di kanan bawah = zoom.
-- Saved Outfits dibuka dari kolom samping (katalog tertutup) -> menutupnya kembali ke layar utama,
-- bukan ke halaman menu katalog.
-- Panel keranjang & wardrobe menutupi isi katalog; hanya satu yang terbuka.
--   app.toast:show("Hello", "info")   app:destroy()

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local WornItems = require(ReplicatedStorage:WaitForChild("Shared").Domain.WornItems)
local Tokens = require(script.Parent.Theme.Tokens)
local CatalogPanel = require(script.Parent.Components.CatalogPanel)
local Toast = require(script.Parent.Components.Toast)
local ActionBar = require(script.Parent.Components.ActionBar)
local WornStrip = require(script.Parent.Components.WornStrip)
local ItemDetailPanel = require(script.Parent.Components.ItemDetailPanel)
local CartPanel = require(script.Parent.Components.CartPanel)
local WardrobePanel = require(script.Parent.Components.WardrobePanel)
local SideRail = require(script.Parent.Components.SideRail)
local OutfitPreview = require(script.Parent.Util.OutfitPreview)
local CatalogController = require(script.Parent.Parent.Controllers.CatalogController)
local OutfitController = require(script.Parent.Parent.Controllers.OutfitController)
local DetailController = require(script.Parent.Parent.Controllers.DetailController)
local CartController = require(script.Parent.Parent.Controllers.CartController)
local WardrobeController = require(script.Parent.Parent.Controllers.WardrobeController)
local TryOnCamera = require(script.Parent.Parent.Controllers.TryOnCamera)

export type Options = {
	onItemActivated: ((item: any) -> ())?,
}

local App = {}
App.__index = App

-- Prompt beli bawaan Roblox (aset / bundle). Gagal -> false.
local function promptBuy(player: Player, id: number, itemType: string): boolean
	local ok, err = pcall(function()
		if itemType == "Bundle" then
			MarketplaceService:PromptBundlePurchase(player, id)
		else
			MarketplaceService:PromptPurchase(player, id)
		end
	end)
	if not ok then
		warn("[App] prompt beli gagal", itemType, id, err)
	end
	return ok
end

-- Teks toast keranjang (teks pemain berbahasa Inggris).
local CART_ADD_TEXT: { [string]: string } = {
	full = "Cart is full (max %d items)",
	notForSale = "This item can't be added to the cart",
	invalid = "This item can't be added to the cart",
}

local CHECKOUT_TEXT: { [string]: string } = {
	BUSY = "A purchase prompt is already open",
	RATE_LIMITED = "Slow down a little",
	TOO_MANY = "Too many items in the cart",
	NETWORK = "Couldn't reach the server",
}

-- Item keranjang dari kartu katalog / detail (hanya field yang dipakai Cart).
local function toCartItem(x: any): any
	return {
		id = x.id,
		itemType = x.itemType,
		name = x.name,
		price = if x.isForSale == false then nil else x.price,
		assetType = x.assetType,
		bundleType = x.bundleType,
		creatorName = x.creatorName,
	}
end

-- Teks toast wardrobe (teks pemain berbahasa Inggris). %s = nama outfit.
-- favorite & setSetting sengaja tanpa toast (bintang / switch sudah berubah sendiri).
local WARDROBE_OK_TEXT: { [string]: string } = {
	save = "Outfit saved",
	wear = "Wearing %s",
	overwrite = "Updated %s",
	rename = "Renamed to %s",
	delete = "Deleted %s",
	bulkDelete = "Deleted %s",
	folderAdd = "Folder %s created",
	folderRename = "Folder renamed to %s",
	folderDelete = "Folder %s deleted",
	setFolders = "Folders updated",
	bulkFolder = "Moved to %s",
}

local WARDROBE_FAIL_TEXT: { [string]: string } = {
	FULL = "Your outfit slots are full",
	FILTERED = "That name isn't allowed. Try another one",
	FILTER_FAILED = "Couldn't check that name, try again",
	BAD_NAME = "Enter a valid name",
	EMPTY = "Enter a name",
	TOO_LONG = "That name is too long",
	NOT_LOADED = "Your data is still loading, try again",
	NOT_READY = "Avatar is loading, try again",
	NOT_FOUND = "That outfit no longer exists",
	DUPLICATE = "You already have a folder with that name",
	TOO_MANY = ("An outfit can be in %d folders at most"):format(8), -- OutfitFolders.MAX_PER_OUTFIT
	INVALID = "This outfit can't be loaded",
	RATE_LIMITED = "Slow down a little",
	NETWORK = "Couldn't reach the server",
	DISABLED = "Outfits are unavailable right now",
}

local WARDROBE_INFO_CODES: { [string]: boolean } = {
	RATE_LIMITED = true,
	NOT_LOADED = true,
	NOT_READY = true,
}

local SOON_SECONDS = 1.2
local DRAG_SENSITIVITY = 0.008 -- radian per piksel (sama dengan OrbitMath.DEFAULTS)
local PINCH_ZOOM = 3 -- seberapa kuat cubit dua jari mengubah zoom kartu
-- Kontrol kartu sengaja RAMPING: ia melayang di atas gambar avatar, jadi tugasnya tersedia
-- saat dicari, bukan menarik perhatian. Tiga tombol zoom/reset ditumpuk dalam SATU kapsul
-- (satu bentuk, bukan tiga lingkaran tebal), dan tiap selnya tetap 34 px supaya masih nyaman
-- ditekan jempol di ponsel.
local ZOOM_BUTTON = 34 -- tinggi satu sel di dalam kapsul, sekaligus garis tengah tombol bulat
local ZOOM_INSET = 10 -- jarak kontrol dari tepi kartu
local ICON_LINE = 2 -- tebal garis ikon
local ICON_SPAN = 13 -- panjang garis plus/minus
local ICON_CHEVRON = 10 -- panjang satu sisi chevron
local ICON_RING = 13 -- garis tengah lingkaran ikon reset

local function plural(n: number, word: string): string
	return ("%d %s%s"):format(n, word, if n == 1 then "" else "s")
end

export type App = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		catalog: CatalogController.CatalogController,
		outfit: OutfitController.OutfitController,
		detail: DetailController.DetailController,
		panel: CatalogPanel.CatalogPanel,
		detailPanel: ItemDetailPanel.ItemDetailPanel,
		cart: CartController.CartController,
		cartPanel: CartPanel.CartPanel,
		wardrobe: WardrobeController.WardrobeController,
		wardrobePanel: WardrobePanel.WardrobePanel,
		previews: OutfitPreview.OutfitPreview,
		_previewCard: Frame, -- kartu avatar SEKARANG (kolom kiri); hanya saat latar dipakai
		_live: OutfitPreview.Handle,
		_previewPort: ViewportFrame, -- salinan avatar; disembunyikan saat kartu sedang tembus
		_previewStroke: UIStroke, -- bingkai kartu; dimatikan saat kartu tembus
		_hasBackground: boolean, -- item AvatarBackground sedang dipakai -> kartu jadi pekat
		_previewShow: TextButton, -- tombol bulat untuk memunculkan kartu yang disembunyikan
		_previewMin: boolean, -- kartu sedang disembunyikan pemain
		leftRail: SideRail.SideRail,
		rightRail: SideRail.SideRail,
		toast: Toast.Toast,
		actions: ActionBar.ActionBar,
		strip: WornStrip.WornStrip,
		camera: TryOnCamera.TryOnCamera,
		_catalogButton: TextButton,
		_wardrobeAlone: boolean, -- wardrobe dibuka dari kolom samping (katalog tadinya tertutup)
		_topBar: Frame,
		_conns: { RBXScriptConnection },
	},
	App
))

local function topButton(name: string, text: string, order: number, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = text
	b.LayoutOrder = order
	b.FontFace = Tokens.Font.Bold
	b.TextSize = Tokens.TextSize.Button
	b.TextColor3 = Tokens.Color.Text
	b.BackgroundColor3 = Tokens.Color.Panel
	b.BackgroundTransparency = Tokens.Transparency.Panel
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Size = UDim2.fromOffset(Tokens.Size.TopButton.X, Tokens.Size.TopButton.Y)
	b.ZIndex = Tokens.ZIndex.Hud

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Pill
	corner.Parent = b

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Tokens.Color.Stroke
	stroke.Transparency = Tokens.Transparency.Stroke
	stroke.Parent = b

	b.Parent = parent
	return b
end

-- Ikon DIGAMBAR dari Frame, bukan glyph font dan bukan assetId. Uji Studio 18 Sep 2026:
-- BuilderSans tidak punya "✥" (U+2725) maupun "▾" (U+25BE) -- keduanya jadi kotak kosong -- dan
-- menebak id aset lebih berbahaya lagi. Garis membulat begini juga lebih rapi daripada huruf.
local function iconBar(parent: Instance, w: number, h: number, rot: number, dx: number)
	local f = Instance.new("Frame")
	f.Name = "Line"
	f.BackgroundColor3 = Tokens.Color.Text
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.new(0.5, dx, 0.5, 0)
	f.Size = UDim2.fromOffset(w, h)
	f.Rotation = rot
	f.ZIndex = Tokens.ZIndex.Hud + 3
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	f.Parent = parent
end

-- "plus" | "minus" | "down" (sembunyikan kartu) | "up" (tampilkan lagi).
-- Chevron = dua garis miring 45 derajat yang bertemu di tengah; jarak dari tengah = panjang * cos45.
local function drawIcon(kind: string, parent: Instance)
	local reach = ICON_CHEVRON * 0.35
	if kind == "plus" then
		iconBar(parent, ICON_SPAN, ICON_LINE, 0, 0)
		iconBar(parent, ICON_LINE, ICON_SPAN, 0, 0)
	elseif kind == "minus" then
		iconBar(parent, ICON_SPAN, ICON_LINE, 0, 0)
	elseif kind == "target" then
		-- Reset tampilan: lingkaran tipis + titik di tengah -- "bawa kembali ke tengah".
		local ring = Instance.new("Frame")
		ring.Name = "Ring"
		ring.BackgroundTransparency = 1
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.fromScale(0.5, 0.5)
		ring.Size = UDim2.fromOffset(ICON_RING, ICON_RING)
		ring.ZIndex = Tokens.ZIndex.Hud + 3
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = ring
		local edge = Instance.new("UIStroke")
		edge.Color = Tokens.Color.Text
		edge.Thickness = 1.5
		edge.Parent = ring
		ring.Parent = parent
		local dot = Instance.new("Frame")
		dot.Name = "Dot"
		dot.BackgroundColor3 = Tokens.Color.Text
		dot.BorderSizePixel = 0
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.5, 0.5)
		dot.Size = UDim2.fromOffset(3, 3)
		dot.ZIndex = Tokens.ZIndex.Hud + 3
		local dotRound = Instance.new("UICorner")
		dotRound.CornerRadius = UDim.new(1, 0)
		dotRound.Parent = dot
		dot.Parent = parent
	elseif kind == "down" then
		iconBar(parent, ICON_CHEVRON, ICON_LINE, 45, -reach)
		iconBar(parent, ICON_CHEVRON, ICON_LINE, -45, reach)
	else
		iconBar(parent, ICON_CHEVRON, ICON_LINE, -45, -reach)
		iconBar(parent, ICON_CHEVRON, ICON_LINE, 45, reach)
	end
end

-- Kapsul kaca tempat tombol-tombol ditumpuk: SATU bentuk membulat, bukan tiga lingkaran.
local function controlCapsule(name: string, cells: number, parent: Instance): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = Tokens.Color.Background
	f.BackgroundTransparency = 0.3
	f.BorderSizePixel = 0
	f.ClipsDescendants = true
	f.Size = UDim2.fromOffset(ZOOM_BUTTON, ZOOM_BUTTON * cells)
	f.ZIndex = Tokens.ZIndex.Hud + 2

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Pill
	corner.Parent = f

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Tokens.Color.Stroke
	stroke.Transparency = 0.6
	stroke.Parent = f

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = f

	f.Parent = parent
	return f
end

-- Satu sel di dalam kapsul: latarnya sendiri tembus, jadi yang terlihat cuma ikonnya.
-- `divider` = garis rambut pemisah dari sel berikutnya.
local function capsuleButton(name: string, icon: string, order: number, divider: boolean, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = ""
	b.LayoutOrder = order
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Size = UDim2.fromOffset(ZOOM_BUTTON, ZOOM_BUTTON)
	b.ZIndex = Tokens.ZIndex.Hud + 2

	drawIcon(icon, b)
	if divider then
		local line = Instance.new("Frame")
		line.Name = "Divider"
		line.BackgroundColor3 = Tokens.Color.Stroke
		line.BackgroundTransparency = 0.7
		line.BorderSizePixel = 0
		line.AnchorPoint = Vector2.new(0.5, 1)
		line.Position = UDim2.fromScale(0.5, 1)
		line.Size = UDim2.new(0.55, 0, 0, 1)
		line.ZIndex = Tokens.ZIndex.Hud + 2
		line.Parent = b
	end
	b.Parent = parent
	return b
end

-- Tombol bulat yang berdiri SENDIRI di atas kartu (sembunyikan / tampilkan).
local function floatButton(name: string, icon: string, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = ""
	b.BackgroundColor3 = Tokens.Color.Background
	b.BackgroundTransparency = 0.3
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Size = UDim2.fromOffset(ZOOM_BUTTON, ZOOM_BUTTON)
	b.ZIndex = Tokens.ZIndex.Hud + 2

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Pill
	corner.Parent = b

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Tokens.Color.Stroke
	stroke.Transparency = 0.6
	stroke.Parent = b

	drawIcon(icon, b)
	b.Parent = parent
	return b
end

function App.mount(opts: Options?): App
	local o = opts or {}
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- Hindari dobel saat script dijalankan ulang di Studio.
	local old = playerGui:FindFirstChild("CatalogApp")
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CatalogApp"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	-- Baris tombol atas (tengah)
	local bar = Instance.new("Frame")
	bar.Name = "TopBar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, Tokens.Space.S)
	bar.Size = UDim2.fromOffset(Tokens.Size.TopButton.X * 2 + Tokens.Space.S, Tokens.Size.TopButton.Y)
	bar.Parent = gui

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Tokens.Space.S)
	list.Parent = bar

	local catalogButton = topButton("Catalog", "Catalog", 1, bar)
	local storesButton = topButton("Stores", "Stores", 2, bar)
	storesButton.TextColor3 = Tokens.Color.TextMuted -- P1: belum aktif

	local toast = Toast.new({ parent = gui })

	local catalog = CatalogController.new()
	local outfit = OutfitController.new()
	local detail = DetailController.new()
	local cart = CartController.new()
	local wardrobe = WardrobeController.new()
	local self: App

	-- Dock (kiri bawah, dekat avatar): Undo / Redo / Reset -> server lewat OutfitController.
	local actions = ActionBar.new({
		parent = gui,
		onAction = function(op)
			outfit:send({ op = op })
		end,
	})

	-- Strip item yang sedang dipakai; tap -> Remove / Buy; klik kanan / tahan -> detail.
	-- Part dari bundle (item.source) -> beli / tampilkan bundle-nya.
	local strip = WornStrip.new({
		parent = gui,
		onRemove = function(item)
			outfit:send({ op = "remove", assetId = item.id })
		end,
		onBuy = function(item)
			if item.source then
				self:buy(item.source, "Bundle")
			else
				self:buy(item.id, "Asset")
			end
		end,
		onInfo = function(item)
			if item.source then
				self:openDetail(item.source, "Bundle")
			else
				self:openDetail(item.id, "Asset")
			end
		end,
	})

	-- Item katalog yang pernah tampil -> nama/harga untuk strip Wearing.
	local known: { [number]: any } = {}
	local function remember(state: any)
		for _, item in state.items do
			if item.itemType ~= "Bundle" then
				known[item.id] = item
			end
		end
	end

	local panel = CatalogPanel.new({
		controller = catalog,
		parent = gui,
		-- Tap kartu -> overlay di kartu (CatalogPanel); aksinya di bawah.
		onItemActivated = o.onItemActivated,
		onTry = function(item)
			outfit:toggle(item)
		end,
		onBuy = function(item)
			self:buy(item.id, item.itemType)
		end,
		onInfo = function(item)
			self:openDetail(item.id, item.itemType)
		end,
		onCart = function(item)
			self:toggleCart(item)
		end,
		isInCart = function(item)
			return cart:has(item.id, item.itemType)
		end,
		onOpenCart = function()
			self:openCart()
		end,
		onClose = function()
			self:_refreshButtons()
		end,
		isSelected = function(item)
			return if item.itemType == "Bundle" then outfit:isBundleWorn(item.id) else outfit:isWorn(item.id)
		end,
		-- Link/ID ditempel -> buka panel detail (server memvalidasi; gagal -> pesan di panel)
		onLink = function(id, kind)
			if id == nil then
				toast:show("That isn't a catalog item link", "warning")
			else
				self:openDetail(id, kind or "Asset")
			end
		end,
	})

	-- Panel keranjang: menutupi isi katalog (di bawah panel detail). Tap baris -> detail di atasnya.
	local cartPanel = CartPanel.new({
		parent = panel.instance,
		controller = cart,
		onItemActivated = function(item)
			self:openDetail(item.id, item.itemType)
		end,
		onCheckout = function()
			self:checkout()
		end,
	})

	-- Panel outfit tersimpan (kartu render avatar 3D): setingkat panel keranjang.
	local previews = OutfitPreview.new()

	-- Kartu avatar SEKARANG (kolom kiri gaya CAC). Kartunya menutupi PERSIS area tempat karakter
	-- dunia berdiri (anchor kamera try-on), jadi tidak pernah ada dua avatar terlihat sekaligus --
	-- tanpa perlu mengutak-atik transparansi karakter asli. Isinya clone karakter (OutfitPreview.
	-- mountCurrent), dan latar AvatarBackground akhirnya punya tempat: `{ background = true }`.
	local previewCard = Instance.new("Frame")
	previewCard.Name = "AvatarPreview"
	previewCard.BackgroundColor3 = Tokens.Color.Panel
	previewCard.BackgroundTransparency = 0 -- WAJIB pekat: kartu inilah yang menutupi avatar dunia
	previewCard.BorderSizePixel = 0
	-- Spike 18 Sep 2026: Frame BIASA tidak menyedot input (processed true=0 / false=32), jadi satu
	-- drag memutar kartu DAN kamera dunia yang tersembunyi di belakangnya sekaligus. `Active = true`
	-- menyedotnya penuh (true=40 / false=0) tanpa perlu ImageButton penutup; karena yang tersedot
	-- adalah InputBegan-nya, TryOnCamera tidak pernah punya drag -- jari yang keluar kartu pun aman.
	previewCard.Active = true
	previewCard.ClipsDescendants = true
	previewCard.Visible = false
	previewCard.ZIndex = Tokens.ZIndex.Hud
	previewCard.Parent = gui

	local previewCorner = Instance.new("UICorner")
	previewCorner.CornerRadius = Tokens.Radius.Large
	previewCorner.Parent = previewCard

	local previewStroke = Instance.new("UIStroke")
	previewStroke.Color = Tokens.Color.Stroke
	previewStroke.Transparency = Tokens.Transparency.Stroke
	previewStroke.Parent = previewCard

	local previewPort = Instance.new("ViewportFrame")
	previewPort.Name = "Preview"
	previewPort.BackgroundColor3 = Tokens.Color.Background
	previewPort.BackgroundTransparency = 0
	previewPort.Ambient = Color3.fromRGB(120, 120, 134)
	previewPort.LightColor = Color3.fromRGB(236, 236, 245)
	previewPort.LightDirection = Vector3.new(-0.4, -1, -0.65)
	previewPort.Size = UDim2.fromScale(1, 1)
	previewPort.ZIndex = Tokens.ZIndex.Hud + 1
	previewPort.Parent = previewCard

	local portCorner = Instance.new("UICorner")
	portCorner.CornerRadius = Tokens.Radius.Large
	portCorner.Parent = previewPort

	-- Kontrol MELAYANG di kanan bawah kartu. Yang dapat tombol hanya yang TIDAK punya gerakan
	-- alami: zoom dan kembali ke tampilan awal. Putar & geser sudah punya drag dan dua jari.
	local previewControls = controlCapsule("Controls", 3, previewCard)
	previewControls.AnchorPoint = Vector2.new(1, 1)
	previewControls.Position = UDim2.new(1, -ZOOM_INSET, 1, -ZOOM_INSET)

	local zoomIn = capsuleButton("ZoomIn", "plus", 1, true, previewControls)
	local zoomOut = capsuleButton("ZoomOut", "minus", 2, true, previewControls)
	local resetView = capsuleButton("ResetView", "target", 3, false, previewControls)

	-- Sembunyikan kartu: pojok kanan ATAS, sejauh mungkin dari kapsul supaya tidak tertekan
	-- tanpa sengaja saat jempol sibuk di kanan bawah.
	local hideButton = floatButton("Hide", "down", previewCard)
	hideButton.AnchorPoint = Vector2.new(1, 0)
	hideButton.Position = UDim2.new(1, -ZOOM_INSET, 0, ZOOM_INSET)

	-- Tombol memunculkan kartu lagi. Anak `gui`, bukan kartu: kartunya sendiri sedang tersembunyi.
	-- Letaknya persis di tempat tombol sembunyikan tadi, jadi jarinya tidak perlu berpindah.
	local showButton = floatButton("ShowPreview", "up", gui)
	showButton.AnchorPoint = Vector2.new(1, 0)
	showButton.Visible = false

	local livePreview = previews:mountCurrent(previewPort, { background = true })
	-- true = panel detail item dibuka dari Saved Outfits -> Back kembali ke sana, bukan ke katalog.
	local wardrobeReturn = false

	local wardrobePanel = WardrobePanel.new({
		parent = panel.instance,
		controller = wardrobe,
		previews = previews,
		onResult = function(op, ok, code, name)
			self:_showWardrobeResult(op, ok, code, name)
		end,
		onItem = function(item)
			wardrobeReturn = true
			self.wardrobePanel:setOpen(false) -- panel katalog tetap terbuka untuk halaman detail
			self:openDetail(item.id, "Asset")
		end,
		onBack = function()
			self:closeWardrobe()
		end,
	})

	-- Kolom samping (pola CAC). Fitur yang belum ada -> teks redup + "Soon".
	local leftRail = SideRail.new({
		parent = gui,
		side = "left",
		items = {
			{ key = "community", text = "Community Outfits", muted = true },
			{ key = "loader", text = "Outfit Loader", muted = true },
		},
		onActivated = function(key)
			self.leftRail:flash(key, "Soon", SOON_SECONDS)
		end,
	})
	local rightRail = SideRail.new({
		parent = gui,
		side = "right",
		items = {
			{ key = "outfits", text = "Saved Outfits" },
			{ key = "emotes", text = "Emotes", muted = true },
		},
		onActivated = function(key)
			if key == "outfits" then
				self:openWardrobe()
			else
				self.rightRail:flash(key, "Soon", SOON_SECONDS)
			end
		end,
	})

	-- Panel detail: menutupi isi panel katalog.
	local detailPanel = ItemDetailPanel.new({
		parent = panel.instance,
		controller = detail,
		isWorn = function(d)
			return if d.itemType == "Bundle" then outfit:isBundleWorn(d.id) else outfit:isWorn(d.id)
		end,
		isPartWorn = function(assetId)
			return outfit:isWorn(assetId)
		end,
		onToggle = function(d)
			outfit:toggle({ id = d.id, itemType = d.itemType })
		end,
		onBuy = function(d)
			self:buy(d.id, d.itemType)
		end,
		onCart = function(d)
			self:toggleCart(d)
		end,
		isInCart = function(d)
			return cart:has(d.id, d.itemType)
		end,
		onBack = function()
			detail:close()
			if wardrobeReturn then
				wardrobeReturn = false
				self:openWardrobe()
			end
		end,
		-- Nama creator diklik: panel detail ditutup, katalog berganti jadi semua karya pencipta itu.
		onCreator = function(d)
			local name = d.creatorName
			if type(name) ~= "string" or name == "" or name == "Unknown" then
				return
			end
			detail:close()
			panel:openCreator(name, d.creatorType)
		end,
		-- Kartu di baris Recommended: buka detailnya (panel yang sama, item lain).
		onRecommended = function(item)
			self:openDetail(item.id, item.itemType)
		end,
		-- Tap part bundle: sedang dipakai -> lepas part itu; belum -> pakai part itu saja.
		onPartActivated = function(part, d)
			if outfit:isWorn(part.assetId) then
				outfit:send({ op = "remove", assetId = part.assetId })
			else
				outfit:send({ op = "wearBundle", bundleId = d.id, partIds = { part.assetId } })
			end
		end,
	})

	-- Kamera try-on: karakter di tengah area layar yang tidak tertutup panel.
	local camera = TryOnCamera.new({
		getAnchor = function()
			local cam = Workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.zero
			if vp.X <= 0 or vp.Y <= 0 then
				return 0.5, 0.5
			end
			local L = panel:getLayout()
			local origin = gui.AbsolutePosition -- geser inset topbar Roblox
			return (origin.X + L.anchorX) / vp.X, (origin.Y + L.anchorY) / vp.Y
		end,
	})

	self = setmetatable({
		gui = gui,
		catalog = catalog,
		outfit = outfit,
		detail = detail,
		panel = panel,
		detailPanel = detailPanel,
		cart = cart,
		cartPanel = cartPanel,
		wardrobe = wardrobe,
		wardrobePanel = wardrobePanel,
		previews = previews,
		_previewCard = previewCard,
		_live = livePreview,
		_previewPort = previewPort,
		_previewStroke = previewStroke,
		_hasBackground = false,
		_previewShow = showButton,
		_previewMin = false,
		leftRail = leftRail,
		rightRail = rightRail,
		toast = toast,
		actions = actions,
		strip = strip,
		camera = camera,
		_catalogButton = catalogButton,
		_wardrobeAlone = false,
		_topBar = bar,
		_conns = {},
	}, App)

	table.insert(
		self._conns,
		catalogButton.Activated:Connect(function()
			self:toggleCatalog()
		end)
	)
	table.insert(
		self._conns,
		storesButton.Activated:Connect(function()
			storesButton.Text = "Soon"
			task.delay(1.2, function()
				storesButton.Text = "Stores"
			end)
		end)
	)

	-- Ukuran layar berubah (putar ponsel / jendela) -> atur ulang tombol atas & bar aksi.
	table.insert(
		self._conns,
		gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_refreshButtons()
		end)
	)

	local function refreshStrip()
		strip:setItems(WornItems.removable(WornItems.list(outfit:getState(), known)))
	end

	remember(catalog:getState())
	local unremember = catalog:onChanged(function(state)
		remember(state)
		refreshStrip() -- nama item bisa bertambah
	end)
	table.insert(self._conns, { Disconnect = unremember } :: any)

	-- Detail aset termuat -> nama/harga juga dikenal strip (mis. item dari paste link).
	local unDetail = detail:onChanged(function(state)
		local d = state.detail
		if d and d.itemType == "Asset" and known[d.id] == nil then
			known[d.id] = d
			refreshStrip()
		end
	end)
	table.insert(self._conns, { Disconnect = unDetail } :: any)

	-- Outfit berubah (dari server) -> perbarui sorotan kartu, panel detail & strip.
	local unsubscribe = outfit:onChanged(function()
		panel:refreshSelection()
		detailPanel:refreshWorn()
		refreshStrip()
		local refresh = livePreview.refresh
		if refresh and previewCard.Visible then
			refresh() -- clone ulang karakter (0,005 detik; makeup ikut sendiri)
		end
	end)
	table.insert(self._conns, { Disconnect = unsubscribe } :: any)

	-- Latar area preview (AvatarBackground) -> SEMUA ViewportFrame preview sekaligus.
	-- Latar area preview (AvatarBackground) -> semua ViewportFrame preview sekaligus.
	-- Kartu TIDAK lagi bergantung pada latar: ia selalu ada selama katalog terbuka (pemain bisa
	-- menyembunyikannya lewat chevron), dan tanpa latar isinya berdiri di atas panggung sendiri.
	local unBackground = outfit:onBackground(function(bg)
		previews:setBackground(bg)
		if self ~= nil then
			self._hasBackground = bg ~= nil -- menentukan kartu tembus atau pekat
			self:_refreshButtons()
		end
	end)
	table.insert(self._conns, { Disconnect = unBackground } :: any)
	task.spawn(outfit.start, outfit) -- yield (GetState)

	-- Keranjang berubah -> angka di header, tanda 🛒 di kartu & panel detail.
	local unCart = cart:onChanged(function(snap)
		panel:setCartCount(snap.count)
		detailPanel:refreshCart()
	end)
	table.insert(self._conns, { Disconnect = unCart } :: any)
	-- Hasil PromptBulkPurchase -> toast (item terbeli sudah dibuang dari keranjang oleh controller).
	local unResult = cart:onResult(function(summary)
		self:_showCheckoutResult(summary)
	end)
	table.insert(self._conns, { Disconnect = unResult } :: any)
	cart:start()
	panel:setCartCount(cart:count())

	-- ===== Kontrol kartu preview =====
	-- Satu jari / tombol kiri = PUTAR (mendatar) + DONGAK (tegak).
	-- Dua jari / tombol kanan = GESER avatar di dalam bingkai -- tanpa tombol mode: sakelar "pan"
	-- membuat orang harus mengingat kartu sedang dalam keadaan apa, dan itu yang bikin ribet.
	-- Cubit / scroll / tombol bulat = ZOOM.
	-- Gerakan lanjutan didengarkan lewat UserInputService supaya jari yang keluar kartu tidak
	-- memutus putaran; TryOnCamera tetap diam karena InputBegan-nya tadi tersedot kartu.
	local dragInput: InputObject? = nil
	local dragMouse = false
	local dragPan = false
	local dragLast = Vector3.zero
	local panLast = Vector2.zero
	table.insert(
		self._conns,
		previewCard.InputBegan:Connect(function(input: InputObject)
			local t = input.UserInputType
			local pan = t == Enum.UserInputType.MouseButton2
			if pan or t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
				dragInput = input
				dragMouse = not (t == Enum.UserInputType.Touch)
				dragPan = pan
				dragLast = input.Position
			end
		end)
	)
	table.insert(
		self._conns,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			local drag = dragInput
			if drag == nil then
				return
			end
			local t = input.UserInputType
			local mine = if dragMouse then t == Enum.UserInputType.MouseMovement else input == drag
			if not mine then
				return
			end
			local delta = input.Position - dragLast
			dragLast = input.Position
			if dragPan then
				self:_slide(delta.X, delta.Y)
			else
				self:_turn(delta.X, delta.Y)
			end
		end)
	)
	table.insert(
		self._conns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			local drag = dragInput
			if drag == nil then
				return
			end
			local t = input.UserInputType
			local mouseDone = t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2
			if if dragMouse then mouseDone else input == drag then
				dragInput = nil
			end
		end)
	)
	-- Scroll di atas kartu = zoom KARTU (bukan jarak kamera dunia).
	table.insert(
		self._conns,
		previewCard.InputChanged:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				self:_zoomView(input.Position.Z)
			end
		end)
	)
	-- Dua jari di atas kartu: geser. `processed` di sini berarti jarinya memang di atas UI kita.
	table.insert(
		self._conns,
		UserInputService.TouchPan:Connect(
			function(
				touches: { any },
				translation: Vector2,
				_velocity: Vector2,
				state: Enum.UserInputState,
				processed: boolean
			)
				if not processed or #touches < 2 then
					return
				end
				if state == Enum.UserInputState.Begin then
					panLast = translation
					dragInput = nil -- dua jari: berhenti memutar
					return
				end
				self:_slide(translation.X - panLast.X, translation.Y - panLast.Y)
				panLast = translation
			end
		)
	)
	-- Cubit dua jari = zoom. `scale` dihitung dari awal gerakan, jadi selisihnyalah yang dipakai.
	local pinchLast = 1
	table.insert(
		self._conns,
		UserInputService.TouchPinch:Connect(
			function(
				_touches: { any },
				scale: number,
				_velocity: number,
				state: Enum.UserInputState,
				processed: boolean
			)
				if not processed then
					return
				end
				if state == Enum.UserInputState.Begin then
					pinchLast = scale
					dragInput = nil
					return
				end
				self:_zoomView((scale - pinchLast) * PINCH_ZOOM)
				pinchLast = scale
			end
		)
	)
	table.insert(
		self._conns,
		hideButton.Activated:Connect(function()
			self._previewMin = true
			self:_refreshButtons()
		end)
	)
	table.insert(
		self._conns,
		showButton.Activated:Connect(function()
			self._previewMin = false
			self:_refreshButtons()
		end)
	)
	table.insert(
		self._conns,
		zoomIn.Activated:Connect(function()
			self:_zoomView(1)
		end)
	)
	table.insert(
		self._conns,
		zoomOut.Activated:Connect(function()
			self:_zoomView(-1)
		end)
	)
	table.insert(
		self._conns,
		resetView.Activated:Connect(function()
			self:_resetView() -- sudut, jarak, dan geseran kembali seperti saat kartu dibuka
		end)
	)

	refreshStrip()
	self:_refreshButtons()
	return self
end

-- Kontrol kartu menggerakkan kamera yang SEDANG dipakai kartu: kamera dunia saat kartu tembus,
-- kamera kartu saat kartu pekat. Dipisah jadi method (bukan tabel closure) karena dipanggil tiap
-- frame selama drag -- membuat tabel baru tiap gerakan jari itu sampah yang tidak perlu.
function App._turn(self: App, dx: number, dy: number)
	if self._hasBackground then
		self._live.addYaw(-dx * DRAG_SENSITIVITY)
		self._live.addPitch(-dy * DRAG_SENSITIVITY)
	else
		self.camera:turn(-dx * DRAG_SENSITIVITY, -dy * DRAG_SENSITIVITY)
	end
end

function App._slide(self: App, dx: number, dy: number)
	if self._hasBackground then
		self._live.addPan(dx, dy)
	else
		self.camera:pan(dx, dy)
	end
end

function App._zoomView(self: App, steps: number)
	if self._hasBackground then
		self._live.addZoom(steps)
	else
		self.camera:zoom(steps)
	end
end

function App._resetView(self: App)
	if self._hasBackground then
		self._live.resetView()
	else
		self.camera:reset()
	end
end

function App._refreshButtons(self: App)
	local open = self.panel:isVisible()
	if not open then
		self._wardrobeAlone = false
		self.detail:close() -- katalog ditutup (X / tombol / C) -> detail & keranjang ikut tertutup
		self.cartPanel:setOpen(false)
		if self.wardrobePanel:isOpen() then
			self.wardrobePanel:setOpen(false)
		end
	end
	self._catalogButton.BackgroundColor3 = if open then Tokens.Color.Accent else Tokens.Color.Panel
	self._catalogButton.BackgroundTransparency = if open then 0 else Tokens.Transparency.Panel
	-- Layar pendek (ponsel mendatar) + katalog terbuka: panel setinggi layar -> tombol atas disembunyikan
	-- (tutup lewat X). Dock (tombol aksi + strip) hanya tampil saat katalog terbuka, di kiri bawah.
	local L = self.panel:getLayout()
	self._topBar.Visible = not (open and L.compact)
	-- Kolom samping: hanya saat katalog tertutup (panel katalog menutupi sisi kanan).
	for _, rail in { self.leftRail, self.rightRail } do
		rail:setVisible(not open)
		rail:setCompact(L.compact)
	end
	local card = self._previewCard
	-- Disembunyikan pemain -> kartu hilang seluruhnya (avatar dunia kelihatan lagi) dan yang
	-- tersisa hanya tombol bulat, PERSIS di tempat tombol sembunyikan tadi.
	local mini = self._previewMin
	local wanted = open
	local showCard = wanted and not mini
	-- DUA MODE. Tanpa item Background kartu dibuat TEMBUS: yang terlihat di dalamnya adalah dunia
	-- sungguhan beserta karakter aslinya, dan yang digambar UI cuma bingkai membulatnya -- pola
	-- kartu preview Catalog Avatar Creator. Begitu Background dipakai, gambar latar tidak mungkin
	-- ditaruh di belakang karakter dunia, jadi kartu berubah pekat dan diisi SALINAN avatar.
	local window = not self._hasBackground
	card.BackgroundTransparency = if window then 1 else 0
	self._previewPort.Visible = not window
	-- Mode tembus: bingkainya pun dilepas. Menggambar kotak di atas dunia yang sudah terlihat utuh
	-- hanya memotong pemandangan; yang tersisa cukup tombol-tombol melayang.
	self._previewStroke.Enabled = not window
	card.Position = UDim2.fromOffset(L.previewX, L.previewY)
	card.Size = UDim2.fromOffset(L.previewW, L.previewH)
	local show = self._previewShow
	show.Position = UDim2.fromOffset(L.previewX + L.previewW - ZOOM_INSET, L.previewY + ZOOM_INSET)
	show.Visible = wanted and mini
	if showCard and not card.Visible then
		card.Visible = true
		local refresh = self._live.refresh
		if refresh then
			refresh() -- baru terlihat lagi: samakan dengan look sekarang
		end
	else
		card.Visible = showCard
	end
	-- Animasi di dalam kartu: kartu MENCERMINKAN pose karakter asli tiap frame (spike 18 Sep:
	-- 4,071 stud vs 0,352 stud diam), jadi animation pack yang dipakai pemain ikut apa adanya.
	-- Hanya jalan selama kartu terlihat supaya tidak ada loop yang bekerja sia-sia.
	local setLive = self._live.setLive
	if setLive then
		setLive(showCard and not window) -- mode tembus: tidak ada salinan yang perlu dicerminkan
	end
	local bar = self.actions.instance
	bar.Visible = open
	bar.AnchorPoint = Vector2.zero
	bar.Position = UDim2.fromOffset(L.dockX, L.dockY)
	local gap = L.dockH - L.actionsH - L.stripH
	self.strip:setPlacement(L.dockX, L.dockY + L.actionsH + gap, L.dockW, L.stripH)
	self.strip:setVisible(open)

	-- Katalog terbuka -> kamera try-on; tertutup -> kamera biasa.
	if open then
		self.camera:enable()
	else
		self.camera:disable()
	end
end

function App.toggleCatalog(self: App)
	self.panel:setVisible(not self.panel:isVisible())
	self:_refreshButtons()
end

-- Buka panel detail (katalog dibuka dulu bila tertutup). Memuat di thread baru (remote yield).
function App.openDetail(self: App, id: number, itemType: string)
	if not self.panel:isVisible() then
		self.panel:setVisible(true)
		self:_refreshButtons()
	end
	task.spawn(self.detail.open, self.detail, id, itemType)
end

-- Buka panel keranjang (katalog dibuka dulu bila tertutup; detail yang terbuka ditutup).
function App.openCart(self: App)
	if not self.panel:isVisible() then
		self.panel:setVisible(true)
		self:_refreshButtons()
	end
	self.detail:close()
	if self.wardrobePanel:isOpen() then
		self.wardrobePanel:setOpen(false)
	end
	self.cartPanel:setOpen(true)
end

-- Tombol Saved Outfits: buka katalog + panel outfit tersimpan (detail & keranjang ditutup).
function App.openWardrobe(self: App)
	if not self.panel:isVisible() then
		self._wardrobeAlone = true -- dibuka dari kolom samping: tutup panel lagi saat wardrobe ditutup
		self.panel:setVisible(true)
		self:_refreshButtons()
	end
	self.detail:close()
	self.cartPanel:setOpen(false)
	if not self.wardrobePanel:isOpen() then
		self.wardrobePanel:setOpen(true) -- memuat ulang daftar
	end
end

-- Back di panel outfit: kembali ke katalog, atau ke layar utama bila dibuka dari kolom samping.
function App.closeWardrobe(self: App)
	self.wardrobePanel:setOpen(false)
	if self._wardrobeAlone then
		self._wardrobeAlone = false
		self.panel:setVisible(false)
		self:_refreshButtons()
	end
end

-- Hasil aksi wardrobe -> toast. Sukses setting tidak perlu toast (switch sudah berubah).
function App._showWardrobeResult(self: App, op: string, ok: boolean, code: string?, name: string?)
	if ok then
		local text = WARDROBE_OK_TEXT[op]
		if text then
			self.toast:show(text:format(name or "outfit"), "info")
		end
		return
	end
	local c = code or "FAILED"
	local text = WARDROBE_FAIL_TEXT[c] or "Something went wrong, try again"
	local kind: any = if WARDROBE_INFO_CODES[c]
		then "info"
		elseif c == "FAILED" or c == "NETWORK" then "error"
		else "warning"
	self.toast:show(text, kind)
end

-- Tombol 🛒 (kartu / detail): tambah atau buang dari keranjang; gagal -> toast.
function App.toggleCart(self: App, x: any)
	local inCart, reason = self.cart:toggle(toCartItem(x))
	if inCart then
		self.toast:show(("Added to cart (%d)"):format(self.cart:count()), "info")
	elseif reason then
		local text = CART_ADD_TEXT[reason] or CART_ADD_TEXT.invalid
		self.toast:show(text:format(self.cart:getSnapshot().max), "warning")
	end
end

-- Tombol Buy All: remote Checkout (yield) di thread baru; gagal -> toast.
function App.checkout(self: App)
	task.spawn(function()
		local ok, code = self.cart:checkout()
		if not ok and code ~= "EMPTY" then
			local text = CHECKOUT_TEXT[code or ""] or "Couldn't open the purchase prompt"
			self.toast:show(text, if code == "RATE_LIMITED" or code == "BUSY" then "info" else "error")
		end
	end)
end

function App._showCheckoutResult(self: App, summary: any)
	local bought, owned, failed = #summary.purchased, #summary.owned, #summary.failed
	if bought > 0 then
		self.toast:show("Purchased " .. plural(bought, "item"), "info")
	end
	if owned > 0 then
		self.toast:show(plural(owned, "item") .. " already owned, removed from cart", "info")
	end
	if failed > 0 then
		local poor = false
		for _, f in summary.failed do
			if f.reason == "InsufficientRobux" then
				poor = true
			end
		end
		local text = if poor then "Not enough Robux" else plural(failed, "item") .. " couldn't be bought"
		self.toast:show(text, "warning")
	end
	if bought + owned + failed == 0 and summary.status == "Error" then
		self.toast:show("Purchase failed, try again", "error")
	end
end

-- Buka prompt beli Roblox; gagal -> toast.
function App.buy(self: App, id: number, itemType: string)
	if not promptBuy(Players.LocalPlayer, id, itemType) then
		self.toast:show("Couldn't open the purchase prompt", "error")
	end
end

function App.destroy(self: App)
	for _, c in self._conns do
		c:Disconnect()
	end
	self.camera:destroy()
	self.outfit:stop()
	self.cart:stop()
	self.cartPanel:destroy()
	self.wardrobePanel:destroy()
	self._live.cancel()
	self.previews:destroy()
	self.leftRail:destroy()
	self.rightRail:destroy()
	self.detailPanel:destroy()
	self.detail:close()
	self.panel:destroy()
	self.toast:destroy()
	self.actions:destroy()
	self.strip:destroy()
	self.gui:Destroy()
end

return App
