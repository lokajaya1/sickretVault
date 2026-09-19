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
		BackgroundChanged = "BackgroundChanged", -- server -> client: { assetId, image, color } | nil
	},
	-- RemoteFunction (client menunggu balasan)
	Functions = {
		CatalogSearch = "CatalogSearch",
		Checkout = "Checkout", -- client -> server: { { id, itemType } } -> { ok, code? }
		GetAnimationClip = "GetAnimationClip", -- { assetId } -> { ok, animationId } (preview animasi)
		GetBundle = "GetBundle",
		GetItemDetail = "GetItemDetail",
		GetRecommended = "GetRecommended", -- { id, itemType, assetType? } -> { ok, items }
		GetState = "GetState",
		Ownership = "Ownership", -- { assets = { id }, bundles = { id } } -> { ok, unowned, unownedBundles }
		RobloxOutfit = "RobloxOutfit", -- { op = "state" | "wear", outfitId } -> { ok, state?, code? }
		Wardrobe = "Wardrobe", -- client -> server: WardrobeValidator.Request -> { ok, code?, outfits?, ... }
	},
}
