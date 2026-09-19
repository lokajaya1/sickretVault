--!strict
-- Dialog "Item Removal" (ikon tong sampah di bar aksi, pola Catalog Avatar Creator).
-- BENTUKNYA: kartu avatar itu SENDIRI yang jadi panel -- viewport memenuhi seluruh kartu, dan
-- judul, daftar centang, serta tombol Remove melayang DI ATASNYA. Sama seperti CAC.
--   local dialog = RemoveDialog.new({
--   	parent = gui, zIndex = Tokens.ZIndex.Popup + 5,
--   	onRemove = function(kinds) end,  -- { "hair", "face" } -> SATU intent removeKind
--   	preview = function(kinds, viewport) ... return cancel end,  -- isi viewport-nya (App)
--   	onClose = function() end,
--   })
--   dialog:open({ hair = 1, accessories = 3 })   -- mode daftar centang (Item Removal)
--   dialog:openConfirm("Reset to Roblox Avatar?", fn)  -- mode tanya: avatar + No / Yes
--   dialog:isOpen()   dialog:close()   dialog:destroy()
-- DUA MODE dalam satu komponen karena kartunya IDENTIK -- avatar, ruang 3D, sudut, kabut, tombol
-- tutup. Yang berbeda cuma isi kakinya. Menyalinnya jadi komponen kedua berarti dua tempat yang
-- harus ikut berubah setiap kali kartunya disetel.
-- Dialog TIDAK memanggil controller sendiri: App yang mengirim intent (biar toast & busy satu jalur),
-- dan App juga yang memutuskan avatar mana yang dipasang di viewport -- komponen UI tidak boleh
-- ikut memutuskan apa itu "rambut".

local Tokens = require(script.Parent.Parent.Theme.Tokens)
local SideRail = require(script.Parent.SideRail)

local CARD_W = 420
local ROW_H = 32
local ROW_GAP = 2
local HEAD_H = 30
local FOOT_H = 40
local LIST_W = 212 -- daftar menutupi kira-kira separuh kartu; sisanya avatar
-- Latar BAWAAN kartu saat pemain tidak memakai item Background: ruang abu GELAP dengan kolam
-- cahaya di lantai -- meniru latar editor avatar bawaan Roblox (rujukan gambar dari user,
-- 19 Sep 2026), bukan studio putih. Kita tidak punya scene 3D-nya, jadi ia ditiru dengan dua
-- lapis datar: gradasi dinding + satu bulatan cahaya di bawah kaki avatar. Begitu item Background
-- dipakai, gambarnya menimpa keduanya (OutfitPreview yang memasangnya, tepat di bawah viewport).
local BACKDROP_BOTTOM = Color3.fromRGB(38, 38, 42)
local BACKDROP_GLOW = Color3.fromRGB(150, 150, 158)
local PAD = Tokens.Space.M

-- Urutan dan tulisannya PERSIS Catalog Avatar Creator, termasuk dua baris terakhir. Makeup TIDAK
-- punya baris sendiri (CAC tidak punya): ia ikut "Face", tempatnya memang di wajah.
-- Gear & Bugged Items ada demi kemiripan, tapi di game ini akan SELALU redup: gear sudah disaring
-- dari katalog sejak #17b, dan "bugged items" adalah penambal masalah CAC yang tidak kita punya.
-- Keduanya tidak punya kategori di OutfitState.KINDS, jadi jumlahnya tidak pernah terisi -> tidak
-- bisa dicentang -> tidak mungkin terkirim ke server.
local ROWS: { { kind: string, label: string } } = {
	{ kind = "all", label = "All" },
	{ kind = "accessories", label = "Accessories" },
	{ kind = "hair", label = "Hair" },
	{ kind = "classic", label = "Classic Clothing" },
	{ kind = "layered", label = "Layered Clothing" },
	{ kind = "face", label = "Face" },
	{ kind = "bodyParts", label = "Body Parts" },
	{ kind = "animations", label = "Animations" },
	{ kind = "gear", label = "Gear" },
	{ kind = "bugged", label = "Bugged Items" },
}

local CARD_H = PAD + HEAD_H + PAD + #ROWS * (ROW_H + ROW_GAP) - ROW_GAP + PAD + FOOT_H + PAD

