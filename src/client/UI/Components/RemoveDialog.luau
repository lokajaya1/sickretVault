--!strict
-- Dialog "Item Removal" (ikon tong sampah di bar aksi, pola Catalog Avatar Creator).
-- Centang beberapa kategori -> satu tombol Remove. Kategorinya persis OutfitState.KINDS, dan
-- "all" TIDAK ikut daftar centang: ia baris bahaya tersendiri di kaki dialog, supaya tidak
-- pernah ketap bersama yang lain.
--   local dialog = RemoveDialog.new({
--   	parent = gui, zIndex = Tokens.ZIndex.Popup + 5,
--   	onRemove = function(kinds) end,  -- { "hair", "face" } -> SATU intent removeKind
--   	onClose = function() end,
--   })
--   dialog:open({ hair = 1, accessories = 3 })   dialog:isOpen()   dialog:close()   dialog:destroy()
-- Dialog TIDAK memanggil controller sendiri: App yang mengirim intent (biar toast & busy satu jalur).
-- Jumlah per kategori datang dari App (dihitung dengan OutfitState.removeKind atas state sekarang),
-- bukan dihitung di sini: komponen UI tidak boleh ikut memutuskan apa itu "rambut".

local Tokens = require(script.Parent.Parent.Theme.Tokens)
local SideRail = require(script.Parent.SideRail)

local DIALOG_W = 320
local ROW_H = 34
local HEAD_H = 30
local FOOT_H = 40
local GAP = Tokens.Space.S
local PAD = Tokens.Space.M

-- Urutannya mengikuti OutfitState.KINDS (tanpa "all"): dari yang paling sering dilepas.
local ROWS: { { kind: string, label: string } } = {
	{ kind = "accessories", label = "Accessories" },
	{ kind = "hair", label = "Hair" },
	{ kind = "face", label = "Face" },
	{ kind = "classic", label = "Classic clothing" },
	{ kind = "layered", label = "Layered clothing" },
	{ kind = "bodyParts", label = "Body parts" },
	{ kind = "animations", label = "Animations" },
}

export type Props = {
	parent: Instance,
	zIndex: number?,
	onRemove: ({ string }) -> (),
	onClose: (() -> ())?,
}

local RemoveDialog = {}
RemoveDialog.__index = RemoveDialog

