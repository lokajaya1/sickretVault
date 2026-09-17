--!strict
-- Panel wardrobe (outfit tersimpan): MENUTUPI isi panel katalog (anak dari CatalogPanel.instance),
-- setingkat CartPanel (App memastikan hanya satu yang terbuka).
-- Hanya menampilkan snapshot WardrobeController; aksi dijalankan lewat controller (task.spawn),
-- hasilnya dilaporkan ke App lewat onResult (untuk toast).
--   local panel = WardrobePanel.new({
--   	parent = catalogPanel.instance, controller = wardrobeController,
--   	onResult = function(op, ok, code, name) ... end,
--   })
--   panel:setOpen(true)   panel:isOpen()   panel:destroy()
-- Isi: Back + judul "Outfits (n/30)"; baris simpan (nama opsional + Save);
-- daftar slot (thumbnail, nama, jumlah item, Wear, ⋯ -> Rename / Update / Delete);
-- bawah: toggle "Wear last outfit when joining".

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local HEADER_H = 36
local SAVE_H = 36
local FOOTER_H = 36
local ROW_H = 64
local ACTIONS_H = 36
local THUMB = 52
local WEAR_W = 64
local MORE_W = 36
local SAVE_W = 84
local SWITCH_W = 52
local MAX_NAME = 32 -- sama dengan Wardrobe.MAX_NAME (server tetap memvalidasi)
local CONFIRM_SECONDS = 3
local Z = Tokens.ZIndex.Panel + 4 -- di atas isi katalog, di bawah ItemDetailPanel (+5)

export type Props = {
	parent: GuiObject, -- CatalogPanel.instance
	controller: any, -- WardrobeController
	onResult: ((op: string, ok: boolean, code: string?, name: string?) -> ())?, -- untuk toast
	onBack: (() -> ())?, -- default: setOpen(false)
}

type Row = {
	id: number,
	frame: Frame,
	wear: TextButton,
	more: TextButton,
	actions: Frame,
	rename: TextButton,
	update: TextButton,
	delete: TextButton,
	nameLabel: TextLabel,
	nameBox: TextBox,
	conns: { RBXScriptConnection },
}

local WardrobePanel = {}
WardrobePanel.__index = WardrobePanel

export type WardrobePanel = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_title: TextLabel,
		_nameInput: TextBox,
		_save: TextButton,
		_list: ScrollingFrame,
		_status: Frame,
		_statusTitle: TextLabel,
		_statusHint: TextLabel,
		_retry: TextButton,
		_switch: TextButton,
		_knob: Frame,
		_rows: { Row },
		_rowsKey: string,
		_snap: any?,
		_expandedId: number?,
		_renamingId: number?,
		_confirmId: number?,
		_confirmToken: number,
		_conns: { RBXScriptConnection },
		_unsubscribe: () -> (),
	},
	WardrobePanel
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

local function label(props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = Z,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextLabel", base)
end

local function button(text: string, props: { [string]: any }): TextButton
	local base = {
		Text = text,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		ZIndex = Z,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextButton", base, { corner(Tokens.Radius.Pill) })
end

local function textBox(props: { [string]: any }): TextBox
	local base = {
		Text = "",
		ClearTextOnFocus = false,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		PlaceholderColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		ZIndex = Z,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextBox", base, {
		corner(Tokens.Radius.Pill),
		make("UIPadding", {
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
		}),
	})
end

-- Potong teks ke MAX_NAME karakter (utf8) selagi diketik.
local function limitLength(box: TextBox): RBXScriptConnection
	return box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = box.Text
		local len = utf8.len(text)
		if len and len > MAX_NAME then
			local cut = utf8.offset(text, MAX_NAME + 1)
			if cut then
				box.Text = string.sub(text, 1, cut - 1)
			end
		end
	end)
end

local function assetThumb(id: number): string
	return ("rbxthumb://type=Asset&id=%d&w=150&h=150"):format(id)
end

local function countText(n: number): string
	return ("%d item%s"):format(n, if n == 1 then "" else "s")
end

-- Tombol aktif/nonaktif (tampilan saja; handler tetap memeriksa status).
local function setEnabled(b: TextButton, enabled: boolean)
	b.AutoButtonColor = enabled
	b.TextTransparency = if enabled then 0 else 0.5
end

