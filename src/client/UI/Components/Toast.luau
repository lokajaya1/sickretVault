--!strict
-- Toast: pesan singkat di bawah-tengah layar yang hilang sendiri.
--   local toast = Toast.new({ parent = screenGui })
--   toast:show("Item not found", "warning")   -- kind: "info" | "warning" | "error"
--   toast:destroy()
-- Maks MAX_VISIBLE pesan sekaligus (yang tertua dibuang). Pesan sama yang muncul lagi
-- tidak ditumpuk: pesan lama diperpanjang dan diberi hitungan (x2, x3, ...).

local TweenService = game:GetService("TweenService")

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local DURATION = 2.5 -- detik tampil
local MAX_VISIBLE = 3
local HEIGHT = 36

export type Kind = "info" | "warning" | "error"

export type Props = {
	parent: Instance,
}

type Entry = {
	frame: Frame,
	label: TextLabel,
	text: string,
	count: number,
	token: number,
}

local Toast = {}
Toast.__index = Toast

export type Toast = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_entries: { Entry },
		_order: number,
	},
	Toast
))

local ACCENT: { [string]: Color3 } = {
	info = Tokens.Color.Accent,
	warning = Tokens.Color.Warning,
	error = Tokens.Color.Danger,
}

function Toast.new(props: Props): Toast
	local holder = Instance.new("Frame")
	holder.Name = "Toasts"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -Tokens.Space.XL * 3)
	holder.Size = UDim2.fromOffset(360, (HEIGHT + Tokens.Space.S) * MAX_VISIBLE)
	holder.ZIndex = Tokens.ZIndex.Toast
	holder.Parent = props.parent

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Tokens.Space.S)
	list.Parent = holder

	return setmetatable({
		instance = holder,
		_entries = {},
		_order = 0,
	}, Toast)
end

local function labelText(e: Entry): string
	return if e.count > 1 then ("%s (x%d)"):format(e.text, e.count) else e.text
end

function Toast._remove(self: Toast, e: Entry)
	local i = table.find(self._entries, e)
	if i then
		table.remove(self._entries, i)
	end
	local fade = TweenService:Create(e.label, Tokens.Tween.Normal, { TextTransparency = 1 })
	TweenService:Create(e.frame, Tokens.Tween.Normal, { BackgroundTransparency = 1 }):Play()
	fade:Play()
	fade.Completed:Once(function()
		e.frame:Destroy()
	end)
end

function Toast._schedule(self: Toast, e: Entry)
	e.token += 1
	local token = e.token
	task.delay(DURATION, function()
		if e.token == token and table.find(self._entries, e) then
			self:_remove(e)
		end
	end)
end

function Toast.show(self: Toast, text: string, kind: Kind?)
	-- pesan sama masih tampil -> perpanjang + hitung
	for _, e in self._entries do
		if e.text == text then
			e.count += 1
			e.label.Text = labelText(e)
			self:_schedule(e)
			return
		end
	end

	while #self._entries >= MAX_VISIBLE do
		self:_remove(self._entries[1])
	end

	self._order += 1
	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.LayoutOrder = self._order
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, HEIGHT)
	frame.BackgroundColor3 = Tokens.Color.Background
	frame.BackgroundTransparency = Tokens.Transparency.Panel
	frame.BorderSizePixel = 0
	frame.ZIndex = Tokens.ZIndex.Toast

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Pill
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = ACCENT[kind or "info"] or Tokens.Color.Accent
	stroke.Thickness = 1.5
	stroke.Parent = frame

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Tokens.Space.L)
	pad.PaddingRight = UDim.new(0, Tokens.Space.L)
	pad.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.FontFace = Tokens.Font.Medium
	label.TextSize = Tokens.TextSize.Body
	label.TextColor3 = Tokens.Color.Text
	label.ZIndex = Tokens.ZIndex.Toast
	label.Parent = frame

	local e: Entry = { frame = frame, label = label, text = text, count = 1, token = 0 }
	label.Text = labelText(e)
	frame.Parent = self.instance
	table.insert(self._entries, e)
	self:_schedule(e)
end

function Toast.destroy(self: Toast)
	table.clear(self._entries)
	self.instance:Destroy()
end

return Toast
