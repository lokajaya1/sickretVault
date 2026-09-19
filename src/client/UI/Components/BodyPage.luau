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
local ColorPicker = require(script.Parent.ColorPicker)

local SWATCH = 34
local GAP = Tokens.Space.S

-- Palet warna kulit. Enam baris nada, dari terang ke gelap, plus baris warna cerah seperti CAC.
local PALETTE = {
	-- Enam baris nada kulit dari terang ke gelap (mengikuti rentang Catalog Avatar Creator),
	-- lalu dua baris warna cerah. Delapan per baris.
	"FFF1E0",
	"FBE3CC",
	"F6D5B8",
	"F0C6A2",
	"E8B68D",
	"DFA579",
	"D49466",
	"C78454",
	"F7E0C9",
	"EDCBA9",
	"E0B58A",
	"D19F6E",
	"C08A55",
	"AE763F",
	"9B632C",
	"87511C",
	"E8CBB0",
	"D4AF8E",
	"BE946E",
	"A67A52",
	"8D6139",
	"744A24",
	"5C3614",
	"44240A",
	"F2D9C4",
	"DDBFA6",
	"C4A187",
	"A88268",
	"8C654B",
	"6F4A32",
	"52321D",
	"351E0E",
	"FFFFFF",
	"F0F0F0",
	"D9D9D9",
	"BFBFBF",
	"A3A2A5",
	"7A7A7C",
	"4D4D50",
	"1B1B1D",
	"F5E6D3",
	"E9D2B6",
	"CDB395",
	"B09474",
	"927556",
	"73573A",
	"553C22",
	"37240F",
	"E25656",
	"F0863C",
	"F0A63C",
	"E2B74D",
	"C9D14F",
	"6FBF73",
	"4FBFA3",
	"4FA3D1",
	"5C6BC0",
	"7E57C2",
	"9575CD",
	"B466C4",
	"D97BA8",
	"E2708A",
	"8D6E63",
	"5D4037",
}

-- Diagram badan yang bisa diketuk: tiap bagian sebuah tombol, warnanya mengikuti warna yang
-- sedang dipakai, dan yang terpilih diberi garis putih. Jauh lebih jelas daripada deretan chip
-- "L Arm / R Arm" -- pemain menunjuk bagiannya langsung, seperti di CAC.
-- Kotaknya digambar dari Frame (bukan gambar/glyph): temuan #30 no. 12.
local FIGURE = {
	{ slot = "HeadColor", x = 38, y = 0, w = 44, h = 40 },
	{ slot = "LeftArmColor", x = 6, y = 44, w = 28, h = 54 },
	{ slot = "TorsoColor", x = 38, y = 44, w = 44, h = 54 },
	{ slot = "RightArmColor", x = 86, y = 44, w = 28, h = 54 },
	{ slot = "LeftLegColor", x = 38, y = 102, w = 21, h = 50 },
	{ slot = "RightLegColor", x = 61, y = 102, w = 21, h = 50 },
}

local SCALES = {
	{ slot = "HeightScale", label = "Height" },
	{ slot = "WidthScale", label = "Width" },
	{ slot = "DepthScale", label = "Depth" },
	{ slot = "HeadScale", label = "Head" },
	{ slot = "BodyTypeScale", label = "Body Type" },
	{ slot = "ProportionScale", label = "Proportions" },
}

local BodyPage = {}
BodyPage.__index = BodyPage

export type Limits = { [string]: { min: number, max: number, default: number } }
export type Props = {
	parent: Instance,
	limits: Limits,
	onColor: (string, string) -> (),
	onScale: (string, number) -> (),
	onRig: (string) -> (),
}

export type BodyPage = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_scroll: ScrollingFrame,
		_swatches: { [string]: Frame },
		_partRow: Frame,
		_partChips: { [string]: TextButton },
		_advanced: TextButton,
		_custom: TextButton,
		_picker: ColorPicker.ColorPicker,
		_sliders: { [string]: Slider.Slider },
		_slot: string,
		_colorNodes: { GuiObject },
		_scaleNodes: { GuiObject },
		_section: string,
		_current: string?,
		_colors: { [string]: string }?,
		_advancedOn: boolean,
		_partLabel: TextLabel,
		_rigButtons: { [string]: TextButton },
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