function WardrobePanel.new(props: Props): WardrobePanel
	local pad = Tokens.Space.M
	local gap = Tokens.Space.S
	local ctl = props.controller

	-- Menutupi seluruh panel katalog (termasuk padding induk), latar penuh.
	local root: Frame = make("Frame", {
		Name = "WardrobePanel",
		Active = true,
		BackgroundColor3 = Tokens.Color.Panel,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(-pad, -pad),
		Size = UDim2.new(1, pad * 2, 1, pad * 2),
		Visible = false,
		ZIndex = Z,
		Parent = props.parent,
	}, {
		corner(Tokens.Radius.Large),
		make("UIPadding", {
			PaddingTop = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, pad),
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
		}),
	})
	-- Penahan klik: supaya tap tidak tembus ke kartu katalog di bawahnya.
	make("TextButton", {
		Name = "InputBlocker",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z - 1,
		Parent = root,
	})

	-- Header: Back + judul
	local back = button("‹ Back", {
		Name = "Back",
		Size = UDim2.fromOffset(84, HEADER_H),
		Parent = root,
	})
	local title = label({
		Name = "Title",
		Text = "Outfits",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		Position = UDim2.fromOffset(84 + pad, 0),
		Size = UDim2.new(1, -(84 + pad), 0, HEADER_H),
		Parent = root,
	})

	-- Baris simpan: nama (opsional) + Save
	local saveTop = HEADER_H + gap
	local nameInput = textBox({
		Name = "NameInput",
		PlaceholderText = "Name (optional)",
		Position = UDim2.fromOffset(0, saveTop),
		Size = UDim2.new(1, -(SAVE_W + gap), 0, SAVE_H),
		Parent = root,
	})
	local save = button("Save", {
		Name = "Save",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, saveTop),
		Size = UDim2.fromOffset(SAVE_W, SAVE_H),
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		Parent = root,
	})

	-- Daftar slot
	local listTop = saveTop + SAVE_H + gap
	local list: ScrollingFrame = make("ScrollingFrame", {
		Name = "Outfits",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, listTop),
		Size = UDim2.new(1, 0, 1, -(listTop + FOOTER_H + gap)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Tokens.Color.TextMuted,
		ZIndex = Z,
		Parent = root,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap),
		}),
		make("UIPadding", { PaddingRight = UDim.new(0, gap) }),
	})

	-- Status: kosong / memuat / gagal (+ Retry)
	local status: Frame = make("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, listTop + Tokens.Space.L),
		Size = UDim2.new(1, 0, 0, 96),
		Visible = false,
		ZIndex = Z,
		Parent = root,
	}, {
		make("UIListLayout", {
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap),
		}),
	})
	local statusTitle = label({
		Name = "Title",
		FontFace = Tokens.Font.Bold,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = status,
	})
	local statusHint = label({
		Name = "Hint",
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = status,
	})
	local retry = button("Try again", {
		Name = "Retry",
		LayoutOrder = 3,
		Size = UDim2.fromOffset(110, 32),
		Parent = status,
	})

	-- Bawah: toggle "Wear last outfit when joining"
	local footer: Frame = make("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		ZIndex = Z,
		Parent = root,
	})
	label({
		Name = "RestoreLabel",
		Text = "Wear last outfit when joining",
		Size = UDim2.new(1, -(SWITCH_W + gap), 1, 0),
		Parent = footer,
	})
	local switch = button("", {
		Name = "RestoreSwitch",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(SWITCH_W, 28),
		Parent = footer,
	})
	local knob: Frame = make("Frame", {
		Name = "Knob",
		BackgroundColor3 = Tokens.Color.Text,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(22, 22),
		ZIndex = Z,
		Parent = switch,
	}, { corner(Tokens.Radius.Pill) })

	local conns: { RBXScriptConnection } = {}
	local self: WardrobePanel = setmetatable({
		instance = root,
		_props = props,
		_title = title,
		_nameInput = nameInput,
		_save = save,
		_list = list,
		_status = status,
		_statusTitle = statusTitle,
		_statusHint = statusHint,
		_retry = retry,
		_switch = switch,
		_knob = knob,
		_rows = {},
		_rowsKey = "",
		_snap = nil,
		_expandedId = nil,
		_renamingId = nil,
		_confirmId = nil,
		_confirmToken = 0,
		_conns = conns,
		_unsubscribe = function() end,
	}, WardrobePanel)

	table.insert(conns, limitLength(nameInput))
	table.insert(
		conns,
		back.Activated:Connect(function()
			if props.onBack then
				props.onBack()
			else
				self:setOpen(false)
			end
		end)
	)
	local function doSave()
		local s = self._snap
		if s == nil or s.busy or not s.loaded then
			return
		end
		local name = nameInput.Text
		self:_act("save", function()
			return ctl:save(name)
		end, function(ok)
			if ok then
				nameInput.Text = ""
				self._list.CanvasPosition = Vector2.zero -- slot baru ada di atas
			end
		end)
	end
	table.insert(conns, save.Activated:Connect(doSave))
	table.insert(
		conns,
		nameInput.FocusLost:Connect(function(enterPressed: boolean)
			if enterPressed then
				doSave()
			end
		end)
	)
	table.insert(
		conns,
		retry.Activated:Connect(function()
			task.spawn(ctl.refresh, ctl)
		end)
	)
	table.insert(
		conns,
		switch.Activated:Connect(function()
			local s = self._snap
			if s == nil or s.busy or s.restoreOutfit == nil then
				return
			end
			local value = not s.restoreOutfit
			self:_act("setSetting", function()
				return ctl:setRestoreOutfit(value)
			end)
		end)
	)

	self._unsubscribe = ctl:onChanged(function(snap)
		self:_render(snap)
	end)
	self:_render(ctl:getSnapshot())
	return self