export type Props = {
	parent: Instance,
	zIndex: number?,
	onRemove: ({ string }) -> (),
	-- kinds = kategori yang dicentang; confirmMode = kartu sedang dipakai mode tanya (di situ
	-- yang harus tampil BUKAN look sekarang, melainkan avatar asli akun).
	preview: ((kinds: { string }, viewport: ViewportFrame, confirmMode: boolean) -> (() -> ())?)?,
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
		_card: TextButton,
		_confirm: TextButton,
		_scrim: Frame,
		_title: TextLabel,
		_divider: Frame,
		_list: Frame,
		_noButton: TextButton,
		_yesButton: TextButton,
		_onYes: (() -> ())?,
		_viewport: ViewportFrame,
		_cancelPreview: (() -> ())?,
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

	-- Selubung selayar penuh TANPA warna: ia cuma menangkap ketukan di luar kartu (= tutup).
	local root: TextButton = make("TextButton", {
		Name = "RemoveDialog",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = Z,
		Parent = props.parent,
	})

	-- KARTU = AVATAR. Viewport memenuhi kartu; semua tulisan melayang di atasnya. ClipsDescendants
	-- supaya avatar ikut membulat mengikuti sudut kartu.
	local card: TextButton = make("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = BACKDROP_BOTTOM,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.92, 0, 0.9, 0),
		ZIndex = Z + 1,
		Parent = root,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Large }),
		make("UISizeConstraint", { MaxSize = Vector2.new(CARD_W, CARD_H) }),
		-- Garis tepi emas setipis rambut: yang memisahkan kartu dari dunia di belakangnya, bukan
		-- bayangan atau bingkai tebal.
		make("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Tokens.Color.Stroke,
			Transparency = Tokens.Transparency.Stroke,
		}),
	})

	-- Dunia avatar MEMENUHI kartu (itu isi panel ini), dan tulisan melayang di atasnya. Supaya
	-- avatar tidak berdiri di belakang daftar, KAMERA-nya yang digeser ke kanan -- App memanggil
	-- `addPan` sesuai lebar daftar. Jadi yang bergeser gambarnya, bukan kotaknya.
	-- ClipsDescendants milik kartu memotong PERSEGI, bukan mengikuti sudut membulatnya (quirk
	-- Roblox). Jadi anak yang memenuhi kartu WAJIB punya UICorner sendiri; tanpa itu sudut lancip
	-- viewport menutupi lengkung kartu dan panelnya terlihat kotak lagi (19 Sep 2026).
	-- Ruangnya BUKAN gambar datar: App menaruh part ke dalam WorldModel viewport ini (lihat
	-- `scene` di OutfitPreview), jadi avatar benar-benar berdiri di dalam ruang itu dan balok-balok
	-- di belakangnya ikut berperspektif. Warna kartu di bawah cuma cadangan kalau latar gagal.
	-- Ambient & arah cahaya disetel di sini: tanpa itu isi ViewportFrame rata tanpa bayangan sisi.
	local viewport: ViewportFrame = make("ViewportFrame", {
		Name = "Preview",
		BackgroundColor3 = BACKDROP_BOTTOM,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Ambient = BACKDROP_GLOW,
		LightColor = Color3.fromRGB(255, 252, 245),
		LightDirection = Vector3.new(-0.4, -1, -0.6),
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z + 1,
		Parent = card,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Large }) })

	-- Kabut dari tepi kiri: yang membuat tulisan terbaca di atas gambar tanpa satu pun kotak gelap.
	-- Pekat di kiri (di bawah daftar) lalu hilang sebelum sampai avatar. HANYA untuk mode daftar --
	-- di mode tanya tidak ada daftar yang perlu dibacakan, jadi ia cuma menggelapkan avatar.
	local scrim: Frame = make("Frame", {
		Name = "Scrim",
		BackgroundColor3 = Tokens.Color.Background,
		BorderSizePixel = 0,
		Size = UDim2.new(0, LIST_W + PAD * 3, 1, 0),
		ZIndex = Z + 2,
		Parent = card,
	}, {
		make("UICorner", { CornerRadius = Tokens.Radius.Large }),
		make("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2),
				NumberSequenceKeypoint.new(0.62, 0.45),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})

	local title: TextLabel = make("TextLabel", {
		Name = "Title",
		Text = "Item Removal",
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = Tokens.Color.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(PAD, PAD),
		Size = UDim2.new(1, -PAD * 2, 0, HEAD_H),
		ZIndex = Z + 4,
		Parent = card,
	})
	local closeButton: TextButton = make("TextButton", {
		Name = "Close",
		Text = "",
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(26, 26),
		ZIndex = Z + 3,
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
			ZIndex = Z + 3,
			Parent = closeButton,
		})
	)

	local list: Frame = make("Frame", {
		Name = "List",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(PAD, PAD + HEAD_H + PAD),
		Size = UDim2.new(0, LIST_W, 0, #ROWS * (ROW_H + ROW_GAP) - ROW_GAP),
		ZIndex = Z + 2,
		Parent = card,
	}, { make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, ROW_GAP) }) })

	local self: RemoveDialog = setmetatable({
		instance = root,
		_props = props,
		_rows = {},
		_counts = {},
		_checked = {},
		_card = card,
		_confirm = nil :: any,
		_scrim = scrim,
		_title = title,
		_divider = nil :: any,
		_list = list,
		_noButton = nil :: any,
		_yesButton = nil :: any,
		_onYes = nil,
		_viewport = viewport,
		_cancelPreview = nil,
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
		-- Baris TANPA kotak: yang menandai baris cuma kotak centang dan tulisannya sendiri. Kabut
		-- di belakangnya yang menjaga keterbacaan, jadi daftar ini terbaca sebagai teks di atas
		-- gambar -- bukan sepuluh tombol bertumpuk.
		local button: TextButton = make("TextButton", {
			Name = row.kind,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = Tokens.Color.Accent,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, ROW_H),
			ZIndex = Z + 3,
			Parent = list,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Medium }) })

		-- Kotak centang digambar, bukan karakter: font kita tidak punya glyph centang (temuan
		-- 19 Sep 2026, silang U+2715 keluar sebagai kotak kosong).
		local box: Frame = make("Frame", {
			Name = "Box",
			BackgroundColor3 = Tokens.Color.Background,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, Tokens.Space.S, 0.5, 0),
			Size = UDim2.fromOffset(16, 16),
			ZIndex = Z + 3,
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
			Size = UDim2.fromOffset(9, 9),
			Visible = false,
			ZIndex = Z + 4,
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
			Position = UDim2.new(0, Tokens.Space.S * 2 + 16, 0.5, 0),
			Size = UDim2.new(1, -(Tokens.Space.S * 3 + 16), 1, 0),
			ZIndex = Z + 3,
			Parent = button,
		})

		self._rows[row.kind] = { button = button, box = box, tick = tick, label = label, text = row.label }
		table.insert(
			conns,
			button.Activated:Connect(function()
				-- Kategori kosong tidak bisa dicentang: tidak ada yang akan terbuang.
				if (self._counts[row.kind] or 0) == 0 then
					return
				end
				local on = not self._checked[row.kind]
				-- "All" dan kategori lain saling meniadakan: mencentang All berarti membuang
				-- semuanya, jadi centang lain tidak menambah apa pun.
				if row.kind == "all" then
					self._checked = {}
				else
					self._checked.all = nil
				end
				self._checked[row.kind] = on
				self:_refresh()
				self:_preview()
			end)
		)
	end

	-- Garis rambut di atas tombol: memisahkan "memilih" dari "melakukan" tanpa menambah kotak.
	-- Ia memudar ke kanan mengikuti kabut, jadi tidak pernah memotong gambar avatar.
	local divider: Frame = make("Frame", {
		Name = "Divider",
		BackgroundColor3 = Tokens.Color.Stroke,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, PAD, 1, -(PAD * 2 + FOOT_H)),
		Size = UDim2.new(0, LIST_W, 0, 1),
		ZIndex = Z + 3,
		Parent = card,
	}, {
		make("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})

	-- Warna bahaya, seperti CAC: tombol ini membuang, bukan menyimpan.
	local confirm: TextButton = make("TextButton", {
		Name = "Confirm",
		Text = "Remove",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Button,
		TextColor3 = Tokens.Color.Text,
		BackgroundColor3 = Tokens.Color.Danger,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, PAD, 1, -PAD),
		Size = UDim2.new(0, LIST_W, 0, FOOT_H),
		ZIndex = Z + 3,
		Parent = card,
	}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })

	-- Mode tanya: dua tombol di kaki kartu. Warnanya mengikuti CAC (No merah, Yes hijau) walau
	-- lazimnya yang merah adalah tindakan yang merusak -- di sini yang merusak justru "Yes".
	-- Kalau nanti lebih suka merah di sisi Yes, tinggal tukar dua warna ini.
	local function footButton(name: string, text: string, color: Color3, xScale: number): TextButton
		return make("TextButton", {
			Name = name,
			Text = text,
			FontFace = Tokens.Font.Bold,
			TextSize = Tokens.TextSize.Button,
			TextColor3 = Tokens.Color.AccentText,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			Visible = false,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(xScale, 0, 1, -PAD),
			Size = UDim2.new(0.38, 0, 0, FOOT_H),
			ZIndex = Z + 3,
			Parent = card,
		}, { make("UICorner", { CornerRadius = Tokens.Radius.Pill }) })
	end
	local noButton = footButton("No", "No", Tokens.Color.Danger, 0.29)
	local yesButton = footButton("Yes", "Yes", Color3.fromRGB(124, 214, 124), 0.71)

	self._confirm = confirm
	self._divider = divider
	self._noButton = noButton
	self._yesButton = yesButton
	table.insert(
		conns,
		noButton.Activated:Connect(function()
			self:close()
		end)
	)
	table.insert(
		conns,
		yesButton.Activated:Connect(function()
			local onYes = self._onYes
			self:close()
			if onYes ~= nil then
				onYes()
			end
		end)
	)
	table.insert(
		conns,
		confirm.Activated:Connect(function()
			local kinds = self:_checkedKinds()
			if #kinds == 0 then
				return
			end
			self:close()
			self._props.onRemove(kinds)
		end)
	)
	table.insert(
		conns,
		card:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_layout()
		end)
	)
	self._conns = conns
	self:_layout()
	return self
