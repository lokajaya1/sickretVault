--!strict
-- Panel katalog DUA TINGKAT (lihat claude/Pedoman_Layout_CAC.md "Layar KATALOG"):
--   1) halaman MENU kategori (mozaik CategoryMenu) -> tampil pertama saat katalog dibuka;
--   2) halaman DAFTAR ITEM: kotak cari + DUA baris tab bergaris bawah (baris 1 = grup mozaik,
--      baris 2 = chip All / Free / Limited lalu kategori grup aktif) + grid ItemCard,
--      plus tombol kembali ke menu. Chip filter -> controller:setFilter(grup, chip).
--   panel:showMenu()   panel:openGroup(group)   panel:page() -- "menu" | "list"
-- Posisi & ukuran dari Shared/Util/PanelLayout: layar lebar -> panel di kanan; ponsel tegak -> panel dari bawah.
-- Hanya MENAMPILKAN state CatalogController dan meneruskan aksi pemain ke controller.
--   local panel = CatalogPanel.new({ controller = catalog, parent = screenGui, onItemActivated = fn })
--   panel:setVisible(true)   panel:getLayout()   panel:destroy()
-- Tab "Wearing" (bila props.getWearing ada) menampilkan item yang sedang dipakai, bukan hasil katalog.
-- Kotak cari juga menerima link/ID item: Enter -> props.onLink(id, kind) (bukan pencarian).
-- Tap kartu -> overlay TRY / BUY / ⓘ / 🛒 di kartu itu (satu kartu saja); gulir / tutup panel -> overlay hilang.
-- Header punya tombol keranjang "🛒 n" (bila props.onOpenCart ada) di kiri tombol tutup: panel:setCartCount(n).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Categories = require(Shared.Config.Categories)
local CatalogMenu = require(Shared.Config.CatalogMenu)
local PanelLayout = require(Shared.Util.PanelLayout)
local ItemLink = require(Shared.Util.ItemLink)
local Tokens = require(script.Parent.Parent.Theme.Tokens)
local ItemCard = require(script.Parent.ItemCard)
local CategoryMenu = require(script.Parent.CategoryMenu)
local CartIcon = require(script.Parent.Parent.Util.CartIcon)

local SEARCH_DEBOUNCE = 0.6 -- detik setelah berhenti mengetik
local HEADER_H = 40
local GAP = Tokens.Space.S
local WEARING = "__wearing" -- kunci tab Wearing di _tabs (bukan kategori server)
local STATUS_H = 28
local STATUS_H_COMPACT = 20
local CART_BTN_W = 60
local BACK_W = 36

export type Props = {
	controller: any, -- CatalogController
	parent: Instance,
	onItemActivated: ((item: any) -> ())?, -- kartu di-tap (overlay dibuka)
	onTry: ((item: any) -> ())?,
	onBuy: ((item: any) -> ())?,
	onInfo: ((item: any) -> ())?, -- tombol ⓘ -> panel detail
	onCart: ((item: any) -> ())?, -- tombol 🛒 di kartu (tambah / buang dari keranjang)
	isInCart: ((item: any) -> boolean)?, -- true = tombol 🛒 kartu ditandai "sudah di keranjang"
	onOpenCart: (() -> ())?, -- tombol 🛒 di header (nil = tombol disembunyikan)
	onClose: (() -> ())?,
	isSelected: ((item: any) -> boolean)?, -- true = kartu diberi sorotan (item sedang dipakai)
	getWearing: (() -> { any })?, -- daftar item terpakai untuk tab Wearing (nil = tab tidak ditampilkan)
	-- link/ID ditempel di kotak cari lalu Enter; id = nil bila teks mirip link tapi tidak valid
	onLink: ((id: number?, kind: ("Asset" | "Bundle")?) -> ())?,
}

local CatalogPanel = {}
CatalogPanel.__index = CatalogPanel

