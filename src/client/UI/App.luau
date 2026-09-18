--!strict
-- Akar UI: ScreenGui + tombol atas (Catalog, Stores) + kolom samping kiri/kanan + panel katalog
-- + panel detail + panel keranjang + panel outfit tersimpan + dock (Undo/Redo/Reset + strip Wearing).
-- Tata letak layar utama mengikuti claude/Pedoman_Layout_CAC.md (kolom kanan: Saved Outfits, Emotes;
-- kolom kiri: Community Outfits, Outfit Loader). Kolom samping hanya tampil saat katalog tertutup.
--   local app = App.mount({ onItemActivated = function(item) ... end })  -- hook tambahan (log) saat kartu di-tap
-- Kartu: tap -> overlay TRY / BUY / ⓘ / 🛒. ⓘ & paste link -> panel detail. 🛒 di header -> panel keranjang.
--   app:toggleCatalog()   app:openDetail(id, "Asset")   app:openCart()   app:checkout()
--   app:openWardrobe()    app:closeWardrobe()
-- Saved Outfits dibuka dari kolom samping (katalog tertutup) -> menutupnya kembali ke layar utama,
-- bukan ke halaman menu katalog.
-- Panel keranjang & wardrobe menutupi isi katalog; hanya satu yang terbuka.
--   app.toast:show("Hello", "info")   app:destroy()

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
		_previewCard: Frame, -- kartu avatar SEKARANG (kolom kiri)
		_live: OutfitPreview.Handle,
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
		if refresh then
			refresh() -- clone ulang karakter (0,005 detik; makeup ikut sendiri)
		end
	end)
	table.insert(self._conns, { Disconnect = unsubscribe } :: any)

	-- Latar area preview (AvatarBackground) -> SEMUA ViewportFrame preview sekaligus.
	local unBackground = outfit:onBackground(function(bg)
		previews:setBackground(bg)
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

	refreshStrip()
	self:_refreshButtons()
	return self
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
	card.Visible = open
	card.Position = UDim2.fromOffset(L.previewX, L.previewY)
	card.Size = UDim2.fromOffset(L.previewW, L.previewH)
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
