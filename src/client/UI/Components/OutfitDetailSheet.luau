--!strict
-- Lembar detail satu outfit tersimpan (dibuka dari tombol VIEW di kartu).
-- Menutupi panel Saved Outfits: preview avatar besar, ganti nama, daftar item, Wear / Update / Delete.
--   local sheet = OutfitDetailSheet.new({
--   	parent = wardrobePanel.instance, previews = outfitPreview,
--   	onWear = fn, onUpdate = fn, onRename = function(name) ... end, onDelete = fn, onBack = fn,
--   })
--   sheet:open(outfit)   sheet:setBusy("Saving…")   sheet:close()   sheet:destroy()
-- Delete butuh dua tap ("Sure?" selama CONFIRM_SECONDS). Ganti nama: Enter menyimpan, tap di luar batal.
-- Panel yang memutuskan aksinya; lembar ini hanya tampilan + meneruskan niat pemain.

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local HEADER_H = 36
local NAME_H = 36
local ITEMS_H = 76
local FOOTER_H = 36
local THUMB = 60
local MAX_NAME = 32 -- sama dengan Wardrobe.MAX_NAME (server tetap memvalidasi)
local CONFIRM_SECONDS = 3
local Z = Tokens.ZIndex.Panel + 7 -- di atas kartu & overlay-nya

export type Outfit = {
	id: number,
	name: string,
	updatedAt: number,
	favorite: boolean,
	count: number,
	thumbs: { number },
	outfit: any,
}

export type Props = {
	parent: GuiObject,
	previews: any, -- OutfitPreview
	onWear: (Outfit) -> (),
	onUpdate: (Outfit) -> (), -- timpa dengan outfit yang sedang dipakai
	onRename: (Outfit, string) -> (),
	onDelete: (Outfit) -> (),
	onBack: () -> (),
}

local OutfitDetailSheet = {}
OutfitDetailSheet.__index = OutfitDetailSheet