end

-- Jalankan aksi controller di thread baru; laporkan hasil ke App.
function WardrobePanel._act(
	self: WardrobePanel,
	op: string,
	fn: () -> (boolean, string?),
	after: ((ok: boolean) -> ())?,
	name: string?
)
	task.spawn(function()
		local ok, code = fn()
		if after then
			after(ok)
		end
		if code ~= "BUSY" and self._props.onResult then
			self._props.onResult(op, ok, code, name)
		end
	end)
end

function WardrobePanel._clearRows(self: WardrobePanel)
	for _, row in self._rows do
		for _, c in row.conns do
			c:Disconnect()
		end
		row.frame:Destroy()
	end
	table.clear(self._rows)
end

function WardrobePanel._buildRow(self: WardrobePanel, outfit: any, order: number): Row
	local gap = Tokens.Space.S
	local ctl = self._props.controller
	local id = outfit.id
	local frame: Frame = make("Frame", {
		Name = "Outfit_" .. tostring(id),
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, ROW_H),
		ZIndex = Z,
		Parent = self._list,
	}, { corner(Tokens.Radius.Medium) })

	-- Thumbnail 2x2 (maks 4 item pertama)
	local grid: Frame = make("Frame", {
		Name = "Thumbs",
		BackgroundColor3 = Tokens.Color.Background,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(gap, (ROW_H - THUMB) / 2),
		Size = UDim2.fromOffset(THUMB, THUMB),
		ZIndex = Z,
		Parent = frame,
	}, {
		corner(Tokens.Radius.Small),
		make("UIGridLayout", {
			CellSize = UDim2.fromOffset(THUMB / 2, THUMB / 2),
			CellPadding = UDim2.new(),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for i, assetId in outfit.thumbs do
		make("ImageLabel", {
			Name = "Thumb" .. i,
			BackgroundTransparency = 1,
			Image = assetThumb(assetId),
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = i,
			ZIndex = Z,
			Parent = grid,
		})
	end

	local textX = gap * 2 + THUMB
	local textW = -(textX + WEAR_W + MORE_W + gap * 3)
	local nameLabel = label({
		Name = "OutfitName",
		Text = outfit.name,
		FontFace = Tokens.Font.Bold,
		Position = UDim2.new(0, textX, 0, gap),
		Size = UDim2.new(1, textW, 0, 22),
		Parent = frame,
	})
	local nameBox = textBox({
		Name = "RenameBox",
		Text = outfit.name,
		Visible = false,
		Position = UDim2.new(0, textX, 0, gap - 2),
		Size = UDim2.new(1, textW, 0, 28),
		Parent = frame,
	})
	label({
		Name = "Count",
		Text = countText(outfit.count),
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		Position = UDim2.new(0, textX, 0, gap + 26),
		Size = UDim2.new(1, textW, 0, 18),
		Parent = frame,
	})
	local wear = button("Wear", {
		Name = "Wear",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(MORE_W + gap * 2), 0, ROW_H / 2),
		Size = UDim2.fromOffset(WEAR_W, 32),
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		Parent = frame,
	})
	local more = button("⋯", {
		Name = "More",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -gap, 0, ROW_H / 2),
		Size = UDim2.fromOffset(MORE_W, 32),
		TextSize = Tokens.TextSize.Title,
		Parent = frame,
	})

	-- Baris aksi (muncul saat ⋯ ditekan): Rename / Update / Delete
	local actions: Frame = make("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(gap, ROW_H),
		Size = UDim2.new(1, -gap * 2, 0, ACTIONS_H - gap),
		Visible = false,
		ZIndex = Z,
		Parent = frame,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap),
		}),
	})
	local third = UDim2.new(1 / 3, -gap * 2 / 3, 1, 0)
	local rename = button("Rename", { Name = "Rename", LayoutOrder = 1, Size = third, Parent = actions })
	local update = button("Update", { Name = "Update", LayoutOrder = 2, Size = third, Parent = actions })
	local delete = button("Delete", {
		Name = "Delete",
		LayoutOrder = 3,
		Size = third,
		TextColor3 = Tokens.Color.Danger,
		Parent = actions,
	})

	local function idle(): boolean
		local s = self._snap
		return s ~= nil and s.busy == nil
	end

	local function commitRename()
		if self._renamingId ~= id then
			return
		end
		self._renamingId = nil
		local newName = nameBox.Text
		local trimmed = string.match(newName, "^%s*(.-)%s*$") or ""
		if trimmed == "" or trimmed == outfit.name or not idle() then
			self:_refreshRows()
			return
		end
		nameLabel.Text = trimmed -- tampil sementara; daftar server menggantikan setelah balasan
		self:_act("rename", function()
			return ctl:rename(id, trimmed)
		end, function(ok)
			if not ok then
				nameLabel.Text = outfit.name -- gagal: kembalikan nama lama
			end
		end, trimmed)
		self:_refreshRows()
	end

	local conns = {
		limitLength(nameBox),
		wear.Activated:Connect(function()
			if idle() then
				self:_act("wear", function()
					return ctl:wear(id)
				end, nil, outfit.name)
			end
		end),
		more.Activated:Connect(function()
			self._expandedId = if self._expandedId == id then nil else id
			self._confirmId = nil
			self:_refreshRows()
		end),
		rename.Activated:Connect(function()
			if not idle() then
				return
			end
			self._renamingId = id
			self._confirmId = nil
			nameBox.Text = outfit.name
			self:_refreshRows()
			nameBox:CaptureFocus()
		end),
		nameBox.FocusLost:Connect(function(enterPressed: boolean)
			if enterPressed then
				commitRename()
			elseif self._renamingId == id then
				self._renamingId = nil -- batal (tap di luar / Esc)
				self:_refreshRows()
			end
		end),
		update.Activated:Connect(function()
			if idle() then
				self:_act("overwrite", function()
					return ctl:overwrite(id)
				end, nil, outfit.name)
			end
		end),
		delete.Activated:Connect(function()
			if not idle() then
				return
			end
			if self._confirmId ~= id then
				-- tap pertama: minta konfirmasi (kembali normal setelah beberapa detik)
				self._confirmId = id
				self._confirmToken += 1
				local token = self._confirmToken
				self:_refreshRows()
				task.delay(CONFIRM_SECONDS, function()
					if self._confirmToken == token and self._confirmId == id then
						self._confirmId = nil
						self:_refreshRows()
					end
				end)
				return
			end
			self._confirmId = nil
			self._expandedId = nil
			self:_act("delete", function()
				return ctl:delete(id)
			end, nil, outfit.name)
		end),
	}
	return {
		id = id,
		frame = frame,
		wear = wear,
		more = more,
		actions = actions,
		rename = rename,
		update = update,
		delete = delete,
		nameLabel = nameLabel,
		nameBox = nameBox,
		conns = conns,
	}
