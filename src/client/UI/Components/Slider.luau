--!strict
-- Slider satu baris: label kiri, nilai kanan, track + knob di bawahnya.
--   local s = Slider.new({
--     parent = frame, order = 1, label = "Height", min = 0.9, max = 1.05, value = 1,
--     onChange = function(v, final) end,
--   })
--   s:set(1.02)   s:destroy()
-- INTENT HANYA DIKIRIM SAAT JARI/TETIKUS DILEPAS (final = true). Kalau dikirim tiap frame, satu
-- geseran jadi puluhan commit dan Undo harus ditekan puluhan kali. Saat digeser (final = false)
-- yang berubah cuma angka di layar.
-- Tanpa glyph simbol (BuilderSans tidak punya semuanya -- temuan #30 no. 12): Frame + teks biasa.
-- Area sentuh track setinggi 44 px walau garisnya 6 px, supaya tetap kena di ponsel.

local UserInputService = game:GetService("UserInputService")
local Tokens = require(script.Parent.Parent.Theme.Tokens)

local TRACK_H = 6
local KNOB = 18

local Slider = {}
Slider.__index = Slider

export type Props = {
	parent: Instance,
	order: number?,
	label: string,
	min: number,
	max: number,
	value: number,
	step: number?,
	compact: boolean?,
	format: ((number) -> string)?,
	onChange: (number, boolean) -> (),
}

export type Slider = typeof(setmetatable(
	{} :: {
		_root: Frame,
		_track: Frame,
		_fill: Frame,
		_knob: Frame,
		_text: TextLabel,
		_min: number,
		_max: number,
		_step: number,
		_v: number,
		_fmt: (number) -> string,
		_on: (number, boolean) -> (),
		_conns: { RBXScriptConnection },
	},
	Slider
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

function Slider.new(props: Props): Slider
	local compact = props.compact == true
	local rowH = if compact then 20 else 24
	local touchH = if compact then 32 else 44
	local fmt = props.format or function(v: number): string
		return string.format("%.2f", v)
	end

	local text = make("TextLabel", {
		Name = "Value",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.4, 0, 1, 0),
		Position = UDim2.new(0.6, 0, 0, 0),
		FontFace = Tokens.Font.Medium,
		TextSize = if compact then Tokens.TextSize.Caption else Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = fmt(props.value),
	})

	local fill = make("Frame", {
		Name = "Fill",
		BackgroundColor3 = Tokens.Color.Accent,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 1, 0),
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	local track = make("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(1, -KNOB, 0, TRACK_H),
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BorderSizePixel = 0,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }), fill })

	local knob = make("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(KNOB, KNOB),
		BackgroundColor3 = Tokens.Color.Text,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	local hit = make("TextButton", {
		Name = "Hit",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, touchH),
		Position = UDim2.new(0, 0, 0, rowH),
	}, { track, knob })

	local root = make("Frame", {
		Name = "Slider_" .. props.label,
		BackgroundTransparency = 1,
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, rowH + touchH),
	}, {
		make("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Size = UDim2.new(0.6, 0, 0, rowH),
			FontFace = Tokens.Font.Regular,
			TextSize = if compact then Tokens.TextSize.Caption else Tokens.TextSize.Body,
			TextColor3 = Tokens.Color.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = props.label,
		}),
		text,
		hit,
	})
	root.Parent = props.parent

	local self: Slider = setmetatable({
		_root = root,
		_track = track,
		_fill = fill,
		_knob = knob,
		_text = text,
		_min = props.min,
		_max = props.max,
		_step = props.step or 0.01,
		_v = props.value,
		_fmt = fmt,
		_on = props.onChange,
		_conns = {},
	}, Slider) :: any

	local dragging = false
	local moved: RBXScriptConnection? = nil
	local ended: RBXScriptConnection? = nil

	local function stop(final: boolean)
		if not dragging then
			return
		end
		dragging = false
		if moved then
			moved:Disconnect()
			moved = nil
		end
		if ended then
			ended:Disconnect()
			ended = nil
		end
		if final then
			self._on(self._v, true)
		end
	end

	table.insert(
		self._conns,
		hit.InputBegan:Connect(function(input)
			if
				input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end
			dragging = true
			self:_fromX(input.Position.X, false)
			moved = UserInputService.InputChanged:Connect(function(m)
				if
					dragging
					and (
						m.UserInputType == Enum.UserInputType.MouseMovement
						or m.UserInputType == Enum.UserInputType.Touch
					)
				then
					self:_fromX(m.Position.X, false)
				end
			end)
			ended = UserInputService.InputEnded:Connect(function(e)
				if e.UserInputType == input.UserInputType then
					stop(true)
				end
			end)
		end)
	)
	table.insert(
		self._conns,
		root.AncestryChanged:Connect(function()
			if not root:IsDescendantOf(game) then
				stop(false)
			end
		end)
	)

	self:_paint()
	return self
end

function Slider._quantize(self: Slider, v: number): number
	local step = self._step
	if step > 0 then
		v = math.floor(v / step + 0.5) * step
	end
	v = math.clamp(v, self._min, self._max)
	return math.floor(v * 1000 + 0.5) / 1000
end

function Slider._paint(self: Slider)
	local span = self._max - self._min
	local a = if span > 0 then (self._v - self._min) / span else 0
	a = math.clamp(a, 0, 1)
	self._fill.Size = UDim2.new(a, 0, 1, 0)
	self._knob.Position = UDim2.new(a, 0, 0.5, 0)
	self._text.Text = self._fmt(self._v)
end

function Slider._fromX(self: Slider, x: number, final: boolean)
	local left = self._track.AbsolutePosition.X
	local w = self._track.AbsoluteSize.X
	local a = if w > 0 then math.clamp((x - left) / w, 0, 1) else 0
	local v = self:_quantize(self._min + a * (self._max - self._min))
	if v ~= self._v then
		self._v = v
		self:_paint()
		self._on(v, final)
	end
end

-- Menyetel dari luar (jawaban server / undo): TIDAK memanggil onChange.
function Slider.set(self: Slider, v: number)
	v = self:_quantize(v)
	if v == self._v then
		return
	end
	self._v = v
	self:_paint()
end

function Slider.value(self: Slider): number
	return self._v
end

function Slider.destroy(self: Slider)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self._root:Destroy()
end

return Slider
