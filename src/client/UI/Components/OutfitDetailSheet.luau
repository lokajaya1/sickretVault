--!strict
-- Halaman detail satu outfit tersimpan (dibuka dari tombol VIEW di kartu), pola Catalog Avatar Creator:
-- dua kolom -> kiri preview avatar besar + tombol Wear, kanan nama, Total Cost, daftar item, Outfit Options.
--   local sheet = OutfitDetailSheet.new({
--   	parent = wardrobePanel.instance, previews = outfitPreview,
--   	loadItems = function(outfit) return wardrobe:items(outfit.id) end,      -- YIELD (dipanggil di task.spawn)
--   	cachedItems = function(outfit) return wardrobe:itemsCached(outfit.id) end,
--   	onWear = fn, onUpdate = fn, onRename = fn, onDelete = fn, onFavorite = fn, onBack = fn,
--   })
--   sheet:open(outfit)   sheet:setBusy("Saving…")   sheet:close()   sheet:destroy()
-- Delete butuh dua tap ("Sure?" selama CONFIRM_SECONDS). Ganti nama: Enter menyimpan, klik di luar batal.
-- Selalu dua kolom (avatar kiri, detail kanan) supaya cocok di layar pendek/HP; lebar kolom kiri menyesuaikan.
-- Harga: dari server (op "items"). Item tanpa harga tidak dihitung ke Total Cost.
-- Preview berputar pelan sendiri; digeser (drag) untuk memutar manual. Avatar TIDAK bisa dianimasikan
-- (lihat catatan di OutfitPreview: model di client tidak punya Motor6D).

local UserInputService = game:GetService("UserInputService")

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local HEADER_H = 36
local WEAR_H = 40
local NAME_H = 34
local ROW_H = 30
local OPTION_H = 32
local STAR_SIZE = 32
local CELL = Vector2.new(88, 140)
local LEFT_FRACTION = 0.4 -- lebar kolom preview
local LEFT_MIN = 120
local LEFT_MAX = 280
local MAX_NAME = 32 -- sama dengan Wardrobe.MAX_NAME (server tetap memvalidasi)
local CONFIRM_SECONDS = 3
local DRAG_SENSITIVITY = 0.012 -- radian per piksel geseran
local ROBUX = utf8.char(0xE002)
local STAR_ON = "★"
local STAR_OFF = "☆"
local Z = Tokens.ZIndex.Panel + 7 -- di atas kartu & overlay-nya

export type Outfit = {
	id: number,
	name: string,
	createdAt: number,
	updatedAt: number,
	favorite: boolean,
	count: number,
	thumbs: { number },
	outfit: any,
}

export type Props = {
	parent: GuiObject,
	previews: any, -- OutfitPreview
	loadItems: ((Outfit) -> (boolean, any))?, -- YIELD; (true, { items, total, missing })
	cachedItems: ((Outfit) -> any)?, -- hasil yang sudah pernah dimuat (tanpa server)
	onWear: (Outfit) -> (),
	onUpdate: (Outfit) -> (), -- timpa dengan outfit yang sedang dipakai
	onRename: (Outfit, string) -> (),
	onDelete: (Outfit) -> (),
	onFavorite: ((Outfit) -> ())?,
	onBack: () -> (),
}

local OutfitDetailSheet = {}
OutfitDetailSheet.__index = OutfitDetailSheet

export type OutfitDetailSheet = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_left: Frame,
		_right: ScrollingFrame,
		_star: TextButton,
		_viewport: ViewportFrame,
		_fallback: Frame,
		_drag: TextButton,
		_dragging: boolean,
		_lastX: number,
		_nameBox: TextBox,
		_total: TextLabel,
		_itemsTitle: TextLabel,
		_grid: Frame,
		_status: TextButton,
		_meta: TextLabel,
		_wear: TextButton,
		_update: TextButton,
		_delete: TextButton,
		_busy: TextLabel,
		_outfit: Outfit?,
		_preview: any,
		_confirm: boolean,
		_confirmToken: number,
		_itemsToken: number,
		_conns: { RBXScriptConnection },
	},
	OutfitDetailSheet
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