export type OutfitDetailSheet = typeof(setmetatable(
	{} :: {
		instance: Frame,
		_props: Props,
		_title: TextLabel,
		_viewport: ViewportFrame,
		_fallback: Frame,
		_nameBox: TextBox,
		_items: ScrollingFrame,
		_wear: TextButton,
		_update: TextButton,
		_delete: TextButton,
		_busy: TextLabel,
		_outfit: Outfit?,
		_preview: any,
		_confirm: boolean,
		_confirmToken: number,
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

	local back = button("‹ Back", { Name = "Back", Size = UDim2.fromOffset(84, HEADER_H), Parent = root })
	local title: TextLabel = make("TextLabel", {
		Name = "Title",
		Text = "Outfit",
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(84 + gap, 0),
		Size = UDim2.new(1, -(84 + gap), 0, HEADER_H),
		ZIndex = Z,
		Parent = root,
	})

	-- Preview besar
	local previewTop = HEADER_H + gap
	local previewH = -(previewTop + NAME_H + ITEMS_H + FOOTER_H + gap * 4)
	local viewport: ViewportFrame = make("ViewportFrame", {
		Name = "Preview",
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0.2,
		Ambient = Color3.fromRGB(190, 190, 200),
		LightColor = Color3.fromRGB(255, 255, 255),
		LightDirection = Vector3.new(-0.3, -1, -0.6),
		Position = UDim2.fromOffset(0, previewTop),
		Size = UDim2.new(1, 0, 1, previewH),
		ZIndex = Z,
		Parent = root,
	}, { corner(Tokens.Radius.Medium) })
	local fallback: Frame = make("Frame", {
		Name = "Fallback",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(THUMB * 2, THUMB * 2),
		Visible = false,
		ZIndex = Z,
		Parent = viewport,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.fromOffset(THUMB, THUMB),
			CellPadding = UDim2.new(),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	-- Ganti nama
	local nameBox: TextBox = make("TextBox", {
		Name = "NameBox",
		Text = "",
		PlaceholderText = "Outfit name",
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
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -(ITEMS_H + FOOTER_H + gap * 2)),
		Size = UDim2.new(1, 0, 0, NAME_H),
		ZIndex = Z,
		Parent = root,
	}, {
		corner(Tokens.Radius.Pill),
		make("UIPadding", {
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
		}),
	})

	-- Item di dalam outfit (thumbnail)
	local items: ScrollingFrame = make("ScrollingFrame", {
		Name = "Items",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -(FOOTER_H + gap)),
		Size = UDim2.new(1, 0, 0, ITEMS_H),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Tokens.Color.TextMuted,
		ZIndex = Z,
		Parent = root,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, gap),
		}),
	})

	-- Aksi
	local footer: Frame = make("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		ZIndex = Z,
		Parent = root,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, gap),
		}),
	})
	local third = UDim2.new(1 / 3, -gap * 2 / 3, 1, 0)
	local wear = button("Wear", {
		Name = "Wear",
		LayoutOrder = 1,
		Size = third,
		BackgroundColor3 = Tokens.Color.Accent,
		BackgroundTransparency = 0,
		TextColor3 = Tokens.Color.AccentText,
		Parent = footer,
	})
	local update = button("Update", { Name = "Update", LayoutOrder = 2, Size = third, Parent = footer })
	local del = button("Delete", {
		Name = "Delete",
		LayoutOrder = 3,
		Size = third,
		TextColor3 = Tokens.Color.Danger,
		Parent = footer,
	})

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
		_title = title,
		_viewport = viewport,
		_fallback = fallback,
		_nameBox = nameBox,
		_items = items,
		_wear = wear,
		_update = update,
		_delete = del,
		_busy = busy,
		_outfit = nil,
		_preview = nil,
		_confirm = false,
		_confirmToken = 0,
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
		back.Activated:Connect(function()
			props.onBack()
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
	return self
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

function OutfitDetailSheet._clearPreview(self: OutfitDetailSheet)
	if self._preview then
		self._preview.cancel()
		self._preview = nil
	end
	self._fallback.Visible = false
end

-- Tampilkan outfit (juga dipakai untuk menyegarkan setelah nama/isi berubah).
function OutfitDetailSheet.open(self: OutfitDetailSheet, outfit: Outfit)
	local same = self._outfit ~= nil and (self._outfit :: Outfit).id == outfit.id
	self._outfit = outfit
	self._title.Text = outfit.name
	if not same or not self._nameBox:IsFocused() then
		self._nameBox.Text = outfit.name
	end
	self:_setConfirm(false)

	-- daftar item
	for _, child in self._items:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for i, assetId in outfit.thumbs do
		make("ImageLabel", {
			Name = "Item" .. i,
			BackgroundColor3 = Tokens.Color.PanelRaised,
			BackgroundTransparency = Tokens.Transparency.PanelRaised,
			BorderSizePixel = 0,
			Image = ("rbxthumb://type=Asset&id=%d&w=150&h=150"):format(assetId),
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = i,
			Size = UDim2.fromOffset(THUMB, THUMB),
			ZIndex = Tokens.ZIndex.Panel + 7,
			Parent = self._items,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Small }) })
	end

	-- preview besar (model dipakai ulang dari cache kartu)
	self:_clearPreview()
	self._viewport.Visible = true
	self._preview = self._props.previews:mount(
		self._viewport,
		("%d:%d"):format(outfit.id, outfit.updatedAt),
		outfit.outfit,
		function()
			self._viewport.Visible = true
			self._fallback.Visible = true
			for _, child in self._fallback:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			for i, assetId in outfit.thumbs do
				make("ImageLabel", {
					Name = "Thumb" .. i,
					BackgroundTransparency = 1,
					Image = ("rbxthumb://type=Asset&id=%d&w=420&h=420"):format(assetId),
					ScaleType = Enum.ScaleType.Fit,
					LayoutOrder = i,
					ZIndex = Tokens.ZIndex.Panel + 7,
					Parent = self._fallback,
				})
			end
		end
	)
	self.instance.Visible = true
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
