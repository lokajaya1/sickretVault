--!strict
-- Panel katalog: judul + tutup, kotak cari, tab kategori, grid ItemCard (infinite scroll), status.
-- Hanya MENAMPILKAN state CatalogController dan meneruskan aksi pemain ke controller.
--   local panel = CatalogPanel.new({ controller = catalog, parent = screenGui, onItemActivated = fn })
--   panel:setVisible(true)   panel:destroy()

local Workspace = game:GetService("Workspace")

local Categories = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config.Categories)
local Tokens = require(script.Parent.Parent.Theme.Tokens)
local ItemCard = require(script.Parent.ItemCard)

local SEARCH_DEBOUNCE = 0.6 -- detik setelah berhenti mengetik
local HEADER_H = 40
local GAP = Tokens.Space.S

export type Props = {
	controller: any, -- CatalogController
	parent: Instance,
	onItemActivated: ((item: any) -> ())?,
	onClose: (() -> ())?,
	isSelected: ((item: any) -> boolean)?, -- true = kartu diberi sorotan (item sedang dipakai)
}

local CatalogPanel = {}
CatalogPanel.__index = CatalogPanel

export type CatalogPanel = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_grid: ScrollingFrame,
		_status: TextLabel,
		_retry: TextButton,
		_search: TextBox,
		_tabs: { [string]: TextButton },
		_cards: { ItemCard.ItemCard },
		_conns: { RBXScriptConnection },
		_unsubscribe: () -> (),
		_searchToken: number,
		_lastCount: number,
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

-- Jalankan fungsi controller di thread baru (remote akan yield).
local function spawnCall(fn: (...any) -> ...any, ...: any)
	task.spawn(fn, ...)
end

