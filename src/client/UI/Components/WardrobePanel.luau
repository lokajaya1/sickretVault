--!strict
-- Panel "Saved Outfits" (pola CAC): MENUTUPI isi panel katalog (anak dari CatalogPanel.instance).
--   local panel = WardrobePanel.new({
--   	parent = catalogPanel.instance, controller = wardrobeController, previews = outfitPreview,
--   	onResult = function(op, ok, code, name) ... end,  -- untuk toast
--   	onBack = function() ... end,                       -- tombol X
--   })
--   panel:setOpen(true)   panel:isOpen()   panel:destroy()
-- Isi: Search + X; baris tab folder (All / Not In Any Folders / folder pemain / ＋ kelola) + dropdown sort;
-- grid kartu (kartu pertama "+" = simpan outfit sekarang); tombol "Select Outfits" di kanan bawah;
-- bawah: toggle "Wear last outfit when joining". Tap kartu -> WEAR / VIEW; VIEW -> OutfitDetailSheet.
-- Mode "Select Outfits": kartu jadi kotak centang, bar bawah = jumlah terpilih + Move / Delete / Cancel.
-- Dialog nama (NamePrompt) dipakai ulang: simpan outfit, folder baru, ganti nama folder.
-- Dialog folder (FolderDialog): "manage" (kelola), "set" (Modify Folders satu outfit), "pick" (pindah massal).
-- Kartu dipakai ulang selama id & updatedAt sama supaya model 3D tidak dibuat ulang.
-- Tab "Roblox" (Outfit Loader) = outfit akun Roblox pemain, BUKAN slot wardrobe kita:
-- read-only (tanpa favorit / folder / hapus) dan tap kartu langsung PAKAI. Daftarnya dari
-- client (GetOutfits), state tiap outfit dari server (266 ms per id) -> diisi SATU PER SATU
-- supaya tidak memberondong server dan tidak membangun 8 model 3D sekaligus (pelajaran #28).
-- Di tab itu kotak Search berubah jadi "enter username.." (pola CAC): Enter -> kartu avatar yang
-- SEDANG dipakai pemain itu. Outfit tersimpan milik orang lain tidak bisa diambil dari dalam game.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local OutfitSort = require(Shared.Domain.OutfitSort)
local Tokens = require(script.Parent.Parent.Theme.Tokens)
local OutfitCard = require(script.Parent.OutfitCard)
local OutfitDetailSheet = require(script.Parent.OutfitDetailSheet)
local FolderDialog = require(script.Parent.FolderDialog)
local NamePrompt = require(script.Parent.NamePrompt)

local SEARCH_H = 36
local TABS_H = 30
local FOOTER_H = 32
local CLOSE_W = 36
local SORT_W = 168
local SWITCH_W = 52
local SELECT_W = 124
local SELECT_H = 30
local ACTION_W = 70
local CELL_MIN = 132 -- lebar kartu minimum -> jumlah kolom menyesuaikan lebar panel
local CELL_RATIO = 1.32 -- tinggi kartu = lebar * rasio
local SEARCH_DEBOUNCE = 0.25
local CONFIRM_SECONDS = 3
local Z = Tokens.ZIndex.Panel + 4 -- di atas isi katalog, di bawah ItemDetailPanel (+5)

export type Props = {
	parent: GuiObject, -- CatalogPanel.instance
	controller: any, -- WardrobeController
	previews: any, -- OutfitPreview
	onResult: ((op: string, ok: boolean, code: string?, name: string?) -> ())?,
	onItem: ((item: any) -> ())?, -- tap item di halaman detail -> App membuka detail item katalog
	onBack: (() -> ())?, -- tombol X (default: setOpen(false))
}

local WardrobePanel = {}
WardrobePanel.__index = WardrobePanel

export type WardrobePanel = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_search: TextBox,
		_tabs: ScrollingFrame,
		_tabSig: string,
		_tabButtons: { [string]: TextButton },
		_tabConns: { RBXScriptConnection },
		_sortButton: TextButton,
		_sortMenu: Frame,
		_grid: ScrollingFrame,
		_layout: UIGridLayout,
		_add: TextButton,
		_status: Frame,
		_statusTitle: TextLabel,
		_statusHint: TextLabel,
		_retry: TextButton,
		_footer: Frame,
		_switch: TextButton,
		_knob: Frame,
		_selectButton: TextButton,
		_selectBar: Frame,
		_selectLabel: TextLabel,
		_selectDelete: TextButton,
		_selecting: boolean,
		_selected: { [number]: boolean },
		_deleteConfirm: boolean,
		_confirmToken: number,
		_prompt: NamePrompt.NamePrompt,
		_dialog: FolderDialog.FolderDialog,
		_sheet: OutfitDetailSheet.OutfitDetailSheet,
		_cards: { [number]: any }, -- id -> OutfitCard
		_cardKey: { [number]: string }, -- id -> "<updatedAt>"
		_armedId: number?,
		_roblox: boolean, -- tab "Roblox" (Outfit Loader) sedang aktif
		_robloxRows: { any }, -- baris outfit Roblox dalam bentuk Summary (outfit = nil sampai terisi)
		_robloxStatus: string?, -- "loading" | kode gagal | nil
		_robloxToken: number, -- pembatal pengisian state saat tab ditutup / dimuat ulang
		_userRows: { any }, -- hasil cari username (kosong = daftar outfit sendiri)
		_userStatus: string?, -- "loading" | kode gagal | nil
		_snap: any?,
		_searchToken: number,
		_conns: { RBXScriptConnection },
		_unsubscribe: () -> (),
	},
	WardrobePanel
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
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = Z,
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
		ZIndex = Z,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextButton", base, { corner(Tokens.Radius.Pill) })
