--!strict
-- DOMAIN MURNI: tidak memanggil service Roblox apa pun, tidak membuat Instance.
-- Peta: nama Enum.AvatarAssetType  ->  slot di OutfitState / HumanoidDescription.
-- Satu-satunya kamus tipe aset; semua modul lain memakai ini.
-- (Konversi ke Enum.AccessoryType ada di adapter Avatar/DescriptionBuilder.)

local M = {}

M.BodyPart = {
	Head = "Head",
	DynamicHead = "Head", -- dynamic head tetap masuk properti Head (butuh MoodAnimation agar berekspresi)
	Torso = "Torso",
	LeftArm = "LeftArm",
	RightArm = "RightArm",
	LeftLeg = "LeftLeg",
	RightLeg = "RightLeg",
}

M.Animation = {
	IdleAnimation = "IdleAnimation",
	WalkAnimation = "WalkAnimation",
	RunAnimation = "RunAnimation",
	JumpAnimation = "JumpAnimation",
	FallAnimation = "FallAnimation",
	ClimbAnimation = "ClimbAnimation",
	SwimAnimation = "SwimAnimation",
	MoodAnimation = "MoodAnimation",
}

M.Classic = {
	Shirt = "Shirt",
	Pants = "Pants",
	TShirt = "GraphicTShirt",
	Face = "Face",
}

M.Layered = {
	TShirtAccessory = true,
	ShirtAccessory = true,
	PantsAccessory = true,
	ShortsAccessory = true,
	DressSkirtAccessory = true,
	SweaterAccessory = true,
	JacketAccessory = true,
	LeftShoeAccessory = true,
	RightShoeAccessory = true,
}

M.Rigid = {
	Hat = true,
	HairAccessory = true,
	FaceAccessory = true,
	NeckAccessory = true,
	ShoulderAccessory = true,
	FrontAccessory = true,
	BackAccessory = true,
	WaistAccessory = true,
	EyebrowAccessory = true, -- TODO verifikasi perilaku (rigid vs layered) di Studio
	EyelashAccessory = true,
}

-- Tipe yang ADA di katalog tapi TIDAK bisa dipakai lewat HumanoidDescription.
-- Spike 18 Sep 2026: SetAccessories + ApplyDescriptionAsync mengembalikan true, tapi item
-- tidak pernah muncul di GetAppliedDescription():GetAccessories() (varian rigid maupun
-- layered+Order). Eyelash & Eyebrow TERBUKTI terpasang, jadi tidak masuk daftar ini.
-- Dipakai UI untuk menyembunyikan tombol TRY, bukan untuk menyembunyikan itemnya.
M.NotWearable = {
	AvatarBackground = true,
	FaceMakeup = true,
	LipMakeup = true,
	EyeMakeup = true,
}

M.BodyPartSlots = { "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }
M.AnimationSlots = {
	"IdleAnimation",
	"WalkAnimation",
	"RunAnimation",
	"JumpAnimation",
	"FallAnimation",
	"ClimbAnimation",
	"SwimAnimation",
	"MoodAnimation",
}
M.ClassicSlots = { "Shirt", "Pants", "GraphicTShirt", "Face" }
M.ColorSlots = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }
M.ScaleSlots = { "HeightScale", "WidthScale", "DepthScale", "HeadScale", "BodyTypeScale", "ProportionScale" }

export type Kind = "bodyPart" | "animation" | "classic" | "accessory" | "unknown"

-- AssetType dari API bisa berupa string nama atau angka id -> normalisasi ke nama.
local idToName: { [number]: string } = {}
for _, item in Enum.AssetType:GetEnumItems() do
	idToName[item.Value] = item.Name
end

function M.normalize(assetType: any): string?
	if type(assetType) == "string" then
		return assetType
	elseif type(assetType) == "number" then
		return idToName[assetType]
	elseif typeof(assetType) == "EnumItem" then
		return (assetType :: EnumItem).Name
	end
	return nil
end

function M.classify(assetTypeName: string): (Kind, string?)
	if M.BodyPart[assetTypeName] then
		return "bodyPart", M.BodyPart[assetTypeName]
	elseif M.Animation[assetTypeName] then
		return "animation", M.Animation[assetTypeName]
	elseif M.Classic[assetTypeName] then
		return "classic", M.Classic[assetTypeName]
	elseif M.Layered[assetTypeName] or M.Rigid[assetTypeName] then
		return "accessory", assetTypeName
	end
	return "unknown", nil
end

function M.isLayered(assetTypeName: string): boolean
	return M.Layered[assetTypeName] == true
end

-- Bisa dicoba di avatar? Bundle (tanpa assetType) dianggap bisa.
function M.isWearable(assetTypeName: string?): boolean
	if assetTypeName == nil then
		return true
	end
	return M.NotWearable[assetTypeName] ~= true
end

return M
