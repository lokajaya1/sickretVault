--!strict
-- Dialog folder outfit (panel Saved Outfits). Tiga mode:
--   "manage" -> kelola folder: daftar folder + Rename / Delete, tombol utama "New folder".
--   "set"    -> folder SATU outfit (tombol "Modify Folders" di halaman detail): centang banyak, lalu Save.
--   "pick"   -> pindahkan outfit yang sedang dipilih ke SATU folder (tap baris langsung jalan),
--               plus baris "Lepas dari <folder>" bila tab folder sedang aktif.
--   local dialog = FolderDialog.new({
--   	parent = wardrobePanel.instance, zIndex = Z,
--   	onCreate = function() end,                       -- tombol "New folder"
--   	onRename = function(id, name) end,               -- tombol Rename di baris
--   	onDelete = function(id, name) end,               -- tombol Delete (sudah dikonfirmasi dua tap)
--   	onSave = function(outfitId, ids) end,            -- mode "set"
--   	onPick = function(id, name, add) end,            -- mode "pick" (add=false -> lepas)
--   	onLimit = function(name) end,                    -- centang melebihi batas folder per outfit
--   })
--   dialog:open("set", { outfitId = 3, folders = { 1, 2 } })   dialog:setFolders(snap.folders, ...)
--   dialog:isOpen()   dialog:close()   dialog:destroy()
-- Dialog TIDAK memanggil controller sendiri: panel yang menjalankan aksinya (biar toast & busy satu jalur).

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local DIALOG_W = 320
local DIALOG_H = 300
local ROW_H = 32
local ACTION_W = 70
local TITLE_H = 26
local FOOTER_H = 34
local CONFIRM_SECONDS = 3
local MAX_PER_OUTFIT = 8 -- sama dengan OutfitFolders.MAX_PER_OUTFIT

export type Folder = { id: number, name: string, count: number }

export type Options = {
	outfitId: number?, -- mode "set"
	folders: { number }?, -- mode "set": folder yang sudah dicentang
	count: number?, -- mode "pick": jumlah outfit terpilih (untuk judul)
	activeFolder: number?, -- mode "pick": tab folder yang sedang aktif (baris "Lepas dari …")
}

export type Props = {
	parent: GuiObject,
	zIndex: number,
	onCreate: () -> (),
	onRename: (id: number, name: string) -> (),
	onDelete: (id: number, name: string) -> (),
	onSave: (outfitId: number, ids: { number }) -> (),
	onPick: (id: number, name: string, add: boolean) -> (),
	onLimit: ((name: string) -> ())?,
}

local FolderDialog = {}
FolderDialog.__index = FolderDialog

export type FolderDialog = typeof(setmetatable(
	{} :: {
		instance: TextButton,
		_props: Props,
		_title: TextLabel,
		_list: ScrollingFrame,
		_primary: TextButton,
		_mode: string?,
		_outfitId: number?,
		_pick: { [number]: boolean },
		_count: number,
		_active: number?,
		_folders: { Folder },
		_full: boolean,
		_rowConns: { RBXScriptConnection },
		_conns: { RBXScriptConnection },
	},
	FolderDialog
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

local function smallButton(text: string, props: { [string]: any }): TextButton
	local base: { [string]: any } = {
		Text = text,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.Text,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = true,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextButton", base, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })
end

function FolderDialog.new(props: Props): FolderDialog
	local pad = Tokens.Space.M
	local gap = Tokens.Space.S
	local Z = props.zIndex

	local root: TextButton = make("TextButton", {
		Name = "FolderDialog",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = Tokens.Transparency.Overlay,
		BorderSizePixel = 0,
		Visible = false,
		Position = UDim2.fromOffset(-pad, -pad),
		Size = UDim2.new(1, pad * 2, 1, pad * 2),
		ZIndex = Z,
		Parent = props.parent,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Large }) })

	local card: TextButton = make("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Panel,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.92, 0, 0.92, 0),
		ZIndex = Z + 1,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Large }),
		make("UISizeConstraint", { MaxSize = Vector2.new(DIALOG_W, DIALOG_H) }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, pad),
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
		}),
	})
	local title: TextLabel = make("TextLabel", {
		Name = "Title",
		Text = "Folders",
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, TITLE_H),
		ZIndex = Z + 1,
		Parent = card,
	})
	local list: ScrollingFrame = make("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, TITLE_H + gap),
		Size = UDim2.new(1, 0, 1, -(TITLE_H + gap + FOOTER_H + gap)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Tokens.Color.TextMuted,
		ZIndex = Z + 1,
		Parent = card,
	}, {
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap / 2) }),
	})
	local footer: Frame = make("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		ZIndex = Z + 1,
		Parent = card,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap),
		}),
	})
	local half = UDim2.new(0.5, -gap / 2, 1, 0)
	local close = smallButton("Close", {
		Name = "Close",
		TextSize = Tokens.TextSize.Body,
		LayoutOrder = 1,
		Size = half,
		ZIndex = Z + 1,
		Parent = footer,
	})
	local primary = smallButton("New folder", {
		Name = "Primary",
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		LayoutOrder = 2,
		Size = half,
		ZIndex = Z + 1,
		Parent = footer,
	})

	local self: FolderDialog = setmetatable({
		instance = root,
		_props = props,
		_title = title,
		_list = list,
		_primary = primary,
		_mode = nil,
		_outfitId = nil,
		_pick = {},
		_count = 0,
		_active = nil,
		_folders = {},
		_full = false,
		_rowConns = {},
		_conns = {},
	}, FolderDialog)

	self._conns = {
		root.Activated:Connect(function()
			self:close()
		end),
		close.Activated:Connect(function()
			self:close()
		end),
		primary.Activated:Connect(function()
			self:_confirm()
		end),
	}
	return self
