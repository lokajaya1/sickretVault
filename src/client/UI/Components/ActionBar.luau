--!strict
-- ActionBar: bar aksi 4 IKON PERSEGI di dock kiri bawah (tepat di bawah kartu preview), tampil
-- saat katalog terbuka. Pola CAC: ikon polos tanpa teks.
--   local bar = ActionBar.new({ parent = screenGui, onAction = function(op) ... end })
--   -- op: "roblox" | "cart" | "reset" | "trash"
--   bar:setPlacement(x, y, w, h)   bar:setVisible(true)   bar:destroy()
-- Nama tombol muncul sebagai label melayang di ATAS bar saat hover / ditekan (layar sentuh tidak
-- punya hover) -- pola yang sama dengan kluster ikon SideRail (#29). Seperti di sana, labelnya
-- SAUDARA bar dan bukan anaknya: anak frame ber-UIListLayout pasti ikut dibariskan (temuan #25
-- no. 2), jadi ia harus dibuang sendiri di destroy().
-- Ikon digambar dari Frame lewat SideRail.drawIcon -- SATU kosakata ikon untuk seluruh UI, supaya
-- tombol yang sama tidak digambar dua kali dengan bentuk yang berbeda.
-- Undo & Redo TIDAK ada di sini: keduanya sepasang panah melayang di pojok kartu preview (pola
-- CAC), supaya bar ini tetap berisi tepat 4 aksi.
-- Komponen ini tidak tahu soal server; App yang meneruskan op.

local Tokens = require(script.Parent.Parent.Theme.Tokens)
local SideRail = require(script.Parent.SideRail)

export type Action = "roblox" | "cart" | "reset" | "trash"

export type Props = {
	parent: Instance,
	onAction: (op: Action) -> (),
}

local ActionBar = {}
ActionBar.__index = ActionBar

export type ActionBar = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_order: { TextButton },
		_list: UIListLayout,
		_label: TextLabel,
		_conns: { RBXScriptConnection },
	},
	ActionBar
))

local LABEL_H = 18
local LABEL_GAP = 4

local BUTTONS: { { op: Action, text: string, icon: string } } = {
	{ op = "roblox", text = "Save to Roblox", icon = "roblox" },
	{ op = "cart", text = "Cart", icon = "cart" },
	{ op = "reset", text = "Reset to My Avatar", icon = "reset" },
	{ op = "trash", text = "Remove Items", icon = "trash" },
}

local function iconButton(name: string, icon: string, order: number, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = ""
	b.LayoutOrder = order
	b.BackgroundColor3 = Tokens.Color.Panel
	b.BackgroundTransparency = Tokens.Transparency.Panel
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.ZIndex = Tokens.ZIndex.Hud
	-- Ukuran diisi setPlacement dalam PIKSEL: tombol persegi TIDAK boleh memakai
	-- UIAspectRatioConstraint di dalam UIListLayout (lebar jadi nol -- temuan #25 no. 2).
	b.Size = UDim2.fromOffset(Tokens.Size.IconButton, Tokens.Size.IconButton)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Tokens.Radius.Medium
	corner.Parent = b

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Tokens.Color.Stroke
	stroke.Transparency = Tokens.Transparency.Stroke
	stroke.Parent = b

	local art = Instance.new("Frame")
	art.Name = "Icon"
	art.BackgroundTransparency = 1
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.5)
	art.Size = UDim2.fromScale(0.58, 0.58)
	art.ZIndex = b.ZIndex + 1
	art.Parent = b
	SideRail.drawIcon(icon, art)

	b.Parent = parent
	return b
end

function ActionBar.new(props: Props): ActionBar
	local frame = Instance.new("Frame")
	frame.Name = "ActionBar"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.zero
	frame.Position = UDim2.fromOffset(0, 0)
	frame.Size = UDim2.fromOffset(0, Tokens.Size.IconButton)
	frame.ZIndex = Tokens.ZIndex.Hud
	frame.Parent = props.parent

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Left
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Tokens.Space.S)
	list.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "ActionLabel"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.zero
	label.Size = UDim2.fromOffset(240, LABEL_H)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.FontFace = Tokens.Font.Bold
	label.TextSize = Tokens.TextSize.Body
	label.TextColor3 = Tokens.Color.Text
	label.Text = ""
	label.Visible = false
	label.ZIndex = Tokens.ZIndex.Hud + 2
	label.Parent = props.parent

	local order: { TextButton } = {}
	local conns: { RBXScriptConnection } = {}
	for i, spec in BUTTONS do
		local b = iconButton(spec.op, spec.icon, i, frame)
		table.insert(order, b)
		table.insert(
			conns,
			b.Activated:Connect(function()
				label.Text = spec.text -- layar sentuh: nama muncul saat ditekan
				label.Visible = true
				props.onAction(spec.op)
			end)
		)
		table.insert(
			conns,
			b.MouseEnter:Connect(function()
				label.Text = spec.text
				label.Visible = true
			end)
		)
		table.insert(
			conns,
			b.MouseLeave:Connect(function()
				if label.Text == spec.text then
					label.Visible = false
				end
			end)
		)
	end

	return setmetatable({
		instance = frame,
		_order = order,
		_list = list,
		_label = label,
		_conns = conns,
	}, ActionBar)
end

-- Dock diukur PanelLayout (dockX/dockY/dockW/actionsH): tombolnya persegi setinggi baris itu.
function ActionBar.setPlacement(self: ActionBar, x: number, y: number, w: number, h: number)
	self.instance.Position = UDim2.fromOffset(x, y)
	self.instance.Size = UDim2.fromOffset(w, h)
	for _, b in self._order do
		b.Size = UDim2.fromOffset(h, h)
	end
	self._list.Padding = UDim.new(0, if h < Tokens.Size.IconButton then Tokens.Space.XS else Tokens.Space.S)
	self._label.Position = UDim2.fromOffset(x, y - LABEL_H - LABEL_GAP)
end

function ActionBar.setVisible(self: ActionBar, visible: boolean)
	self.instance.Visible = visible
	if not visible then
		self._label.Visible = false
	end
end

-- Teks sementara di label melayang (mis. "Soon"), kembali setelah `seconds`.
function ActionBar.flash(self: ActionBar, text: string, seconds: number)
	local l = self._label
	l.Text = text
	l.Visible = true
	task.delay(seconds, function()
		if l.Parent and l.Text == text then
			l.Visible = false
		end
	end)
end

function ActionBar.destroy(self: ActionBar)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self._label:Destroy() -- label melayang itu SAUDARA bar, tidak ikut terbuang sendiri
	self.instance:Destroy()
end

return ActionBar
