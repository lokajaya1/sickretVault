--!strict
-- SATU-SATUNYA daftar nama remote. Tambah remote baru di sini saja.
-- Nama di Events/Functions juga dipakai sebagai kunci Limits.Rate.
return {
	-- RemoteEvent (tanpa balasan)
	Events = {
		AvatarIntent = "AvatarIntent", -- client -> server: Types.Intent
		StateChanged = "StateChanged", -- server -> client: OutfitState terbaru
		Notify = "Notify", -- server -> client: { code, message } untuk toast
		MakeupChanged = "MakeupChanged", -- server -> client: daftar makeup terpasang (Makeup.toDto)
	},
	-- RemoteFunction (client menunggu balasan)
	Functions = {
		CatalogSearch = "CatalogSearch",
		Checkout = "Checkout", -- client -> server: { { id, itemType } } -> { ok, code? }
		GetBundle = "GetBundle",
		GetItemDetail = "GetItemDetail",
		GetState = "GetState",
		Wardrobe = "Wardrobe", -- client -> server: WardrobeValidator.Request -> { ok, code?, outfits?, ... }
	},
}
