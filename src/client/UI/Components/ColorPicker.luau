--!strict
-- Color Picker melayang (pola Catalog Avatar Creator): kotak Saturation/Value, strip Hue, kotak hex.
--   local p = ColorPicker.new({ parent = gui, onPick = function(hex) end })
--   p:open("A3A2A5")   p:close()   p:isOpen()   p:destroy()
-- TANPA gambar: kotak SV dibuat dari dua UIGradient bertumpuk (putih -> transparan mendatar,
-- transparan -> hitam menurun) di atas Frame berwarna hue; strip Hue satu UIGradient 7 titik.
-- Warna dikirim HANYA saat "Use" ditekan. Menggeser titik tidak mengirim apa-apa, jadi satu
-- pilihan warna = satu commit = satu Undo (sama seperti slider skala).

local UserInputService = game:GetService("UserInputService")
local Tokens = require(script.Parent.Parent.Theme.Tokens)

local W, SV_H, HUE_W = 300, 170, 24

local ColorPicker = {}
ColorPicker.__index = ColorPicker

export type Props = { parent: Instance, zIndex: number?, onPick: (string) -> () }

export type ColorPicker = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_sv: Frame,
		_svDot: Frame,
		_hue: Frame,
		_hueDot: Frame,
		_preview: Frame,
		_hex: TextBox,
		_h: number,
		_s: number,
		_v: number,
		_on: (string) -> (),
		_conns: { RBXScriptConnection },
	},
	ColorPicker
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

-- Geser: sama seperti Slider -- tekan di area, ikuti jari/tetikus, berhenti saat dilepas.
local function bindDrag(self: ColorPicker, area: GuiObject, fn: (number, number) -> ())
	local moved: RBXScriptConnection? = nil
	local ended: RBXScriptConnection? = nil
	local function alpha(px: number, py: number)
		local p, s = area.AbsolutePosition, area.AbsoluteSize
		local ax = if s.X > 0 then math.clamp((px - p.X) / s.X, 0, 1) else 0
		local ay = if s.Y > 0 then math.clamp((py - p.Y) / s.Y, 0, 1) else 0
		fn(ax, ay)
	end
	table.insert(
		self._conns,
		area.InputBegan:Connect(function(input)
			if
				input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end
			alpha(input.Position.X, input.Position.Y)
			moved = UserInputService.InputChanged:Connect(function(m)
				if
					m.UserInputType == Enum.UserInputType.MouseMovement
					or m.UserInputType == Enum.UserInputType.Touch
				then
					alpha(m.Position.X, m.Position.Y)
				end
			end)
			ended = UserInputService.InputEnded:Connect(function(e)
				if e.UserInputType == input.UserInputType then
					if moved then
						moved:Disconnect()
						moved = nil
					end
					if ended then
						ended:Disconnect()
						ended = nil
					end
				end
			end)
		end)
	)
end

