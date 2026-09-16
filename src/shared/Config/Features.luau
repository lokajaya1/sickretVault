--!strict
-- Feature flag: matikan fitur yang bermasalah tanpa membongkar kode.
return {
	BundlePartialTryOn = true,
	-- Ambil skala + MoodAnimation dari UserOutfit bundle. Opsional: jika API berubah, bundle tetap jalan tanpa ini.
	BundleOutfitEnrichment = true,
	-- Perintah inspeksi API mentah (hanya aktif di Studio). Nyalakan hanya saat perlu verifikasi API
	-- (hasil 16 Sep 2026 sudah dicatat di docs/API_VERIFICATION.md).
	DevInspect = false,
}