end

-- Perbarui tampilan baris tanpa membangun ulang (busy, expand, rename, konfirmasi hapus).
function WardrobePanel._refreshRows(self: WardrobePanel)
	local s = self._snap
	local busy = s and s.busy
	for _, row in self._rows do
		local expanded = self._expandedId == row.id
		local renaming = self._renamingId == row.id
		local mine = s and s.busyId == row.id
		row.frame.Size = UDim2.new(1, 0, 0, if expanded then ROW_H + ACTIONS_H else ROW_H)
		row.actions.Visible = expanded
		row.more.Text = if expanded then "✕" else "⋯"
		row.nameLabel.Visible = not renaming
		row.nameBox.Visible = renaming
		row.wear.Text = if mine and busy == "wear" then "…" else "Wear"
		row.update.Text = if mine and busy == "overwrite" then "Saving…" else "Update"
		row.rename.Text = if mine and busy == "rename" then "Saving…" else "Rename"
		local confirming = self._confirmId == row.id
		row.delete.Text = if mine and busy == "delete" then "Deleting…" elseif confirming then "Sure?" else "Delete"
		row.delete.BackgroundColor3 = if confirming then Tokens.Color.Danger else Tokens.Color.PanelRaised
		row.delete.TextColor3 = if confirming then Tokens.Color.AccentText else Tokens.Color.Danger
		for _, b in { row.wear, row.update, row.rename, row.delete } do
			setEnabled(b, busy == nil)
		end
	end
