--!strict
-- Akar UI: ScreenGui + tombol atas (Catalog, Stores) + panel katalog + panel detail + panel keranjang
-- + dock (Undo/Redo/Reset + strip Wearing).
--   local app = App.mount({ onItemActivated = function(item) ... end })  -- hook tambahan (log) saat kartu di-tap
-- Kartu: tap -> overlay TRY / BUY / ⓘ / 🛒. ⓘ & paste link -> panel detail. 🛒 di header -> panel keranjang.
--   app:toggleCatalog()   app:openDetail(id, "Asset")   app:openCart()   app:checkout()
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
local CatalogController = require(script.Parent.Parent.Controllers.CatalogController)
local OutfitController = require(script.Parent.Parent.Controllers.OutfitController)
local DetailController = require(script.Parent.Parent.Controllers.DetailController)
local CartController = require(script.Parent.Parent.Controllers.CartController)
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
		toast: Toast.Toast,
		actions: ActionBar.ActionBar,
		strip: WornStrip.WornStrip,
		camera: TryOnCamera.TryOnCamera,
		_catalogButton: TextButton,
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
		toast = toast,
		actions = actions,
		strip = strip,
		camera = camera,
		_catalogButton = catalogButton,
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
	end)
	table.insert(self._conns, { Disconnect = unsubscribe } :: any)
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
		self.detail:close() -- katalog ditutup (X / tombol / C) -> detail & keranjang ikut tertutup
		self.cartPanel:setOpen(false)
	end
	self._catalogButton.BackgroundColor3 = if open then Tokens.Color.Accent else Tokens.Color.Panel
	self._catalogButton.BackgroundTransparency = if open then 0 else Tokens.Transparency.Panel
	-- Layar pendek (ponsel mendatar) + katalog terbuka: panel setinggi layar -> tombol atas disembunyikan
	-- (tutup lewat X). Dock (tombol aksi + strip) hanya tampil saat katalog terbuka, di kiri bawah.
	local L = self.panel:getLayout()
	self._topBar.Visible = not (open and L.compact)
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
	self.cartPanel:setOpen(true)
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
	self.detailPanel:destroy()
	self.detail:close()
	self.panel:destroy()
	self.toast:destroy()
	self.actions:destroy()
	self.strip:destroy()
	self.gui:Destroy()
end

return App