export type CatalogPanel = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_grid: ScrollingFrame,
		_menu: CategoryMenu.CategoryMenu,
		_title: TextLabel,
		_back: TextButton,
		_tabBar: ScrollingFrame,
		_groupBar: ScrollingFrame,
		_groupTabs: { [string]: TextButton },
		_filterTabs: { [string]: TextButton },
		_tabScroll: number, -- posisi geser baris kedua (dipulihkan setelah render ulang)
		_page: "menu" | "list",
		_group: CatalogMenu.Group?,
		_hasError: boolean,
		_innerW: number,
		_innerH: number,
		_contentTop: number,
		_status: TextLabel,
		_retry: TextButton,
		_search: TextBox,
		_cartButton: TextButton,
		_tabs: { [string]: TextButton },
		_cards: { ItemCard.ItemCard },
		_conns: { RBXScriptConnection },
		_unsubscribe: () -> (),
		_searchToken: number,
		_lastCount: number,
		_wearing: boolean,
		_layout: PanelLayout.Layout,
	},
	CatalogPanel
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

local function textButton(text: string, props: { [string]: any }): TextButton
	local base = {
		Text = text,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		ZIndex = Tokens.ZIndex.Panel,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextButton", base, { corner(Tokens.Radius.Pill) })
end

-- Tab bergaris bawah (pola CAC): latar transparan; aktif = teks terang + garis aksen di bawahnya.
local function setTabActive(b: TextButton, active: boolean)
	b.TextColor3 = if active then Tokens.Color.Text else Tokens.Color.TextMuted
	local line = b:FindFirstChild("Line")
	if line then
		(line :: Frame).Visible = active
	end
end

-- Jalankan fungsi controller di thread baru (remote akan yield).
local function spawnCall(fn: (...any) -> ...any, ...: any)
	task.spawn(fn, ...)
end

function CatalogPanel.new(props: Props): CatalogPanel
	local ctl = props.controller

	local root: Frame = make("Frame", {
		Name = "CatalogPanel",
		AnchorPoint = Vector2.new(0, 0),
		BackgroundColor3 = Tokens.Color.Panel,
		BackgroundTransparency = Tokens.Transparency.Panel,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = Tokens.ZIndex.Panel,
		Parent = props.parent,
	}, {
		corner(Tokens.Radius.Large),
		make("UIPadding", {
			PaddingTop = UDim.new(0, Tokens.Space.M),
			PaddingBottom = UDim.new(0, Tokens.Space.M),
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
		}),
	})

	-- Header: judul + tombol tutup (posisi akhir diatur applyLayout)
	local title: TextLabel = make("TextLabel", {
		Name = "Title",
		Text = "Catalog",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(HEADER_H + CART_BTN_W + GAP), 0, HEADER_H),
		ZIndex = Tokens.ZIndex.Panel,
		Parent = root,
	})
	local close = textButton("X", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 4),
		Size = UDim2.fromOffset(32, 32),
		Parent = root,
	})
	-- Tombol keranjang (kiri tombol tutup); teks "🛒 n" diatur setCartCount
	local hasCart = props.onOpenCart ~= nil
	local cartButton = textButton("", {
		Name = "Cart",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(32 + GAP), 0, 4),
		Size = UDim2.fromOffset(CART_BTN_W, 32),
		Visible = hasCart,
		Parent = root,
	})

	-- Tombol kembali ke halaman menu kategori (hanya di halaman daftar item)
	local back = textButton("<", {
		Name = "Back",
		Position = UDim2.fromOffset(0, HEADER_H + GAP),
		Size = UDim2.fromOffset(BACK_W, Tokens.Size.SearchHeight),
		Visible = false,
		Parent = root,
	})

	-- Kotak cari
	local searchTop = HEADER_H + GAP
	local search: TextBox = make("TextBox", {
		Name = "Search",
		PlaceholderText = if props.onLink then "Search or paste item link/ID" else "Search catalog...",
		PlaceholderColor3 = Tokens.Color.TextMuted,
		Text = "",
		ClearTextOnFocus = false,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, searchTop),
		Size = UDim2.new(1, 0, 0, Tokens.Size.SearchHeight),
		ZIndex = Tokens.ZIndex.Panel,
		Parent = root,
	}, {
		corner(Tokens.Radius.Medium),
		make("UIPadding", { PaddingLeft = UDim.new(0, Tokens.Space.M), PaddingRight = UDim.new(0, Tokens.Space.M) }),
	})

	-- Dua baris tab yang bisa digeser: grup (atas) & kategori dalam grup (bawah)
	local conns: { RBXScriptConnection } = {}

	-- CATATAN (18 Sep 2026): AutomaticCanvasSize dihitung ulang setiap properti anak berubah
	-- (garis bawah tab aktif muncul/hilang) dan SELALU membuang posisi gulir. Karena itu canvas
	-- dihitung sendiri dari UIListLayout: lebarnya hanya berubah saat isi tab benar-benar berganti.
	local function tabStrip(name: string, top: number): ScrollingFrame
		local layout = make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.XS + 2),
		})
		local bar: ScrollingFrame = make("ScrollingFrame", {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, top),
			Size = UDim2.new(1, 0, 0, Tokens.Size.TabHeight + 6),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.None,
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 3,
			ZIndex = Tokens.ZIndex.Panel,
			Parent = root,
		}, { layout })
		local function fit()
			local w = layout.AbsoluteContentSize.X
			if math.abs(bar.CanvasSize.X.Offset - w) > 0.5 then
				bar.CanvasSize = UDim2.fromOffset(w, 0)
			end
		end
		table.insert(conns, layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit))
		fit()
		return bar
	end

	local groupsTop = searchTop + Tokens.Size.SearchHeight + GAP
	local groupBar: ScrollingFrame = tabStrip("GroupTabs", groupsTop)

	-- Tab kategori (geser horizontal)
	local tabsTop = groupsTop + Tokens.Size.TabHeight + 6 + GAP
	local tabBar: ScrollingFrame = tabStrip("Tabs", tabsTop)

	local tabs: { [string]: TextButton } = {}
	local groupTabs: { [string]: TextButton } = {}
	local self: CatalogPanel
	local function stripTab(name: string, label: string, order: number, parent: Instance, bold: boolean): TextButton
		local b = textButton(label, {
			Name = name,
			LayoutOrder = order,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, Tokens.Size.TabHeight),
			TextSize = if bold then Tokens.TextSize.Button else Tokens.TextSize.Body,
			TextColor3 = Tokens.Color.TextMuted,
			BackgroundTransparency = 1,
			Parent = parent,
		})
		make("UIPadding", {
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
			Parent = b,
		})
		make("Frame", {
			Name = "Line",
			BackgroundColor3 = Tokens.Color.Accent,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(1, 0, 0, 2),
			Visible = false,
			ZIndex = Tokens.ZIndex.Panel,
			Parent = b,
		})
		return b
	end
	local function tabButton(id: string, label: string, order: number): TextButton
		local b = stripTab("Tab_" .. id, label, order, tabBar, false)
		tabs[id] = b
		return b
	end
	-- Baris 2, paling kiri: chip filter se-grup (All / Free / Limited).
	local filterTabs: { [string]: TextButton } = {}
	for i, f in CatalogMenu.FILTERS do
		local b = stripTab("Flt_" .. f.id, f.label, i - #CatalogMenu.FILTERS - 1, tabBar, false)
		filterTabs[f.id] = b
		table.insert(
			conns,
			b.Activated:Connect(function()
				self:_setFilter(f.id)
			end)
		)
	end

	-- Baris 1: grup mozaik; selalu lengkap supaya bisa pindah grup tanpa kembali ke menu.
	for i, group in CatalogMenu.list do
		local b = stripTab("Group_" .. group.id, group.label, i, groupBar, true)
		groupTabs[group.id] = b
		table.insert(
			conns,
			b.Activated:Connect(function()
				self:openGroup(group)
			end)
		)
	end
	if props.getWearing then
		local b = tabButton(WEARING, "Wearing", 0)
		table.insert(
			conns,
			b.Activated:Connect(function()
				self:_setWearing(true)
			end)
		)
	end
	for i, cat in Categories.list do
		local b = tabButton(cat.id, cat.label, i)
		table.insert(
			conns,
			b.Activated:Connect(function()
				self:_setWearing(false)
				spawnCall(ctl.setCategory, ctl, cat.id)
			end)
		)
	end

	-- Grid item
	local gridTop = tabsTop + Tokens.Size.TabHeight + 6 + GAP
	local statusH = STATUS_H
	local grid: ScrollingFrame = make("ScrollingFrame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, gridTop),
		Size = UDim2.new(1, 0, 1, -gridTop - statusH),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ZIndex = Tokens.ZIndex.Panel,
		Parent = root,
	}, {
		make("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 2) }),
	})
	local gridLayout: UIGridLayout = make("UIGridLayout", {
		CellSize = UDim2.fromOffset(Tokens.Size.Card.X, Tokens.Size.Card.Y),
		CellPadding = UDim2.fromOffset(GAP, GAP),
		SortOrder = Enum.SortOrder.LayoutOrder, -- penting: default bisa urut Name
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = grid,
	})

	-- Status bawah + tombol coba lagi
	local status: TextLabel = make("TextLabel", {
		Name = "Status",
		Text = "",
		FontFace = Tokens.Font.Medium,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, -90, 0, statusH),
		ZIndex = Tokens.ZIndex.Panel,
		Parent = root,
	})
	local retry = textButton("Retry", {
		Name = "Retry",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(80, statusH - 4),
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		Visible = false,
		Parent = root,
	})

	-- Halaman menu kategori (mozaik). Tap kartu -> halaman daftar item grup itu.
	local menu = CategoryMenu.new({
		parent = root,
		onGroup = function(group)
			self:openGroup(group)
		end,
	})

	self = setmetatable({
		instance = root,
		_props = props,
		_grid = grid,
		_menu = menu,
		_title = title,
		_back = back,
		_tabBar = tabBar,
		_groupBar = groupBar,
		_groupTabs = groupTabs,
		_filterTabs = filterTabs,
		_tabScroll = 0,
		_page = "menu",
		_group = nil,
		_hasError = false,
		_innerW = 0,
		_innerH = 0,
		_contentTop = HEADER_H + GAP,
		_status = status,
		_retry = retry,
		_search = search,
		_cartButton = cartButton,
		_tabs = tabs,
		_cards = {},
		_conns = conns,
		_unsubscribe = function() end,
		_searchToken = 0,
		_lastCount = 0,
		_wearing = false,
		_layout = PanelLayout.compute(1280, 720),
	}, CatalogPanel)

	table.insert(
		conns,
		close.Activated:Connect(function()
			self:setVisible(false)
			if props.onClose then
				props.onClose()
			end
		end)
	)
	table.insert(
		conns,
		back.Activated:Connect(function()
			self:showMenu()
		end)
	)
	table.insert(
		conns,
		retry.Activated:Connect(function()
			spawnCall(ctl.retry, ctl)
		end)
	)
	table.insert(
		conns,
		cartButton.Activated:Connect(function()
			self:disarm()
			if props.onOpenCart then
				props.onOpenCart()
			end
		end)
	)

	-- Cari: Enter langsung, mengetik -> debounce
	local skipTextChange = false -- kotak dikosongkan oleh kode (setelah paste link) -> jangan cari
	local function submitSearch()
		self._searchToken += 1
		self:_setWearing(false) -- cari selalu di katalog
		spawnCall(ctl.setKeyword, ctl, search.Text)
	end
	table.insert(
		conns,
		search.FocusLost:Connect(function(enter: boolean)
			if not enter then
				return
			end
			-- Link / ID item -> coba pakai, kotak dikosongkan (tanpa memicu pencarian)
			local onLink = props.onLink
			if onLink and ItemLink.looksLikeLink(search.Text) then
				local id, kind = ItemLink.parse(search.Text)
				if id then
					skipTextChange = true
					search.Text = ""
				end
				self._searchToken += 1 -- batalkan pencarian yang tertunda
				onLink(id, kind)
				return
			end
			submitSearch()
		end)
	)
	table.insert(
		conns,
		search:GetPropertyChangedSignal("Text"):Connect(function()
			self._searchToken += 1
			if skipTextChange then
				skipTextChange = false
				return
			end
			if props.onLink and ItemLink.looksLikeLink(search.Text) then
				return -- sedang menempel link/ID: jangan cari
			end
			local token = self._searchToken
			task.delay(SEARCH_DEBOUNCE, function()
				if token == self._searchToken then
					submitSearch()
				end
			end)
		end)
	)

	-- Baris tab digeser pemain -> ingat posisinya (Roblox mengembalikan ke 0 saat isi berubah).
	table.insert(
		conns,
		tabBar:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			local x = tabBar.CanvasPosition.X
			if x > 0 then
				self._tabScroll = x
			end
		end)
	)
	-- Isi tab berubah -> Roblox menghitung ulang canvas DAN membuang posisi gulir; kembalikan.
	table.insert(
		conns,
		tabBar:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
			self:_restoreTabScroll()
		end)
	)

	-- Infinite scroll (+ gulir menutup overlay kartu)
	table.insert(
		conns,
		grid:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			self:disarm()
			self:_maybeLoadMore()
		end)
	)

	-- Posisi, ukuran & kolom grid mengikuti ukuran layar (lihat PanelLayout)
	local host = props.parent :: GuiBase2d
	local function applyLayout()
		local size = host.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then
			return
		end
		local L = PanelLayout.compute(size.X, size.Y)
		self._layout = L
		root.Position = UDim2.fromOffset(L.x, L.y)
		root.Size = UDim2.fromOffset(L.w, L.h)
		gridLayout.CellSize = UDim2.fromOffset(L.cellW, L.cellH)

		-- Header: normal = judul di baris sendiri; compact = judul disembunyikan, cari + tutup satu baris.
		local c = L.compact
		local sh = Tokens.Size.SearchHeight
		title.Visible = not c
		close.Position = if c then UDim2.fromScale(1, 0) else UDim2.new(1, 0, 0, 4)
		close.Size = if c then UDim2.fromOffset(sh, sh) else UDim2.fromOffset(32, 32)
		local closeW = if c then sh else 32
		cartButton.Position = if c then UDim2.new(1, -(closeW + GAP), 0, 0) else UDim2.new(1, -(closeW + GAP), 0, 4)
		cartButton.Size = if c then UDim2.fromOffset(CART_BTN_W, sh) else UDim2.fromOffset(CART_BTN_W, 32)
		local sTop = if c then 0 else HEADER_H + GAP
		-- Tombol kembali di kiri kotak cari; kotak cari menyusut selebar tombol itu.
		back.Position = UDim2.fromOffset(0, sTop)
		back.Size = UDim2.fromOffset(BACK_W, sh)
		local leftW = BACK_W + GAP
		search.Position = UDim2.fromOffset(leftW, sTop)
		-- compact: cari + (keranjang) + tutup satu baris
		local rightW = sh + GAP + (if hasCart then CART_BTN_W + GAP else 0)
		search.Size = if c then UDim2.new(1, -(rightW + leftW), 0, sh) else UDim2.new(1, -leftW, 0, sh)
		local grTop = sTop + sh + (if c then 6 else GAP)
		groupBar.Position = UDim2.fromOffset(0, grTop)
		local tTop = grTop + Tokens.Size.TabHeight + 6 + (if c then 2 else 4)
		tabBar.Position = UDim2.fromOffset(0, tTop)
		local gTop = tTop + Tokens.Size.TabHeight + 6 + (if c then 4 else GAP)
		local stH = if c then STATUS_H_COMPACT else STATUS_H
		grid.Position = UDim2.fromOffset(0, gTop)
		grid.Size = UDim2.new(1, 0, 1, -gTop - stH)
		status.Size = UDim2.new(1, -90, 0, stH)
		status.TextSize = if c then Tokens.TextSize.Caption else Tokens.TextSize.Body
		retry.Size = UDim2.fromOffset(80, stH - 4)

		-- Area isi untuk halaman menu kategori (di bawah judul / tombol tutup yang mengambang).
		self._innerW = L.w - Tokens.Space.M * 2
		self._innerH = L.h - Tokens.Space.M * 2
		self._contentTop = if c then sh + 4 else HEADER_H + GAP
		self:_applyPage()
	end
	applyLayout()
	table.insert(conns, host:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout))

	self._unsubscribe = ctl:onChanged(function(state)
		self:_render(state)
	end)
	self:_render(ctl:getState())
	return self
