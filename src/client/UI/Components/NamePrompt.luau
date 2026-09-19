--!strict
-- Dialog kecil "isi nama" yang dipakai ulang di panel Saved Outfits:
-- simpan outfit ("save"), buat folder ("folderNew"), ganti nama folder ("folderRename").
-- Sejak #30 ia juga dipakai sebagai dialog PILIHAN tanpa kotak teks: mode "saveTarget"
-- ("How would you like to save your outfit?") menyembunyikan kotak & hint, lalu mengubah dua
-- tombol di bawah menjadi dua KARTU sejajar. Jawabannya datang lewat `name`: "outfit" (kartu
-- kiri) atau "avatar" (kartu kanan) -- jadi tidak perlu file dialog baru.
--   local prompt = NamePrompt.new({
--   	parent = wardrobePanel.instance,
--   	onConfirm = function(mode, name, folderId) ... end, -- name nil = kotak dikosongkan
--   })
--   prompt:open("folderRename", 3, "Pesta")   prompt:close()   prompt:isOpen()   prompt:destroy()
-- Mode "save" boleh dikirim dengan name = nil (server memberi nama bawaan "Outfit N");
-- mode folder TIDAK boleh kosong -> tombol confirm diabaikan bila kosong (dialog tetap terbuka).
-- Panjang teks dipotong sesuai batas modenya (server tetap memvalidasi).

local Lighting = game:GetService("Lighting")

local Tokens = require(script.Parent.Parent.Theme.Tokens)
local SideRail = require(script.Parent.SideRail)

local PROMPT_W = 320
local PROMPT_H = 168
local CHOICE_W = 420 -- mode pilihan: dua kartu sejajar butuh lebih lebar
local CHOICE_H = 216 -- judul + baris syarat + dua kartu
local CHOICE_ROW_H = 104 -- tinggi kartu pilihan
local ROW_H = 34 -- tinggi baris tombol biasa
local BLUR_SIZE = 18 -- mode pilihan: dunia di belakang diburamkan, selubung hitamnya dibuang
local MAX_NAME = 32 -- sama dengan Wardrobe.MAX_NAME
local MAX_FOLDER_NAME = 24 -- sama dengan OutfitFolders.MAX_NAME

export type Mode = string -- "save" | "folderNew" | "folderRename" | "saveTarget"

-- `choice` = mode pilihan (tanpa kotak teks): `cancel`/`confirm` jadi dua kartu, dan `cancelValue`
-- /`confirmValue` adalah jawaban yang dikirim lewat argumen `name` di onConfirm.
type Text = {
	title: string,
	hint: string,
	placeholder: string,
	confirm: string,
	max: number,
	cancel: string?,
	note: string?, -- baris kedua kartu kiri
	confirmNote: string?, -- baris kedua kartu kanan
	choice: boolean?,
	cancelValue: string?,
	confirmValue: string?,
}

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
	-- Pola CAC: dua kartu, bukan tombol OK/Cancel. Keluar tanpa memilih = tap di luar kartu.
	saveTarget = {
		title = "How would you like to save your outfit?",
		-- Diukur 19 Sep 2026: PromptCreateOutfit menolak look berisi item yang belum dimiliki
		-- (Failed), sementara PromptSaveAvatar menerimanya. Dua kartu itu TIDAK setara, jadi
		-- syaratnya ditulis sejak awal -- bukan baru muncul sebagai pesan gagal.
		hint = "New outfits only work if you own every item you're wearing.",
		placeholder = "",
		confirm = "My Roblox Avatar",
		confirmNote = "Replaces the avatar you wear on Roblox",
		cancel = "New Roblox Outfit",
		note = "Saves this look as a new saved outfit",
		choice = true,
		cancelValue = "outfit",
		confirmValue = "avatar",
		max = MAX_NAME,
	},
}

