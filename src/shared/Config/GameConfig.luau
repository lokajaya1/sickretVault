--!strict
-- Konfigurasi umum game (bukan batas avatar -> itu di Limits).
return {
	-- "debug" | "info" | "warn" | "error"
	LogLevel = "info",
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