local function button(text: string, props: { [string]: any }): TextButton
	local base: { [string]: any } = {
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

local function label(props: { [string]: any }): TextLabel
	local base: { [string]: any } = {
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = Z,
	}
	for k, v in props do
		base[k] = v
	end
	return make("TextLabel", base)
end

local function priceText(price: number?): string
	if price == nil then
		return "Off Sale"
	elseif price <= 0 then
		return "Free"
	end
	return ROBUX .. " " .. tostring(price)
end

local function dateText(seconds: number): string
	if type(seconds) ~= "number" or seconds <= 0 then
		return "Created on —"
	end
	return "Created on " .. os.date("!%d %b %Y", seconds)
end

-- Tombol yang fiturnya belum ada (tampil redup + label "Soon").
local function soonButton(text: string, order: number, parent: Instance): TextButton
	local b = button(text .. " · Soon", {
		Name = text,
		LayoutOrder = order,
		Size = UDim2.new(0.5, -Tokens.Space.XS, 0, OPTION_H),
		TextColor3 = Tokens.Color.TextMuted,
		BackgroundTransparency = 0.6,
		AutoButtonColor = false,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Caption,
		Parent = parent,
	})
	return b
end

function OutfitDetailSheet.new(props: Props): OutfitDetailSheet
	local pad = Tokens.Space.M
	local gap = Tokens.Space.S

	local root: Frame = make("Frame", {
		Name = "OutfitDetail",
		Active = true,
		BackgroundColor3 = Tokens.Color.Panel,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
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

	-- Header: kembali + bintang favorit
	local back = button("‹ Back", { Name = "Back", Size = UDim2.fromOffset(84, HEADER_H), Parent = root })
	local star = button("", {
		Name = "Favorite",
		Text = STAR_OFF,
		TextSize = Tokens.TextSize.Title,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(STAR_SIZE, STAR_SIZE),
		Parent = root,
	})

	local body: Frame = make("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, HEADER_H + gap),
		Size = UDim2.new(1, 0, 1, -(HEADER_H + gap)),
		ZIndex = Z,
		Parent = root,
	})

	-- Kolom kiri: preview besar + Wear
	local left: Frame = make("Frame", {
		Name = "Left",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.44, 1),
		ZIndex = Z,
		Parent = body,
	})
	local viewport: ViewportFrame = make("ViewportFrame", {
		Name = "Preview",
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0.2,
		Ambient = Color3.fromRGB(120, 120, 134),
		LightColor = Color3.fromRGB(236, 236, 245),
		LightDirection = Vector3.new(-0.4, -1, -0.65),
		Size = UDim2.new(1, 0, 1, -(WEAR_H + gap)),
		ZIndex = Z,
		Parent = left,
	}, { corner(Tokens.Radius.Medium) })
	local fallback: Frame = make("Frame", {
		Name = "Fallback",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.8),
		Visible = false,
		ZIndex = Z,
		Parent = viewport,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.fromScale(0.5, 0.5),
			CellPadding = UDim2.new(),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	-- Lapisan tak terlihat untuk menangkap geseran di atas preview
	local drag: TextButton = make("TextButton", {
		Name = "Drag",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -(WEAR_H + gap)),
		ZIndex = Z + 1,
		Parent = left,
	})

	local wear = button("Wear", {
		Name = "Wear",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, WEAR_H),
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		TextSize = Tokens.TextSize.Button,
		Parent = left,
	})

	-- Kolom kanan: nama, biaya, item, opsi
	local right: ScrollingFrame = make("ScrollingFrame", {
		Name = "Right",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.56, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Tokens.Color.TextMuted,
		ZIndex = Z,
		Parent = body,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap),
		}),
		make("UIPadding", { PaddingRight = UDim.new(0, gap) }),
	})

	local nameBox: TextBox = make("TextBox", {
		Name = "NameBox",
		Text = "",
		PlaceholderText = "Outfit name",
		ClearTextOnFocus = false,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		PlaceholderColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, NAME_H),
		ZIndex = Z,
		Parent = right,
	}, {
		corner(Tokens.Radius.Small),
		make("UIPadding", { PaddingLeft = UDim.new(0, gap), PaddingRight = UDim.new(0, gap) }),
	})

	local costRow: Frame = make("Frame", {
		Name = "Cost",
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, ROW_H),
		ZIndex = Z,
		Parent = right,
	})
	label({
		Name = "CostLabel",
		Text = "Total Cost",
		TextColor3 = Tokens.Color.TextMuted,
		Size = UDim2.new(0.5, 0, 1, 0),
		Parent = costRow,
	})
	local total = label({
		Name = "CostValue",
		Text = "—",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Button,
		TextColor3 = Tokens.Color.Robux,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		Parent = costRow,
	})

	local saveRoblox = soonButton("Save to Roblox", 3, right)
	saveRoblox.Size = UDim2.new(1, 0, 0, OPTION_H)

	local itemsTitle = label({
		Name = "ItemsTitle",
		Text = "Items",
		FontFace = Tokens.Font.Bold,
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, ROW_H),
		Parent = right,
	})

	local grid: Frame = make("Frame", {
		Name = "Items",
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 5,
		Size = UDim2.new(1, 0, 0, 0),
		ZIndex = Z,
		Parent = right,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.fromOffset(CELL.X, CELL.Y),
			CellPadding = UDim2.fromOffset(gap, gap),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	local status = button("Loading items…", {
		Name = "ItemsStatus",
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		LayoutOrder = 6,
		Size = UDim2.new(1, 0, 0, ROW_H),
		Parent = right,
	})

	local meta = label({
		Name = "Meta",
		Text = "",
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 7,
		Size = UDim2.new(1, 0, 0, ROW_H + Tokens.TextSize.Caption),
		Parent = right,
	})

	label({
		Name = "OptionsTitle",
		Text = "Outfit Options",
		FontFace = Tokens.Font.Bold,
		LayoutOrder = 8,
		Size = UDim2.new(1, 0, 0, ROW_H),
		Parent = right,
	})
	local options: Frame = make("Frame", {
		Name = "Options",
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 9,
		Size = UDim2.new(1, 0, 0, 0),
		ZIndex = Z,
		Parent = right,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.new(0.5, -Tokens.Space.XS, 0, OPTION_H),
			CellPadding = UDim2.fromOffset(gap, gap),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local half = UDim2.new(0.5, -Tokens.Space.XS, 0, OPTION_H)
	local update = button("Update", { Name = "Update", LayoutOrder = 1, Size = half, Parent = options })
	local rename = button("Rename", { Name = "Rename", LayoutOrder = 2, Size = half, Parent = options })
	local del = button("Delete", {
		Name = "Delete",
		LayoutOrder = 3,
		Size = half,
		TextColor3 = Tokens.Color.Danger,
		Parent = options,
	})
	soonButton("Share", 4, options)
	soonButton("Modify Folders", 5, options)

	local busy: TextLabel = make("TextLabel", {
		Name = "Busy",
		Text = "",
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = Tokens.Transparency.Overlay,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Button,
		TextColor3 = Tokens.Color.Text,
		Visible = false,
		Position = UDim2.fromOffset(-pad, -pad),
		Size = UDim2.new(1, pad * 2, 1, pad * 2),
		ZIndex = Z + 2,
		Parent = root,
	}, { corner(Tokens.Radius.Large) })

	local self: OutfitDetailSheet = setmetatable({
		instance = root,
		_props = props,
		_left = left,
		_right = right,
		_star = star,
		_viewport = viewport,
		_fallback = fallback,
		_drag = drag,
		_dragging = false,
		_lastX = 0,
		_nameBox = nameBox,
		_total = total,
		_itemsTitle = itemsTitle,
		_grid = grid,
		_status = status,
		_meta = meta,
		_wear = wear,
		_update = update,
		_delete = del,
		_busy = busy,
		_outfit = nil,
		_preview = nil,
		_confirm = false,
		_confirmToken = 0,
		_itemsToken = 0,
		_conns = {},
	}, OutfitDetailSheet)

	local function current(): Outfit?
		return self._outfit
	end

	local function commitRename(enterPressed: boolean)
		local outfit = current()
		if outfit == nil then
			return
		end
		local text = string.match(nameBox.Text, "^%s*(.-)%s*$") or ""
		if not enterPressed or text == "" or text == outfit.name then
			nameBox.Text = outfit.name -- batal
			return
		end
		props.onRename(outfit, text)
	end

	self._conns = {
		body:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_layout()
		end),
		back.Activated:Connect(function()
			props.onBack()
		end),
		star.Activated:Connect(function()
			local outfit = current()
			if outfit and props.onFavorite then
				props.onFavorite(outfit)
			end
		end),
		nameBox:GetPropertyChangedSignal("Text"):Connect(function()
			local len = utf8.len(nameBox.Text)
			if len and len > MAX_NAME then
				local cut = utf8.offset(nameBox.Text, MAX_NAME + 1)
				if cut then
					nameBox.Text = string.sub(nameBox.Text, 1, cut - 1)
				end
			end
		end),
		nameBox.FocusLost:Connect(commitRename),
		drag.InputBegan:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				self._dragging = true
				self._lastX = input.Position.X
				self:_setSpin(false)
			end
		end),
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if not self._dragging then
				return
			end
			if
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			then
				local x = input.Position.X
				local preview = self._preview
				if preview then
					preview.addYaw((self._lastX - x) * DRAG_SENSITIVITY)
				end
				self._lastX = x
			end
		end),
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				if self._dragging then
					self._dragging = false
					self:_setSpin(true)
				end
			end
		end),
		rename.Activated:Connect(function()
			nameBox:CaptureFocus()
		end),
		status.Activated:Connect(function()
			local outfit = current()
			if outfit then
				self:_loadItems(outfit, true)
			end
		end),
		wear.Activated:Connect(function()
			local outfit = current()
			if outfit then
				props.onWear(outfit)
			end
		end),
		update.Activated:Connect(function()
			local outfit = current()
			if outfit then
				props.onUpdate(outfit)
			end
		end),
		del.Activated:Connect(function()
			local outfit = current()
			if outfit == nil then
				return
			end
			if not self._confirm then
				self:_setConfirm(true)
				return
			end
			self:_setConfirm(false)
			props.onDelete(outfit)
		end),
	}
	self:_layout()
	return self
