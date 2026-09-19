--!strict
-- Halaman "Body" di panel katalog: warna kulit + skala badan (pola Catalog Avatar Creator).
--   local page = BodyPage.new({
--     parent = panelFrame, limits = OutfitState.SCALE_LIMITS,
--     onColor = function(slot, hex) end,   -- slot "all" = palet kulit
--     onScale = function(slot, value) end,
--   })
--   page:setVisible(true)   page:setArea(x, y, w, h)   page:setState(colors, scales)
-- BENTUK: satu ScrollingFrame. Isinya TIDAK pernah dipaksa muat -- di layar pendek ia bergulir,
-- bukan mengecil dan bukan tumpang tindih (temuan #30 no. 22).
-- Advanced Colors MATI -> mengetuk petak warna mewarnai SELURUH badan ("all").
-- Advanced Colors HIDUP -> muncul enam chip bagian tubuh; petak warna mengenai bagian terpilih.
-- Halaman ini tidak tahu apa-apa soal intent/server: ia memanggil onColor/onScale, titik.

local Tokens = require(script.Parent.Parent.Theme.Tokens)
local Slider = require(script.Parent.Slider)

local SWATCH = 34
local GAP = Tokens.Space.S

-- Palet warna kulit. Enam baris nada, dari terang ke gelap, plus baris warna cerah seperti CAC.
local PALETTE = {
	"F8E0C8",
	"F2D1B0",
	"E8BE96",
	"D9A67C",
	"C58C63",
	"A9714C",
	"8C5A3C",
	"6E442C",
	"543322",
	"3B2418",
	"FFF3E4",
	"EADBC8",
	"A3A2A5",
	"D9D9D9",
	"FFFFFF",
	"1B1B1B",
	"E25656",
	"F0A63C",
	"E2B74D",
	"6FBF73",
	"4FA3D1",
	"5C6BC0",
	"9575CD",
	"D97BA8",
}

local PARTS = {
	{ slot = "HeadColor", label = "Head" },
	{ slot = "TorsoColor", label = "Torso" },
	{ slot = "LeftArmColor", label = "L Arm" },
	{ slot = "RightArmColor", label = "R Arm" },
	{ slot = "LeftLegColor", label = "L Leg" },
	{ slot = "RightLegColor", label = "R Leg" },
}

-- Depth sengaja TIDAK ditawarkan: editor avatar Roblox pun tidak punya slidernya.
local SCALES = {
	{ slot = "HeightScale", label = "Height" },
	{ slot = "WidthScale", label = "Width" },
	{ slot = "HeadScale", label = "Head" },
	{ slot = "BodyTypeScale", label = "Body Type" },
	{ slot = "ProportionScale", label = "Proportion" },
}

local BodyPage = {}
BodyPage.__index = BodyPage

export type Limits = { [string]: { min: number, max: number, default: number } }
export type Props = {
	parent: Instance,
	limits: Limits,
	onColor: (string, string) -> (),
	onScale: (string, number) -> (),
}

export type BodyPage = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_scroll: ScrollingFrame,
		_swatches: { [string]: Frame },
		_partRow: Frame,
		_partChips: { [string]: TextButton },
		_advanced: TextButton,
		_custom: TextBox,
		_sliders: { [string]: Slider.Slider },
		_slot: string,
		_on: Props,
		_conns: { RBXScriptConnection },
	},
	BodyPage
))

local function make(className: string, props: { [string]: any }, children: { Instance }?): any
	local x = Instance.new(className)
	for k, v in props do
		(x :: any)[k] = v
	end
	if children then
		for _, c in children do
			c.Parent = x
		end
	end
	return x
end

local function heading(text: string, order: number, parent: Instance)
	make("TextLabel", {
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 22),
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		Parent = parent,
	})
end

