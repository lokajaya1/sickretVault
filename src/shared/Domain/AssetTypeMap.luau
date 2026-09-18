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

-- Emote (kategori "Emotes" di Config/Categories): ADA di katalog sebagai aset biasa, tapi TIDAK
-- punya slot HumanoidDescription -- emote dipasang lewat jalur lain (PromptSaveAvatar/EmoteWheel).
-- Diberi kind "animation" supaya (a) ItemInfoService tidak membuangnya (kind "unknown" dibuang,
-- temuan #23 no. 5) dan (b) UI tahu ini barang yang DIPERAGAKAN, bukan dipakai. Slotnya tetap nil,
-- jadi OutfitState.wear tetap menolaknya dan ia tidak pernah bocor ke description.
M.Emote = {
	EmoteAnimation = true,
}

-- Makeup: ADA di katalog, tidak bisa lewat HumanoidDescription, tapi BISA dipasang sebagai
-- Decal di Head (PR #18). Diberi kind sendiri supaya ItemInfoService tidak membuangnya,
-- tapi TANPA slot -> OutfitState.wear tetap menolaknya (tidak akan bocor ke description).
M.Makeup = {
	FaceMakeup = true,
	EyeMakeup = true,
	LipMakeup = true,
}

-- AvatarBackground: ADA di katalog, tapi bukan barang yang menempel di avatar — ia LATAR
-- area preview (spike 18 Sep 2026: ImageLabel di dalam ViewportFrame, di belakang rig).
-- Diberi kind sendiri supaya ItemInfoService tidak membuangnya (kind "unknown" dibuang),
-- dan TANPA slot supaya OutfitState.wear tetap menolaknya -> tidak pernah bocor ke description.
M.Background = {
	AvatarBackground = true,
}

-- Tipe yang ADA di katalog tapi tombol pakainya disembunyikan UI. Sekarang KOSONG:
-- makeup keluar sejak PR #18 (Decal di Head), AvatarBackground keluar sejak PR avatar-background
-- (tombolnya memasang latar preview). Dipakai UI untuk menyembunyikan tombol TRY, bukan itemnya.
M.NotWearable = {} :: { [string]: boolean }

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

export type Kind = "bodyPart" | "animation" | "classic" | "accessory" | "makeup" | "background" | "unknown"

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
	elseif M.Emote[assetTypeName] then
		return "animation", nil -- slot nil disengaja: emote bukan slot HumanoidDescription
	elseif M.Makeup[assetTypeName] then
		return "makeup", nil -- slot nil disengaja: bukan slot HumanoidDescription mana pun
	elseif M.Background[assetTypeName] then
		return "background", nil -- latar area preview; slot nil karena tidak menempel di avatar
	end
	return "unknown", nil
end

-- Bagian tubuh yang harus DIBIDIK kamera saat menampilkan avatar memakai item ini.
-- Dipakai preview kartu katalog: kartu cuma ~100 px, avatar seluruh badan di situ jadi bercak
-- kecil (dinilai di Studio 19 Sep 2026), jadi kamera didekatkan ke bagian tempat item menempel.
-- "full" = tidak ada bagian khusus (animasi, latar, bundle, tipe tak dikenal) -> seluruh badan.
local FOCUS_HEAD = {
	Head = true,
	DynamicHead = true,
	Face = true,
	Hat = true,
	HairAccessory = true,
	FaceAccessory = true,
	NeckAccessory = true,
	EyebrowAccessory = true,
	EyelashAccessory = true,
	FaceMakeup = true,
	EyeMakeup = true,
	LipMakeup = true,
}
local FOCUS_TORSO = {
	Torso = true,
	LeftArm = true,
	RightArm = true,
	Shirt = true,
	TShirt = true,
	ShirtAccessory = true,
	TShirtAccessory = true,
	SweaterAccessory = true,
	JacketAccessory = true,
	ShoulderAccessory = true,
	FrontAccessory = true,
	BackAccessory = true,
	WaistAccessory = true,
}
local FOCUS_LEGS = {
	LeftLeg = true,
	RightLeg = true,
	Pants = true,
	PantsAccessory = true,
	ShortsAccessory = true,
	DressSkirtAccessory = true,
	LeftShoeAccessory = true,
	RightShoeAccessory = true,
}

export type Focus = "head" | "torso" | "legs" | "full"

function M.focusRegion(assetTypeName: string?): Focus
	if assetTypeName == nil then
		return "full" -- bundle: banyak bagian sekaligus
	end
	if FOCUS_HEAD[assetTypeName] then
		return "head"
	elseif FOCUS_TORSO[assetTypeName] then
		return "torso"
	elseif FOCUS_LEGS[assetTypeName] then
		return "legs"
	end
	return "full"
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
