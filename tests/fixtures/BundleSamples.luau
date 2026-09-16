--!strict
-- Contoh respons GetBundleDetailsAsync (SEMENTARA, dibuat tangan).
-- Ganti dengan data asli dari server/Dev/Inspect setelah verifikasi API (docs/API_VERIFICATION.md).

local M = {}

-- Bundle tubuh lengkap: dynamic head + 5 body part + outfit
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
