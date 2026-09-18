--!strict
-- Kartu outfit tersimpan (grid Saved Outfits, pola CAC): render avatar 3D + nama + bintang favorit.
-- Tap kartu -> onActivated (panel lalu memanggil setArmed(true)) -> overlay WEAR / VIEW.
-- Tap bagian kosong overlay -> onDismiss. Ukuran kartu diatur UIGridLayout induknya.
--   local card = OutfitCard.new({
--   	outfit = summary, previews = outfitPreview,
--   	onActivated = fn, onWear = fn, onView = fn, onFavorite = fn, onDismiss = fn,
--   })
--   card.instance.Parent = grid
--   card:setArmed(true)   card:setFavorite(true)   card:setBusy("Wearing…")   card:destroy()
--   card:setSelectMode(true)  card:setSelected(true)   -- mode "Select Outfits" (pilih banyak)
-- Mode pilih: tap kartu = centang/hapus centang (onToggleSelect), overlay & bintang & ikon hapus tidak muncul.
-- Render 3D gagal -> otomatis menampilkan thumbnail item (maks 4) sebagai cadangan.
-- Pita MAKEUP: preview 3D TIDAK bisa menampilkan makeup (Decal di Head, di luar
-- HumanoidDescription, dan model preview dibuat di client) -> kartu mengabarkannya lewat pita.
-- Bintang: selalu tampil bila favorit; selain itu muncul saat hover (PC) atau kartu armed (HP).
-- Hapus TIDAK ada di kartu: lewat halaman detail (VIEW -> Delete) atau mode "Select Outfits".

local Tokens = require(script.Parent.Parent.Theme.Tokens)

local NAME_H = 28
local BADGE_H = 20
local STAR_SIZE = 28
local ACTION_H = 34
local CHECK_SIZE = 26
local CHECK_ON = "✓"
local STAR_ON = "★"
local STAR_OFF = "☆"

export type Outfit = {
	id: number,
	name: string,
	updatedAt: number,
	favorite: boolean,
	count: number,
	makeup: number?, -- berapa makeup di look ini (tidak terlihat di preview 3D)
	thumbs: { number },
	outfit: any,
}

type Callback = ((Outfit) -> ())?

export type Props = {
	outfit: Outfit,
	previews: any, -- OutfitPreview
	layoutOrder: number?,
	onToggleSelect: Callback, -- tap kartu saat mode pilih
	onActivated: Callback, -- tap kartu (belum armed)
	onWear: Callback,
	onView: Callback,
	onFavorite: Callback, -- tombol bintang
	onDismiss: Callback, -- tap bagian kosong overlay
}

local OutfitCard = {}
OutfitCard.__index = OutfitCard