end

-- Kartu boleh menyempit (ponsel mendatar: tinggi layar ~390 px, kartu ~350 px) sementara isinya
-- dihitung dalam PIKSEL. Tanpa penataan ulang, sepuluh baris + kepala + tombol butuh ~444 px dan
-- yang terjadi bukan "mengecil" melainkan TUMPANG TINDIH: tombol Remove duduk di atas baris Face
-- (terlihat di iPhone 13, 19 Sep 2026). Jadi tinggi baris dihitung dari ruang yang BENAR-BENAR ada,
-- dan tulisannya ikut mengecil kalau barisnya jadi pendek.
function RemoveDialog._layout(self: RemoveDialog)
	local size = self._card.AbsoluteSize
	if size.Y <= 0 then
		return
	end
	local pad = if size.Y < 380 then Tokens.Space.S else PAD
	local headH = if size.Y < 380 then 24 else HEAD_H
	local footH = if size.Y < 380 then 32 else FOOT_H
	local listTop = pad + headH + pad
	local avail = size.Y - listTop - footH - pad * 2
	local rowH = math.clamp(math.floor((avail - (#ROWS - 1) * ROW_GAP) / #ROWS), 16, ROW_H)
	local listW = math.min(LIST_W, math.floor(size.X * 0.56))
	local small = rowH < 26

	self._title.Position = UDim2.fromOffset(pad, pad)
	self._title.Size = UDim2.new(1, -pad * 2, 0, headH)
	self._title.TextSize = if small then Tokens.TextSize.Button else Tokens.TextSize.Title

	self._list.Position = UDim2.fromOffset(pad, listTop)
	self._list.Size = UDim2.new(0, listW, 0, #ROWS * (rowH + ROW_GAP) - ROW_GAP)
	for _, row in self._rows do
		row.button.Size = UDim2.new(1, 0, 0, rowH)
		row.label.TextSize = if small then Tokens.TextSize.Caption else Tokens.TextSize.Body
		local box = if small then 13 else 16
		row.box.Size = UDim2.fromOffset(box, box)
		row.box.Position = UDim2.new(0, Tokens.Space.S, 0.5, 0)
		row.tick.Size = UDim2.fromOffset(box - 7, box - 7)
		row.label.Position = UDim2.new(0, Tokens.Space.S * 2 + box, 0.5, 0)
		row.label.Size = UDim2.new(1, -(Tokens.Space.S * 3 + box), 1, 0)
	end

	self._scrim.Size = UDim2.new(0, listW + pad * 2, 1, 0)
	self._divider.Position = UDim2.new(0, pad, 1, -(pad * 2 + footH))
	self._divider.Size = UDim2.new(0, listW, 0, 1)
	self._confirm.Position = UDim2.new(0, pad, 1, -pad)
	self._confirm.Size = UDim2.new(0, listW, 0, footH)
	self._confirm.TextSize = if small then Tokens.TextSize.Body else Tokens.TextSize.Button
	for _, button in { self._noButton, self._yesButton } do
		button.Position = UDim2.new(if button == self._noButton then 0.29 else 0.71, 0, 1, -pad)
		button.Size = UDim2.new(0.38, 0, 0, footH)
		button.TextSize = if small then Tokens.TextSize.Body else Tokens.TextSize.Button
	end
end

function RemoveDialog._checkedKinds(self: RemoveDialog): { string }
	local kinds = {}
	for _, row in ROWS do
		if self._checked[row.kind] then
			table.insert(kinds, row.kind)
		end
	end
	return kinds
end

-- Isi viewport dibangun ulang tiap centang berubah: tanpa centang = avatar apa adanya, dengan
-- centang = avatar SETELAH kategori itu dibuang. Yang membangunnya App (lihat props.preview).
function RemoveDialog._preview(self: RemoveDialog)
	local preview = self._props.preview
	if preview == nil then
		return
	end
	if self._cancelPreview ~= nil then
		pcall(self._cancelPreview)
		self._cancelPreview = nil
	end
	if not self.instance.Visible then
		return
	end
	self._cancelPreview = preview(self:_checkedKinds(), self._viewport, self._onYes ~= nil)
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
		-- Kategori kosong dibiarkan terlihat (daftar CAC selalu sepuluh baris) tapi diredupkan.
		row.label.Text = if count > 0 then ("%s  ·  %d"):format(row.text, count) else row.text
		row.label.TextColor3 = if count == 0
			then Tokens.Color.TextMuted
			elseif on then Tokens.Color.Accent
			else Tokens.Color.Text
		-- Baris tercentang diberi sapuan emas tipis; sisanya bening.
		row.button.BackgroundTransparency = if on then 0.88 else 1
		row.box.Visible = count > 0
	end
	-- Tombol mati sampai ada yang dicentang: warnanya pudar DAN tulisannya ikut redup, supaya
	-- tidak terbaca sebagai tombol siap tekan yang kebetulan diam.
	self._confirm.BackgroundTransparency = if selected > 0 then 0 else 0.6
	self._confirm.TextTransparency = if selected > 0 then 0 else 0.45
	self._confirm.AutoButtonColor = selected > 0
end

-- Menyalakan bagian kaki yang dipakai satu mode dan mematikan milik mode lain. Judulnya ikut:
-- daftar centang dibaca dari kiri ke bawah, sedangkan pertanyaan berdiri di tengah kartu.
function RemoveDialog._setMode(self: RemoveDialog, confirmMode: boolean)
	self._scrim.Visible = not confirmMode
	self._list.Visible = not confirmMode
	self._divider.Visible = not confirmMode
	self._confirm.Visible = not confirmMode
	self._noButton.Visible = confirmMode
	self._yesButton.Visible = confirmMode
	self._title.TextXAlignment = if confirmMode then Enum.TextXAlignment.Center else Enum.TextXAlignment.Left
end

-- counts = { [kind] = berapa item yang akan terbuang }, dihitung App dari state sekarang.
function RemoveDialog.open(self: RemoveDialog, counts: { [string]: number })
	self._counts = counts
	self._checked = {}
	self._onYes = nil
	self._title.Text = "Item Removal"
	self:_setMode(false)
	self:_refresh()
	self.instance.Visible = true
	self:_layout()
	self:_preview()
end

-- Mode tanya: kartu yang sama, tanpa daftar. Dipakai "Reset to Roblox Avatar?" -- tindakan yang
-- membuang SELURUH hasil coba-coba, jadi ia pantas dilihat dulu bersama avatarnya.
function RemoveDialog.openConfirm(self: RemoveDialog, title: string, onYes: () -> ())
	self._counts = {}
	self._checked = {}
	self._onYes = onYes
	self._title.Text = title
	self:_setMode(true)
	self.instance.Visible = true
	self:_layout()
	self:_preview()
end

function RemoveDialog.isOpen(self: RemoveDialog): boolean
	return self.instance.Visible
end

function RemoveDialog.close(self: RemoveDialog)
	if not self.instance.Visible then
		return
	end
	self.instance.Visible = false
	if self._cancelPreview ~= nil then
		pcall(self._cancelPreview)
		self._cancelPreview = nil
	end
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
	if self._cancelPreview ~= nil then
		pcall(self._cancelPreview)
		self._cancelPreview = nil
	end
	self.instance:Destroy()
end

return RemoveDialog