end

function WardrobePanel._render(self: WardrobePanel, snap: any)
	self._snap = snap
	local keys = {}
	for i, o in snap.outfits do
		keys[i] = ("%d:%s:%d:%s"):format(o.id, o.name, o.count, table.concat(o.thumbs, "."))
	end
	local key = table.concat(keys, ",")
	if key ~= self._rowsKey then
		self._rowsKey = key
		self:_clearRows()
		local exists = false
		for i, o in snap.outfits do
			table.insert(self._rows, self:_buildRow(o, i))
			exists = exists or o.id == self._expandedId
		end
		if not exists then
			self._expandedId = nil
		end
		self._renamingId = nil
		self._confirmId = nil
	end
	self:_refreshRows()

	local n = #snap.outfits
	self._title.Text = if snap.loaded then ("Outfits (%d/%d)"):format(n, snap.max) else "Outfits"

	-- Status: memuat / gagal / kosong
	local showStatus = false
	if not snap.loaded then
		showStatus = true
		if snap.loading or snap.error == nil then
			self._statusTitle.Text = "Loading outfits…"
			self._statusHint.Text = ""
			self._retry.Visible = false
		else
			local unavailable = snap.error == "DISABLED"
			self._statusTitle.Text = if unavailable then "Outfits are unavailable" else "Couldn't load your outfits"
			self._statusHint.Text = if snap.error == "NOT_LOADED"
				then "Your data is still loading. Try again in a moment."
				else ""
			self._retry.Visible = not unavailable
		end
	elseif n == 0 then
		showStatus = true
		self._statusTitle.Text = "No saved outfits yet"
		self._statusHint.Text = "Save what you're wearing to use it later."
		self._retry.Visible = false
	end
	self._status.Visible = showStatus

	-- Tombol Save
	local canSave = snap.loaded and snap.busy == nil and not snap.isFull
	self._save.Text = if snap.busy == "save" then "Saving…" elseif snap.isFull then "Full" else "Save"
	self._save.BackgroundColor3 = if canSave then Tokens.Color.Accent else Tokens.Color.PanelRaised
	self._save.TextColor3 = if canSave then Tokens.Color.AccentText else Tokens.Color.TextMuted
	self._save.AutoButtonColor = canSave
	self._nameInput.TextEditable = snap.loaded and not snap.isFull

	-- Toggle setting
	local on = snap.restoreOutfit == true
	local known = snap.restoreOutfit ~= nil
	self._switch.BackgroundColor3 = if on then Tokens.Color.Accent else Tokens.Color.PanelRaised
	self._switch.BackgroundTransparency = if on then 0 else Tokens.Transparency.PanelRaised
	self._switch.AutoButtonColor = known and snap.busy == nil
	self._knob.Position = if on then UDim2.new(1, -25, 0.5, 0) else UDim2.new(0, 3, 0.5, 0)
	self._knob.BackgroundTransparency = if known then 0 else 0.6
end

-- Buka: muat ulang daftar (daftar bisa berubah dari perangkat lain / server).
function WardrobePanel.setOpen(self: WardrobePanel, open: boolean)
	self.instance.Visible = open
	if open then
		self._list.CanvasPosition = Vector2.zero
		local ctl = self._props.controller
		task.spawn(ctl.refresh, ctl)
	else
		self._expandedId = nil
		self._renamingId = nil
		self._confirmId = nil
		self._nameInput:ReleaseFocus()
		self:_refreshRows()
	end
end

function WardrobePanel.isOpen(self: WardrobePanel): boolean
	return self.instance.Visible
end

function WardrobePanel.destroy(self: WardrobePanel)
	self._unsubscribe()
	self:_clearRows()
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return WardrobePanel