export type OutfitCard = typeof(setmetatable(
	{} :: {
		instance: TextButton,
		outfit: Outfit,
		_viewport: ViewportFrame,
		_fallback: Frame,
		_name: TextLabel,
		_makeup: TextLabel,
		_star: TextButton,
		_check: TextLabel,
		_stroke: UIStroke,
		_overlay: TextButton,
		_busy: TextLabel,
		_preview: any, -- OutfitPreview.Handle
		_hover: boolean,
		_armed: boolean,
		_select: boolean,
		_selected: boolean,
		_conns: { RBXScriptConnection },
	},
	OutfitCard
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

local function actionButton(text: string, order: number, parent: Instance): TextButton
	return make("TextButton", {
		Name = text,
		Text = text,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Button,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Accent,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, ACTION_H),
		ZIndex = Tokens.ZIndex.Panel + 6,
		Parent = parent,
	}, { corner(Tokens.Radius.Pill) })
end

function OutfitCard.new(props: Props): OutfitCard
	local Z = Tokens.ZIndex.Panel + 5
	local outfit = props.outfit
	local pad = Tokens.Space.S

	local root: TextButton = make("TextButton", {
		Name = "Outfit_" .. tostring(outfit.id),
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.PanelRaised,
		BackgroundTransparency = Tokens.Transparency.PanelRaised,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = props.layoutOrder or 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z,
	}, { corner(Tokens.Radius.Medium) })

	-- Garis tepi saat kartu tercentang (mode pilih)
	local stroke: UIStroke = make("UIStroke", {
		Color = Tokens.Color.Accent,
		Thickness = 0,
		Transparency = 0,
		Parent = root,
	})

	-- Render avatar 3D
	local viewport: ViewportFrame = make("ViewportFrame", {
		Name = "Preview",
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0,
		Ambient = Color3.fromRGB(120, 120, 134),
		LightColor = Color3.fromRGB(236, 236, 245),
		LightDirection = Vector3.new(-0.4, -1, -0.65),
		Size = UDim2.new(1, 0, 1, -NAME_H),
		ZIndex = Z,
		Parent = root,
	})

	-- Cadangan: thumbnail item 2x2 (dipakai bila render 3D gagal)
	local fallback: Frame = make("Frame", {
		Name = "Fallback",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(1, -pad * 4, 1, -NAME_H - pad * 4),
		Visible = false,
		ZIndex = Z,
		Parent = root,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.fromScale(0.5, 0.5),
			CellPadding = UDim2.new(),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for i, assetId in outfit.thumbs do
		make("ImageLabel", {
			Name = "Thumb" .. i,
			BackgroundTransparency = 1,
			Image = ("rbxthumb://type=Asset&id=%d&w=150&h=150"):format(assetId),
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = i,
			ZIndex = Z,
			Parent = fallback,
		})
	end

	local nameLabel: TextLabel = make("TextLabel", {
		Name = "OutfitName",
		Text = outfit.name,
		BackgroundTransparency = 1,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, -pad * 2, 0, NAME_H),
		ZIndex = Z,
		Parent = root,
	}, { make("UIPadding", { PaddingLeft = UDim.new(0, pad), PaddingRight = UDim.new(0, pad) }) })

	-- Pita MAKEUP (kiri bawah, di atas nama): satu-satunya petunjuk bahwa look ini bermakeup,
	-- karena preview 3D-nya tidak bisa menampilkannya.
	local makeupCount = if type(outfit.makeup) == "number" then outfit.makeup else 0
	local makeupBadge: TextLabel = make("TextLabel", {
		Name = "MakeupBadge",
		Text = if makeupCount > 1 then ("MAKEUP x%d"):format(makeupCount) else "MAKEUP",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Caption,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Accent,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.X,
		Visible = makeupCount > 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, pad, 1, -NAME_H),
		Size = UDim2.fromOffset(0, BADGE_H),
		ZIndex = Z + 1,
		Parent = root,
	}, {
		corner(Tokens.Radius.Pill),
		make("UIPadding", { PaddingLeft = UDim.new(0, pad), PaddingRight = UDim.new(0, pad) }),
	})

	local star: TextButton = make("TextButton", {
		Name = "Favorite",
		Text = if outfit.favorite then STAR_ON else STAR_OFF,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Title,
		TextColor3 = if outfit.favorite then Tokens.Color.Warning else Tokens.Color.Text,
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Visible = outfit.favorite,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -pad, 0, pad),
		Size = UDim2.fromOffset(STAR_SIZE, STAR_SIZE),
		ZIndex = Z + 1,
		Parent = root,
	}, { corner(Tokens.Radius.Pill) })

	-- Centang mode pilih (label, bukan tombol: tap tetap mengenai kartu)
	local check: TextLabel = make("TextLabel", {
		Name = "Check",
		Text = "",
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.AccentText,
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Visible = false,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -pad, 0, pad),
		Size = UDim2.fromOffset(CHECK_SIZE, CHECK_SIZE),
		ZIndex = Z + 2,
		Parent = root,
	}, { corner(Tokens.Radius.Pill) })

	-- Overlay WEAR / VIEW (muncul saat kartu di-tap)
	local overlay: TextButton = make("TextButton", {
		Name = "Overlay",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = Tokens.Transparency.Overlay,
		BorderSizePixel = 0,
		Visible = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z + 2,
		Parent = root,
	}, {
		corner(Tokens.Radius.Medium),
		make("UIPadding", {
			PaddingLeft = UDim.new(0, pad * 2),
			PaddingRight = UDim.new(0, pad * 2),
		}),
	})
	local actions: Frame = make("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, ACTION_H * 2 + pad),
		ZIndex = Tokens.ZIndex.Panel + 6,
		Parent = overlay,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, pad),
		}),
	})
	local wear = actionButton("WEAR", 1, actions)
	local view = actionButton("VIEW", 2, actions)
	view.BackgroundColor3 = Tokens.Color.PanelRaised
	view.BackgroundTransparency = 0
	view.TextColor3 = Tokens.Color.Text

	local busy: TextLabel = make("TextLabel", {
		Name = "Busy",
		Text = "",
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = Tokens.Transparency.Overlay,
		FontFace = Tokens.Font.Bold,
		TextSize = Tokens.TextSize.Body,
		TextColor3 = Tokens.Color.Text,
		Visible = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = Z + 3,
		Parent = root,
	}, { corner(Tokens.Radius.Medium) })

	local self: OutfitCard = setmetatable({
		instance = root,
		outfit = outfit,
		_viewport = viewport,
		_fallback = fallback,
		_name = nameLabel,
		_makeup = makeupBadge,
		_star = star,
		_check = check,
		_stroke = stroke,
		_overlay = overlay,
		_busy = busy,
		_preview = nil,
		_hover = false,
		_armed = false,
		_select = false,
		_selected = false,
		_conns = {},
	}, OutfitCard)

	local function fire(fn: Callback)
		if fn then
			fn(outfit)
		end
	end

	self._conns = {
		root.Activated:Connect(function()
			if self._select then
				fire(props.onToggleSelect)
			elseif not self._armed then
				fire(props.onActivated)
			end
		end),
		root.MouseEnter:Connect(function()
			self._hover = true
			self:_refreshStar()
		end),
		root.MouseLeave:Connect(function()
			self._hover = false
			self:_refreshStar()
		end),
		star.Activated:Connect(function()
			fire(props.onFavorite)
		end),
		wear.Activated:Connect(function()
			fire(props.onWear)
		end),
		view.Activated:Connect(function()
			fire(props.onView)
		end),
		overlay.Activated:Connect(function()
			fire(props.onDismiss)
		end),
	}

	-- Render avatar; gagal -> thumbnail item
	self._preview = props.previews:mount(
		viewport,
		("%d:%d"):format(outfit.id, outfit.updatedAt),
		outfit.outfit,
		function()
			viewport.Visible = false
			fallback.Visible = true
		end
	)
	return self