end

-- Selalu dua kolom: avatar kiri (lebar menyesuaikan, dibatasi LEFT_MIN/LEFT_MAX), detail kanan.
function OutfitDetailSheet._layout(self: OutfitDetailSheet)
	local gap = Tokens.Space.S
	local body = self._left.Parent :: Frame
	local width = body.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local leftW = math.clamp(math.floor(width * LEFT_FRACTION), LEFT_MIN, math.max(LEFT_MIN, LEFT_MAX))
	leftW = math.min(leftW, math.max(math.floor(width * 0.5), LEFT_MIN))
	self._left.Position = UDim2.new()
	self._left.Size = UDim2.new(0, leftW, 1, 0)
	self._right.AnchorPoint = Vector2.new(1, 0)
	self._right.Position = UDim2.fromScale(1, 0)
	self._right.Size = UDim2.new(1, -(leftW + gap), 1, 0)
end

function OutfitDetailSheet._setConfirm(self: OutfitDetailSheet, confirm: boolean)
	self._confirm = confirm
	self._delete.Text = if confirm then "Sure?" else "Delete"
	self._delete.BackgroundColor3 = if confirm then Tokens.Color.Danger else Tokens.Color.PanelRaised
	self._delete.BackgroundTransparency = if confirm then 0 else Tokens.Transparency.PanelRaised
	self._delete.TextColor3 = if confirm then Tokens.Color.AccentText else Tokens.Color.Danger
	self._confirmToken += 1
	if confirm then
		local token = self._confirmToken
		task.delay(CONFIRM_SECONDS, function()
			if self._confirmToken == token and self._confirm then
				self:_setConfirm(false)
			end
		end)
	end