end

function CatalogPanel._maybeLoadMore(self: CatalogPanel)
	local grid = self._grid
	if not self.instance.Visible or self._wearing or self._page ~= "list" then
		return
	end
	local state = self._props.controller:getState()
	if state.loading or not state.hasMore or state.error or state.page == 0 then
		return
	end
	local bottom = grid.CanvasPosition.Y + grid.AbsoluteWindowSize.Y
	if bottom >= grid.AbsoluteCanvasSize.Y - Tokens.LoadMoreThreshold then
		spawnCall(self._props.controller.loadMore, self._props.controller)
	end
end

-- Masuk/keluar mode Wearing lalu gambar ulang.
function CatalogPanel._setWearing(self: CatalogPanel, on: boolean)
	if self._wearing == on then
		return
	end
	self._wearing = on
	self._lastCount = 0
	self._grid.CanvasPosition = Vector2.zero
	self:_render(self._props.controller:getState())
end

-- Tutup overlay semua kartu.
function CatalogPanel.disarm(self: CatalogPanel)
	for _, card in self._cards do
		if card:isArmed() then
			card:setArmed(false)
		end
	end
end

-- Buat kartu baru; aksi overlay diteruskan ke props.
function CatalogPanel._newCard(self: CatalogPanel, item: any, order: number): ItemCard.ItemCard
	local props = self._props
	local card: ItemCard.ItemCard
	local function call(fn: ((any) -> ())?, closeAfter: boolean): (any) -> ()
		return function(it)
			if closeAfter then
				card:setArmed(false)
			end
			if fn then
				fn(it)
			end
		end
	end
	card = ItemCard.new({
		item = item,
		layoutOrder = order,
		onActivated = function(it)
			self:disarm()
			card:setArmed(true)
			if props.onItemActivated then
				props.onItemActivated(it)
			end
		end,
		onDismiss = function()
			card:setArmed(false)
		end,
		onTry = call(props.onTry, false), -- overlay tetap terbuka: TRY <-> REMOVE
		onBuy = call(props.onBuy, true),
		onInfo = call(props.onInfo, true),
		onCart = if props.onCart
			then function(it)
				(props.onCart :: any)(it)
				card:setInCart(self:_isInCart(it)) -- overlay tetap terbuka: 🛒+ <-> 🛒✓
			end
			else nil,
	})
	return card
