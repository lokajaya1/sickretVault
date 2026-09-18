--!strict
-- Batas avatar & anti-spam. Nilai batas aksesori nanti disinkronkan dari
-- AvatarEditorService:GetAvatarRulesAsync(). Nilai di sini hanya fallback aman.
-- Hasil Dev/Inspect (16 Sep 2026): rules hanya memberi MaxNumber PER TIPE
-- (Hat=3, aksesori lain=1, makeup=6), bukan total -> total di bawah tetap fallback.
return {
	MaxRigidAccessories = 10, -- fallback; rules tidak memberi total (lihat docs/API_VERIFICATION.md)
	MaxLayeredAccessories = 10, -- fallback; rules tidak memberi total (lihat docs/API_VERIFICATION.md)
	ApplyDebounce = 0.25, -- detik; gabungkan intent beruntun sebelum ApplyDescription
	UndoDepth = 30,
	Rate = { -- token bucket per pemain per remote
		AvatarIntent = { capacity = 20, refillPerSec = 8 },
		CatalogSearch = { capacity = 6, refillPerSec = 1 },
		Checkout = { capacity = 3, refillPerSec = 0.2 }, -- 1 prompt tiap ~5 dtk
		GetBundle = { capacity = 10, refillPerSec = 2 },
		GetItemDetail = { capacity = 10, refillPerSec = 2 },
		GetRecommended = { capacity = 6, refillPerSec = 1 }, -- 2 panggilan API per permintaan
		GetState = { capacity = 5, refillPerSec = 1 },
		Wardrobe = { capacity = 8, refillPerSec = 1 }, -- save/rename memanggil filter teks (mahal)
	},
	SearchCacheTTL = 600,
	ItemCacheTTL = 3600,
	ItemCacheSize = 5000,
	ItemBatchSize = 100, -- batas API GetBatchItemDetailsAsync (Studio 16 Sep 2026: 101 id ditolak)
}
