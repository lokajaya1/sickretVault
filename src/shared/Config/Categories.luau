--!strict
-- Definisi tab katalog -> parameter SearchCatalogAsync.
-- Dipakai client (label/ikon) & server (membangun CatalogSearchParams). Tambah kategori di sini saja.
export type Category = {
	id: string,
	label: string,
	assetTypes: { string }?, -- nama Enum.AvatarAssetType
	bundleTypes: { string }?, -- nama Enum.BundleType
}

local list: { Category } = {
	{ id = "hats", label = "Hats", assetTypes = { "Hat" } },
	{ id = "hair", label = "Hair", assetTypes = { "HairAccessory" } },
	{
		id = "face_acc",
		label = "Face",
		assetTypes = { "FaceAccessory", "EyebrowAccessory", "EyelashAccessory" },
	},
	{ id = "neck", label = "Neck", assetTypes = { "NeckAccessory" } },
	{ id = "shoulder", label = "Shoulder", assetTypes = { "ShoulderAccessory" } },
	{ id = "front", label = "Front", assetTypes = { "FrontAccessory" } },
	{ id = "back", label = "Back", assetTypes = { "BackAccessory" } },
	{ id = "waist", label = "Waist", assetTypes = { "WaistAccessory" } },
	{
		id = "tops",
		label = "Tops",
		assetTypes = { "TShirtAccessory", "ShirtAccessory", "SweaterAccessory", "JacketAccessory" },
	},
	{
		id = "bottoms",
		label = "Bottoms",
		assetTypes = { "PantsAccessory", "ShortsAccessory", "DressSkirtAccessory" },
	},
	{ id = "classic", label = "Classic", assetTypes = { "Shirt", "Pants", "TShirt" } },
	{ id = "faces", label = "Faces", assetTypes = { "Face" } },
	{ id = "shoes", label = "Shoes", bundleTypes = { "Shoes" } },
	{ id = "bodies", label = "Bodies", bundleTypes = { "BodyParts" } },
	{ id = "heads", label = "Heads", bundleTypes = { "DynamicHead" } },
	{ id = "animations", label = "Animations", bundleTypes = { "Animations" } },
	{ id = "emotes", label = "Emotes", assetTypes = { "EmoteAnimation" } },
}

local byId: { [string]: Category } = {}
for _, c in list do
	byId[c.id] = c
end

return { list = list, byId = byId }
