--!strict
-- ActionBar: tombol Undo / Redo / Reset di kanan atas layar.
--   local bar = ActionBar.new({ parent = screenGui, onAction = function(op) ... end })
--   -- op: "undo" | "redo" | "reset"
--   bar:destroy()
-- Komponen ini tidak tahu soal server; App yang meneruskan op ke OutfitController.

local Tokens = require(script.Parent.Parent.Theme.Tokens)

export type Action = "undo" | "redo" | "reset"

export type Props = {
	parent: Instance,
	onAction: (op: Action) -> (),
}

local ActionBar = {}
ActionBar.__index = ActionBar

export type ActionBar = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_conns: { RBXScriptConnection },
	},
	ActionBar
))

local BUTTONS: { { op: Action, text: string, danger: boolean } } = {
	{ op = "undo", text = "Undo", danger = false },
	{ op = "redo", text = "Redo", danger = false },
	{ op = "reset", text = "Reset", danger = true },
}

local function makeButton(text: string, order: number, danger: boolean, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Name = text
	b.Text = text
	b.LayoutOrder = order
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Size = UDim2.fromOffset(Tokens.Size.IconButton, Tokens.Size.IconButton)
	b.FontFace = Tokens.Font.Bold
	b.TextSize = Tokens.TextSize.Body
	b.TextColor3 = if danger then Tokens.Color.Danger else Tokens.Color.Text
	b.BackgroundColor3 = Tokens.Color.Panel
	b.BackgroundTransparency = Tokens.Transparency.Panel
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.ZIndex = Tokens.ZIndex.Hud

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Pill
	corner.Parent = b

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Tokens.Color.Stroke
	stroke.Transparency = Tokens.Transparency.Stroke
	stroke.Parent = b

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Tokens.Space.M)
	pad.PaddingRight = UDim.new(0, Tokens.Space.M)
	pad.Parent = b

	b.Parent = parent
	return b
end

function ActionBar.new(props: Props): ActionBar
	local frame = Instance.new("Frame")
	frame.Name = "ActionBar"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(1, -Tokens.Space.S, 0, Tokens.Space.S)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, Tokens.Size.IconButton)
	frame.Parent = props.parent

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Tokens.Space.S)
	list.Parent = frame

	local conns = {}
	for i, spec in BUTTONS do
		local b = makeButton(spec.text, i, spec.danger, frame)
		table.insert(
			conns,
			b.Activated:Connect(function()
				props.onAction(spec.op)
			end)
		)
	end

	return setmetatable({
		instance = frame,
		_conns = conns,
	}, ActionBar)
end

function ActionBar.destroy(self: ActionBar)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return ActionBar