local function heading(text: string, order: number, parent: Instance): TextLabel
	return make("TextLabel", {
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
		_colorNodes = {},
		_scaleNodes = {},
		_section = "color",
		_current = nil,
		_colors = nil,
		_advancedOn = false,
		_partLabel = nil :: any,
		_rigButtons = {},
		_picker = nil :: any,
		_on = props,
		_conns = {},
	}, BodyPage) :: any

	local skinHead = heading("Skin Tone", 1, scroll)

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
	local custom = make("TextButton", {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		AutoButtonColor = false,
		Text = "Custom Color",
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })
	self._custom = custom
	table.insert(
		self._conns,
		custom.Activated:Connect(function()
			-- Warna awal picker = warna bagian yang sedang disorot, bukan selalu merah.
			self._picker:open(self._current)
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
	self._advanced = advanced
	table.insert(
		self._conns,
		advanced.Activated:Connect(function()
			self:_setAdvanced(self._slot == "all")
		end)
	)

	local partRow = make("Frame", {
		LayoutOrder = 5,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 152),
	})
	self._partRow = partRow
	for i, part in FIGURE do
		local btn = make("TextButton", {
			LayoutOrder = i,
			Position = UDim2.fromOffset(part.x, part.y),
			Size = UDim2.fromOffset(part.w, part.h),
			BackgroundColor3 = Color3.fromRGB(64, 64, 68),
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Parent = partRow,
		}, {
			make("UICorner", { CornerRadius = Tokens.Radius.Small }),
			make("UIStroke", { Thickness = 1, Color = Tokens.Color.Stroke, Transparency = 0 }),
		})
		self._partChips[part.slot] = btn
		table.insert(
			self._conns,
			btn.Activated:Connect(function()
				-- Mengetuk sebuah bagian BERARTI memilih bagian itu -- kalau ketukannya diam saja
				-- selama Advanced Colors mati, diagramnya terasa rusak. Jadi ketukan itu sendiri
				-- yang menyalakan Advanced Colors.
				self:_setAdvanced(true)
				self._slot = part.slot
				self:_syncChips()
			end)
		)
	end

	-- Diagram badan dan tombolnya BERDAMPINGAN: diagram di kiri dengan garis tepi supaya terbaca
	-- sebagai satu benda, Custom Color & Advanced Colors di kanan. Dipisah baris, pemain harus
	-- menggulir untuk melihat keduanya dan tidak jelas bahwa tombolnya mengenai bagian terpilih.
	local colorRow = make("Frame", {
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 152),
	})
	colorRow.Parent = scroll
	partRow.Parent = colorRow
	self._partLabel = make("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(132, 4),
		Size = UDim2.new(1, -132, 0, 22),
		FontFace = Tokens.Font.Medium,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Coloring: All",
		Parent = colorRow,
	})
	partRow.Size = UDim2.fromOffset(120, 152)
	partRow.BackgroundColor3 = Tokens.Color.PanelRaised
	partRow.BackgroundTransparency = Tokens.Transparency.PanelRaised
	make("UICorner", { CornerRadius = Tokens.Radius.Medium }).Parent = partRow
	make("UIStroke", {
		Color = Tokens.Color.Stroke,
		Transparency = Tokens.Transparency.Stroke,
		Thickness = 1,
	}).Parent =
		partRow
	custom.Parent = colorRow
	custom.Position = UDim2.fromOffset(132, 34)
	custom.Size = UDim2.new(1, -132, 0, 36)
	advanced.Parent = colorRow
	advanced.Position = UDim2.fromOffset(132, 82)
	advanced.Size = UDim2.new(1, -132, 0, 36)

	local scaleHead = heading("Scale", 6, scroll)

	-- Rig Type: R6 / R15. Bukan slider, tapi tempatnya memang di halaman Scale (pola CAC).
	local rigRow = make("Frame", {
		LayoutOrder = 7,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 56),
	}, {
		make("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 20),
			FontFace = Tokens.Font.Regular,
			TextSize = Tokens.TextSize.Body,
			TextColor3 = Tokens.Color.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "Rig Type",
		}),
	})
	rigRow.Parent = scroll
	for i, rig in { "R6", "R15" } do
		local b = make("TextButton", {
			Position = UDim2.fromOffset((i - 1) * 76, 24),
			Size = UDim2.fromOffset(70, 30),
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			FontFace = Tokens.Font.Medium,
			TextSize = Tokens.TextSize.Body,
			TextColor3 = Tokens.Color.TextMuted,
			Text = rig,
			Parent = rigRow,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })
		self._rigButtons[rig] = b
		table.insert(
			self._conns,
			b.Activated:Connect(function()
				-- Sorotan mengikuti ketukan SEKARANG: setState hanya dipanggil saat panel dibuka,
				-- jadi tanpa ini tombolnya diam sampai panel ditutup-buka. Kalau server menolak,
				-- setState berikutnya yang mengoreksi.
				self:_syncRig(rig)
				props.onRig(rig)
			end)
		)
	end
	for i, s in SCALES do
		local lim = props.limits[s.slot]
		if lim then
			self._sliders[s.slot] = Slider.new({
				parent = scroll,
				order = 8 + i,
				label = s.label,
				min = lim.min,
				max = lim.max,
				-- SCALE_LIMITS boleh saja tidak punya `default` (tabelnya ditulis min/max saja).
				-- Tanpa cadangan ini Slider menerima nil dan meledak di string.format.
				value = lim.default or math.clamp(1, lim.min, lim.max),
				format = function(v: number): string
					return string.format("%d%%", math.floor(v * 100 + 0.5))
				end,
				onChange = function(v, final)
					if final then
						props.onScale(s.slot, v)
					end
				end,
			})
		end
	end

	self._colorNodes = { skinHead, grid, colorRow }
	self._scaleNodes = { scaleHead, rigRow }
	self._picker = ColorPicker.new({
		parent = props.parent,
		onPick = function(hex)
			self._on.onColor(self._slot, hex)
		end,
	})
	self:_syncChips()
	self:setSection("color")
	return self