end

function WardrobePanel.new(props: Props): WardrobePanel
	local pad = Tokens.Space.M
	local gap = Tokens.Space.S
	local ctl = props.controller

	local root: Frame = make("Frame", {
		Name = "WardrobePanel",
		Active = true,
		BackgroundColor3 = Tokens.Color.Panel,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(-pad, -pad),
		Size = UDim2.new(1, pad * 2, 1, pad * 2),
		Visible = false,
		ZIndex = Z,
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
	make("TextButton", {
		Name = "InputBlocker",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z - 1,
		Parent = root,
	})

	-- Baris 1: Search + X
	local search: TextBox = make("TextBox", {
		Name = "Search",
		Text = "",
		PlaceholderText = "Search…",
		ClearTextOnFocus = false,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		PlaceholderColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -(CLOSE_W + gap), 0, SEARCH_H),
		ZIndex = Z,
		Parent = root,
	}, {
		corner(Tokens.Radius.Pill),
		make("UIPadding", { PaddingLeft = UDim.new(0, pad), PaddingRight = UDim.new(0, pad) }),
	})
	local close = button("✕", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(CLOSE_W, SEARCH_H),
		Parent = root,
	})

	-- Baris 2: tab folder (geser mendatar) + dropdown sort
	local tabsTop = SEARCH_H + gap
	local tabs: ScrollingFrame = make("ScrollingFrame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, tabsTop),
		Size = UDim2.new(1, -(SORT_W + gap), 0, TABS_H),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 0,
		ClipsDescendants = true,
		ZIndex = Z,
		Parent = root,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, gap / 2),
		}),
	})
	local sortButton = button("Recently Updated ▼", {
		Name = "Sort",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, tabsTop),
		Size = UDim2.fromOffset(SORT_W, TABS_H),
		TextSize = Tokens.TextSize.Caption,
		Parent = root,
	})

	-- Grid kartu
	local gridTop = tabsTop + TABS_H + gap
	local grid: ScrollingFrame = make("ScrollingFrame", {
		Name = "Outfits",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, gridTop),
		Size = UDim2.new(1, 0, 1, -(gridTop + FOOTER_H + gap)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Tokens.Color.TextMuted,
		ClipsDescendants = true,
		ZIndex = Z,
		Parent = root,
	}, {
		make("UIPadding", { PaddingRight = UDim.new(0, gap) }),
	})
	local gridLayout: UIGridLayout = make("UIGridLayout", {
		CellSize = UDim2.fromOffset(CELL_MIN, CELL_MIN * CELL_RATIO),
		CellPadding = UDim2.fromOffset(gap, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})

	-- Kartu "+" (simpan outfit yang sedang dipakai)
	local add = button("+", {
		Name = "Add",
		LayoutOrder = 0,
		TextSize = 44,
		Size = UDim2.fromOffset(CELL_MIN, CELL_MIN * CELL_RATIO),
		Parent = grid,
	})
	add:FindFirstChildOfClass("UICorner").CornerRadius = Tokens.Radius.Medium

	-- Status (memuat / gagal / kosong)
	local status: Frame = make("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, gridTop + Tokens.Space.XL),
		Size = UDim2.new(1, 0, 0, 96),
		Visible = false,
		ZIndex = Z + 1,
		Parent = root,
	}, {
		make("UIListLayout", {
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap),
		}),
	})
	local statusTitle = label({
		Name = "Title",
		FontFace = Tokens.Font.Bold,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 20),
		ZIndex = Z + 1,
		Parent = status,
	})
	local statusHint = label({
		Name = "Hint",
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 30),
		ZIndex = Z + 1,
		Parent = status,
	})
	local retry = button("Try again", {
		Name = "Retry",
		LayoutOrder = 3,
		Size = UDim2.fromOffset(110, 32),
		ZIndex = Z + 1,
		Parent = status,
	})

	-- Tombol mengambang "Select Outfits" (kanan bawah, di atas grid)
	local selectButton = button("Select Outfits", {
		Name = "SelectOutfits",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -(FOOTER_H + gap)),
		Size = UDim2.fromOffset(SELECT_W, SELECT_H),
		TextSize = Tokens.TextSize.Caption,
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0.1,
		Visible = false,
		ZIndex = Z + 2,
		Parent = root,
	})

	-- Bawah: toggle "pakai outfit terakhir saat join"
	local footer: Frame = make("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		ZIndex = Z,
		Parent = root,
	})
	label({
		Name = "RestoreLabel",
		Text = "Wear last outfit when joining",
		Size = UDim2.new(1, -(SWITCH_W + gap), 1, 0),
		Parent = footer,
	})
	local switch = button("", {
		Name = "RestoreSwitch",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(SWITCH_W, 26),
		Parent = footer,
	})
	local knob: Frame = make("Frame", {
		Name = "Knob",
		BackgroundColor3 = Tokens.Color.Text,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(20, 20),
		ZIndex = Z,
		Parent = switch,
	}, { corner(Tokens.Radius.Pill) })

	-- Bar mode pilih (menggantikan footer selama memilih)
	local selectBar: Frame = make("Frame", {
		Name = "SelectBar",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		Visible = false,
		ZIndex = Z + 2,
		Parent = root,
	})
	local selectLabel = label({
		Name = "Count",
		Text = "0 selected",
		FontFace = Tokens.Font.Bold,
		Size = UDim2.new(1, -(ACTION_W * 3 + gap * 2), 1, 0),
		ZIndex = Z + 2,
		Parent = selectBar,
	})
	local selectActions: Frame = make("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.new(0, ACTION_W * 3 + gap, 0, SELECT_H),
		ZIndex = Z + 2,
		Parent = selectBar,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap / 2),
		}),
	})
	local selectMove = button("Move…", {
		Name = "Move",
		LayoutOrder = 1,
		Size = UDim2.fromOffset(ACTION_W, SELECT_H),
		TextSize = Tokens.TextSize.Caption,
		ZIndex = Z + 2,
		Parent = selectActions,
	})
	local selectDelete = button("Delete", {
		Name = "Delete",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(ACTION_W, SELECT_H),
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.Danger,
		ZIndex = Z + 2,
		Parent = selectActions,
	})
	local selectCancel = button("Cancel", {
		Name = "Cancel",
		LayoutOrder = 3,
		Size = UDim2.fromOffset(ACTION_W, SELECT_H),
		TextSize = Tokens.TextSize.Caption,
		ZIndex = Z + 2,
		Parent = selectActions,
	})

	-- Menu sort (di atas grid)
	local sortMenu: Frame = make("Frame", {
		Name = "SortMenu",
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, tabsTop + TABS_H + 4),
		Size = UDim2.fromOffset(SORT_W, #OutfitSort.OPTIONS * 28 + gap),
		Visible = false,
		ZIndex = Z + 3,
		Parent = root,
	}, {
		corner(Tokens.Radius.Medium),
		make("UIPadding", { PaddingTop = UDim.new(0, gap / 2), PaddingBottom = UDim.new(0, gap / 2) }),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	local self: WardrobePanel
	local conns: { RBXScriptConnection } = {}

	-- Dialog folder: aksinya dijalankan panel (satu jalur dengan toast & busy).
	local dialog = FolderDialog.new({
		parent = root,
		zIndex = Z + 6,
		onCreate = function()
			self._prompt:open("folderNew")
		end,
		onRename = function(id, name)
			self._prompt:open("folderRename", id, name)
		end,
		onDelete = function(id, name)
			self:_act("folderDelete", nil, name, function()
				return ctl:folderDelete(id)
			end)
		end,
		onSave = function(outfitId, ids)
			self:_act("setFolders", outfitId, nil, function()
				return ctl:setFolders(outfitId, ids)
			end)
		end,
		onPick = function(id, name, addToFolder)
			local ids = self:_selectedIds()
			if #ids == 0 then
				return
			end
			self:_act("bulkFolder", nil, name, function()
				local ok, code = ctl:bulkFolder(ids, id, addToFolder)
				if ok then
					self:_setSelecting(false)
				end
				return ok, code
			end)
		end,
		onLimit = function(name)
			if props.onResult then
				props.onResult("setFolders", false, "TOO_MANY", name)
			end
		end,
	})

	-- Dialog nama: simpan outfit / folder baru / ganti nama folder.
	local prompt = NamePrompt.new({
		parent = root,
		zIndex = Z + 8,
		onConfirm = function(mode, name, folderId)
			if mode == "save" then
				self:_act("save", nil, name, function()
					return ctl:save(name) -- nil -> server memberi nama bawaan ("Outfit N")
				end)
			elseif name == nil then
				return
			elseif mode == "folderNew" then
				self:_act("folderAdd", nil, name, function()
					return ctl:folderAdd(name :: string)
				end)
			elseif mode == "folderRename" and folderId ~= nil then
				self:_act("folderRename", nil, name, function()
					return ctl:folderRename(folderId, name :: string)
				end)
			end
		end,
	})

	local sheet = OutfitDetailSheet.new({
		parent = root,
		previews = props.previews,
		loadItems = function(outfit)
			return ctl:items(outfit.id)
		end,
		cachedItems = function(outfit)
			return ctl:itemsCached(outfit.id)
		end,
		onFavorite = function(outfit)
			self:_act("favorite", outfit.id, outfit.name, function()
				return ctl:favorite(outfit.id, not outfit.favorite)
			end)
		end,
		onItem = props.onItem,
		onWear = function(outfit)
			self:_act("wear", outfit.id, outfit.name, function()
				return ctl:wear(outfit.id)
			end)
		end,
		onUpdate = function(outfit)
			self:_act("overwrite", outfit.id, outfit.name, function()
				return ctl:overwrite(outfit.id)
			end)
		end,
		onRename = function(outfit, name)
			self:_act("rename", outfit.id, name, function()
				return ctl:rename(outfit.id, name)
			end)
		end,
		onDelete = function(outfit)
			self:_act("delete", outfit.id, outfit.name, function()
				return ctl:delete(outfit.id)
			end)
		end,
		onModifyFolders = function(outfit)
			self._dialog:open("set", { outfitId = outfit.id, folders = outfit.folders })
		end,
		folderNames = function(outfit)
			return self:_folderNames(outfit)
		end,
		onBack = function()
			self._sheet:close()
		end,
	})

	self = setmetatable({
		instance = root,
		_props = props,
		_search = search,
		_tabs = tabs,
		_tabSig = "",
		_roblox = false,
		_robloxRows = {},
		_robloxStatus = nil,
		_robloxToken = 0,
		_userRows = {},
		_userStatus = nil,
		_tabButtons = {},
		_tabConns = {},
		_sortButton = sortButton,
		_sortMenu = sortMenu,
		_grid = grid,
		_layout = gridLayout,
		_add = add,
		_status = status,
		_statusTitle = statusTitle,
		_statusHint = statusHint,
		_retry = retry,
		_footer = footer,
		_switch = switch,
		_knob = knob,
		_selectButton = selectButton,
		_selectBar = selectBar,
		_selectLabel = selectLabel,
		_selectDelete = selectDelete,
		_selecting = false,
		_selected = {},
		_deleteConfirm = false,
		_confirmToken = 0,
		_prompt = prompt,
		_dialog = dialog,
		_sheet = sheet,
		_cards = {},
		_cardKey = {},
		_armedId = nil,
		_snap = nil,
		_searchToken = 0,
		_conns = conns,
		_unsubscribe = function() end,
	}, WardrobePanel)

	-- Pilihan sort
	for i, opt in OutfitSort.OPTIONS do
		local item = make("TextButton", {
			Name = opt.key,
			Text = opt.label,
			FontFace = Tokens.Font.Regular,
			TextSize = Tokens.TextSize.Body,
			TextColor3 = Tokens.Color.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundTransparency = 1,
			AutoButtonColor = true,
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 28),
			ZIndex = Z + 3,
			Parent = sortMenu,
		}, { make("UIPadding", { PaddingLeft = UDim.new(0, pad), PaddingRight = UDim.new(0, pad) }) })
		local key = opt.key
		table.insert(
			conns,
			item.Activated:Connect(function()
				sortMenu.Visible = false
				ctl:setSort(key)
			end)
		)
	end

	table.insert(
		conns,
		close.Activated:Connect(function()
			if props.onBack then
				props.onBack()
			else
				self:setOpen(false)
			end
		end)
	)
	table.insert(
		conns,
		sortButton.Activated:Connect(function()
			sortMenu.Visible = not sortMenu.Visible
		end)
	)
	table.insert(
		conns,
		search:GetPropertyChangedSignal("Text"):Connect(function()
			self._searchToken += 1
			local token = self._searchToken
			local text = search.Text
			if self._roblox then
				-- kotak username: kosong = kembali ke outfit sendiri, isinya baru dicari saat Enter
				if text == "" and (#self._userRows > 0 or self._userStatus ~= nil) then
					self._userRows = {}
					self._userStatus = nil
					self:_rerender()
				end
				return
			end
			task.delay(SEARCH_DEBOUNCE, function()
				if self._searchToken == token then
					ctl:setQuery(text)
				end
			end)
		end)
	)
	table.insert(
		conns,
		search.FocusLost:Connect(function(enterPressed: boolean)
			if enterPressed and self._roblox then
				self:_loadUser(search.Text)
			end
		end)
	)
	table.insert(
		conns,
		add.Activated:Connect(function()
			local snap = self._snap
			if snap == nil or not snap.loaded or snap.busy ~= nil or snap.isFull then
				return
			end
			self:_dismiss()
			prompt:open("save")
		end)
	)
	table.insert(
		conns,
		selectButton.Activated:Connect(function()
			self:_setSelecting(true)
		end)
	)
	table.insert(
		conns,
		selectCancel.Activated:Connect(function()
			self:_setSelecting(false)
		end)
	)
	table.insert(
		conns,
		selectMove.Activated:Connect(function()
			local snap = self._snap
			local ids = self:_selectedIds()
			if #ids == 0 or snap == nil then
				return
			end
			local active = if type(snap.folderFilter) == "number" then snap.folderFilter else nil
			dialog:open("pick", { count = #ids, activeFolder = active })
		end)
	)
	table.insert(
		conns,
		selectDelete.Activated:Connect(function()
			self:_bulkDelete()
		end)
	)
	table.insert(
		conns,
		retry.Activated:Connect(function()
			if self._roblox then
				self:_loadRoblox(true)
				return
			end
			task.spawn(ctl.refresh, ctl)
		end)
	)
	table.insert(
		conns,
		switch.Activated:Connect(function()
			local snap = self._snap
			if snap == nil or snap.busy or snap.restoreOutfit == nil then
				return
			end
			local value = not snap.restoreOutfit
			self:_act("setSetting", nil, nil, function()
				return ctl:setRestoreOutfit(value)
			end)
		end)
	)
	table.insert(
		conns,
		grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_resizeCells()
		end)
	)

	self._unsubscribe = ctl:onChanged(function(snap)
		self:_render(snap)
	end)
	self:_render(ctl:getSnapshot())
	self:_resizeCells()
	return self
end

-- Jalankan aksi controller di thread baru; hasil -> onResult (toast).
function WardrobePanel._act(self: WardrobePanel, op: string, id: number?, name: string?, fn: () -> (boolean, string?))
	task.spawn(function()
		local ok, code = fn()
		if code ~= "BUSY" and self._props.onResult then
			self._props.onResult(op, ok, code, name)
		end
		if ok and op == "delete" and self._sheet:outfitId() == id then
			self._sheet:close()
		end
	end)
end

-- ===== Tab folder =====

-- Nama folder sebuah outfit untuk baris info di halaman detail.
function WardrobePanel._folderNames(self: WardrobePanel, outfit: any): string
	local snap = self._snap
	local ids = outfit.folders
	if snap == nil or type(ids) ~= "table" or #ids == 0 then
		return "None"
	end
	local names: { string } = {}
	for _, folder in snap.folders do
		if table.find(ids, folder.id) then
			table.insert(names, folder.name)
		end
	end
	if #names == 0 then
		return "None"
	end
	return table.concat(names, ", ")
end

-- Bangun ulang tombol tab bila daftar folder berubah; selain itu hanya warnanya yang diperbarui.
function WardrobePanel._syncTabs(self: WardrobePanel, snap: any)
	local parts: { string } = { tostring(snap.unfiled) }
	for _, folder in snap.folders do
		table.insert(parts, ("%d:%s:%d"):format(folder.id, folder.name, folder.count))
	end
	local sig = table.concat(parts, "|")
	if sig ~= self._tabSig then
		self._tabSig = sig
		for _, c in self._tabConns do
			c:Disconnect()
		end
		table.clear(self._tabConns)
		for _, child in self._tabs:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		table.clear(self._tabButtons)

		local ctl = self._props.controller
		local entries: { { key: string, text: string, value: any } } = {
			{ key = "roblox", text = "Roblox", value = "roblox" },
			{ key = "all", text = "All", value = OutfitSort.ALL },
			{ key = "none", text = ("Not In Any Folders (%d)"):format(snap.unfiled), value = OutfitSort.NONE },
		}
		for _, folder in snap.folders do
			table.insert(entries, {
				key = tostring(folder.id),
				text = ("%s (%d)"):format(folder.name, folder.count),
				value = folder.id,
			})
		end
		for i, entry in entries do
			local tab = button(entry.text, {
				Name = "Tab_" .. entry.key,
				LayoutOrder = i,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, TABS_H),
				TextSize = Tokens.TextSize.Caption,
				Parent = self._tabs,
			})
			make("UIPadding", {
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
				Parent = tab,
			})
			self._tabButtons[entry.key] = tab
			local value = entry.value
			table.insert(
				self._tabConns,
				tab.Activated:Connect(function()
					self:_setSelecting(false)
					if value == "roblox" then
						self:_setRoblox(true)
						return
					end
					self:_setRoblox(false)
					ctl:setFolderFilter(value)
				end)
			)
		end
		-- tombol kelola folder (paling kanan)
		local manage = button("＋", {
			Name = "Tab_manage",
			LayoutOrder = #entries + 1,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, TABS_H),
			Parent = self._tabs,
		})
		make("UIPadding", {
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
			Parent = manage,
		})
		table.insert(
			self._tabConns,
			manage.Activated:Connect(function()
				self._dialog:open("manage")
			end)
		)
	end

	local active = snap.folderFilter
	for key, tab in self._tabButtons do
		local id = tonumber(key)
		local on = if self._roblox
			then key == "roblox"
			else (key == "all" and active == OutfitSort.ALL)
				or (key == "none" and active == OutfitSort.NONE)
				or (id ~= nil and active == id)
		tab.BackgroundColor3 = if on then Tokens.Color.Accent else Tokens.Color.PanelRaised
		tab.BackgroundTransparency = if on then 0 else Tokens.Transparency.PanelRaised
		tab.TextColor3 = if on then Tokens.Color.AccentText else Tokens.Color.Text
	end
end

-- ===== Mode "Select Outfits" =====

function WardrobePanel._setSelecting(self: WardrobePanel, on: boolean)
	if self._selecting == on then
		return
	end
	self._selecting = on
	table.clear(self._selected)
	self:_setDeleteConfirm(false)
	if on then
		self:_dismiss()
		self._sheet:close()
	elseif self._dialog:mode() == "pick" then
		self._dialog:close()
	end
	for _, card in self._cards do
		card:setSelectMode(on)
	end
	self:_refreshSelection()
end

function WardrobePanel._toggleSelect(self: WardrobePanel, id: number)
	self._selected[id] = if self._selected[id] then nil else true
	self:_setDeleteConfirm(false)
	local card = self._cards[id]
	if card then
		card:setSelected(self._selected[id] == true)
	end
	self:_refreshSelection()
end

function WardrobePanel._selectedIds(self: WardrobePanel): { number }
	local ids: { number } = {}
	for id in self._selected do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- Bar bawah mengikuti jumlah yang dicentang.
function WardrobePanel._refreshSelection(self: WardrobePanel)
	local snap = self._snap
	local hasOutfits = snap ~= nil and snap.loaded and #snap.outfits > 0
	self._selectBar.Visible = self._selecting
	self._footer.Visible = not self._selecting
	self._selectButton.Visible = not self._selecting and hasOutfits
	self._selectLabel.Text = ("%d selected"):format(#self:_selectedIds())
end

-- Hapus massal butuh dua tap ("Sure?").
function WardrobePanel._setDeleteConfirm(self: WardrobePanel, confirm: boolean)
	self._deleteConfirm = confirm
	self._selectDelete.Text = if confirm then "Sure?" else "Delete"
	self._confirmToken += 1
	if confirm then
		local token = self._confirmToken
		task.delay(CONFIRM_SECONDS, function()
			if self._confirmToken == token and self._deleteConfirm then
				self:_setDeleteConfirm(false)
			end
		end)
	end
end

function WardrobePanel._bulkDelete(self: WardrobePanel)
	local ids = self:_selectedIds()
	if #ids == 0 then
		return
	end
	if not self._deleteConfirm then
		self:_setDeleteConfirm(true)
		return
	end
	self:_setDeleteConfirm(false)
	local ctl = self._props.controller
	local name = ("%d outfit"):format(#ids)
	self:_act("bulkDelete", nil, name, function()
		local ok, code = ctl:bulkDelete(ids)
		if ok then
			self:_setSelecting(false)
		end
		return ok, code
	end)
end

-- ===== Grid =====

-- Jumlah kolom & ukuran kartu menyesuaikan lebar panel.
function WardrobePanel._resizeCells(self: WardrobePanel)
	local gap = Tokens.Space.S
	local width = self._grid.AbsoluteSize.X - gap -- padding kanan
	if width <= 0 then
		return
	end
	local cols = math.clamp(math.floor((width + gap) / (CELL_MIN + gap)), 2, 4)
	local cellW = math.floor((width - gap * (cols - 1)) / cols)
	local cellH = math.floor(cellW * CELL_RATIO)
	self._layout.CellSize = UDim2.fromOffset(cellW, cellH)
	self._add.Size = UDim2.fromOffset(cellW, cellH)
end

function WardrobePanel._dismiss(self: WardrobePanel)
	local armed = self._armedId
	if armed == nil then
		return
	end
	local card = self._cards[armed]
	if card then
		card:setArmed(false)
	end
	self._armedId = nil
end

function WardrobePanel._arm(self: WardrobePanel, id: number)
	if self._armedId == id then
		return
	end
	self:_dismiss()
	local card = self._cards[id]
	if card then
		card:setArmed(true)
		self._armedId = id
	end
end

function WardrobePanel._buildCard(self: WardrobePanel, outfit: any, order: number): any
	local ctl = self._props.controller
	local card = OutfitCard.new({
		outfit = outfit,
		previews = self._props.previews,
		layoutOrder = order,
		onActivated = function(o)
			if self._roblox then
				-- outfit Roblox read-only: tidak ada WEAR/VIEW, tap = pakai
				local fromUser = (o :: any).fromUser == true
				self:_act("wear", o.id, o.name, function()
					if fromUser then
						return ctl:wearRobloxUser(o.id)
					end
					return ctl:wearRoblox(o.id)
				end)
				return
			end
			self:_arm(o.id)
		end,
		onToggleSelect = function(o)
			self:_toggleSelect(o.id)
		end,
		onDismiss = function()
			self:_dismiss()
		end,
		onWear = function(o)
			self:_dismiss()
			self:_act("wear", o.id, o.name, function()
				return ctl:wear(o.id)
			end)
		end,
		onView = function(o)
			self:_dismiss()
			self._sheet:open(o)
		end,
		onFavorite = function(o)
			local value = not o.favorite
			self:_act("favorite", o.id, o.name, function()
				return ctl:favorite(o.id, value)
			end)
		end,
	})
	card.instance.Parent = self._grid
	return card
end

function WardrobePanel._syncCards(self: WardrobePanel, visible: { any })
	local seen: { [number]: boolean } = {}
	for i, outfit in visible do
		if outfit.outfit == nil then
			continue -- state-nya belum datang; kartu dibuat setelah ada (OutfitPreview butuh isinya)
		end
		seen[outfit.id] = true
		local key = tostring(outfit.updatedAt)
		local card = self._cards[outfit.id]
		if card and self._cardKey[outfit.id] ~= key then
			card:destroy() -- isi outfit berubah -> model 3D dibuat ulang
			card = nil
		end
		if card == nil then
			card = self:_buildCard(outfit, i)
			self._cards[outfit.id] = card
			self._cardKey[outfit.id] = key
			if self._armedId == outfit.id then
				card:setArmed(true)
			end
		else
			card.instance.LayoutOrder = i
			card:setName(outfit.name)
			card:setFavorite(outfit.favorite)
			card.outfit = outfit
		end
		card:setSelectMode(self._selecting)
		if self._selecting then
			card:setSelected(self._selected[outfit.id] == true)
		end
	end
	for id, card in self._cards do
		if not seen[id] then
			card:destroy()
			self._cards[id] = nil
			self._cardKey[id] = nil
			self._selected[id] = nil
			if self._armedId == id then
				self._armedId = nil
			end
		end
	end
end

-- ===== Tab "Roblox" (Outfit Loader) =====

-- Ubah baris GetOutfits jadi bentuk Summary yang dimengerti OutfitCard. `outfit` (OutfitState)
-- sengaja kosong dulu: ia baru datang dari server, dan updatedAt dipakai sebagai kunci kartu
-- (0 = belum ada state, 1 = sudah) supaya kartunya dibangun ulang begitu state-nya tiba.
local function robloxRow(entry: any): any
	return {
		id = entry.id,
		name = entry.name,
		updatedAt = 0,
		createdAt = 0,
		favorite = false,
		folders = {},
		count = 0,
		makeup = 0,
		thumbs = {},
		outfit = nil,
	}
end

-- Gambar ulang dengan snapshot terakhir. Snapshot bisa BELUM ADA (panel belum pernah dirender,
-- mis. tombol Outfit Loader ditekan sebelum daftar wardrobe datang) -> jangan memaksa render.
function WardrobePanel._rerender(self: WardrobePanel)
	if self._snap ~= nil then
		self:_render(self._snap)
	end
end

-- Isi state kartu SATU PER SATU (266 ms per id di server + ~425 ms per model 3D).
function WardrobePanel._fillStates(self: WardrobePanel, rows: { any }, token: number)
	local ctl = self._props.controller
	for _, row in rows do
		if token ~= self._robloxToken then
			return -- tab sudah ditinggalkan / dimuat ulang
		end
		if row.outfit == nil then
			local ok, state = ctl:robloxState(row.id)
			if token ~= self._robloxToken then
				return
			end
			if ok then
				row.outfit = state
				row.updatedAt = 1 -- kunci kartu berubah -> model 3D dibangun dengan state ini
				if self._roblox then
					self:_rerender()
				end
			end
		end
	end
end

function WardrobePanel._fillRobloxStates(self: WardrobePanel, token: number)
	self:_fillStates(self._robloxRows, token)
end

function WardrobePanel._loadRoblox(self: WardrobePanel, force: boolean?)
	local ctl = self._props.controller
	self._robloxToken += 1
	local token = self._robloxToken
	self._robloxStatus = "loading"
	self:_rerender()
	task.spawn(function()
		local ok, res = ctl:robloxOutfits(force)
		if token ~= self._robloxToken then
			return
		end
		if not ok then
			self._robloxStatus = if type(res) == "string" then res else "FAILED"
			self:_rerender()
			return
		end
		local rows: { any } = {}
		for _, entry in res do
			table.insert(rows, robloxRow(entry))
		end
		self._robloxRows = rows
		self._robloxStatus = nil
		self:_rerender()
		self:_fillRobloxStates(token)
	end)
end

-- Cari username (kotak Search di tab Roblox). Hasilnya SATU kartu: avatar yang sedang ia pakai.
function WardrobePanel._loadUser(self: WardrobePanel, raw: string)
	local name = string.match(raw, "^%s*(.-)%s*$") or raw
	if name == "" then
		self._userRows = {}
		self._userStatus = nil
		self:_rerender()
		return
	end
	local ctl = self._props.controller
	self._robloxToken += 1 -- hentikan pengisian kartu outfit sendiri
	local token = self._robloxToken
	self._userStatus = "loading"
	self._userRows = {}
	self:_rerender()
	task.spawn(function()
		local ok, res = ctl:robloxUser(name)
		if token ~= self._robloxToken then
			return
		end
		if not ok or type(res) ~= "table" then
			self._userStatus = if type(res) == "string" then res else "FAILED"
			self:_rerender()
			return
		end
		local row = robloxRow({ id = res.userId, name = name .. " (now)" })
		row.outfit = res.state
		row.updatedAt = 1
		row.fromUser = true -- tap = pakai avatar pemain itu, bukan outfitId
		self._userRows = { row }
		self._userStatus = nil
		self:_rerender()

		-- Outfit TERSIMPAN orang itu: lewat proxy, jadi boleh gagal (429 / proxy mati) — kartu
		-- "now" di atas tetap ada karena ia jalur engine, tidak lewat proxy sama sekali.
		local okList, list = ctl:robloxUserOutfits(res.userId)
		if token ~= self._robloxToken then
			return
		end
		if not okList or type(list) ~= "table" or #list == 0 then
			return
		end
		for _, entry in list do
			table.insert(self._userRows, robloxRow(entry))
		end
		self:_fillStates(self._userRows, token)
	end)
end

-- Pindah ke / dari tab Roblox. Kartu wardrobe & kartu Roblox memakai grid yang sama, jadi
-- _syncCards yang membuang kartu yang tidak ada di daftar baru.
function WardrobePanel._setRoblox(self: WardrobePanel, on: boolean)
	if self._roblox == on then
		if on and #self._robloxRows == 0 and self._robloxStatus == nil then
			self:_loadRoblox()
		end
		return
	end
	self._roblox = on
	self:_dismiss()
	self._search.PlaceholderText = if on then "enter username.." else "Search…"
	self._search.Text = ""
	self._userRows = {}
	self._userStatus = nil
	self._grid.CanvasPosition = Vector2.zero
	if on then
		if #self._robloxRows == 0 then
			self:_loadRoblox()
			return
		end
	else
		self._robloxToken += 1 -- hentikan pengisian state yang sedang jalan
	end
	self:_rerender()
end

-- Dipanggil App dari tombol "Outfit Loader" (kolom kiri, pola CAC).
function WardrobePanel.openRoblox(self: WardrobePanel)
	self:setOpen(true)
	self:_setRoblox(true)
end

function WardrobePanel._render(self: WardrobePanel, snap: any)
	self._snap = snap
	self:_syncTabs(snap)
	local rows = if not self._roblox
		then snap.visible
		elseif #self._userRows > 0 or self._userStatus ~= nil then self._userRows
		else self._robloxRows
	self:_syncCards(rows)
	self._dialog:setFolders(snap.folders, snap.foldersFull)

	-- kartu "+" & tombol sibuk. Tab Roblox read-only: tidak ada simpan & tidak ada pilih massal.
	local busy = snap.busy
	self._add.Text = if busy == "save" then "…" else "+"
	self._add.Visible = not self._roblox and not snap.isFull and snap.loaded and not self._selecting
	self._selectButton.Visible = not self._roblox
	for id, card in self._cards do
		card:setBusy(if busy ~= nil and snap.busyId == id then "…" else nil)
	end
	self._sheet:setBusy(if busy ~= nil and snap.busyId == self._sheet:outfitId() then "…" else nil)

	-- lembar detail ikut menyegarkan bila outfitnya berubah
	local openId = self._sheet:outfitId()
	if openId then
		for _, outfit in snap.outfits do
			if outfit.id == openId then
				self._sheet:open(outfit)
			end
		end
	end
	self:_refreshSelection()

	self._sortButton.Text = OutfitSort.labelOf(snap.sortKey) .. " ▼"
	if not self._roblox and self._search.Text ~= snap.query and not self._search:IsFocused() then
		self._search.Text = snap.query
	end

	-- status
	local n = #rows
	local showStatus = false
	if self._roblox then
		if self._userStatus ~= nil then
			showStatus = true -- cabang ini hanya untuk "sedang mencari" / gagal
			if self._userStatus == "loading" then
				self._statusTitle.Text = "Looking up that player…"
				self._statusHint.Text = ""
			elseif self._userStatus == "NO_USER" or self._userStatus == "BAD_NAME" then
				self._statusTitle.Text = "No player with that username"
				self._statusHint.Text = "Check the spelling, or clear the box for your own outfits."
			else
				self._statusTitle.Text = "Couldn't load that player"
				self._statusHint.Text = ""
			end
			self._retry.Visible = false
			self._status.Visible = showStatus
			return
		end
		if self._robloxStatus == "loading" then
			showStatus = true
			self._statusTitle.Text = "Loading your Roblox outfits…"
			self._statusHint.Text = ""
			self._retry.Visible = false
		elseif self._robloxStatus ~= nil then
			showStatus = true
			local denied = self._robloxStatus == "DENIED"
			self._statusTitle.Text = if denied
				then "Roblox needs your permission"
				else "Couldn't load your Roblox outfits"
			self._statusHint.Text = if denied then "Tap Retry and allow the inventory prompt." else ""
			self._retry.Visible = true
		elseif n == 0 then
			showStatus = true
			self._statusTitle.Text = "No Roblox outfits found"
			self._statusHint.Text = "Outfits you save on Roblox show up here."
			self._retry.Visible = true
		end
		self._status.Visible = showStatus
		return
	end
	if not snap.loaded then
		showStatus = true
		if snap.loading or snap.error == nil then
			self._statusTitle.Text = "Loading outfits…"
			self._statusHint.Text = ""
			self._retry.Visible = false
		else
			local unavailable = snap.error == "DISABLED"
			self._statusTitle.Text = if unavailable then "Outfits are unavailable" else "Couldn't load your outfits"
			self._statusHint.Text = if snap.error == "NOT_LOADED"
				then "Your data is still loading. Try again in a moment."
				else ""
			self._retry.Visible = not unavailable
		end
	elseif n == 0 then
		showStatus = true
		if snap.query ~= "" then
			self._statusTitle.Text = "No outfits match your search"
			self._statusHint.Text = ""
		elseif snap.folderFilter == OutfitSort.NONE then
			self._statusTitle.Text = "Semua outfit sudah masuk folder"
			self._statusHint.Text = ""
		elseif type(snap.folderFilter) == "number" then
			self._statusTitle.Text = "Folder ini masih kosong"
			self._statusHint.Text = "Pakai Select Outfits untuk memindahkan outfit ke sini."
		else
			self._statusTitle.Text = "No saved outfits yet"
			self._statusHint.Text = "Tap + to save what you're wearing."
		end
		self._retry.Visible = false
	end
	self._status.Visible = showStatus

	-- toggle setting
	local on = snap.restoreOutfit == true
	local known = snap.restoreOutfit ~= nil
	self._switch.BackgroundColor3 = if on then Tokens.Color.Accent else Tokens.Color.PanelRaised
	self._switch.BackgroundTransparency = if on then 0 else Tokens.Transparency.PanelRaised
	self._switch.AutoButtonColor = known and busy == nil
	self._knob.Position = if on then UDim2.new(1, -23, 0.5, 0) else UDim2.new(0, 3, 0.5, 0)
	self._knob.BackgroundTransparency = if known then 0 else 0.6
end

-- Buka: muat ulang daftar (bisa berubah dari perangkat lain).
function WardrobePanel.setOpen(self: WardrobePanel, open: boolean)
	self.instance.Visible = open
	if open then
		self._roblox = false -- openRoblox() yang menyalakannya lagi
		self._robloxToken += 1
		self._grid.CanvasPosition = Vector2.zero
		local ctl = self._props.controller
		task.spawn(ctl.refresh, ctl)
		self:_resizeCells()
	else
		self:_setSelecting(false)
		self:_dismiss()
		self._prompt:close()
		self._dialog:close()
		self._sortMenu.Visible = false
		self._sheet:close()
		self._search:ReleaseFocus()
	end
end

function WardrobePanel.isOpen(self: WardrobePanel): boolean
	return self.instance.Visible
end

function WardrobePanel.destroy(self: WardrobePanel)
	self._unsubscribe()
	for id, card in self._cards do
		card:destroy()
		self._cards[id] = nil
	end
	self._sheet:destroy()
	self._dialog:destroy()
	self._prompt:destroy()
	for _, c in self._tabConns do
		c:Disconnect()
	end
	table.clear(self._tabConns)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return WardrobePanel