function CatalogPanel.new(props: Props): CatalogPanel
	local ctl = props.controller

	local root: Frame = make("Frame", {
		Name = "CatalogPanel",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, Tokens.Space.L, 0, 72),
		Size = UDim2.new(Tokens.Size.PanelWidth, 0, 1, -72 - Tokens.Space.L),
		BackgroundColor3 = Tokens.Color.Panel,
		BackgroundTransparency = Tokens.Transparency.Panel,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = Tokens.ZIndex.Panel,
		Parent = props.parent,
	}, {
		corner(Tokens.Radius.Large),
		make("UISizeConstraint", {
			MinSize = Vector2.new(Tokens.Size.PanelMinWidth, 0),
			MaxSize = Vector2.new(Tokens.Size.PanelMaxWidth, math.huge),
		}),
		make("UIPadding", {
			PaddingTop = UDim.new(0, Tokens.Space.M),
			PaddingBottom = UDim.new(0, Tokens.Space.M),
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
		}),
	})

	-- Header: judul + tombol tutup
	make("TextLabel", {
		Name = "Title",
		Text = "Catalog",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -HEADER_H, 0, HEADER_H),
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

	-- Kotak cari
	local searchTop = HEADER_H + GAP
	local search: TextBox = make("TextBox", {
		Name = "Search",
		PlaceholderText = "Search catalog...",
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

	-- Tab kategori (geser horizontal)
	local tabsTop = searchTop + Tokens.Size.SearchHeight + GAP
	local tabBar: ScrollingFrame = make("ScrollingFrame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, tabsTop),
		Size = UDim2.new(1, 0, 0, Tokens.Size.TabHeight + 6),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 3,
		ZIndex = Tokens.ZIndex.Panel,
		Parent = root,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.XS + 2),
		}),
	})

	local tabs: { [string]: TextButton } = {}
	local conns: { RBXScriptConnection } = {}
	for i, cat in Categories.list do
		local b = textButton(cat.label, {
			Name = "Tab_" .. cat.id,
			LayoutOrder = i,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, Tokens.Size.TabHeight),
			TextSize = Tokens.TextSize.Body,
			Parent = tabBar,
		})
		make("UIPadding", {
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
			Parent = b,
		})
		tabs[cat.id] = b
		table.insert(
			conns,
			b.Activated:Connect(function()
				spawnCall(ctl.setCategory, ctl, cat.id)
			end)
		)
	end

	-- Grid item
	local gridTop = tabsTop + Tokens.Size.TabHeight + 6 + GAP
	local statusH = 28
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
		make("UIGridLayout", {
			CellSize = UDim2.fromOffset(Tokens.Size.Card.X, Tokens.Size.Card.Y),
			CellPadding = UDim2.fromOffset(GAP, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder, -- penting: default bisa urut Name
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
		make("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 2) }),
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

	local self = setmetatable({
		instance = root,
		_props = props,
		_grid = grid,
		_status = status,
		_retry = retry,
		_search = search,
		_tabs = tabs,
		_cards = {},
		_conns = conns,
		_unsubscribe = function() end,
		_searchToken = 0,
		_lastCount = 0,
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
		retry.Activated:Connect(function()
			spawnCall(ctl.retry, ctl)
		end)
	)

	-- Cari: Enter langsung, mengetik -> debounce
	local function submitSearch()
		self._searchToken += 1
		spawnCall(ctl.setKeyword, ctl, search.Text)
	end
	table.insert(
		conns,
		search.FocusLost:Connect(function(enter: boolean)
			if enter then
				submitSearch()
			end
		end)
	)
	table.insert(
		conns,
		search:GetPropertyChangedSignal("Text"):Connect(function()
			self._searchToken += 1
			local token = self._searchToken
			task.delay(SEARCH_DEBOUNCE, function()
				if token == self._searchToken then
					submitSearch()
				end
			end)
		end)
	)

	-- Infinite scroll
	table.insert(
		conns,
		grid:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			self:_maybeLoadMore()
		end)
	)

	-- Lebar panel: ponsel -> lebih lebar
	local function applyWidth()
		local cam = Workspace.CurrentCamera
		local w = if cam then cam.ViewportSize.X else 1000
		local scale = if w < Tokens.Breakpoint.Phone then Tokens.PanelWidthPhone else Tokens.Size.PanelWidth
		root.Size = UDim2.new(scale, 0, 1, -72 - Tokens.Space.L)
	end
	applyWidth()
	local cam = Workspace.CurrentCamera
	if cam then
		table.insert(conns, cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyWidth))
	end

	self._unsubscribe = ctl:onChanged(function(state)
		self:_render(state)
	end)
	self:_render(ctl:getState())
	return self
end

function CatalogPanel._maybeLoadMore(self: CatalogPanel)
	local grid = self._grid
	if not self.instance.Visible then
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

function CatalogPanel._render(self: CatalogPanel, state: any)
	-- Tab aktif
	for id, b in self._tabs do
		local active = id == state.categoryId
		b.BackgroundColor3 = if active then Tokens.Color.Accent else Tokens.Color.PanelRaised
		b.TextColor3 = if active then Tokens.Color.AccentText else Tokens.Color.TextMuted
	end

	-- Daftar baru (reset) -> gulir ke atas
	if #state.items < self._lastCount then
		self._grid.CanvasPosition = Vector2.zero
	end
	self._lastCount = #state.items

	-- Kartu: pakai ulang yang ada, buat bila kurang, hapus kelebihan
	local cards = self._cards
	for i, item in state.items do
		local card = cards[i]
		if card == nil then
			card = ItemCard.new({ item = item, layoutOrder = i, onActivated = self._props.onItemActivated })
			card.instance.Parent = self._grid
			cards[i] = card
		elseif card.item ~= item then
			card:setItem(item)
		end
		card:setSelected(self:_isSelected(item))
	end
	for i = #cards, #state.items + 1, -1 do
		cards[i]:destroy()
		cards[i] = nil
	end

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
	self._retry.Visible = state.error ~= nil

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

-- Perbarui sorotan semua kartu (dipanggil saat outfit berubah).
-- Perbarui sorotan semua kartu (dipanggil saat outfit berubah).
function CatalogPanel.refreshSelection(self: CatalogPanel)
	for _, card in self._cards do
		card:setSelected(self:_isSelected(card.item))
	end
end

function CatalogPanel.setVisible(self: CatalogPanel, visible: boolean)
	self.instance.Visible = visible
	local state = self._props.controller:getState()
	if visible and state.page == 0 and not state.loading then
		spawnCall(self._props.controller.setCategory, self._props.controller, state.categoryId)
	end
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
	self.instance:Destroy()
end

return CatalogPanel