end

-- "color" = palet + Custom + Advanced Colors; "scale" = lima slider. Satu ScrollingFrame,
-- isinya yang ditukar -- bukan dua panel yang harus dijaga sinkron.
function BodyPage.setSection(self: BodyPage, section: string)
	self._section = section
	local color = section ~= "scale"
	for _, n in self._colorNodes do
		n.Visible = color
	end
	for _, n in self._scaleNodes do
		n.Visible = not color
	end
	for _, s in self._sliders do
		s:setVisible(not color)
	end
	self._partRow.Visible = color
end

function BodyPage._setAdvanced(self: BodyPage, on: boolean)
	self._advancedOn = on
	self._slot = if on then "HeadColor" else "all"
	self._advanced.Text = if on then "Advanced Colors: On" else "Advanced Colors: Off"
	self._advanced.TextColor3 = if on then Tokens.Color.Accent else Tokens.Color.TextMuted
	self:_syncChips()
end

function BodyPage._syncChips(self: BodyPage)
	for slot, btn in self._partChips do
		local active = self._slot == "all" or self._slot == slot
		local stroke = btn:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 0
			stroke.Color = if active then Tokens.Color.Text else Tokens.Color.Stroke
			stroke.Thickness = if active then 3 else 1
		end
		-- Bagian yang TIDAK kena diredupkan. Dengan Advanced Colors mati semuanya terang, dan itu
		-- memang benar: warnanya akan kena ke seluruh badan.
		btn.BackgroundTransparency = if active then 0 else 0.55
		local hex = if self._colors then self._colors[slot] else nil
		btn.BackgroundColor3 = if hex then Color3.fromHex(hex) else Color3.fromRGB(64, 64, 68)
	end
	if self._partLabel then
		local names = {
			all = "All",
			HeadColor = "Head",
			TorsoColor = "Torso",
			LeftArmColor = "Left Arm",
			RightArmColor = "Right Arm",
			LeftLegColor = "Left Leg",
			RightLegColor = "Right Leg",
		}
		self._partLabel.Text = "Coloring: " .. (names[self._slot] or self._slot)
	end
end

-- Dipanggil setiap state server berubah (termasuk Undo): cincin petak + posisi slider mengikuti
-- KEADAAN SEBENARNYA, bukan apa yang terakhir ditekan pemain.
function BodyPage.setState(self: BodyPage, colors: { [string]: string }?, scales: { [string]: number }?, rig: string?)
	local shown = if colors then colors[if self._slot == "all" then "HeadColor" else self._slot] else nil
	self._current = shown
	self._colors = colors
	self:_syncChips()
	for hex, ring in self._swatches do
		local stroke = ring:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = if shown ~= nil and hex == string.upper(shown) then 0 else 1
		end
	end
	self:_syncRig(rig)
	if scales then
		for slot, slider in self._sliders do
			local v = scales[slot]
			if type(v) == "number" then
				slider:set(v)
			end
		end
	end
end

function BodyPage._syncRig(self: BodyPage, rig: string?)
	for name, b in self._rigButtons do
		local on = name == rig
		b.BackgroundColor3 = if on then Tokens.Color.Accent else Tokens.Color.PanelRaised
		b.TextColor3 = if on then Tokens.Color.AccentText else Tokens.Color.TextMuted
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
	self._picker:destroy()
	self.instance:Destroy()
end

return BodyPage