function BodyPage.new(props: Props): BodyPage
	local scroll = make("ScrollingFrame", {
		Name = "BodyScroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Tokens.Color.Accent,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, {
		make("UIListLayout", { Padding = UDim.new(0, GAP), SortOrder = Enum.SortOrder.LayoutOrder }),
		make("UIPadding", {
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
			PaddingTop = UDim.new(0, Tokens.Space.S),
			PaddingBottom = UDim.new(0, Tokens.Space.XL),
		}),
	})

	local root = make("Frame", {
		Name = "BodyPage",
		BackgroundTransparency = 1,
		Visible = false,
		Size = UDim2.fromScale(1, 1),
	}, { scroll })
	root.Parent = props.parent

	local self: BodyPage = setmetatable({
		instance = root,
		_scroll = scroll,
		_swatches = {},
		_partRow = nil :: any,
		_partChips = {},
		_advanced = nil :: any,
		_custom = nil :: any,
		_sliders = {},
		_slot = "all",
		_on = props,
		_conns = {},
	}, BodyPage) :: any

	heading("Skin Tone", 1, scroll)

	local grid = make("Frame", {
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.fromOffset(SWATCH, SWATCH),
			CellPadding = UDim2.fromOffset(Tokens.Space.XS, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	grid.Parent = scroll

	for i, hex in PALETTE do
		local ring = make("Frame", {
			BackgroundTransparency = 1,
			LayoutOrder = i,
		}, {
			make("UIStroke", {
				Thickness = 2,
				Color = Tokens.Color.Accent,
				Transparency = 1, -- 0 saat warna ini sedang dipakai
			}),
			make("UICorner", { CornerRadius = Tokens.Radius.Small }),
		})
		local btn = make("TextButton", {
			BackgroundColor3 = Color3.fromHex(hex),
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			Size = UDim2.fromScale(1, 1),
			Parent = ring,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })
		ring.Parent = grid
		self._swatches[hex] = ring
		table.insert(
			self._conns,
			btn.Activated:Connect(function()
				self._on.onColor(self._slot, hex)
			end)
		)
	end

	-- Custom Color: kotak hex. Validator server yang memutuskan sah atau tidak -- di sini tidak ada
	-- salinan aturan hex kedua.
	local custom = make("TextBox", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		PlaceholderText = "Custom color, contoh A3A2A5",
		PlaceholderColor3 = Tokens.Color.TextMuted,
		ClearTextOnFocus = false,
		Text = "",
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })
	custom.Parent = scroll
	self._custom = custom
	table.insert(
		self._conns,
		custom.FocusLost:Connect(function(enter)
			if enter and custom.Text ~= "" then
				self._on.onColor(self._slot, custom.Text)
			end
		end)
	)

	-- Advanced Colors: mewarnai per bagian, bukan seluruh badan.
	local advanced = make("TextButton", {
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		FontFace = Tokens.Font.Medium,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.TextMuted,
		Text = "Advanced Colors: Off",
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })
	advanced.Parent = scroll
	self._advanced = advanced
	table.insert(
		self._conns,
		advanced.Activated:Connect(function()
			self:_setAdvanced(self._slot == "all")
		end)
	)

	local partRow = make("Frame", {
		LayoutOrder = 5,
		Visible = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.fromOffset(84, 28),
			CellPadding = UDim2.fromOffset(Tokens.Space.XS, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	partRow.Parent = scroll
	self._partRow = partRow
	for i, p in PARTS do
		local chip = make("TextButton", {
			LayoutOrder = i,
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			FontFace = Tokens.Font.Regular,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.TextMuted,
			Text = p.label,
			Parent = partRow,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })
		self._partChips[p.slot] = chip
		table.insert(
			self._conns,
			chip.Activated:Connect(function()
				self._slot = p.slot
				self:_syncChips()
			end)
		)
	end

	heading("Scale", 6, scroll)
	for i, s in SCALES do
		local lim = props.limits[s.slot]
		if lim then
			self._sliders[s.slot] = Slider.new({
				parent = scroll,
				order = 6 + i,
				label = s.label,
				min = lim.min,
				max = lim.max,
				value = lim.default,
				onChange = function(v, final)
					if final then
						props.onScale(s.slot, v)
					end
				end,
			})
		end
	end

	return self
end

function BodyPage._setAdvanced(self: BodyPage, on: boolean)
	self._slot = if on then PARTS[1].slot else "all"
	self._partRow.Visible = on
	self._advanced.Text = if on then "Advanced Colors: On" else "Advanced Colors: Off"
	self._advanced.TextColor3 = if on then Tokens.Color.Accent else Tokens.Color.TextMuted
	self:_syncChips()
end

function BodyPage._syncChips(self: BodyPage)
	for slot, chip in self._partChips do
		local active = slot == self._slot
		chip.BackgroundColor3 = if active then Tokens.Color.Accent else Tokens.Color.PanelRaised
		chip.TextColor3 = if active then Tokens.Color.AccentText else Tokens.Color.TextMuted
	end
end

-- Dipanggil setiap state server berubah (termasuk Undo): cincin petak + posisi slider mengikuti
-- KEADAAN SEBENARNYA, bukan apa yang terakhir ditekan pemain.
function BodyPage.setState(self: BodyPage, colors: { [string]: string }?, scales: { [string]: number }?)
	local shown = if colors then colors[if self._slot == "all" then "HeadColor" else self._slot] else nil
	for hex, ring in self._swatches do
		local stroke = ring:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = if shown ~= nil and hex == string.upper(shown) then 0 else 1
		end
	end
	if scales then
		for slot, slider in self._sliders do
			local v = scales[slot]
			if type(v) == "number" then
				slider:set(v)
			end
		end
	end
end

function BodyPage.setVisible(self: BodyPage, on: boolean)
	self.instance.Visible = on
end

function BodyPage.setArea(self: BodyPage, x: number, y: number, w: number, h: number)
	self.instance.Position = UDim2.fromOffset(x, y)
	self.instance.Size = UDim2.fromOffset(w, h)
end

function BodyPage.destroy(self: BodyPage)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	for _, s in self._sliders do
		s:destroy()
	end
	self.instance:Destroy()
end

return BodyPage
