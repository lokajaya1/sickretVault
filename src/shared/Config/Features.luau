--!strict
-- Feature flag: matikan fitur yang bermasalah tanpa membongkar kode.
return {
	BundlePartialTryOn = true,
	-- Ambil skala + MoodAnimation dari UserOutfit bundle. Opsional: jika API berubah, bundle tetap jalan tanpa ini.
	BundleOutfitEnrichment = true,
	-- Perintah inspeksi API mentah (hanya aktif di Studio).
	DevInspect = true,
}
