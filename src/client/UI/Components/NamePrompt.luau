--!strict
-- Dialog kecil "isi nama" yang dipakai ulang di panel Saved Outfits:
-- simpan outfit ("save"), buat folder ("folderNew"), ganti nama folder ("folderRename").
--   local prompt = NamePrompt.new({
--   	parent = wardrobePanel.instance,
--   	onConfirm = function(mode, name, folderId) ... end, -- name nil = kotak dikosongkan
--   })
--   prompt:open("folderRename", 3, "Pesta")   prompt:close()   prompt:isOpen()   prompt:destroy()
-- Mode "save" boleh dikirim dengan name = nil (server memberi nama bawaan "Outfit N");
-- mode folder TIDAK boleh kosong -> tombol confirm diabaikan bila kosong (dialog tetap terbuka).
-- Panjang teks dipotong sesuai batas modenya (server tetap memvalidasi).

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local PROMPT_W = 320
local PROMPT_H = 168
local MAX_NAME = 32 -- sama dengan Wardrobe.MAX_NAME
local MAX_FOLDER_NAME = 24 -- sama dengan OutfitFolders.MAX_NAME

export type Mode = string -- "save" | "folderNew" | "folderRename"

type Text = { title: string, hint: string, placeholder: string, confirm: string, max: number }

local TEXT: { [string]: Text } = {
	save = {
		title = "Save current outfit",
		hint = "Kosongkan untuk nama otomatis.",
		placeholder = "Outfit name",
		confirm = "Save",
		max = MAX_NAME,
	},
	folderNew = {
		title = "New folder",
		hint = ("Maks %d huruf."):format(MAX_FOLDER_NAME),
		placeholder = "Folder name",
		confirm = "Create",
		max = MAX_FOLDER_NAME,
	},
	folderRename = {
		title = "Rename folder",
		hint = ("Maks %d huruf."):format(MAX_FOLDER_NAME),
		placeholder = "Folder name",
		confirm = "Save",
		max = MAX_FOLDER_NAME,
	},
}

export type Props = {
	parent: GuiObject,
	zIndex: number, -- lapisan dasar (dialog dipasang di atasnya)
	onConfirm: (mode: Mode, name: string?, folderId: number?) -> (),
}

local NamePrompt = {}
NamePrompt.__index = NamePrompt

export type NamePrompt = typeof(setmetatable(
	{} :: {
		instance: TextButton,
		_props: Props,
		_title: TextLabel,
		_hint: TextLabel,
		_box: TextBox,
		_confirmButton: TextButton,
		_mode: Mode,
		_folderId: number?,
		_conns: { RBXScriptConnection },
	},
	NamePrompt
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

-- Teks kotak -> nil bila kosong.
local function clean(text: string): string?
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	return if trimmed == "" then nil else trimmed
end

function NamePrompt.new(props: Props): NamePrompt
	local pad = Tokens.Space.M
	local gap = Tokens.Space.S
	local Z = props.zIndex

	local root: TextButton = make("TextButton", {
		Name = "NamePrompt",
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

	-- TextButton (bukan Frame) supaya klik di dalam kartu tidak menutup dialog.
	local card: TextButton = make("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Panel,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, PROMPT_H),
		ZIndex = Z + 1,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Large }),
		make("UISizeConstraint", { MaxSize = Vector2.new(PROMPT_W, PROMPT_H) }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, pad),
			PaddingBottom = UDim.new(0, pad),
			PaddingLeft = UDim.new(0, pad),
			PaddingRight = UDim.new(0, pad),
		}),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap) }),
	})
	local title: TextLabel = make("TextLabel", {
		Name = "Title",
		Text = TEXT.save.title,
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 26),
		ZIndex = Z + 1,
		Parent = card,
	})
	local hint: TextLabel = make("TextLabel", {
		Name = "Hint",
		Text = TEXT.save.hint,
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Regular,
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 18),
		ZIndex = Z + 1,
		Parent = card,
	})
	local box: TextBox = make("TextBox", {
		Name = "Name",
		Text = "",
		PlaceholderText = TEXT.save.placeholder,
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
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 34),
		ZIndex = Z + 1,
		Parent = card,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Pill }),
		make("UIPadding", { PaddingLeft = UDim.new(0, pad), PaddingRight = UDim.new(0, pad) }),
	})
	local row: Frame = make("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 34),
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
	local cancel: TextButton = make("TextButton", {
		Name = "Cancel",
		Text = "Cancel",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Size = half,
		ZIndex = Z + 1,
		Parent = row,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })
	local confirm: TextButton = make("TextButton", {
		Name = "Confirm",
		Text = TEXT.save.confirm,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Accent,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Size = half,
		ZIndex = Z + 1,
		Parent = row,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	local self: NamePrompt = setmetatable({
		instance = root,
		_props = props,
		_title = title,
		_hint = hint,
		_box = box,
		_confirmButton = confirm,
		_mode = "save",
		_folderId = nil,
		_conns = {},
	}, NamePrompt)

	self._conns = {
		root.Activated:Connect(function()
			self:close()
		end),
		cancel.Activated:Connect(function()
			self:close()
		end),
		confirm.Activated:Connect(function()
			self:_confirm()
		end),
		box.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				self:_confirm()
			end
		end),
		box:GetPropertyChangedSignal("Text"):Connect(function()
			local max = TEXT[self._mode].max
			local len = utf8.len(box.Text)
			if len and len > max then
				local cut = utf8.offset(box.Text, max + 1)
				if cut then
					box.Text = string.sub(box.Text, 1, cut - 1)
				end
			end
		end),
	}
	return self
end

function NamePrompt._confirm(self: NamePrompt)
	local mode = self._mode
	local folderId = self._folderId
	local name = clean(self._box.Text)
	if mode ~= "save" and name == nil then
		return -- nama folder wajib
	end
	self:close()
	self._props.onConfirm(mode, name, folderId)
end

function NamePrompt.open(self: NamePrompt, mode: Mode, folderId: number?, initial: string?)
	local text = TEXT[mode]
	if text == nil then
		return
	end
	self._mode = mode
	self._folderId = folderId
	self._title.Text = text.title
	self._hint.Text = text.hint
	self._box.PlaceholderText = text.placeholder
	self._confirmButton.Text = text.confirm
	self._box.Text = initial or ""
	self.instance.Visible = true
	self._box:CaptureFocus()
end

function NamePrompt.isOpen(self: NamePrompt): boolean
	return self.instance.Visible
end

function NamePrompt.close(self: NamePrompt)
	if not self.instance.Visible then
		return
	end
	self._box:ReleaseFocus()
	self.instance.Visible = false
end

function NamePrompt.destroy(self: NamePrompt)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return NamePrompt
