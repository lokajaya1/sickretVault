--!strict
-- Konfigurasi umum game (bukan batas avatar -> itu di Limits).
return {
	-- "debug" | "info" | "warn" | "error"
	LogLevel = "info",
	-- Proxy untuk API web avatar Roblox. HttpService MEMBLOKIR domain Roblox sendiri
	-- ("HttpService is not allowed to access that Roblox resource", diukur 19 Sep 2026), jadi daftar
	-- outfit milik pemain LAIN hanya bisa diambil lewat perantara. roproxy.com itu proxy PUBLIK:
	-- gratis, tapi dipakai ribuan game dan sering membalas HTTP 429 -> hasilnya di-cache, dan panel
	-- tetap jalan tanpa daftar ini. Ganti ke proxy sendiri (mis. Cloudflare Worker) kalau sudah ada;
	-- "" = fitur dimatikan.
	OutfitProxy = "avatar.roproxy.com",
	-- Nama folder remote di ReplicatedStorage (dibuat server).
	RemoteFolderName = "Remotes",
	-- Batas payload intent dari client.
	Intent = {
		MaxKeys = 6, -- jumlah field maksimum dalam satu intent
		MaxPartIds = 50, -- panjang maksimum partIds pada wearBundle
		MaxId = 2 ^ 53, -- id aset/bundle maksimum (batas integer aman)
		MinLayerOrder = 1,
		MaxLayerOrder = 100,
	},
}