export type RemoveDialog = typeof(setmetatable(
	{} :: {
		instance: TextButton,
		_props: Props,
		_rows: { [string]: { button: TextButton, box: Frame, tick: Frame, label: TextLabel, text: string } },
		_counts: { [string]: number },
		_checked: { [string]: boolean },
		_confirm: TextButton,
		_allButton: TextButton,
		_conns: { RBXScriptConnection },
	},
	RemoveDialog
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

function RemoveDialog.new(props: Props): RemoveDialog
	local Z = props.zIndex or (Tokens.ZIndex.Popup + 5)

	-- Selubung selayar penuh: tap di luar kartu = tutup. Di sini aman (beda dengan dialog simpan
	-- yang menutupi seluruh layar) karena katalog di belakangnya masih terlihat sebagai konteks.
	local root: TextButton = make("TextButton", {
		Name = "RemoveDialog",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = Tokens.Transparency.Overlay,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = Z,
		Parent = props.parent,
	})

	local height = HEAD_H + GAP + #ROWS * (ROW_H + GAP) + FOOT_H + GAP + ROW_H + PAD * 2
	local card: TextButton = make("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Panel,
		BackgroundTransparency = Tokens.Transparency.Panel,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, height),
		ZIndex = Z + 1,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Large }),
		make("UISizeConstraint", { MaxSize = Vector2.new(DIALOG_W, height) }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, PAD),
			PaddingBottom = UDim.new(0, PAD),
			PaddingLeft = UDim.new(0, PAD),
			PaddingRight = UDim.new(0, PAD),
		}),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, GAP) }),
	})

	local head: TextLabel = make("TextLabel", {
		Name = "Title",
		Text = "Remove items",
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, HEAD_H),
		ZIndex = Z + 1,
		Parent = card,
	})
	local closeButton: TextButton = make("TextButton", {
		Name = "Close",
		Text = "",
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(28, 28),
		ZIndex = Z + 2,
		Parent = head,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })
	SideRail.drawIcon(
		"close",
		make("Frame", {
			Name = "Icon",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(11, 11),
			ZIndex = Z + 2,
			Parent = closeButton,
		})
	)

	local self: RemoveDialog = setmetatable({
		instance = root,
		_props = props,
		_rows = {},
		_counts = {},
		_checked = {},
		_confirm = nil :: any,
		_allButton = nil :: any,
		_conns = {},
	}, RemoveDialog)

	local conns = {
		root.Activated:Connect(function()
			self:close()
		end),
		closeButton.Activated:Connect(function()
			self:close()
		end),
	}

	for i, row in ROWS do
		local button: TextButton = make("TextButton", {
			Name = row.kind,
			Text = "",
			AutoButtonColor = true,
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BackgroundTransparency = Tokens.Transparency.PanelRaised,
			BorderSizePixel = 0,
			LayoutOrder = i + 1,
			Size = UDim2.new(1, 0, 0, ROW_H),
			ZIndex = Z + 1,
			Parent = card,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Medium }) })

		-- Kotak centang digambar, bukan karakter: font kita tidak punya glyph centang (temuan
		-- 19 Sep 2026, silang U+2715 keluar sebagai kotak kosong).
		local box: Frame = make("Frame", {
			Name = "Box",
			BackgroundColor3 = Tokens.Color.Panel,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, GAP, 0.5, 0),
			Size = UDim2.fromOffset(18, 18),
			ZIndex = Z + 2,
			Parent = button,
		}, {
			make("UICorner", { CornerRadius = Tokens.Radius.Small }),
			make("UIStroke", {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Tokens.Color.Stroke,
				Transparency = Tokens.Transparency.Stroke,
			}),
		})
		local tick: Frame = make("Frame", {
			Name = "Tick",
			BackgroundColor3 = Tokens.Color.Accent,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(10, 10),
			Visible = false,
			ZIndex = Z + 3,
			Parent = box,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })

		local label: TextLabel = make("TextLabel", {
			Name = "Label",
			Text = row.label,
			BackgroundTransparency = 1,
			FontFace = Tokens.Font.Medium,
			TextSize = Tokens.TextSize.Body,
			TextColor3 = Tokens.Color.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, GAP * 2 + 18, 0.5, 0),
			Size = UDim2.new(1, -(GAP * 3 + 18), 1, 0),
			ZIndex = Z + 2,
			Parent = button,
		})

		self._rows[row.kind] = { button = button, box = box, tick = tick, label = label, text = row.label }
		table.insert(
			conns,
			button.Activated:Connect(function()
				-- Kategori kosong tidak bisa dicentang: tidak ada yang akan terbuang, dan tombol
				-- Remove yang menghitung centang jadi berbohong soal jumlahnya.
				if (self._counts[row.kind] or 0) == 0 then
					return
				end
				self._checked[row.kind] = not self._checked[row.kind]
				self:_refresh()
			end)
		)
	end

	local confirm: TextButton = make("TextButton", {
		Name = "Confirm",
		Text = "Remove",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Accent,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		LayoutOrder = #ROWS + 2,
		Size = UDim2.new(1, 0, 0, FOOT_H),
		ZIndex = Z + 1,
		Parent = card,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	-- Baris bahaya, dipisah dari daftar centang: ia melepas SEMUANYA sekaligus, jadi ia tidak
	-- boleh ikut terbawa satu tap Remove bersama kategori lain.
	local allButton: TextButton = make("TextButton", {
		Name = "All",
		Text = "Remove everything",
		FontFace = Tokens.Font.Medium,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Danger,
		BackgroundTransparency = 1,
		AutoButtonColor = true,
		LayoutOrder = #ROWS + 3,
		Size = UDim2.new(1, 0, 0, ROW_H),
		ZIndex = Z + 1,
		Parent = card,
	})

	self._confirm = confirm
	self._allButton = allButton
	table.insert(
		conns,
		confirm.Activated:Connect(function()
			local kinds = {}
			for _, row in ROWS do
				if self._checked[row.kind] then
					table.insert(kinds, row.kind)
				end
			end
			if #kinds == 0 then
				return
			end
			self:close()
			self._props.onRemove(kinds)
		end)
	)
	table.insert(
		conns,
		allButton.Activated:Connect(function()
			self:close()
			self._props.onRemove({ "all" })
		end)
	)
	self._conns = conns
	return self
end

function RemoveDialog._refresh(self: RemoveDialog)
	local selected = 0
	for kind, row in self._rows do
		local count = self._counts[kind] or 0
		local on = self._checked[kind] == true
		if on then
			selected += count
		end
		row.tick.Visible = on
		-- Kategori kosong dibiarkan terlihat (supaya daftarnya tidak berubah-ubah bentuk) tapi
		-- diredupkan: pemain bisa melihat "memang tidak ada yang dipakai di situ".
		row.label.Text = if count > 0 then ("%s  ·  %d"):format(row.text, count) else row.text
		row.label.TextColor3 = if count > 0 then Tokens.Color.Text else Tokens.Color.TextMuted
		row.button.BackgroundTransparency = if count > 0 then Tokens.Transparency.PanelRaised else 0.6
		row.box.Visible = count > 0
	end
	self._confirm.Text = if selected > 0 then ("Remove %d"):format(selected) else "Remove"
	self._confirm.BackgroundTransparency = if selected > 0 then 0 else 0.6
end

-- counts = { [kind] = berapa item yang akan terbuang }, dihitung App dari state sekarang.
function RemoveDialog.open(self: RemoveDialog, counts: { [string]: number })
	self._counts = counts
	self._checked = {}
	self:_refresh()
	self.instance.Visible = true
end

function RemoveDialog.isOpen(self: RemoveDialog): boolean
	return self.instance.Visible
end

function RemoveDialog.close(self: RemoveDialog)
	if not self.instance.Visible then
		return
	end
	self.instance.Visible = false
	local onClose = self._props.onClose
	if onClose then
		onClose()
	end
end

function RemoveDialog.destroy(self: RemoveDialog)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return RemoveDialog
