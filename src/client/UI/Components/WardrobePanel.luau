--!strict
-- Panel "Saved Outfits" (pola CAC): MENUTUPI isi panel katalog (anak dari CatalogPanel.instance).
--   local panel = WardrobePanel.new({
--   	parent = catalogPanel.instance, controller = wardrobeController, previews = outfitPreview,
--   	onResult = function(op, ok, code, name) ... end,  -- untuk toast
--   	onBack = function() ... end,                       -- tombol X
--   })
--   panel:setOpen(true)   panel:isOpen()   panel:destroy()
-- Isi: Search + X; tab "All" + dropdown sort; grid kartu (kartu pertama "+" = simpan outfit sekarang);
-- Kartu punya ikon hapus (dua tap) selain bintang favorit.
-- Tombol "+" membuka dialog nama dulu (boleh dikosongkan -> server memberi nama "Outfit N").
-- bawah: toggle "Wear last outfit when joining". Tap kartu -> WEAR / VIEW; VIEW -> OutfitDetailSheet.
-- Folder & "Select Outfits" menyusul di PR berikutnya (lihat claude/Pedoman_Layout_CAC.md).
-- Kartu dipakai ulang selama id & updatedAt sama supaya model 3D tidak dibuat ulang.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local OutfitSort = require(Shared.Domain.OutfitSort)
local Tokens = require(script.Parent.Parent.Theme.Tokens)
local OutfitCard = require(script.Parent.OutfitCard)
local OutfitDetailSheet = require(script.Parent.OutfitDetailSheet)

local SEARCH_H = 36
local TABS_H = 30
local FOOTER_H = 32
local CLOSE_W = 36
local SORT_W = 168
local SWITCH_W = 52
local CELL_MIN = 132 -- lebar kartu minimum -> jumlah kolom menyesuaikan lebar panel
local CELL_RATIO = 1.32 -- tinggi kartu = lebar * rasio
local SEARCH_DEBOUNCE = 0.25
local PROMPT_W = 320
local PROMPT_H = 168
local MAX_NAME = 32 -- sama dengan Wardrobe.MAX_NAME (server tetap memvalidasi)
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
		_sortButton: TextButton,
		_sortMenu: Frame,
		_grid: ScrollingFrame,
		_layout: UIGridLayout,
		_add: TextButton,
		_prompt: TextButton,
		_promptBox: TextBox,
		_status: Frame,
		_statusTitle: TextLabel,
		_statusHint: TextLabel,
		_retry: TextButton,
		_switch: TextButton,
		_knob: Frame,
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