end

-- Daftar folder terbaru dari snapshot controller (dialog ikut menyegarkan bila sedang terbuka).
function FolderDialog.setFolders(self: FolderDialog, folders: { Folder }, full: boolean)
	self._folders = folders
	self._full = full
	if self.instance.Visible then
		self:_render()
	end
end

function FolderDialog.open(self: FolderDialog, mode: string, options: Options?)
	local o = options or {}
	self._mode = mode
	self._outfitId = o.outfitId
	self._count = o.count or 0
	self._active = o.activeFolder
	table.clear(self._pick)
	for _, id in o.folders or {} do
		self._pick[id] = true
	end
	self.instance.Visible = true
	self:_render()
end

function FolderDialog.isOpen(self: FolderDialog): boolean
	return self.instance.Visible
end

function FolderDialog.mode(self: FolderDialog): string?
	return if self.instance.Visible then self._mode else nil
end

function FolderDialog.close(self: FolderDialog)
	self._mode = nil
	self._outfitId = nil
	self.instance.Visible = false
end

function FolderDialog._pickCount(self: FolderDialog): number
	local n = 0
	for _ in self._pick do
		n += 1
	end
	return n
end

-- Baris dasar (tombol selebar daftar).
function FolderDialog._row(self: FolderDialog, order: number, text: string): TextButton
	local row = smallButton(text, {
		Name = "Row" .. tostring(order),
		TextSize = Tokens.TextSize.Body,
		FontFace = Tokens.Font.Regular,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = order,
		Size = UDim2.new(1, -Tokens.Space.S, 0, ROW_H),
		ZIndex = self._props.zIndex + 1,
		Parent = self._list,
	})
	make("UIPadding", {
		PaddingLeft = UDim.new(0, Tokens.Space.M),
		PaddingRight = UDim.new(0, Tokens.Space.M),
		Parent = row,
	})
	return row
end