end

-- Kartu: pakai ulang yang ada, buat bila kurang, hapus kelebihan
function CatalogPanel._renderCards(self: CatalogPanel, items: { any })
	local cards = self._cards
	for i, item in items do
		local card = cards[i]
		if card == nil then
			card = self:_newCard(item, i)
			card.instance.Parent = self._grid
			cards[i] = card
		elseif card.item ~= item then
			card:setItem(item)
		end
		card:setSelected(self:_isSelected(item))
		card:setInCart(self:_isInCart(item))
	end
	for i = #cards, #items + 1, -1 do
		cards[i]:destroy()
		cards[i] = nil
	end
end

function CatalogPanel._render(self: CatalogPanel, state: any)
	if self._page == "menu" then
		return -- halaman mozaik: tidak ada grid yang perlu digambar
	end
	-- Tab aktif
	local active: string? = if self._wearing then WEARING else self._props.controller:activeChip()
	for id, b in self._tabs do
		setTabActive(b, id == active)
	end
	for id, b in self._filterTabs do
		setTabActive(b, id == active)
	end

	if self._wearing then
		local getWearing = self._props.getWearing
		local items = if getWearing then getWearing() else {}
		self:_renderCards(items)
		self._status.Text = if #items == 0 then "Nothing worn yet" else ("%d items worn"):format(#items)
		self._status.TextColor3 = Tokens.Color.TextMuted
		self._hasError = false
		self._retry.Visible = false
		return
	end

	-- Daftar baru (reset) -> gulir ke atas
	if #state.items < self._lastCount then
		self._grid.CanvasPosition = Vector2.zero
	end
	self._lastCount = #state.items

	self:_renderCards(state.items)

	-- Status
	local text = ""
	if state.error then
		text = if state.error == "RATE_LIMITED" then "Too fast, wait a moment" else "Failed to load"
	elseif state.loading then
		text = "Loading..."
	elseif #state.items == 0 and state.page > 0 then
		text = "No items found"
	elseif not state.hasMore and #state.items > 0 then
		text = ("%d items"):format(#state.items)
	end
	self._status.Text = text
	self._status.TextColor3 = if state.error then Tokens.Color.Warning else Tokens.Color.TextMuted
	self._hasError = state.error ~= nil
	self._retry.Visible = self._hasError and self._page == "list"

	-- Isi belum memenuhi layar? muat halaman berikutnya setelah layout diperbarui
	if not state.loading and state.hasMore and not state.error then
		task.defer(function()
			self:_maybeLoadMore()
		end)
	end
end

function CatalogPanel._isSelected(self: CatalogPanel, item: any): boolean
	local fn = self._props.isSelected
	return fn ~= nil and fn(item) == true
end

function CatalogPanel._isInCart(self: CatalogPanel, item: any): boolean
	local fn = self._props.isInCart
	return fn ~= nil and fn(item) == true
end

-- Keranjang berubah -> angka di tombol header & tanda 🛒 di kartu.
function CatalogPanel.setCartCount(self: CatalogPanel, count: number)
	local color = if count > 0 then Tokens.Color.Text else Tokens.Color.TextMuted
	CartIcon.apply(self._cartButton, "cart", color, tostring(count))
	for _, card in self._cards do
		card:setInCart(self:_isInCart(card.item))
	end
end

-- Outfit berubah: tab Wearing -> gambar ulang daftar; tab lain -> perbarui sorotan kartu.
function CatalogPanel.refreshSelection(self: CatalogPanel)
	if self._wearing then
		self:_render(self._props.controller:getState())
		return
	end
	for _, card in self._cards do
		card:setSelected(self:_isSelected(card.item))
	end
end

-- Halaman aktif: "menu" (mozaik kategori) atau "list" (daftar item).
function CatalogPanel.page(self: CatalogPanel): "menu" | "list"
	return self._page
end

-- Kembali ke halaman menu kategori (tombol <, atau saat panel baru dibuka).
function CatalogPanel.showMenu(self: CatalogPanel)
	self:disarm()
	self._page = "menu"
	self._group = nil
	self:_applyPage()
end

-- Buka halaman daftar item sebuah grup mozaik; tab = kategori milik grup itu.
function CatalogPanel.openGroup(self: CatalogPanel, group: CatalogMenu.Group)
	if group.soon then
		return -- grup belum punya isi (kartu mozaik hanya berkedip "Soon")
	end
	self:disarm()
	self._page = "list"
	self._group = group
	self._wearing = false
	self._lastCount = 0
	self._grid.CanvasPosition = Vector2.zero
	self._tabScroll = 0 -- grup baru: baris kedua mulai dari kiri lagi
	self._tabBar.CanvasPosition = Vector2.zero
	self._groupBar.CanvasPosition = Vector2.zero
	self:_applyPage()
	spawnCall(self._props.controller.setFilter, self._props.controller, group.id, "all")
end

-- Chip All / Free / Limited pada grup yang sedang dibuka.
function CatalogPanel._setFilter(self: CatalogPanel, filterId: string)
	local group = self._group
	if group == nil then
		return
	end
	self:disarm()
	self._wearing = false
	self._lastCount = 0
	self._grid.CanvasPosition = Vector2.zero
	spawnCall(self._props.controller.setFilter, self._props.controller, group.id, filterId)
end

-- Tampilkan bagian yang sesuai halaman aktif (dipanggil applyLayout & saat halaman berganti).
function CatalogPanel._applyPage(self: CatalogPanel)
	local isMenu = self._page == "menu"
	local group = self._group
	self._menu:setVisible(isMenu)
	self._search.Visible = not isMenu
	self._back.Visible = not isMenu
	self._tabBar.Visible = not isMenu
	self._groupBar.Visible = not isMenu
	for gid, b in self._groupTabs do
		setTabActive(b, group ~= nil and gid == group.id)
	end
	self._grid.Visible = not isMenu
	self._status.Visible = not isMenu
	self._retry.Visible = not isMenu and self._hasError
	self._title.Text = if isMenu or group == nil then "Catalog" else group.label

	if isMenu then
		self._menu:setArea(0, self._contentTop, self._innerW, self._innerH - self._contentTop)
		return
	end

	-- Chip filter berlaku di semua grup -> selalu tampil di halaman daftar item.
	for _, b in self._filterTabs do
		b.Visible = true
	end

	-- Tab: hanya kategori milik grup ini (Wearing tetap di paling kiri bila ada).
	local order: { [string]: number } = {}
	for i, id in CatalogMenu.categoryIds(group :: CatalogMenu.Group) do
		order[id] = i
	end
	for id, b in self._tabs do
		if id == WEARING then
			b.Visible = true
			b.LayoutOrder = 0
		else
			local n = order[id]
			b.Visible = n ~= nil
			b.LayoutOrder = n or 999
		end
	end
	self:_render(self._props.controller:getState())
	self:_restoreTabScroll()
end

-- Kembalikan posisi geser baris tab setelah tata letaknya dihitung ulang.
-- Dicoba beberapa kali: ukuran canvas kadang baru selesai dihitung satu-dua frame kemudian,
-- dan setiap perhitungan ulang membuang posisi gulir.
function CatalogPanel._restoreTabScroll(self: CatalogPanel)
	local want = self._tabScroll
	if want <= 0 then
		return
	end
	local function put()
		if self.instance.Parent and self._page == "list" and self._tabScroll == want then
			local bar = self._tabBar
			local maxX = math.max(0, bar.AbsoluteCanvasSize.X - bar.AbsoluteWindowSize.X)
			bar.CanvasPosition = Vector2.new(math.min(want, maxX), 0)
		end
	end
	task.defer(put)
	task.delay(0.05, put)
	task.delay(0.15, put)
end

function CatalogPanel.setVisible(self: CatalogPanel, visible: boolean)
	self.instance.Visible = visible
	if not visible then
		-- ditutup -> dibuka lagi selalu mulai dari halaman menu kategori
		self:disarm()
		self._page = "menu"
		self._group = nil
	else
		self:_applyPage()
	end
end

-- Tata letak terakhir (piksel GUI), dipakai kamera try-on untuk mencari area kosong.
function CatalogPanel.getLayout(self: CatalogPanel): PanelLayout.Layout
	return self._layout
end

function CatalogPanel.isVisible(self: CatalogPanel): boolean
	return self.instance.Visible
end

function CatalogPanel.destroy(self: CatalogPanel)
	self._unsubscribe()
	for _, c in self._conns do
		c:Disconnect()
	end
	for _, card in self._cards do
		card:destroy()
	end
	self._menu:destroy()
	self.instance:Destroy()
end

return CatalogPanel
