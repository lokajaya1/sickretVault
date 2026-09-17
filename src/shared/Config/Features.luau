--!strict
-- Feature flag: matikan fitur yang bermasalah tanpa membongkar kode.
return {
	BundlePartialTryOn = true,
	-- Ambil skala + MoodAnimation dari UserOutfit bundle. Opsional: jika API berubah, bundle tetap jalan tanpa ini.
	BundleOutfitEnrichment = true,
	-- Perintah inspeksi API mentah (hanya aktif di Studio). Nyalakan hanya saat perlu verifikasi API
	-- (hasil 16 Sep 2026 sudah dicatat di docs/API_VERIFICATION.md).
	DevInspect = false,
	-- Simpan data pemain (ProfileStore): outfit terakhir dipasang lagi saat join.
	-- false = tanpa DataStore sama sekali (mis. bila DataStore bermasalah).
	PlayerData = true,
	-- true = di Studio pakai ProfileStore.Mock (data asli tidak tersentuh, hilang saat Stop).
	-- false = Studio memakai DataStore asli (butuh place di-publish + Enable Studio Access to API Services).
	PlayerDataStudioMock = false,
	-- Wardrobe (slot outfit tersimpan). Butuh PlayerData = true. false = remote Wardrobe menjawab DISABLED.
	Wardrobe = true,
}