-- Teks kotak nama -> nil bila kosong (server yang memberi nama bawaan).
local function cleanName(text: string): string?
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	return if trimmed == "" then nil else trimmed
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

	-- Baris 2: tab "All" (folder menyusul) + dropdown sort
	local tabsTop = SEARCH_H + gap
	-- Tab folder: sementara hanya "All" (folder menyusul di PR berikutnya)
	button("All", {
		Name = "TabAll",
		Position = UDim2.fromOffset(0, tabsTop),
		Size = UDim2.fromOffset(64, TABS_H),
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		Parent = root,
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

	-- Dialog nama (muncul saat kartu "+" ditekan)
	local prompt: TextButton = make("TextButton", {
		Name = "NamePrompt",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = Tokens.Transparency.Overlay,
		BorderSizePixel = 0,
		Visible = false,
		Position = UDim2.fromOffset(-pad, -pad),
		Size = UDim2.new(1, pad * 2, 1, pad * 2),
		ZIndex = Z + 6,
		Parent = root,
	}, { corner(Tokens.Radius.Large) })
	-- TextButton (bukan Frame) supaya klik di dalam kartu tidak menutup dialog.
	local promptCard: TextButton = make("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Panel,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, PROMPT_H),
		ZIndex = Z + 7,
		Parent = prompt,
	}, {
		corner(Tokens.Radius.Large),
		make("UISizeConstraint", { MaxSize = Vector2.new(PROMPT_W, PROMPT_H) }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, pad),
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
		}),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap) }),
	})
	label({
		Name = "PromptTitle",
		Text = "Save current outfit",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 26),
		ZIndex = Z + 7,
		Parent = promptCard,
	})
	label({
		Name = "PromptHint",
		Text = "Kosongkan untuk nama otomatis.",
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 18),
		ZIndex = Z + 7,
		Parent = promptCard,
	})
	local promptBox: TextBox = make("TextBox", {
		Name = "PromptName",
		Text = "",
		PlaceholderText = "Outfit name",
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
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 34),
		ZIndex = Z + 7,
		Parent = promptCard,
	}, {
		corner(Tokens.Radius.Pill),
		make("UIPadding", { PaddingLeft = UDim.new(0, Tokens.Space.M), PaddingRight = UDim.new(0, Tokens.Space.M) }),
	})
	local promptRow: Frame = make("Frame", {
		Name = "PromptActions",
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 34),
		ZIndex = Z + 7,
		Parent = promptCard,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap),
		}),
	})
	local promptHalf = UDim2.new(0.5, -gap / 2, 1, 0)
	local promptCancel = button("Cancel", {
		Name = "Cancel",
		LayoutOrder = 1,
		Size = promptHalf,
		ZIndex = Z + 7,
		Parent = promptRow,
	})
	local promptSave = button("Save", {
		Name = "Save",
		LayoutOrder = 2,
		Size = promptHalf,
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		ZIndex = Z + 7,
		Parent = promptRow,
	})

	local self: WardrobePanel
	local conns: { RBXScriptConnection } = {}

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
		onBack = function()
			self._sheet:close()
		end,
	})

	self = setmetatable({
		instance = root,
		_props = props,
		_search = search,
		_sortButton = sortButton,
		_sortMenu = sortMenu,
		_grid = grid,
		_layout = gridLayout,
		_add = add,
		_prompt = prompt,
		_promptBox = promptBox,
		_status = status,
		_statusTitle = statusTitle,
		_statusHint = statusHint,
		_retry = retry,
		_switch = switch,
		_knob = knob,
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
			self:_dismiss()
			self:_openPrompt()
		end)
	)
	table.insert(
		conns,
		prompt.Activated:Connect(function()
			self:_closePrompt()
		end)
	)
	table.insert(
		conns,
		promptCancel.Activated:Connect(function()
			self:_closePrompt()
		end)
	)
	table.insert(
		conns,
		promptSave.Activated:Connect(function()
			self:_saveCurrent(cleanName(promptBox.Text))
		end)
	)
	table.insert(
		conns,
		promptBox.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				self:_saveCurrent(cleanName(promptBox.Text))
			end
		end)
	)
	table.insert(
		conns,
		promptBox:GetPropertyChangedSignal("Text"):Connect(function()
			local len = utf8.len(promptBox.Text)
			if len and len > MAX_NAME then
				local cut = utf8.offset(promptBox.Text, MAX_NAME + 1)
				if cut then
					promptBox.Text = string.sub(promptBox.Text, 1, cut - 1)
				end
			end
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

-- Dialog nama untuk kartu "+".
function WardrobePanel._openPrompt(self: WardrobePanel)
	local snap = self._snap
	if snap == nil or not snap.loaded or snap.busy ~= nil or snap.isFull then
		return
	end
	self._promptBox.Text = ""
	self._prompt.Visible = true
	self._promptBox:CaptureFocus()
end

function WardrobePanel._closePrompt(self: WardrobePanel)
	if not self._prompt.Visible then
		return
	end
	self._promptBox:ReleaseFocus()
	self._prompt.Visible = false
end

-- name nil -> server memberi nama bawaan ("Outfit N").
function WardrobePanel._saveCurrent(self: WardrobePanel, name: string?)
	local ctl = self._props.controller
	self:_closePrompt()
	self:_act("save", nil, name, function()
		return ctl:save(name)
	end)
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
		onDelete = function(o)
			self:_dismiss()
			self:_act("delete", o.id, o.name, function()
				return ctl:delete(o.id)
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
	end
	for id, card in self._cards do
		if not seen[id] then
			card:destroy()
			self._cards[id] = nil
			self._cardKey[id] = nil
			if self._armedId == id then
				self._armedId = nil
			end
		end
	end
end

function WardrobePanel._render(self: WardrobePanel, snap: any)
	self._snap = snap
	self:_syncCards(snap.visible)

	-- kartu "+" & tombol sibuk
	local busy = snap.busy
	self._add.Text = if busy == "save" then "…" else "+"
	self._add.Visible = not snap.isFull and snap.loaded
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
		self:_dismiss()
		self:_closePrompt()
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
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return WardrobePanel
