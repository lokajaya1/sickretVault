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
			task.delay(SEARCH_DEBOUNCE, function()
				if self._searchToken == token then
					ctl:setQuery(text)
				end
			end)
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
		local on = (key == "all" and active == OutfitSort.ALL)
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

function WardrobePanel._render(self: WardrobePanel, snap: any)
	self._snap = snap
	self:_syncTabs(snap)
	self:_syncCards(snap.visible)
	self._dialog:setFolders(snap.folders, snap.foldersFull)

	-- kartu "+" & tombol sibuk
	local busy = snap.busy
	self._add.Text = if busy == "save" then "…" else "+"
	self._add.Visible = not snap.isFull and snap.loaded and not self._selecting
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
	if self._search.Text ~= snap.query and not self._search:IsFocused() then
		self._search.Text = snap.query
	end

	-- status
	local n = #snap.visible
	local showStatus = false
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
