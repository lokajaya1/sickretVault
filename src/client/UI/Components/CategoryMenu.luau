--!strict
-- Halaman MENU KATEGORI katalog: mozaik kartu besar (bento) di dalam panel katalog.
-- Susunan & isi grup dari Shared/Config/CatalogMenu; ukuran unit dari Shared/Util/PanelLayout.
--   local menu = CategoryMenu.new({ parent = panelFrame, onGroup = function(group) ... end })
--   menu:setArea(x, y, w, h)  -- kotak isi panel (piksel, relatif panel); dipanggil ulang saat layar berubah
--   menu:setVisible(true)     menu:destroy()
-- Kartu: label HURUF BESAR di kiri atas + watermark label samar di kanan bawah (ikon gambar menyusul
-- di PR #17c). Warna dari Tokens (PanelRaised -> Accent sesuai group.tone), BUKAN pelangi CAC.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CatalogMenu = require(Shared.Config.CatalogMenu)
local PanelLayout = require(Shared.Util.PanelLayout)
local Tokens = require(script.Parent.Parent.Theme.Tokens)

local TONE_MIX = 0.35 -- seberapa jauh warna kartu bergeser ke Accent (0 = polos)
local SOON_SECONDS = 1.2 -- lama label "SOON" ditampilkan (pola tombol Stores)
local LABEL_PAD = 10
local WATERMARK_TRANSPARENCY = 0.88

export type Props = {
	parent: Instance,
	onGroup: (group: CatalogMenu.Group) -> (),
}

local CategoryMenu = {}
CategoryMenu.__index = CategoryMenu

export type CategoryMenu = typeof(setmetatable(
	{} :: {
		instance: ScrollingFrame,
		_props: Props,
		_cards: { [string]: TextButton },
		_labels: { [string]: TextLabel },
		_marks: { [string]: TextLabel },
		_conns: { RBXScriptConnection },
	},
	CategoryMenu
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

-- Ukuran teks label mengikuti besar kartu (kartu kecil di HP tidak boleh kepotong).
local function labelSize(unitH: number): number
	if unitH >= 120 then
		return Tokens.TextSize.Title
	elseif unitH >= 80 then
		return Tokens.TextSize.Button
	end
	return Tokens.TextSize.Body
end

function CategoryMenu.new(props: Props): CategoryMenu
	local root: ScrollingFrame = make("ScrollingFrame", {
		Name = "CategoryMenu",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ZIndex = Tokens.ZIndex.Panel,
		Parent = props.parent,
	})

	local self: CategoryMenu
	local cards: { [string]: TextButton } = {}
	local labels: { [string]: TextLabel } = {}
	local marks: { [string]: TextLabel } = {}
	local conns: { RBXScriptConnection } = {}

	for i, group in CatalogMenu.list do
		local card: TextButton = make("TextButton", {
			Name = "Group_" .. group.id,
			Text = "",
			AutoButtonColor = true,
			BackgroundColor3 = Tokens.Color.PanelRaised:Lerp(Tokens.Color.Accent, group.tone * TONE_MIX),
			BackgroundTransparency = Tokens.Transparency.PanelRaised,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			LayoutOrder = i,
			ZIndex = Tokens.ZIndex.Panel,
			Parent = root,
		}, {
			make("UICorner", { CornerRadius = Tokens.Radius.Large }),
			make("UIStroke", {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Tokens.Color.Stroke,
				Transparency = Tokens.Transparency.Stroke,
			}),
		})

		-- Watermark: label yang sama, besar & samar di pojok kanan bawah (pengganti ikon sampai #17c).
		marks[group.id] = make("TextLabel", {
			Name = "Watermark",
			Text = group.label,
			FontFace = Tokens.Font.Bold,
			TextSize = Tokens.TextSize.Title,
			TextColor3 = Tokens.Color.Text,
			TextTransparency = WATERMARK_TRANSPARENCY,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -LABEL_PAD, 1, 0),
			Size = UDim2.new(1, -LABEL_PAD * 2, 0.6, 0),
			ZIndex = Tokens.ZIndex.Panel,
			Parent = card,
		})

		labels[group.id] = make("TextLabel", {
			Name = "Label",
			Text = group.label,
			FontFace = Tokens.Font.Bold,
			TextSize = Tokens.TextSize.Title,
			TextColor3 = Tokens.Color.Text,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(LABEL_PAD, LABEL_PAD),
			Size = UDim2.new(1, -LABEL_PAD * 2, 0.6, 0),
			ZIndex = Tokens.ZIndex.Panel + 1,
			Parent = card,
		})

		if group.soon then
			labels[group.id].TextColor3 = Tokens.Color.TextMuted
		end

		cards[group.id] = card
		table.insert(
			conns,
			card.Activated:Connect(function()
				if group.soon then
					self:_flashSoon(group)
					return
				end
				props.onGroup(group)
			end)
		)
	end

	self = setmetatable({
		instance = root,
		_props = props,
		_cards = cards,
		_labels = labels,
		_marks = marks,
		_conns = conns,
	}, CategoryMenu)
	return self
end

-- Kotak isi panel (piksel, relatif panel). Menghitung ulang mozaik: 4 kolom, atau 2 kolom bila sempit.
function CategoryMenu.setArea(self: CategoryMenu, x: number, y: number, w: number, h: number)
	local root = self.instance
	root.Position = UDim2.fromOffset(x, y)
	root.Size = UDim2.fromOffset(math.max(w, 0), math.max(h, 0))

	local narrow = PanelLayout.mosaicNarrow(w)
	local cols, rows = CatalogMenu.grid(narrow)
	local unitW, unitH, totalH = PanelLayout.mosaic(w, h, cols, rows)
	local gap = PanelLayout.MOSAIC_GAP
	local size = labelSize(unitH)

	for _, group in CatalogMenu.list do
		local s = CatalogMenu.span(group, narrow)
		local card = self._cards[group.id]
		card.Position = UDim2.fromOffset(s.x * (unitW + gap), s.y * (unitH + gap))
		card.Size = UDim2.fromOffset(s.w * unitW + (s.w - 1) * gap, s.h * unitH + (s.h - 1) * gap)
		self._labels[group.id].TextSize = size
		self._marks[group.id].TextSize = size * 2
	end
	root.CanvasSize = UDim2.fromOffset(0, totalH)
end

-- Kartu grup yang belum ada isinya: label berkedip "SOON" sebentar (pola tombol Stores).
function CategoryMenu._flashSoon(self: CategoryMenu, group: CatalogMenu.Group)
	local label = self._labels[group.id]
	if label == nil or label.Text ~= group.label then
		return -- sedang berkedip
	end
	label.Text = "SOON"
	task.delay(SOON_SECONDS, function()
		if label.Parent then
			label.Text = group.label
		end
	end)
end

function CategoryMenu.setVisible(self: CategoryMenu, visible: boolean)
	self.instance.Visible = visible
	if visible then
		self.instance.CanvasPosition = Vector2.zero
	end
end

function CategoryMenu.isVisible(self: CategoryMenu): boolean
	return self.instance.Visible
end

function CategoryMenu.destroy(self: CategoryMenu)
	for _, c in self._conns do
		c:Disconnect()
	end
	self.instance:Destroy()
end

return CategoryMenu
