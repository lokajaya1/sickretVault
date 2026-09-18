--!strict
-- Panel katalog DUA TINGKAT (lihat claude/Pedoman_Layout_CAC.md "Layar KATALOG"):
--   1) halaman MENU kategori (mozaik CategoryMenu) -> tampil pertama saat katalog dibuka;
--   2) halaman DAFTAR ITEM: kotak cari + DUA baris tab bergaris bawah (baris 1 = grup mozaik,
--      baris 2 = chip All / Free / Limited lalu kategori grup aktif) + grid ItemCard,
--      plus tombol kembali ke menu. Chip filter -> controller:setFilter(grup, chip).
--   panel:showMenu()   panel:openGroup(group)   panel:page() -- "menu" | "list"
--   panel:openCreator("94E", "Group")  -- hasil satu pencipta (#17d): tanpa grup, tanpa chip tipe
-- Posisi & ukuran dari Shared/Util/PanelLayout: layar lebar -> panel di kanan; ponsel tegak -> panel dari bawah.
-- Hanya MENAMPILKAN state CatalogController dan meneruskan aksi pemain ke controller.
--   local panel = CatalogPanel.new({ controller = catalog, parent = screenGui, onItemActivated = fn })
--   panel:setVisible(true)   panel:getLayout()   panel:destroy()
-- Tab "Wearing" (bila props.getWearing ada) menampilkan item yang sedang dipakai, bukan hasil katalog.
-- Kotak cari juga menerima link/ID item: Enter -> props.onLink(id, kind) (bukan pencarian).
-- Tap kartu -> overlay TRY / BUY / ⓘ / 🛒 di kartu itu (satu kartu saja); gulir / tutup panel -> overlay hilang.
-- Header punya tombol keranjang "🛒 n" (bila props.onOpenCart ada) di kiri tombol tutup: panel:setCartCount(n).
-- Di ujung kanan kotak cari ada tombol "Search Options" (#17e): popover melayang berisi sort,
-- rentang harga, creator, dan sakelar off-sale. Ikonnya digambar dari Frame, bukan glyph font
-- (pelajaran #25 no. 3). Klik di luar popover = tutup.

local TweenService = game:GetService("TweenService")

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
local TAB_HOLD_SECONDS = 0.5 -- lama posisi geser baris tab dijaga setelah isi berubah
local OPT_W = 260 -- lebar popover "Search Options"
local OPT_HEAD_H = 26 -- judul di dalam popover
local OPT_FOOT_H = 34 -- baris tombol Reset / Apply
local OPT_SLIDE = 8 -- jarak melorot popover saat dibuka (piksel)
-- Tipe pencipta yang bisa dipilih di popover. "All" = properti CreatorType TIDAK diset:
-- Enum.CreatorTypeFilter tidak punya anggota yang berarti "semua" (spike 19 Sep 2026 tes 14).
local CREATOR_KINDS = { { label = "All" }, { label = "User", kind = "User" }, { label = "Group", kind = "Group" } }

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

-- Keadaan popover yang BELUM diterapkan. Dipisah dari state controller supaya mengetik di kotak
-- Min tidak langsung memicu pencarian (tiga ketikan = tiga pencarian beruntun = HTTP 429, #17b).
type OptionsDraft = {
	sort: string,
	minPrice: number?,
	maxPrice: number?,
	includeOffSale: boolean,
	creatorName: string?,
	creatorType: string?,
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
		_creatorName: string?,
		_back: TextButton,
		_tabBar: ScrollingFrame,
		_groupBar: ScrollingFrame,
		_groupTabs: { [string]: TextButton },
		_filterTabs: { [string]: TextButton },
		_groupScroll: number, -- posisi geser baris grup (baris pertama)
		_groupHoldUntil: number,
		_tabHoldUntil: number, -- os.clock() sampai kapan posisi geser dijaga (lihat _keepTabScroll)
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
		_optButton: TextButton, -- pemicu popover "Search Options"
		_optPanel: Frame,
		_optBody: ScrollingFrame, -- isi popover (diisi langkah 7b)
		_optScrim: TextButton, -- penangkap klik di luar popover
		_optOpen: boolean,
		_optSortRows: { [string]: TextButton },
		_optMin: TextBox,
		_optMax: TextBox,
		_optPresets: { TextButton },
		_optOffSale: TextButton,
		_optCreator: TextBox,
		_optCreatorChips: { TextButton },
		_optPos: UDim2, -- posisi akhir popover (dihitung applyLayout); animasi berangkat dari atasnya
		_draft: OptionsDraft,
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

-- Chip cepat rentang harga: di ponsel mengetik angka itu repot, jadi yang sering dipakai disiapkan.
-- `max` nil = tanpa batas atas, `min` nil = tanpa batas bawah.
local PRICE_PRESETS = {
	{ label = "Free", min = 0, max = 0 },
	{ label = "<100", max = 99 },
	{ label = "100-500", min = 100, max = 500 },
	{ label = "500+", min = 500 },
}

-- Angka dari kotak Min/Max: kosong / ngawur / negatif -> tidak ada batas.
local function draftPrice(text: string): number?
	local n = tonumber(text)
	if n == nil or n ~= n or n < 0 then
		return nil
	end
	return math.floor(n)
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

	-- Tombol "Search Options" di ujung kanan kotak cari (#17e).
	local optButton: TextButton = make("TextButton", {
		Name = "OptButton",
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		Position = UDim2.new(1, -Tokens.Size.SearchHeight, 0, searchTop),
		Size = UDim2.fromOffset(Tokens.Size.SearchHeight, Tokens.Size.SearchHeight),
		Visible = false,
		ZIndex = Tokens.ZIndex.Panel,
		Parent = root,
	}, { corner(Tokens.Radius.Medium) })

	-- Ikon tiga garis bergeser ("sliders"), DIGAMBAR: BuilderSans tidak punya glyph yang cocok dan
	-- assetId ikon belum diverifikasi (pelajaran #25 no. 3). Warnanya diubah saat saringan aktif.
	local lineW = { 15, 11, 15 }
	local knobX = { 8, 2, 4 }
	for i = 1, 3 do
		local y = 11 + (i - 1) * 7
		make("Frame", {
			Name = "OptLine" .. tostring(i),
			BackgroundColor3 = Tokens.Color.Text,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(11, y),
			Size = UDim2.fromOffset(lineW[i], 2),
			ZIndex = Tokens.ZIndex.Panel + 1,
			Parent = optButton,
		}, { corner(Tokens.Radius.Pill) })
		make("Frame", {
			Name = "OptKnob" .. tostring(i),
			BackgroundColor3 = Tokens.Color.Text,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(11 + knobX[i], y - 2),
			Size = UDim2.fromOffset(6, 6),
			ZIndex = Tokens.ZIndex.Panel + 2,
			Parent = optButton,
		}, { corner(Tokens.Radius.Pill) })
	end

	-- Penangkap klik di luar popover. `Active = true` menyedot drag supaya tidak diteruskan ke grid
	-- maupun kamera dunia di belakang panel (pelajaran #25 no. 1).
	local optScrim: TextButton = make("TextButton", {
		Name = "OptScrim",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = true,
		Visible = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = Tokens.ZIndex.Popup - 1,
		Parent = root,
	})

	local optPanel: Frame = make("Frame", {
		Name = "OptPanel",
		Active = true,
		-- Uji Studio 19 Sep 2026: ZIndex-nya SEHAT (Z=20 vs Grid/Tabs Z=10, ZIndexBehavior Sibling;
		-- dipaksa merah pekat lewat Command Bar -> menutupi kartu & tab sepenuhnya). Yang salah
		-- KONTRAS: Color.Panel di atas panel katalog yang juga Color.Panel = batasnya hilang, dan
		-- kartu di sekelilingnya terbaca seolah menembus. Jadi permukaannya dibuat LEBIH GELAP dari
		-- panel, pekat penuh, dan yang memisahkan adalah tepi emasnya.
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Visible = false,
		Size = UDim2.fromOffset(OPT_W, 200),
		ZIndex = Tokens.ZIndex.Popup,
		Parent = root,
	}, {
		corner(Tokens.Radius.Medium),
		make("UIStroke", {
			Color = Tokens.Color.Stroke,
			Thickness = 1,
			Transparency = 0.35, -- lebih tegas dari Transparency.Stroke (0.85): ini satu-satunya batas
		}),
	})

	make("TextLabel", {
		Name = "OptTitle",
		Text = "Search Options",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(Tokens.Space.M, 0),
		Size = UDim2.new(1, -Tokens.Space.M * 2, 0, OPT_HEAD_H),
		ZIndex = Tokens.ZIndex.Popup + 1,
		Parent = optPanel,
	})

	-- Isi popover digulir: di landscape ponsel tinggi panel bisa lebih pendek daripada isinya.
	local optBody: ScrollingFrame = make("ScrollingFrame", {
		Name = "OptBody",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Tokens.Color.TextMuted,
		CanvasSize = UDim2.fromOffset(0, 0),
		-- Isinya lebih tinggi daripada popover di landscape ponsel. Posisi gulir TIDAK perlu dijaga
		-- di sini (beda dengan baris tab, catatan 18 Sep 2026), jadi AutomaticCanvasSize aman.
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(Tokens.Space.M, OPT_HEAD_H),
		Size = UDim2.new(1, -Tokens.Space.M * 2, 1, -(OPT_HEAD_H + OPT_FOOT_H)),
		ZIndex = Tokens.ZIndex.Popup + 1,
		Parent = optPanel,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.XS),
		}),
	})

	local optReset = textButton("Reset", {
		Name = "OptReset",
		TextSize = Tokens.TextSize.Caption,
		Position = UDim2.new(0, Tokens.Space.M, 1, -OPT_FOOT_H + 2),
		Size = UDim2.new(0.4, -Tokens.Space.M, 0, OPT_FOOT_H - 8),
		ZIndex = Tokens.ZIndex.Popup + 1,
		Parent = optPanel,
	})
	local optApply = textButton("Apply", {
		Name = "OptApply",
		TextSize = Tokens.TextSize.Caption,
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		Position = UDim2.new(0.42, 0, 1, -OPT_FOOT_H + 2),
		Size = UDim2.new(0.58, -Tokens.Space.M, 0, OPT_FOOT_H - 8),
		ZIndex = Tokens.ZIndex.Popup + 1,
		Parent = optPanel,
	})

	-- Isi popover (#17e). Kontrolnya hanya menulis ke draft; `self` belum ada di sini, jadi
	-- sambungannya dipasang di bawah bersama tombol Apply.
	local function optLabel(text: string, order: number)
		make("TextLabel", {
			Name = "OptLabel" .. tostring(order),
			Text = text,
			FontFace = Tokens.Font.Bold,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 16),
			ZIndex = Tokens.ZIndex.Popup + 1,
			Parent = optBody,
		})
	end

	local function optRow(name: string, order: number, height: number): Frame
		return make("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, height),
			ZIndex = Tokens.ZIndex.Popup + 1,
			Parent = optBody,
		})
	end

	local function optBox(name: string, placeholder: string, holder: Instance): TextBox
		return make("TextBox", {
			Name = name,
			PlaceholderText = placeholder,
			PlaceholderColor3 = Tokens.Color.TextMuted,
			Text = "",
			ClearTextOnFocus = false,
			FontFace = Tokens.Font.Regular,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BackgroundTransparency = Tokens.Transparency.PanelRaised,
			BorderSizePixel = 0,
			ZIndex = Tokens.ZIndex.Popup + 1,
			Parent = holder,
		}, {
			corner(Tokens.Radius.Small),
			make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
		})
	end

	optLabel("Sort by", 1)
	local optSortRows: { [string]: TextButton } = {}
	local sortList: { any } = if type(ctl.SORT_OPTIONS) == "table" then ctl.SORT_OPTIONS else {}
	for i, entry in sortList do
		optSortRows[entry.key] = make("TextButton", {
			Name = "OptSort_" .. tostring(entry.key),
			Text = entry.label,
			FontFace = Tokens.Font.Regular,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundTransparency = 1,
			AutoButtonColor = true,
			LayoutOrder = 1 + i,
			Size = UDim2.new(1, 0, 0, 20),
			ZIndex = Tokens.ZIndex.Popup + 1,
			Parent = optBody,
		}, { make("UIPadding", { PaddingLeft = UDim.new(0, 8) }) })
	end

	optLabel("Price (R$)", 7)
	local moneyRow = optRow("OptPriceRow", 8, 26)
	local optMin = optBox("OptMin", "Min", moneyRow)
	optMin.Position = UDim2.fromScale(0, 0)
	optMin.Size = UDim2.new(0.5, -3, 1, 0)
	local optMax = optBox("OptMax", "Max", moneyRow)
	optMax.Position = UDim2.new(0.5, 3, 0, 0)
	optMax.Size = UDim2.new(0.5, -3, 1, 0)

	local presetRow = optRow("OptPricePresets", 9, 22)
	local optPresets: { TextButton } = {}
	local presetW = 1 / #PRICE_PRESETS
	for i, preset in PRICE_PRESETS do
		optPresets[i] = textButton(preset.label, {
			Name = "OptPreset" .. tostring(i),
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.TextMuted,
			Position = UDim2.new(presetW * (i - 1), 2, 0, 0),
			Size = UDim2.new(presetW, -4, 1, 0),
			ZIndex = Tokens.ZIndex.Popup + 1,
			Parent = presetRow,
		})
	end

	local offRow = optRow("OptOffSaleRow", 10, 26)
	make("TextLabel", {
		Name = "OptOffSaleLabel",
		Text = "Include off sale",
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -60, 1, 0),
		ZIndex = Tokens.ZIndex.Popup + 1,
		Parent = offRow,
	})
	local optOffSale = textButton("OFF", {
		Name = "OptOffSale",
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		Position = UDim2.new(1, -56, 0, 1),
		Size = UDim2.fromOffset(56, 24),
		ZIndex = Tokens.ZIndex.Popup + 1,
		Parent = offRow,
	})

	-- Creator: nama + tipe. Mengisinya melepas kategori & grup (mode creator #26) supaya SEMUA tipe
	-- karyanya muncul; nama ngawur memberi 0 item, bukan daftar item gratis bawaan (spike tes 15e).
	optLabel("Creator", 11)
	local creatorRow = optRow("OptCreatorRow", 12, 26)
	local optCreator = optBox("OptCreator", "Creator name", creatorRow)
	optCreator.Position = UDim2.fromScale(0, 0)
	optCreator.Size = UDim2.fromScale(1, 1)

	local kindRow = optRow("OptCreatorKinds", 13, 22)
	local optCreatorChips: { TextButton } = {}
	local kindW = 1 / #CREATOR_KINDS
	for i, kind in CREATOR_KINDS do
		optCreatorChips[i] = textButton(kind.label, {
			Name = "OptKind" .. tostring(i),
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.TextMuted,
			Position = UDim2.new(kindW * (i - 1), 2, 0, 0),
			Size = UDim2.new(kindW, -4, 1, 0),
			ZIndex = Tokens.ZIndex.Popup + 1,
			Parent = kindRow,
		})
	end

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
				self:_keepTabScroll()
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
		_creatorName = nil,
		_back = back,
		_tabBar = tabBar,
		_groupBar = groupBar,
		_groupTabs = groupTabs,
		_filterTabs = filterTabs,
		_tabScroll = 0,
		_tabHoldUntil = 0,
		_groupScroll = 0,
		_groupHoldUntil = 0,
		_page = "menu",
		_group = nil,
		_hasError = false,
		_innerW = 0,
		_innerH = 0,
		_contentTop = HEADER_H + GAP,
		_status = status,
		_retry = retry,
		_search = search,
		_optButton = optButton,
		_optPanel = optPanel,
		_optBody = optBody,
		_optScrim = optScrim,
		_optOpen = false,
		_optSortRows = optSortRows,
		_optMin = optMin,
		_optMax = optMax,
		_optPresets = optPresets,
		_optOffSale = optOffSale,
		_optCreator = optCreator,
		_optCreatorChips = optCreatorChips,
		_optPos = UDim2.fromOffset(0, 0),
		_draft = { sort = "Relevance", includeOffSale = false },
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
			if os.clock() < self._tabHoldUntil then
				return -- sedang dijaga: perubahan dari tata letak, bukan dari pemain
			end
			self._tabScroll = tabBar.CanvasPosition.X
		end)
	)

	table.insert(
		conns,
		groupBar:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			if os.clock() < self._groupHoldUntil then
				return
			end
			self._groupScroll = groupBar.CanvasPosition.X
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
		-- Tombol opsi menempel di ujung kanan BARIS KOTAK CARI; di compact baris itu juga berisi
		-- keranjang & tutup, jadi ia bergeser ke kiri sebanyak rightW.
		local optRight = if c then rightW else 0
		optButton.Position = UDim2.new(1, -(optRight + sh), 0, sTop)
		optButton.Size = UDim2.fromOffset(sh, sh)
		local searchRight = leftW + optRight + sh + GAP
		search.Size = UDim2.new(1, -searchRight, 0, sh)
		-- Popover menggantung di bawah tombolnya, rata kanan. Lebar & tinggi DIJEPIT ke ukuran panel:
		-- di landscape ponsel panelnya bisa lebih sempit/pendek daripada popover bawaan.
		local optTop = sTop + sh + 4
		local optW = math.min(OPT_W, math.max(160, L.w - Tokens.Space.M * 2))
		local optH = math.max(90, math.min(240, L.h - optTop - GAP))
		optPanel.Position = UDim2.new(1, -(optRight + optW), 0, optTop)
		optPanel.Size = UDim2.fromOffset(optW, optH)
		self._optPos = optPanel.Position -- titik akhir animasi; layar bisa berubah ukuran kapan saja
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

	table.insert(
		conns,
		optButton.Activated:Connect(function()
			self:_setOptionsOpen(not self._optOpen)
		end)
	)
	table.insert(
		conns,
		optScrim.Activated:Connect(function()
			self:_setOptionsOpen(false)
		end)
	)
	table.insert(
		conns,
		optReset.Activated:Connect(function()
			self:_setOptionsOpen(false)
			spawnCall(ctl.clearOptions, ctl)
		end)
	)
	for key, row in optSortRows do
		local pick = key
		table.insert(
			conns,
			row.Activated:Connect(function()
				self._draft.sort = pick
				self:_syncOptionsDraft()
			end)
		)
	end
	table.insert(
		conns,
		optMin.FocusLost:Connect(function()
			self._draft.minPrice = draftPrice(optMin.Text)
			self:_syncOptionsDraft()
		end)
	)
	table.insert(
		conns,
		optMax.FocusLost:Connect(function()
			self._draft.maxPrice = draftPrice(optMax.Text)
			self:_syncOptionsDraft()
		end)
	)
	for i, chip in optPresets do
		local preset = PRICE_PRESETS[i]
		table.insert(
			conns,
			chip.Activated:Connect(function()
				self._draft.minPrice = preset.min
				self._draft.maxPrice = preset.max
				self:_syncOptionsDraft()
			end)
		)
	end
	table.insert(
		conns,
		optCreator.FocusLost:Connect(function()
			local name = string.match(optCreator.Text, "^%s*(.-)%s*$") or ""
			self._draft.creatorName = if name ~= "" then name else nil
			if self._draft.creatorName == nil then
				self._draft.creatorType = nil -- tipe tanpa nama ditolak server (BAD_ARG)
			end
			self:_syncOptionsDraft()
		end)
	)
	for i, chip in optCreatorChips do
		local kind = CREATOR_KINDS[i].kind
		table.insert(
			conns,
			chip.Activated:Connect(function()
				self._draft.creatorType = kind
				self:_syncOptionsDraft()
			end)
		)
	end
	table.insert(
		conns,
		optOffSale.Activated:Connect(function()
			self._draft.includeOffSale = not self._draft.includeOffSale
			self:_syncOptionsDraft()
		end)
	)
	table.insert(
		conns,
		optApply.Activated:Connect(function()
			self:_setOptionsOpen(false)
			self:_applyOptions()
		end)
	)

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
-- Buka/tutup popover "Search Options". Scrim ikut supaya klik di luar menutupnya.
function CatalogPanel._setOptionsOpen(self: CatalogPanel, open: boolean)
	if open then
		self:_seedDraft() -- popover selalu terbuka menampilkan saringan yang sedang berlaku
	end
	self._optOpen = open
	self._optScrim.Visible = open
	if not open then
		-- Menutup TANPA tween: popover yang masih terlihat 0,12 detik sesudah pemain klik di luar
		-- terasa lambat, bukan halus.
		self._optPanel.Visible = false
		return
	end
	-- Melorot dari 8px di atas titik akhirnya. Yang ditween POSITION, bukan Size: Size memaksa
	-- UIListLayout + AutomaticCanvasSize menghitung ulang isi popover tiap frame.
	local target = self._optPos
	self._optPanel.Position = target + UDim2.fromOffset(0, -OPT_SLIDE)
	self._optPanel.Visible = true
	TweenService:Create(self._optPanel, Tokens.Tween.Fast, { Position = target }):Play()
end

-- Tombol pemicu jadi emas selama ada saringan yang aktif, supaya pemain tahu hasilnya disaring
-- walaupun popovernya tertutup.
function CatalogPanel._syncOptionsMark(self: CatalogPanel)
	local ctl = self._props.controller
	local active = type(ctl.hasOptions) == "function" and ctl:hasOptions()
	local tint = if active then Tokens.Color.Accent else Tokens.Color.Text
	for _, part in self._optButton:GetChildren() do
		if part:IsA("Frame") then
			part.BackgroundColor3 = tint
		end
	end
end

-- Kirim isi popover ke controller sebagai SATU pencarian. Langkah 7b mengisi tabelnya dari
-- kontrol di dalam popover; sekarang masih memakai keadaan yang ada.
-- Salin saringan yang sedang berlaku ke draft (dipanggil tiap popover dibuka).
function CatalogPanel._seedDraft(self: CatalogPanel)
	local s = self._props.controller:getState()
	self._draft = {
		sort = s.sort,
		minPrice = s.minPrice,
		maxPrice = s.maxPrice,
		includeOffSale = s.includeOffSale == true,
		creatorName = s.creatorName,
		creatorType = s.creatorType,
	}
	self:_syncOptionsDraft()
end

-- Gambar ulang kontrol popover dari draft.
function CatalogPanel._syncOptionsDraft(self: CatalogPanel)
	local d = self._draft
	for key, row in self._optSortRows do
		local on = key == d.sort
		row.TextColor3 = if on then Tokens.Color.Accent else Tokens.Color.TextMuted
		row.FontFace = if on then Tokens.Font.Bold else Tokens.Font.Regular
	end
	self._optMin.Text = if d.minPrice ~= nil then tostring(d.minPrice) else ""
	self._optMax.Text = if d.maxPrice ~= nil then tostring(d.maxPrice) else ""
	for i, chip in self._optPresets do
		local preset = PRICE_PRESETS[i]
		local on = d.minPrice == preset.min and d.maxPrice == preset.max
		chip.BackgroundColor3 = if on then Tokens.Color.Accent else Tokens.Color.PanelRaised
		chip.TextColor3 = if on then Tokens.Color.AccentText else Tokens.Color.TextMuted
	end
	self._optCreator.Text = d.creatorName or ""
	for i, chip in self._optCreatorChips do
		-- "All" (kind nil) menyala juga selama pemain belum memilih User/Group.
		local on = CREATOR_KINDS[i].kind == d.creatorType
		chip.BackgroundColor3 = if on then Tokens.Color.Accent else Tokens.Color.PanelRaised
		chip.TextColor3 = if on then Tokens.Color.AccentText else Tokens.Color.TextMuted
	end
	self._optOffSale.Text = if d.includeOffSale then "ON" else "OFF"
	self._optOffSale.BackgroundColor3 = if d.includeOffSale then Tokens.Color.Accent else Tokens.Color.PanelRaised
	self._optOffSale.TextColor3 = if d.includeOffSale then Tokens.Color.AccentText else Tokens.Color.TextMuted
end

-- Apply: seluruh draft dikirim SEKALI (setOptions melakukan satu pencarian, bukan satu per kontrol).
function CatalogPanel._applyOptions(self: CatalogPanel)
	local ctl = self._props.controller
	local d = self._draft
	spawnCall(ctl.setOptions, ctl, {
		sort = d.sort,
		minPrice = d.minPrice,
		maxPrice = d.maxPrice,
		includeOffSale = d.includeOffSale,
		creatorName = d.creatorName,
		creatorType = d.creatorType,
	})
end

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
	self:_syncOptionsMark()
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
	self._creatorName = nil
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
	self._creatorName = nil
	self._wearing = false
	self._lastCount = 0
	self._grid.CanvasPosition = Vector2.zero
	self._tabScroll = 0 -- grup baru: baris kedua mulai dari kiri lagi
	self._tabBar.CanvasPosition = Vector2.zero
	self:_keepGroupScroll() -- baris grup tetap di posisi pemain (dulu dipaksa ke 0 di sini)
	self:_applyPage()
	spawnCall(self._props.controller.setFilter, self._props.controller, group.id, "all")
end

-- Hasil satu pencipta (nama creator diklik di halaman detail). Tidak punya grup, jadi chip tipe
-- disembunyikan: yang ditampilkan SEMUA karya pencipta itu. Tombol "<" kembali ke menu kategori.
function CatalogPanel.openCreator(self: CatalogPanel, creatorName: string, creatorType: string?)
	self:disarm()
	self._page = "list"
	self._group = nil
	self._creatorName = creatorName
	self._wearing = false
	self._lastCount = 0
	self._grid.CanvasPosition = Vector2.zero
	self:_applyPage()
	spawnCall(self._props.controller.setCreator, self._props.controller, creatorName, creatorType)
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
	self:_keepTabScroll()
	spawnCall(self._props.controller.setFilter, self._props.controller, group.id, filterId)
end

-- Tampilkan bagian yang sesuai halaman aktif (dipanggil applyLayout & saat halaman berganti).
function CatalogPanel._applyPage(self: CatalogPanel)
	local isMenu = self._page == "menu"
	local group = self._group
	self._menu:setVisible(isMenu)
	self._search.Visible = not isMenu
	self._optButton.Visible = not isMenu
	if isMenu then
		self:_setOptionsOpen(false)
	end
	self._back.Visible = not isMenu
	self._tabBar.Visible = not isMenu
	self._groupBar.Visible = not isMenu
	for gid, b in self._groupTabs do
		setTabActive(b, group ~= nil and gid == group.id)
	end
	self._grid.Visible = not isMenu
	self._status.Visible = not isMenu
	self._retry.Visible = not isMenu and self._hasError
	self._title.Text = if isMenu
		then "Catalog"
		elseif self._creatorName then "By " .. self._creatorName
		elseif group == nil then "Catalog"
		else group.label

	if isMenu then
		self._menu:setArea(0, self._contentTop, self._innerW, self._innerH - self._contentTop)
		return
	end

	-- Chip filter berlaku di semua grup -> selalu tampil di halaman daftar item, KECUALI di hasil
	-- satu pencipta (di sana tidak ada grup yang bisa disaring).
	for _, b in self._filterTabs do
		b.Visible = self._creatorName == nil
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
-- Jaga posisi geser baris tab selama TAB_HOLD_SECONDS.
-- Roblox menulis ulang CanvasPosition ke 0 setiap kali isi/ukuran kanvas dihitung ulang
-- (ganti kategori, tab aktif berubah lebar), dan itu terjadi beberapa frame SETELAH klik,
-- jadi menyetel ulang sekali saja tidak cukup. Selama dijaga, listener di atas berhenti
-- merekam supaya angka 0 hasil reset tidak menggantikan posisi pemain.
function CatalogPanel._keepTabScroll(self: CatalogPanel)
	local want = self._tabScroll
	self._tabHoldUntil = os.clock() + TAB_HOLD_SECONDS
	task.spawn(function()
		while os.clock() < self._tabHoldUntil do
			if self.instance.Parent == nil or self._page ~= "list" then
				return
			end
			if math.abs(self._tabBar.CanvasPosition.X - want) > 0.5 then
				self._tabBar.CanvasPosition = Vector2.new(want, 0)
			end
			task.wait()
		end
	end)
end

function CatalogPanel._restoreTabScroll(self: CatalogPanel)
	self:_keepTabScroll()
	self:_keepGroupScroll()
end

-- Sama seperti _keepTabScroll, untuk baris grup (baris pertama).
function CatalogPanel._keepGroupScroll(self: CatalogPanel)
	local want = self._groupScroll
	self._groupHoldUntil = os.clock() + TAB_HOLD_SECONDS
	task.spawn(function()
		while os.clock() < self._groupHoldUntil do
			if self.instance.Parent == nil or self._page ~= "list" then
				return
			end
			if math.abs(self._groupBar.CanvasPosition.X - want) > 0.5 then
				self._groupBar.CanvasPosition = Vector2.new(want, 0)
			end
			task.wait()
		end
	end)
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