end

function OutfitCard._refreshStar(self: OutfitCard)
	local shown = (self._hover or self._armed) and not self._select
	self._star.Visible = (self.outfit.favorite or shown) and not self._select
end

function OutfitCard.setFavorite(self: OutfitCard, favorite: boolean)
	self.outfit.favorite = favorite
	self._star.Text = if favorite then STAR_ON else STAR_OFF
	self._star.TextColor3 = if favorite then Tokens.Color.Warning else Tokens.Color.Text
	self:_refreshStar()
end

function OutfitCard.setArmed(self: OutfitCard, armed: boolean)
	self._armed = armed and not self._select
	self._overlay.Visible = self._armed
	self:_refreshStar()
end

-- Mode "Select Outfits": kartu jadi kotak centang, aksi lain dimatikan.
function OutfitCard.setSelectMode(self: OutfitCard, on: boolean)
	if self._select == on then
		return
	end
	self._select = on
	if on then
		self:setArmed(false)
	else
		self:setSelected(false)
	end
	self._check.Visible = on
	self:_refreshStar()
end

function OutfitCard.setSelected(self: OutfitCard, selected: boolean)
	self._selected = selected
	self._check.Text = if selected then CHECK_ON else ""
	self._check.BackgroundColor3 = if selected then Tokens.Color.Accent else Tokens.Color.Background
	self._check.BackgroundTransparency = if selected then 0 else 0.25
	self._stroke.Thickness = if selected then 2 else 0
end

function OutfitCard.isSelected(self: OutfitCard): boolean
	return self._selected
end

function OutfitCard.isArmed(self: OutfitCard): boolean
	return self._armed
end

-- text nil -> selesai.
function OutfitCard.setBusy(self: OutfitCard, text: string?)
	self._busy.Text = text or ""
	self._busy.Visible = text ~= nil
end

function OutfitCard.setName(self: OutfitCard, name: string)
	self.outfit.name = name
	self._name.Text = name
end

-- Dipakai setelah slot ditimpa (isi look berubah tanpa kartu dibangun ulang).
function OutfitCard.setMakeup(self: OutfitCard, count: number)
	self.outfit.makeup = count
	self._makeup.Text = if count > 1 then ("MAKEUP x%d"):format(count) else "MAKEUP"
	self._makeup.Visible = count > 0
end

function OutfitCard.destroy(self: OutfitCard)
	if self._preview then
		self._preview.cancel()
		self._preview = nil
	end
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self.instance:Destroy()
end

return OutfitCard