export type Props = {
	parent: Instance, -- GuiObject, atau ScreenGui bila dialog dipakai selayar penuh (#30)
	zIndex: number, -- lapisan dasar (dialog dipasang di atasnya)
	onConfirm: (mode: Mode, name: string?, folderId: number?) -> (),
	onClose: (() -> ())?, -- dialog ditutup (batal, tap di luar, atau sesudah confirm)
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
		_card: TextButton,
		_cardSize: UISizeConstraint,
		_row: Frame,
		_closeButton: TextButton,
		_cancelButton: TextButton,
		_confirmButton: TextButton,
		_blur: BlurEffect?,
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

-- Kartu pilihan: nama tebal + keterangan kecil di baris kedua (RichText, bukan dua TextLabel --
-- tombolnya tetap satu benda yang bisa ditekan di mana saja).
local function twoLine(title: string, note: string?): string
	if note == nil or note == "" then
		return title
	end
	local c = Tokens.Color.TextMuted
	return ('%s\n<font size="12" color="rgb(%d,%d,%d)">%s</font>'):format(
		title,
		math.round(c.R * 255),
		math.round(c.G * 255),
		math.round(c.B * 255),
		note
	)
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

	-- Batas ukuran kartu dipegang: mode pilihan memakai kartu yang lebih lebar & tinggi.
	local cardSize: UISizeConstraint = make("UISizeConstraint", { MaxSize = Vector2.new(PROMPT_W, PROMPT_H) })

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
		cardSize,
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
	-- Tombol tutup di pojok kanan atas kartu. Ia anak JUDUL, bukan anak kartu: kartu memakai
	-- UIListLayout, yang akan menyusun tombol ini jadi satu baris sendiri di bawah judul. Anak
	-- sebuah TextLabel tidak ikut disusun, jadi ia bisa melayang di kanan atas tanpa Frame
	-- pembungkus tambahan. Hanya untuk mode pilihan: mode isian nama sudah punya tombol Cancel,
	-- sedangkan mode pilihan (sejak selubung hitamnya dibuang) tidak lagi terlihat bisa ditutup.
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
		Visible = false,
		ZIndex = Z + 2,
		Parent = title,
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
		Size = UDim2.new(1, 0, 0, ROW_H),
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
	-- RichText: mode pilihan menulis dua baris (nama + keterangan kecil) di dalam satu tombol.
	local cancel: TextButton = make("TextButton", {
		Name = "Cancel",
		Text = "Cancel",
		RichText = true,
		TextWrapped = true,
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
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Pill }),
		make("UIStroke", {
			Name = "Edge",
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Tokens.Color.Stroke,
			Transparency = Tokens.Transparency.Stroke,
			Enabled = false,
		}),
	})
	local confirm: TextButton = make("TextButton", {
		Name = "Confirm",
		Text = TEXT.save.confirm,
		RichText = true,
		TextWrapped = true,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Accent,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Size = half,
		ZIndex = Z + 1,
		Parent = row,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Pill }),
		make("UIStroke", {
			Name = "Edge",
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Tokens.Color.Stroke,
			Transparency = Tokens.Transparency.Stroke,
			Enabled = false,
		}),
	})

	local self: NamePrompt = setmetatable({
		instance = root,
		_props = props,
		_title = title,
		_hint = hint,
		_box = box,
		_card = card,
		_cardSize = cardSize,
		_row = row,
		_closeButton = closeButton,
		_cancelButton = cancel,
		_confirmButton = confirm,
		_blur = nil,
		_mode = "save",
		_folderId = nil,
		_conns = {},
	}, NamePrompt)

	self._conns = {
		root.Activated:Connect(function()
			-- Mode PILIHAN tidak lagi tertutup oleh ketukan di luar kartu. Sejak panel katalog
			-- ikut disingkirkan, "di luar kartu" = seluruh layar: satu klik nyasar (di macOS,
			-- klik untuk memberi fokus ke jendela Studio sudah cukup) menutup dialog dan
			-- memunculkan katalog kembali -- persis gejala "tekan C kok pindah ke katalog",
			-- padahal pelakunya klik, bukan tombol C. Jalan keluarnya sekarang tombol silang.
			local text = TEXT[self._mode]
			if text ~= nil and text.choice then
				return
			end
			self:close()
		end),
		closeButton.Activated:Connect(function()
			self:close()
		end),
		cancel.Activated:Connect(function()
			-- Mode pilihan: tombol kiri BUKAN "batal", ia jawaban pertama.
			local text = TEXT[self._mode]
			if text ~= nil and text.choice then
				self:close()
				self._props.onConfirm(self._mode, text.cancelValue, nil)
				return
			end
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
	local choice = TEXT[mode]
	if choice ~= nil and choice.choice then
		self:close()
		self._props.onConfirm(mode, choice.confirmValue, nil)
		return
	end
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
	self._box.Text = initial or ""

	-- Dua tampilan dalam satu dialog: isian nama, atau dua kartu pilihan (UIListLayout melewati
	-- anak yang Visible = false, jadi hint & kotak cukup disembunyikan).
	local choice = text.choice == true
	self._hint.Visible = text.hint ~= ""
	self._box.Visible = not choice
	self._closeButton.Visible = choice
	self._cardSize.MaxSize = if choice then Vector2.new(CHOICE_W, CHOICE_H) else Vector2.new(PROMPT_W, PROMPT_H)
	self._card.Size = UDim2.new(0.9, 0, 0, if choice then CHOICE_H else PROMPT_H)
	self._row.Size = UDim2.new(1, 0, 0, if choice then CHOICE_ROW_H else ROW_H)
	self._cancelButton.Text = if choice then twoLine(text.cancel or "", text.note) else "Cancel"
	self._confirmButton.Text = if choice then twoLine(text.confirm, text.confirmNote) else text.confirm
	-- Kartu pilihan tidak boleh ada yang "terpilih duluan": keduanya permukaan yang sama.
	self._confirmButton.BackgroundColor3 = if choice then Tokens.Color.PanelRaised else Tokens.Color.Accent
	self._confirmButton.BackgroundTransparency = if choice then Tokens.Transparency.PanelRaised else 0
	self._confirmButton.TextColor3 = if choice then Tokens.Color.Text else Tokens.Color.AccentText
	for _, b in { self._cancelButton, self._confirmButton } do
		local edge = b:FindFirstChild("Edge")
		if edge and edge:IsA("UIStroke") then
			edge.Enabled = choice
		end
		local corner = b:FindFirstChildOfClass("UICorner")
		if corner then
			corner.CornerRadius = if choice then Tokens.Radius.Large else Tokens.Radius.Pill
		end
	end

	-- Mode pilihan tidak memakai selubung hitam (permintaan 19 Sep 2026): yang diburamkan dunia
	-- 3D lewat Lighting. UI di belakang TIDAK bisa diburamkan di Roblox -- tidak ada backdrop
	-- blur untuk GuiObject. Mode isian nama tetap memakai selubung: ia dialog kecil di ATAS
	-- panel, bukan layar penuh, jadi tanpa selubung batasnya hilang.
	self.instance.BackgroundTransparency = if choice then 1 else Tokens.Transparency.Overlay
	self:_setBlur(choice)

	self.instance.Visible = true
	if not choice then
		self._box:CaptureFocus()
	end
end

function NamePrompt._setBlur(self: NamePrompt, on: boolean)
	if on then
		if self._blur == nil then
			local blur = Instance.new("BlurEffect")
			blur.Name = "NamePromptBlur"
			blur.Size = BLUR_SIZE
			blur.Parent = Lighting
			self._blur = blur
		end
		return
	end
	if self._blur ~= nil then
		self._blur:Destroy()
		self._blur = nil
	end
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
	self:_setBlur(false)
	local onClose = self._props.onClose
	if onClose then
		onClose()
	end
end

function NamePrompt.destroy(self: NamePrompt)
	self:_setBlur(false)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return NamePrompt
