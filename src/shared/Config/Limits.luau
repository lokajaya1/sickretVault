--!strict
-- Batas avatar & anti-spam. Nilai batas aksesori nanti disinkronkan dari
-- AvatarEditorService:GetAvatarRulesAsync(). Nilai di sini hanya fallback aman.
return {
	MaxRigidAccessories = 10, -- TODO verifikasi via GetAvatarRulesAsync
	MaxLayeredAccessories = 10, -- TODO verifikasi via GetAvatarRulesAsync
	ApplyDebounce = 0.25, -- detik; gabungkan intent beruntun sebelum ApplyDescription
	UndoDepth = 30,
	Rate = { -- token bucket per pemain per remote
		AvatarIntent = { capacity = 20, refillPerSec = 8 },
		CatalogSearch = { capacity = 6, refillPerSec = 1 },
		GetBundle = { capacity = 10, refillPerSec = 2 },
		GetState = { capacity = 5, refillPerSec = 1 },
	},
	SearchCacheTTL = 600,
	ItemCacheTTL = 3600,
	ItemCacheSize = 5000,
	ItemBatchSize = 50, -- TODO verifikasi batas GetBatchItemDetailsAsync
}