-- Baris mode kelola: nama + Rename + Delete (Frame supaya tombol tidak kena padding teks).
function FolderDialog._manageRow(self: FolderDialog, order: number, folder: Folder)
	local Z = self._props.zIndex
	local props = self._props
	local row: Frame = make("Frame", {
		Name = "Folder" .. tostring(folder.id),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Size = UDim2.new(1, -Tokens.Space.S, 0, ROW_H),
		ZIndex = Z + 1,
		Parent = self._list,
	})
	make("TextLabel", {
		Name = "Name",
		Text = ("%s (%d)"):format(folder.name, folder.count),
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -(ACTION_W * 2 + Tokens.Space.S), 1, 0),
		ZIndex = Z + 1,
		Parent = row,
	})
	local rename = smallButton("Rename", {
		Name = "Rename",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(ACTION_W + Tokens.Space.XS), 0.5, 0),
		Size = UDim2.fromOffset(ACTION_W, ROW_H - 6),
		ZIndex = Z + 1,
		Parent = row,
	})
	local del = smallButton("Delete", {
		Name = "Delete",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(ACTION_W, ROW_H - 6),
		TextColor3 = Tokens.Color.Danger,
		ZIndex = Z + 1,
		Parent = row,
	})
	local armed = false
	table.insert(
		self._rowConns,
		rename.Activated:Connect(function()
			props.onRename(folder.id, folder.name)
		end)
	)
	table.insert(
		self._rowConns,
		del.Activated:Connect(function()
			-- hapus butuh dua tap ("Sure?") supaya folder tidak hilang tak sengaja
			if not armed then
				armed = true
				del.Text = "Sure?"
				task.delay(CONFIRM_SECONDS, function()
					if armed and del.Parent ~= nil then
						armed = false
						del.Text = "Delete"
					end
				end)
				return
			end
			armed = false
			del.Text = "Delete"
			props.onDelete(folder.id, folder.name)
		end)
	)
end

function FolderDialog._render(self: FolderDialog)
	for _, c in self._rowConns do
		c:Disconnect()
	end
	table.clear(self._rowConns)
	for _, child in self._list:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	local mode = self._mode
	if mode == nil then
		return
	end
	local props = self._props

	if mode == "manage" then
		self._title.Text = "Folders"
		self._primary.Text = "New folder"
		self._primary.Visible = not self._full
	elseif mode == "set" then
		self._title.Text = "Modify Folders"
		self._primary.Text = "Save"
		self._primary.Visible = true
	else
		self._title.Text = ("Move %d outfit"):format(self._count)
		self._primary.Visible = false
	end

	local order = 0
	if #self._folders == 0 then
		order += 1
		local empty = self:_row(order, "Belum ada folder. Buat lewat tombol ＋ / New folder.")
		empty.AutoButtonColor = false
		empty.TextSize = Tokens.TextSize.Caption
		empty.TextColor3 = Tokens.Color.TextMuted
	end

	for _, folder in self._folders do
		order += 1
		if mode == "manage" then
			self:_manageRow(order, folder)
		elseif mode == "set" then
			local checked = self._pick[folder.id] == true
			local row = self:_row(order, ("%s %s"):format(if checked then "☑" else "☐", folder.name))
			table.insert(
				self._rowConns,
				row.Activated:Connect(function()
					if self._pick[folder.id] then
						self._pick[folder.id] = nil
					elseif self:_pickCount() >= MAX_PER_OUTFIT then
						if props.onLimit then
							props.onLimit(folder.name)
						end
						return
					else
						self._pick[folder.id] = true
					end
					self:_render()
				end)
			)
		else
			local row = self:_row(order, ("%s (%d)"):format(folder.name, folder.count))
			table.insert(
				self._rowConns,
				row.Activated:Connect(function()
					self:close()
					props.onPick(folder.id, folder.name, true)
				end)
			)
		end
	end

	-- mode "pick" di dalam tab folder: sekalian bisa melepas dari folder itu
	local active = self._active
	if mode == "pick" and active ~= nil then
		local name = "folder ini"
		for _, folder in self._folders do
			if folder.id == active then
				name = folder.name
			end
		end
		order += 1
		local row = self:_row(order, ("Lepas dari %s"):format(name))
		row.TextColor3 = Tokens.Color.Danger
		table.insert(
			self._rowConns,
			row.Activated:Connect(function()
				self:close()
				props.onPick(active, name, false)
			end)
		)
	end
end

-- Tombol utama: "New folder" (manage) / "Save" (set).
function FolderDialog._confirm(self: FolderDialog)
	local mode = self._mode
	if mode == "manage" then
		self._props.onCreate()
	elseif mode == "set" then
		local outfitId = self._outfitId
		if outfitId == nil then
			return
		end
		local ids: { number } = {}
		for id in self._pick do
			table.insert(ids, id)
		end
		table.sort(ids)
		self:close()
		self._props.onSave(outfitId, ids)
	end
end

function FolderDialog.destroy(self: FolderDialog)
	for _, c in self._rowConns do
		c:Disconnect()
	end
	table.clear(self._rowConns)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return FolderDialog
