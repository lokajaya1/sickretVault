--!strict
-- Akar UI: ScreenGui + tombol atas (Catalog, Stores) + panel katalog.
--   local app = App.mount({ onItemActivated = function(item) ... end })
--   app:toggleCatalog()   app.toast:show("Hello", "info")   app:destroy()

local Players = game:GetService("Players")

local Tokens = require(script.Parent.Theme.Tokens)
local CatalogPanel = require(script.Parent.Components.CatalogPanel)
local Toast = require(script.Parent.Components.Toast)
local CatalogController = require(script.Parent.Parent.Controllers.CatalogController)
local OutfitController = require(script.Parent.Parent.Controllers.OutfitController)

export type Options = {
	onItemActivated: ((item: any) -> ())?,
}

local App = {}
App.__index = App

export type App = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		catalog: CatalogController.CatalogController,
		outfit: OutfitController.OutfitController,
		panel: CatalogPanel.CatalogPanel,
		toast: Toast.Toast,
		_catalogButton: TextButton,
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
	local self: App

	local panel = CatalogPanel.new({
		controller = catalog,
		parent = gui,
		onItemActivated = o.onItemActivated,
		onClose = function()
			self:_refreshButtons()
		end,
		isSelected = function(item)
			return item.itemType ~= "Bundle" and outfit:isWorn(item.id)
		end,
	})

	self = setmetatable({
		gui = gui,
		catalog = catalog,
		outfit = outfit,
		panel = panel,
		toast = toast,
		_catalogButton = catalogButton,
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

	-- Outfit berubah (dari server) -> perbarui sorotan kartu.
	local unsubscribe = outfit:onChanged(function()
		panel:refreshSelection()
	end)
	table.insert(self._conns, { Disconnect = unsubscribe } :: any)
	task.spawn(outfit.start, outfit) -- yield (GetState)

	self:_refreshButtons()
	return self
end

function App._refreshButtons(self: App)
	local open = self.panel:isVisible()
	self._catalogButton.BackgroundColor3 = if open then Tokens.Color.Accent else Tokens.Color.Panel
	self._catalogButton.BackgroundTransparency = if open then 0 else Tokens.Transparency.Panel
end

function App.toggleCatalog(self: App)
	self.panel:setVisible(not self.panel:isVisible())
	self:_refreshButtons()
end

function App.destroy(self: App)
	for _, c in self._conns do
		c:Disconnect()
	end
	self.outfit:stop()
	self.panel:destroy()
	self.toast:destroy()
	self.gui:Destroy()
end

return App
