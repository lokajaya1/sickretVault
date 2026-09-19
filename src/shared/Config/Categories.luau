--!strict
-- Definisi tab katalog -> parameter SearchCatalogAsync.
-- Dipakai client (label/ikon) & server (membangun CatalogSearchParams). Tambah kategori di sini saja.
-- Kategori dikelompokkan oleh Config/CatalogMenu (kartu mozaik + baris tab grup).
-- Nama tipe aset diverifikasi lewat spike Studio 18 Sep 2026 (tests/CatalogFilter.studio):
--   ADA FaceMakeup, LipMakeup, EyeMakeup, AvatarBackground, MoodAnimation, Eyebrow/EyelashAccessory,
--   Left/RightShoeAccessory. Classic face ("Face") sudah off-sale -> tidak dipakai.
-- Spike putaran 3 (semua kategori dicoba lewat CatalogService): Left/RightShoeAccessory,
-- DynamicHeadAvatar dan MoodAnimation SELALU 0 item (sepatu layered dijual sebagai bundle Shoes;
-- dua sisanya tidak muncul di pencarian katalog) -> tidak dijadikan kategori.
-- CATATAN: satu kategori JANGAN mencampur assetTypes & bundleTypes (spike: hasilnya jatuh ke
-- daftar item gratis bawaan Roblox). Pisahkan jadi dua kategori.
export type Category = {
	id: string,
	label: string,
	assetTypes: { string }?, -- nama Enum.AvatarAssetType
	bundleTypes: { string }?, -- nama Enum.BundleType
}

local list: { Category } = {
	-- ACCESSORIES
	{ id = "hats", label = "Hats", assetTypes = { "Hat" } },
	{ id = "neck", label = "Neck", assetTypes = { "NeckAccessory" } },
	{ id = "shoulder", label = "Shoulder", assetTypes = { "ShoulderAccessory" } },
	{ id = "front", label = "Front", assetTypes = { "FrontAccessory" } },
	{ id = "back", label = "Back", assetTypes = { "BackAccessory" } },
	{ id = "waist", label = "Waist", assetTypes = { "WaistAccessory" } },
	{ id = "shoes", label = "Shoes", bundleTypes = { "Shoes" } },

	-- HAIR
	{ id = "hair", label = "Hair", assetTypes = { "HairAccessory" } },

	-- CLOTHING (satu chip = satu tipe aset, seperti katalog Roblox; "Layered" = semua pakaian 3D)
	{
		id = "layered",
		label = "Layered",
		assetTypes = {
			"TShirtAccessory",
			"ShirtAccessory",
			"SweaterAccessory",
			"JacketAccessory",
			"PantsAccessory",
			"ShortsAccessory",
			"DressSkirtAccessory",
		},
	},
	{ id = "tshirts", label = "T-Shirts", assetTypes = { "TShirtAccessory" } },
	{ id = "shirts", label = "Shirts", assetTypes = { "ShirtAccessory" } },
	{ id = "jackets", label = "Jackets", assetTypes = { "JacketAccessory" } },
	{ id = "sweaters", label = "Sweaters", assetTypes = { "SweaterAccessory" } },
	{ id = "pants", label = "Pants", assetTypes = { "PantsAccessory" } },
	{ id = "shorts", label = "Shorts", assetTypes = { "ShortsAccessory" } },
	{ id = "skirts", label = "Dresses & Skirts", assetTypes = { "DressSkirtAccessory" } },
	{ id = "classic_shirts", label = "Classic Shirts", assetTypes = { "Shirt" } },
	{ id = "classic_pants", label = "Classic Pants", assetTypes = { "Pants" } },
	{ id = "classic_tshirts", label = "Classic T-Shirts", assetTypes = { "TShirt" } },

	-- FACES (wajah & kepala)
	{ id = "face_acc", label = "Face", assetTypes = { "FaceAccessory" } },
	{ id = "heads", label = "Heads", bundleTypes = { "DynamicHead" } },

	-- CHARACTERS (bundle avatar lengkap)
	{ id = "bodies", label = "Bodies", bundleTypes = { "BodyParts" } },

	-- MAKEUP (tipe aset baru Roblox; sub-filter mengikuti CAC)
	{ id = "eye_makeup", label = "Eyes", assetTypes = { "EyeMakeup" } },
	{ id = "lip_makeup", label = "Lips", assetTypes = { "LipMakeup" } },
	{ id = "face_makeup", label = "Face", assetTypes = { "FaceMakeup" } },
	{ id = "eyelashes", label = "Eyelashes", assetTypes = { "EyelashAccessory" } },
	{ id = "eyebrows", label = "Eyebrows", assetTypes = { "EyebrowAccessory" } },

	-- ANIMATION PACKS
	{ id = "animations", label = "Animations", bundleTypes = { "Animations" } },
	{ id = "emotes", label = "Emotes", assetTypes = { "EmoteAnimation" } },

	-- BACKGROUNDS
	{ id = "backgrounds", label = "Backgrounds", assetTypes = { "AvatarBackground" } },

	-- BODY. Yang ditampilkan adalah PART SATUAN, bukan bundle: part bundle (mis. "Korblox
	-- Deathspeaker - Torso") adalah aset tersendiri dengan AvatarAssetType Torso/LeftArm/dst,
	-- jadi pencarian per tipe aset sudah mengembalikannya satu per satu dan pemain bisa memakai
	-- SATU bagian saja. Menambahkan bundleTypes di sini justru memunculkan bundle utuhnya --
	-- itu sudah punya kategorinya sendiri (`bodies`, `heads`) di grup CHARACTERS.
	{ id = "body_face", label = "Face", assetTypes = { "FaceAccessory", "Face" } },
	{ id = "head_shapes", label = "Head", assetTypes = { "Head" } },
	{ id = "torso", label = "Torso", assetTypes = { "Torso" } },
	{ id = "left_arm", label = "LeftArm", assetTypes = { "LeftArm" } },
	{ id = "right_arm", label = "RightArm", assetTypes = { "RightArm" } },
	{ id = "left_leg", label = "LeftLeg", assetTypes = { "LeftLeg" } },
	{ id = "right_leg", label = "RightLeg", assetTypes = { "RightLeg" } },
}

local byId: { [string]: Category } = {}
for _, c in list do
	byId[c.id] = c
end

return { list = list, byId = byId }
