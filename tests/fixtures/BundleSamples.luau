--!strict
-- Contoh respons GetBundleDetailsAsync.
--   M.RealBody : data ASLI dari server/Dev/Inspect (Studio, 16 Sep 2026) -> docs/API_VERIFICATION.md
--   M.Body/Shoes/Broken/Invalid : buatan tangan untuk kasus tepi (skala asing, id string, respons rusak)

local M = {}

-- ASLI: bundle 104915988289001 "Tallest male can shoes 3.0".
-- 7 aset + 2 UserOutfit (#1 = OutfitType "Avatar", #2 = "DynamicHead").
M.RealBody = {
	raw = {
		BundleType = "BodyParts",
		Description = "version 3.0",
		Id = 104915988289001,
		Items = {
			{
				AssetType = "RightArm",
				Id = 108248819544910,
				Name = "Tallest male can shoes 3.0 - แขนขวา",
				Type = "Asset",
			},
			{
				AssetType = "Torso",
				Id = 99377734100872,
				Name = "Tallest male can shoes 3.0 - ลำตัว",
				Type = "Asset",
			},
			{
				AssetType = "LeftLeg",
				Id = 72234257632785,
				Name = "Tallest male can shoes 3.0 - ขาซ้าย",
				Type = "Asset",
			},
			{
				AssetType = "LeftArm",
				Id = 83468903837271,
				Name = "Tallest male can shoes 3.0 - แขนซ้าย",
				Type = "Asset",
			},
			{ AssetType = "MoodAnimation", Id = 14618207727, Name = "Default Mood", Type = "Asset" },
			{
				AssetType = "RightLeg",
				Id = 106894876305910,
				Name = "Tallest male can shoes 3.0 - ขาขวา",
				Type = "Asset",
			},
			{
				AssetType = "DynamicHead",
				Id = 110446883733723,
				Name = "Tallest male can shoes 3.0 - ศีรษะไดนามิก",
				SupportsHeadShapes = false,
				Type = "Asset",
			},
			{ Id = 6016977565474900, Name = "Tallest male can shoes 3.0", Type = "UserOutfit" },
			{ Id = 5533792516890598, Name = "Tallest male can shoes 3.0", Type = "UserOutfit" },
		},
		Name = "Tallest male can shoes 3.0",
		PriceDiscountDetails = {
			{ AmountInRobux = 20, Percent = 10, Type = "RobloxPlusSubscription" },
		},
		UserBasePriceInRobux = 200,
	},
	-- dari GetBatchItemDetailsAsync (AssetType)
	assetTypes = {
		[14618207727] = "MoodAnimation",
		[72234257632785] = "LeftLeg",
		[83468903837271] = "LeftArm",
		[99377734100872] = "Torso",
		[106894876305910] = "RightLeg",
		[108248819544910] = "RightArm",
		[110446883733723] = "DynamicHead",
	},
	-- GetOutfitDetailsAsync (diringkas: hanya field yang dipakai). Id outfit berupa STRING.
	outfits = {
		["6016977565474900"] = {
			Id = "6016977565474900",
			OutfitType = "Avatar",
			InventoryType = "Body",
			PlayerAvatarType = "R15",
			Scale = { BodyType = 0, Depth = 1, Head = 1, Height = 1, Proportion = 0, Width = 1 },
		},
		["5533792516890598"] = {
			Id = "5533792516890598",
			OutfitType = "DynamicHead",
			InventoryType = "DynamicHead",
			PlayerAvatarType = "R15",
			Scale = { BodyType = 0, Depth = 1, Head = 1, Height = 1, Proportion = 0, Width = 1 },
		},
	},
	-- hasil adapter Scale outfit #1 -> nama ScaleSlots (dikerjakan BundleService nanti)
	enrichment = {
		scales = {
			HeightScale = 1,
			WidthScale = 1,
			DepthScale = 1,
			HeadScale = 1,
			BodyTypeScale = 0,
			ProportionScale = 0,
		},
		moodAnimation = 14618207727, -- sudah ada di bundle -> tidak boleh dobel
	},
}

-- BUATAN TANGAN: bundle tubuh dengan skala asing & mood yang belum ada di bundle
M.Body = {
	raw = {
		Id = 1001,
		Name = "Test Body",
		BundleType = "BodyParts",
		Items = {
			{ Id = 11, Name = "Test Head", Type = "Asset" },
			{ Id = 12, Name = "Test Torso", Type = "Asset" },
			{ Id = 13, Name = "Test Left Arm", Type = "Asset" },
			{ Id = 14, Name = "Test Right Arm", Type = "Asset" },
			{ Id = 15, Name = "Test Left Leg", Type = "Asset" },
			{ Id = 16, Name = "Test Right Leg", Type = "Asset" },
			{ Id = 9001, Name = "Test Body", Type = "UserOutfit" },
		},
	},
	assetTypes = {
		[11] = "DynamicHead",
		[12] = "Torso",
		[13] = "LeftArm",
		[14] = "RightArm",
		[15] = "LeftLeg",
		[16] = "RightLeg",
	},
	enrichment = {
		scales = { HeightScale = 1.05, WidthScale = 0.9, BodyTypeScale = 0.3, Bogus = 5 },
		moodAnimation = 77,
	},
}

-- Bundle sepatu: kunci huruf kecil + id string (jaga-jaga bentuk respons berubah)
M.Shoes = {
	raw = {
		id = "1002",
		name = "Test Shoes",
		bundleType = "Shoes",
		items = {
			{ id = "21", name = "Left Shoe", type = "Asset" },
			{ id = "22", name = "Right Shoe", type = "Asset" },
			{ id = "21", name = "Left Shoe (dup)", type = "Asset" },
		},
	},
	assetTypes = {
		[21] = "LeftShoeAccessory",
		[22] = "RightShoeAccessory",
	},
	enrichment = { moodAnimation = 77 }, -- tidak ada kepala -> tidak boleh ditambah
}

-- Respons rusak / aneh: item bukan tabel, tipe asing, id tidak valid, tipe aset tak didukung
M.Broken = {
	raw = {
		Id = 1003,
		Items = {
			"bukan tabel",
			{ Id = 31, Name = "Hat", Type = "Asset" },
			{ Id = 32, Name = "Gear", Type = "Asset" },
			{ Id = 33, Name = "Mystery", Type = "Asset" }, -- tipe tidak diketahui ItemInfo
			{ Id = -5, Name = "Negatif", Type = "Asset" },
			{ Id = 34, Name = "Baru", Type = "Emote" },
			{ Name = "Tanpa Id", Type = "Asset" },
		},
	},
	assetTypes = {
		[31] = "Hat",
		[32] = "Gear",
	},
}

-- Respons yang harus ditolak
M.Invalid = {
	notTable = "oops",
	noId = { Name = "x", Items = {} },
	noItems = { Id = 1004 },
	noAssets = { Id = 1005, Items = { { Id = 1, Type = "UserOutfit" } } },
}

return M