end

-- Putaran otomatis hanya saat lembar terbuka & tidak sedang digeser.
function OutfitDetailSheet._setSpin(self: OutfitDetailSheet, on: boolean)
	local preview = self._preview
	if preview then
		preview.setSpin(on and self.instance.Visible and not self._dragging)
	end
end

function OutfitDetailSheet._clearPreview(self: OutfitDetailSheet)
	if self._preview then
		self._preview.setSpin(false)
		self._preview.cancel()
		self._preview = nil
	end
	self._dragging = false
	self._fallback.Visible = false
end

local function clearChildren(parent: Instance)
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function OutfitDetailSheet._setStatus(self: OutfitDetailSheet, text: string?, retry: boolean)
	self._status.Text = text or ""
	self._status.Visible = text ~= nil
	self._status.AutoButtonColor = retry
	self._status.TextColor3 = if retry then Tokens.Color.Danger else Tokens.Color.TextMuted
end

-- Tampilkan item + Total Cost dari balasan server.
function OutfitDetailSheet._showItems(self: OutfitDetailSheet, data: any)
	clearChildren(self._grid)
	local items = if type(data) == "table" and type(data.items) == "table" then data.items else {}
	local gap = Tokens.Space.XS
	for i, item in items do
		local cell: Frame = make("Frame", {
			Name = "Item" .. tostring(item.id),
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BackgroundTransparency = Tokens.Transparency.PanelRaised,
			BorderSizePixel = 0,
			LayoutOrder = i,
			ZIndex = Z,
			Parent = self._grid,
		}, { corner(Tokens.Radius.Small) })
		local line = Tokens.TextSize.Caption + 2
		make("ImageLabel", {
			Name = "Thumb",
			BackgroundTransparency = 1,
			Image = ("rbxthumb://type=Asset&id=%d&w=150&h=150"):format(item.id),
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.new(1, 0, 1, -(line * 3 + gap * 2)),
			ZIndex = Z,
			Parent = cell,
		})
		label({
			Name = "Name",
			Text = if type(item.name) == "string" then item.name else "Item",
			TextSize = Tokens.TextSize.Caption,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -(line * 2 + gap)),
			Size = UDim2.new(1, -gap * 2, 0, line),
			Parent = cell,
		})
		label({
			Name = "Creator",
			Text = if type(item.creator) == "string" and item.creator ~= "" then "by " .. item.creator else "",
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = Tokens.Color.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -(line + gap)),
			Size = UDim2.new(1, -gap * 2, 0, line),
			Parent = cell,
		})
		label({
			Name = "Price",
			Text = priceText(item.price),
			FontFace = Tokens.Font.Bold,
			TextSize = Tokens.TextSize.Caption,
			TextColor3 = if item.price then Tokens.Color.Robux else Tokens.Color.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -gap),
			Size = UDim2.new(1, -gap * 2, 0, line),
			Parent = cell,
		})
	end

	local totalValue = if type(data) == "table" and type(data.total) == "number" then data.total else 0
	self._total.Text = if totalValue > 0 then ROBUX .. " " .. tostring(totalValue) else "Free"
	self._total.TextColor3 = if totalValue > 0 then Tokens.Color.Robux else Tokens.Color.TextMuted
	self._itemsTitle.Text = ("Items (%d)"):format(#items)

	local missing = if type(data) == "table" and type(data.missing) == "number" then data.missing else 0
	if #items == 0 then
		self:_setStatus("No items in this outfit", false)
	elseif missing > 0 then
		self:_setStatus(("%d item tidak bisa dimuat"):format(missing), false)
	else
		self:_setStatus(nil, false)
	end
end

-- Muat detail item (nama & harga). force = abaikan cache lalu minta lagi.
function OutfitDetailSheet._loadItems(self: OutfitDetailSheet, outfit: Outfit, force: boolean?)
	self._itemsToken += 1
	local token = self._itemsToken
	local props = self._props

	if not force and props.cachedItems then
		local cached = props.cachedItems(outfit)
		if cached ~= nil then
			self:_showItems(cached)
			return
		end
	end

	clearChildren(self._grid)
	self._total.Text = "—"
	self._total.TextColor3 = Tokens.Color.TextMuted
	self._itemsTitle.Text = ("Items (%d)"):format(outfit.count)
	local load = props.loadItems
	if load == nil then
		self:_setStatus(nil, false)
		return
	end
	self:_setStatus("Loading items…", false)
	task.spawn(function()
		local ok, data = load(outfit)
		if token ~= self._itemsToken then
			return -- outfit lain sudah dibuka
		end
		if ok then
			self:_showItems(data)
		else
			self:_setStatus("Gagal memuat item — ketuk untuk coba lagi", true)
		end
	end)
end

-- Tampilkan outfit (juga dipakai untuk menyegarkan setelah nama/isi berubah).
function OutfitDetailSheet.open(self: OutfitDetailSheet, outfit: Outfit)
	local same = self._outfit ~= nil and (self._outfit :: Outfit).id == outfit.id
	local changed = not same or (self._outfit :: Outfit).updatedAt ~= outfit.updatedAt
	self._outfit = outfit
	if not same or not self._nameBox:IsFocused() then
		self._nameBox.Text = outfit.name
	end
	self._star.Text = if outfit.favorite then STAR_ON else STAR_OFF
	self._star.TextColor3 = if outfit.favorite then Tokens.Color.Warning else Tokens.Color.TextMuted
	self._meta.Text = dateText(outfit.createdAt) .. "\nFolders: None"
	self:_setConfirm(false)

	if changed then
		self:_loadItems(outfit)
		self:_clearPreview()
		self._viewport.Visible = true
		self._preview = self._props.previews:mount(
			self._viewport,
			("%d:%d"):format(outfit.id, outfit.updatedAt),
			outfit.outfit,
			function()
				self._fallback.Visible = true
				clearChildren(self._fallback)
				for i, assetId in outfit.thumbs do
					make("ImageLabel", {
						Name = "Thumb" .. i,
						BackgroundTransparency = 1,
						Image = ("rbxthumb://type=Asset&id=%d&w=420&h=420"):format(assetId),
						ScaleType = Enum.ScaleType.Fit,
						LayoutOrder = i,
						ZIndex = Z,
						Parent = self._fallback,
					})
				end
			end
		)
	end
	self.instance.Visible = true
	self:_layout()
	self:_setSpin(true)
end

function OutfitDetailSheet.outfitId(self: OutfitDetailSheet): number?
	local outfit = self._outfit
	return if outfit then outfit.id else nil
end

function OutfitDetailSheet.isOpen(self: OutfitDetailSheet): boolean
	return self.instance.Visible
end

function OutfitDetailSheet.setBusy(self: OutfitDetailSheet, text: string?)
	self._busy.Text = text or ""
	self._busy.Visible = text ~= nil
end

function OutfitDetailSheet.close(self: OutfitDetailSheet)
	self.instance.Visible = false
	self._nameBox:ReleaseFocus()
	self:_clearPreview()
	self:_setConfirm(false)
	self._itemsToken += 1
	self._outfit = nil
	self:setBusy(nil)
end

function OutfitDetailSheet.destroy(self: OutfitDetailSheet)
	self:_clearPreview()
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return OutfitDetailSheet