function ColorPicker.new(props: Props): ColorPicker
	local z = props.zIndex or (Tokens.ZIndex.Popup + 20)

	local hueKeys = {}
	for i = 0, 6 do
		table.insert(hueKeys, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6, 1, 1)))
	end

	local svDot = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = Tokens.Color.Text,
		BorderSizePixel = 0,
		ZIndex = z + 3,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	local sv = make("Frame", {
		Position = UDim2.fromOffset(Tokens.Space.M, 40),
		Size = UDim2.new(1, -(Tokens.Space.M * 3 + HUE_W), 0, SV_H),
		BackgroundColor3 = Color3.fromHSV(0, 1, 1),
		BorderSizePixel = 0,
		ZIndex = z + 1,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Small }),
		make("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ZIndex = z + 1,
		}, {
			make("UICorner", { CornerRadius = Tokens.Radius.Small }),
			make("UIGradient", {
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		}),
		make("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BorderSizePixel = 0,
			ZIndex = z + 2,
		}, {
			make("UICorner", { CornerRadius = Tokens.Radius.Small }),
			make("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(1, 0),
				}),
			}),
		}),
		svDot,
	})

	local hueDot = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, 6, 0, 4),
		BackgroundColor3 = Tokens.Color.Text,
		BorderSizePixel = 0,
		ZIndex = z + 3,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	local hue = make("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Tokens.Space.M, 0, 40),
		Size = UDim2.fromOffset(HUE_W, SV_H),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ZIndex = z + 1,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Small }),
		make("UIGradient", { Rotation = 90, Color = ColorSequence.new(hueKeys) }),
		hueDot,
	})

	local preview = make("Frame", {
		Position = UDim2.fromOffset(Tokens.Space.M, 40 + SV_H + Tokens.Space.M),
		Size = UDim2.fromOffset(44, 32),
		BackgroundColor3 = Color3.fromHSV(0, 1, 1),
		BorderSizePixel = 0,
		ZIndex = z + 1,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })

	local hex = make("TextBox", {
		Position = UDim2.fromOffset(Tokens.Space.M + 52, 40 + SV_H + Tokens.Space.M),
		Size = UDim2.new(1, -(Tokens.Space.M * 2 + 52), 0, 32),
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BorderSizePixel = 0,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		ClearTextOnFocus = false,
		Text = "FF0000",
		ZIndex = z + 1,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })

	local function actionButton(text: string, x: UDim2, accent: boolean): TextButton
		return make("TextButton", {
			Position = x,
			Size = UDim2.new(0.5, -Tokens.Space.M - Tokens.Space.XS, 0, 36),
			BackgroundColor3 = if accent then Tokens.Color.Accent else Tokens.Color.PanelRaised,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			FontFace = Tokens.Font.Medium,
			TextSize = Tokens.TextSize.Button,
			TextColor3 = if accent then Tokens.Color.AccentText else Tokens.Color.Text,
			Text = text,
			ZIndex = z + 1,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })
	end

	local cancel = actionButton("Cancel", UDim2.fromOffset(Tokens.Space.M, 40 + SV_H + 58), false)
	local use = actionButton("Use", UDim2.new(0.5, Tokens.Space.XS, 0, 40 + SV_H + 58), true)

	local root = make("Frame", {
		Name = "ColorPicker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(W, 40 + SV_H + 58 + 36 + Tokens.Space.M),
		BackgroundColor3 = Tokens.Color.Panel,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = z,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Large }),
		make("UIStroke", {
			Color = Tokens.Color.Stroke,
			Transparency = Tokens.Transparency.Stroke,
			Thickness = 1,
		}),
		make("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(Tokens.Space.M, 8),
			Size = UDim2.new(1, -Tokens.Space.M * 2, 0, 24),
			FontFace = Tokens.Font.Bold,
			TextSize = Tokens.TextSize.Body,
			TextColor3 = Tokens.Color.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "Color Picker",
			ZIndex = z + 1,
		}),
		sv,
		hue,
		preview,
		hex,
		cancel,
		use,
	})
	root.Parent = props.parent

	local self: ColorPicker = setmetatable({
		instance = root,
		_sv = sv,
		_svDot = svDot,
		_hue = hue,
		_hueDot = hueDot,
		_preview = preview,
		_hex = hex,
		_h = 0,
		_s = 1,
		_v = 1,
		_on = props.onPick,
		_conns = {},
	}, ColorPicker) :: any

	bindDrag(self, sv, function(ax, ay)
		self._s, self._v = ax, 1 - ay
		self:_paint()
	end)
	bindDrag(self, hue, function(_, ay)
		self._h = ay
		self:_paint()
	end)

	table.insert(
		self._conns,
		hex.FocusLost:Connect(function()
			local t = (hex.Text:gsub("%s", ""):gsub("^#", ""))
			if t:match("^%x%x%x%x%x%x$") then
				self._h, self._s, self._v = Color3.fromHex(t):ToHSV()
			end
			self:_paint()
		end)
	)
	table.insert(
		self._conns,
		cancel.Activated:Connect(function()
			self:close()
		end)
	)
	table.insert(
		self._conns,
		use.Activated:Connect(function()
			local picked = string.upper(Color3.fromHSV(self._h, self._s, self._v):ToHex())
			self:close()
			self._on(picked)
		end)
	)

	self:_paint()
	return self
end

function ColorPicker._paint(self: ColorPicker)
	local c = Color3.fromHSV(self._h, self._s, self._v)
	self._sv.BackgroundColor3 = Color3.fromHSV(self._h, 1, 1)
	self._svDot.Position = UDim2.fromScale(self._s, 1 - self._v)
	self._hueDot.Position = UDim2.fromScale(0.5, self._h)
	self._preview.BackgroundColor3 = c
	self._hex.Text = string.upper(c:ToHex())
end

function ColorPicker.open(self: ColorPicker, hex: string?)
	if hex and hex:match("^%x%x%x%x%x%x$") then
		self._h, self._s, self._v = Color3.fromHex(hex):ToHSV()
	end
	self:_paint()
	self.instance.Visible = true
end

function ColorPicker.close(self: ColorPicker)
	self.instance.Visible = false
end

function ColorPicker.isOpen(self: ColorPicker): boolean
	return self.instance.Visible
end

function ColorPicker.destroy(self: ColorPicker)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return ColorPicker
