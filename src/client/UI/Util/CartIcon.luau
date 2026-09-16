--!strict
-- Ikon keranjang (gambar putih polos, diwarnai lewat ImageColor3) untuk tombol TextButton.
--   CartIcon.apply(button, "add", Tokens.Color.Text)            -- ikon saja (teks tombol dikosongkan)
--   CartIcon.apply(button, "cart", Tokens.Color.Text, "3")      -- ikon + angka di tengah tombol (header)
-- kind: "cart" (header) | "add" (belum di keranjang) | "check" (sudah di keranjang)
-- Gambar diunggah lewat Asset Manager (17 Sep 2026); sumber PNG: ikon outline 256 px (latar transparan).

local CartIcon = {}

CartIcon.Image = {
	cart = "rbxassetid://93218042895597",
	add = "rbxassetid://123919019565851",
	check = "rbxassetid://86736942160992",
}

local ICON_SCALE = 0.62 -- tinggi ikon relatif terhadap tinggi tombol

type Parts = { icon: ImageLabel, count: TextLabel }

-- Isi tombol: Frame transparan + UIListLayout (ikon, angka) di tengah. Dibuat sekali.
local function ensure(button: TextButton): Parts
	local content = button:FindFirstChild("CartContent")
	if content then
		return {
			icon = content:FindFirstChild("Icon") :: ImageLabel,
			count = content:FindFirstChild("Count") :: TextLabel,
		}
	end
	local frame = Instance.new("Frame")
	frame.Name = "CartContent"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.ZIndex = button.ZIndex
	frame.Parent = button

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = frame

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY -- persegi mengikuti tinggi tombol
	icon.Size = UDim2.fromScale(ICON_SCALE, ICON_SCALE)
	icon.LayoutOrder = 1
	icon.ZIndex = button.ZIndex
	icon.Parent = frame

	local count = Instance.new("TextLabel")
	count.Name = "Count"
	count.BackgroundTransparency = 1
	count.FontFace = button.FontFace
	count.TextSize = button.TextSize
	count.AutomaticSize = Enum.AutomaticSize.X
	count.Size = UDim2.fromScale(0, 1)
	count.LayoutOrder = 2
	count.Visible = false
	count.ZIndex = button.ZIndex
	count.Parent = frame

	return { icon = icon, count = count }
end

function CartIcon.apply(button: TextButton, kind: string, color: Color3, count: string?)
	local parts = ensure(button)
	button.Text = ""
	parts.icon.Image = CartIcon.Image[kind] or CartIcon.Image.cart
	parts.icon.ImageColor3 = color
	parts.count.Visible = count ~= nil
	parts.count.Text = count or ""
	parts.count.TextColor3 = color
end

return CartIcon
