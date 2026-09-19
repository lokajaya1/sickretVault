--!strict
-- Titik masuk server: buat remote, rakit service, sambungkan handler remote.
-- Urutan penting: Remotes.init() dulu, baru service & handler.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local RemoteNames = require(Shared.Net.RemoteNames)
local RateLimiter = require(Shared.Util.RateLimiter)
local Log = require(Shared.Util.Log)
local Features = require(Shared.Config.Features)
local PlayerData = require(Shared.Domain.PlayerData)
local Makeup = require(Shared.Domain.Makeup)
local ItemDetail = require(Shared.Domain.ItemDetail)
local DescriptionBuilder = require(Shared.Avatar.DescriptionBuilder)
local IntentValidator = require(script.Validators.IntentValidator)
local WardrobeValidator = require(script.Validators.WardrobeValidator)
local RobloxApi = require(script.Gateways.RobloxApi)
local AssetDecal = require(script.Gateways.AssetDecal)
local CatalogService = require(script.Services.CatalogService)
local ItemInfoService = require(script.Services.ItemInfoService)
local BundleService = require(script.Services.BundleService)
local ItemDetailService = require(script.Services.ItemDetailService)
local CheckoutService = require(script.Services.CheckoutService)
local AvatarService = require(script.Services.AvatarService)
local MakeupService = require(script.Services.MakeupService)
local AvatarRules = require(script.Services.AvatarRules)
local PlayerDataService = require(script.Services.PlayerDataService)
local WardrobeService = require(script.Services.WardrobeService)
local OutfitItemsService = require(script.Services.OutfitItemsService)
local Inspect = require(script.Dev.Inspect)

local log = Log.new("Server")

-- 1. Buat semua remote sebelum client membutuhkannya.
Remotes.init()

-- 2. Gateway API Roblox + service (satu instance untuk seluruh server).
local api = RobloxApi.new()
local catalog = CatalogService.new({ api = api })
local itemInfo = ItemInfoService.new({ api = api })
local rules = AvatarRules.new({ api = api }) -- batas per tipe (Hat=3, lainnya 1)
local bundles = BundleService.new({ api = api, itemInfo = itemInfo }) -- detail bundle (part + skala)
local details = ItemDetailService.new({ api = api, bundles = bundles }) -- panel detail item
local assetDecals = AssetDecal.new() -- InsertService: id item makeup -> texture id (server saja)

local stateChanged = Remotes.event(RemoteNames.Events.StateChanged)
local notify = Remotes.event(RemoteNames.Events.Notify)
local makeupChanged = Remotes.event(RemoteNames.Events.MakeupChanged)
local backgroundChanged = Remotes.event(RemoteNames.Events.BackgroundChanged)

-- Checkout keranjang: PromptBulkPurchase HARUS dari server; hasilnya didengarkan client.
local checkout = CheckoutService.new()

-- Data pemain (ProfileStore: session lock, auto save, BindToClose). Flag mati -> tanpa simpan.
local playerData: PlayerDataService.PlayerDataService? = nil
if Features.PlayerData then
	local ProfileStore = require(script.Parent:WaitForChild("ServerPackages").ProfileStore)
	local store = ProfileStore.New(PlayerDataService.STORE_NAME, PlayerData.TEMPLATE)
	if Features.PlayerDataStudioMock and RunService:IsStudio() then
		store = store.Mock -- Studio tidak menyentuh data asli (hilang saat Stop)
	end
	playerData = PlayerDataService.new({ store = store })
end

-- Makeup TIDAK bisa lewat HumanoidDescription (spike #18) -> Decal di Head.
-- Sejak PR makeup-wardrobe service ini hanya RESOLVER + RENDERER: state look-nya milik AvatarService.
local makeup = MakeupService.new({ decals = assetDecals, itemInfo = itemInfo })

-- Dto makeup terakhir yang dikirim per pemain: StateChanged sering, makeup jarang berubah.
local lastMakeupSent: { [Player]: any } = {}

local avatar: AvatarService.AvatarService

-- Simpan LOOK terakhir (outfit + makeup) ke profil (di memori; ProfileStore yang menulis).
-- Sama dengan avatar asli DAN tanpa makeup -> hapus, supaya ganti avatar di website tetap
-- terlihat saat join.
local function saveLook(player: Player, state, makeupState)
	if playerData then
		local keep = not avatar:isBaseline(player)
		playerData:setLastOutfit(player, if keep then state else nil, if keep then makeupState else nil)
	end
end

avatar = AvatarService.new({
	api = api,
	itemInfo = itemInfo,
	rules = rules,
	bundles = bundles,
	onState = function(player: Player, state, makeupState)
		if player.Parent == Players then
			stateChanged:FireClient(player, state)
			-- makeup ikut look, tapi hanya dikirim kalau memang berubah (hemat redraw kartu)
			local prev = lastMakeupSent[player]
			if prev == nil or not Makeup.equals(prev, makeupState) then
				lastMakeupSent[player] = makeupState
				makeupChanged:FireClient(player, Makeup.toDto(makeupState))
			end
		end
		saveLook(player, state, makeupState)
	end,
	onError = function(player: Player, code: string)
		if player.Parent == Players then
			notify:FireClient(player, { code = code })
		end
	end,
	-- Bagian makeup dari look berubah -> tempel ulang decal (tanpa yield, template sudah di-cache).
	applyMakeup = function(player: Player, makeupState)
		makeup:apply(player, makeupState)
	end,
	-- Head bisa berganti saat respawn / apply berhasil -> decal makeup dipasang ulang.
	onApplied = function(player: Player)
		makeup:reapply(player)
	end,
})

-- Detail item (nama & harga) dari daftar id. Dipegang di luar WardrobeService karena panel review
-- Save to Roblox juga memakainya: item yang sedang dipakai sering TIDAK pernah lewat katalog di
-- client (mis. hasil restore saat join), jadi client tidak tahu nama maupun harganya.
local outfitItems = OutfitItemsService.new({ api = api })

-- Wardrobe (slot outfit) butuh data pemain.
local wardrobe = if playerData and Features.Wardrobe
	then WardrobeService.new({
		playerData = playerData,
		avatar = avatar,
		makeup = makeup, -- slot menyimpan look utuh: makeup di slot perlu di-resolve saat dipakai
		items = outfitItems,
	})
	else nil

-- 3. Rate limiter per remote (preset dari Limits.Rate).
local intentLimiter = RateLimiter.fromLimits(RemoteNames.Events.AvatarIntent)
local searchLimiter = RateLimiter.fromLimits(RemoteNames.Functions.CatalogSearch)
local stateLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetState)
local bundleLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetBundle)
local detailLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetItemDetail)
local recLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetRecommended)
local clipLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetAnimationClip)
local checkoutLimiter = RateLimiter.fromLimits(RemoteNames.Functions.Checkout)
local wardrobeLimiter = RateLimiter.fromLimits(RemoteNames.Functions.Wardrobe)
local robloxOutfitLimiter = RateLimiter.fromLimits(RemoteNames.Functions.RobloxOutfit)
local ownershipLimiter = RateLimiter.fromLimits(RemoteNames.Functions.Ownership)

-- 4a-0. LATAR area preview (AvatarBackground). Item ini TIDAK menempel di avatar: yang berubah
--       cuma gambar di belakang ViewportFrame preview, per pemain. Jadi statenya satu assetId di
--       PlayerData (bukan OutfitState, bukan timeline Undo/Redo milik AvatarService), dan
--       intent `wear`/`remove` untuknya dihentikan di sini supaya tidak sampai ke AvatarService.

-- Kirim latar ke SATU pemain. assetId nil = latar dilepas. YIELD (InsertService, di-cache gateway).
local function pushBackground(player: Player, assetId: number?): (boolean, string?)
	if assetId == nil then
		backgroundChanged:FireClient(player, nil)
		return true, nil
	end
	local ok, bg = assetDecals:getBackground(assetId)
	if not ok then
		return false, if bg then bg.code else "FAILED"
	end
	backgroundChanged:FireClient(player, { assetId = assetId, image = bg.image, color = bg.color })
	return true, nil
end

-- Return (ditangani, ok, code). ditangani = false -> intent diteruskan ke jalur biasa.
local function routeBackgroundIntent(player: Player, intent: any): (boolean, boolean, string?)
	if intent.op ~= "wear" and intent.op ~= "remove" then
		return false, false, nil
	end
	local okInfo, info = itemInfo:get(intent.assetId) -- yield; di-cache, tidak menambah request
	if not okInfo or info.kind ~= "background" then
		return false, false, nil
	end
	if playerData == nil then
		return true, false, "NOT_READY"
	end
	local worn = playerData:getBackground(player)
	if intent.op == "remove" then
		if worn ~= info.assetId then
			return true, false, "NOTHING"
		end
		playerData:setBackground(player, nil)
		pushBackground(player, nil)
		return true, true, nil
	end
	if worn == info.assetId then
		return true, false, "NOTHING" -- klik ganda
	end
	-- gambar dulu, simpan belakangan: latar yang gagal dimuat tidak boleh nyangkut di profil
	local okPush, code = pushBackground(player, info.assetId) -- yield
	if not okPush then
		return true, false, code or "FAILED"
	end
	playerData:setBackground(player, info.assetId)
	return true, true, nil
end

-- 4a. Intent `wear` perlu tahu dulu item ini makeup atau bukan: cuma MakeupService yang bisa
--     menerjemahkan id item -> slot + texture (InsertService, YIELD). UNSUPPORTED_TYPE = bukan
--     makeup -> diteruskan ke AvatarService seperti biasa. (ItemInfoService punya cache, jadi
--     pemeriksaan tipe tidak menambah request.)
--     `remove` & `reset` TIDAK perlu dibelokkan lagi: AvatarService yang memegang state makeup.
local function routeIntent(player: Player, intent: any): (boolean, string?)
	local isBackground, okBg, codeBg = routeBackgroundIntent(player, intent) -- yield
	if isBackground then
		return okBg, codeBg
	end
	if intent.op == "wear" then
		local ok, res = makeup:resolve(intent.assetId) -- yield
		if ok then
			return avatar:wearMakeup(player, res)
		end
		if res ~= "UNSUPPORTED_TYPE" then
			return false, res
		end
	end
	return avatar:handle(player, intent)
end

-- 4. AvatarIntent: rate limit -> validasi -> AvatarService. Gagal -> Notify { code, op }.
Remotes.event(RemoteNames.Events.AvatarIntent).OnServerEvent:Connect(function(player: Player, raw: any)
	if not intentLimiter:take(player.UserId) then
		notify:FireClient(player, { code = "RATE_LIMITED" })
		return
	end
	local intent, err = IntentValidator.validate(raw)
	if not intent then
		log.warn("intent ditolak", err, player.Name)
		notify:FireClient(player, { code = "BAD_ARG" })
		return
	end
	local pOk, ok, code = pcall(routeIntent, player, intent)
	if not pOk then
		log.error("AvatarIntent error", ok, player.Name)
		ok, code = false, "FAILED"
	end
	log.info("intent", intent.op, ok, code, player.Name)
	-- NOTHING = tidak ada perubahan (mis. klik ganda) -> tidak perlu toast
	if not ok and code ~= "NOTHING" and player.Parent == Players then
		notify:FireClient(player, { code = code, op = intent.op })
	end
end)

-- 4b. GetState: client minta state terkini (mis. setelah UI dibuat ulang).
Remotes.func(RemoteNames.Functions.GetState).OnServerInvoke = function(player: Player)
	if not stateLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	local state = avatar:getState(player)
	if state == nil then
		return { ok = false, code = "NOT_READY" }
	end
	local bgId = if playerData then playerData:getBackground(player) else nil
	local background = nil
	if bgId ~= nil then
		local okBg, bg = assetDecals:getBackground(bgId) -- yield; di-cache
		background = if okBg then { assetId = bgId, image = bg.image, color = bg.color } else nil
	end
	return {
		ok = true,
		state = state,
		-- Avatar asli akun: dipakai panel "Reset to Roblox Avatar?" untuk memperlihatkan apa yang
		-- akan didapat pemain SEBELUM ia menekan Yes. Tidak berubah sepanjang sesi.
		baseline = avatar:getBaseline(player),
		makeup = Makeup.toDto(avatar:getMakeup(player)),
		background = background,
	}
end

-- 5. CatalogSearch: rate limit -> CatalogService.search. Selalu mengembalikan tabel Response.
Remotes.func(RemoteNames.Functions.CatalogSearch).OnServerInvoke = function(player: Player, raw: any)
	if not searchLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED", message = "terlalu cepat, tunggu sebentar" }
	end
	local ok, res = pcall(catalog.search, catalog, raw)
	if not ok then
		log.error("CatalogSearch error", res, player.Name)
		return { ok = false, code = "FAILED", message = "gagal memuat katalog" }
	end
	if not res.ok then
		log.debug("CatalogSearch", res.code, res.message, player.Name)
	end
	return res
end

-- 5a. GetBundle: detail bundle (daftar part) untuk panel pilih part (UI menyusul).
Remotes.func(RemoteNames.Functions.GetBundle).OnServerInvoke = function(player: Player, raw: any)
	if not bundleLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	if type(raw) ~= "number" or raw <= 0 or raw % 1 ~= 0 or raw > 2 ^ 53 then
		return { ok = false, code = "BAD_ARG" }
	end
	local pOk, ok, res = pcall(bundles.get, bundles, raw)
	if not pOk then
		log.error("GetBundle error", ok, player.Name)
		return { ok = false, code = "FAILED" }
	end
	if not ok then
		return { ok = false, code = res.code }
	end
	return { ok = true, bundle = res }
end

-- 5b. GetItemDetail: { id, itemType = "Asset" | "Bundle" } -> { ok, detail } | { ok = false, code }.
Remotes.func(RemoteNames.Functions.GetItemDetail).OnServerInvoke = function(player: Player, raw: any)
	if not detailLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	if type(raw) ~= "table" then
		return { ok = false, code = "BAD_ARG" }
	end
	local id, itemType = raw.id, raw.itemType
	if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 or id > 2 ^ 53 then
		return { ok = false, code = "BAD_ARG" }
	end
	if itemType ~= "Asset" and itemType ~= "Bundle" then
		return { ok = false, code = "BAD_ARG" }
	end
	local pOk, ok, res = pcall(details.get, details, id, itemType)
	if not pOk then
		log.error("GetItemDetail error", ok, player.Name)
		return { ok = false, code = "FAILED" }
	end
	if not ok then
		log.debug("GetItemDetail", itemType, id, res.code, player.Name)
		return { ok = false, code = res.code }
	end
	return { ok = true, detail = res }
end

-- 5b1b. GetAnimationClip: { assetId } -> { ok, animationId } | { ok = false, code }.
-- Kartu animasi butuh id KLIP untuk memutar preview, dan cuma server yang boleh memanggil
-- InsertService (temuan #18 no. 4). Hasilnya di-cache gateway, jadi id yang sama tidak diambil dua kali.
Remotes.func(RemoteNames.Functions.GetAnimationClip).OnServerInvoke = function(player: Player, raw: any)
	if not clipLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	local assetId = if type(raw) == "table" then raw.assetId else nil
	if type(assetId) ~= "number" then
		return { ok = false, code = "BAD_ARG" }
	end
	local ok, clip = assetDecals:getAnimationClip(assetId)
	if not ok then
		return { ok = false, code = if clip then clip.code else "FAILED" }
	end
	return { ok = true, animationId = clip.animationId }
end

-- 5b2. GetRecommended: { id, itemType, assetType? } -> { ok, items } | { ok = false, code }.
-- Terpisah dari GetItemDetail supaya panel detail muncul dulu; rekomendasi menyusul sendiri.
Remotes.func(RemoteNames.Functions.GetRecommended).OnServerInvoke = function(player: Player, raw: any)
	if not recLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	if type(raw) ~= "table" then
		return { ok = false, code = "BAD_ARG" }
	end
	local id, itemType, assetType = raw.id, raw.itemType, raw.assetType
	if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 or id > 2 ^ 53 then
		return { ok = false, code = "BAD_ARG" }
	end
	if itemType ~= "Asset" and itemType ~= "Bundle" then
		return { ok = false, code = "BAD_ARG" }
	end
	if assetType ~= nil and type(assetType) ~= "string" then
		return { ok = false, code = "BAD_ARG" }
	end
	local pOk, ok, res = pcall(details.getRecommended, details, id, itemType, assetType)
	if not pOk then
		log.error("GetRecommended error", ok, player.Name)
		return { ok = false, code = "FAILED" }
	end
	if not ok then
		log.debug("GetRecommended", itemType, id, res.code, player.Name)
		return { ok = false, code = res.code }
	end
	return { ok = true, items = res }
end

-- 5c. Checkout: { { id, itemType } } -> { ok = true } | { ok = false, code }.
-- ok = true artinya prompt tampil; hasil (PromptBulkPurchaseFinished) didengarkan di client.
Remotes.func(RemoteNames.Functions.Checkout).OnServerInvoke = function(player: Player, raw: any)
	if not checkoutLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	local pOk, ok, res = pcall(checkout.prompt, checkout, player, raw)
	if not pOk then
		log.error("Checkout error", ok, player.Name)
		return { ok = false, code = "FAILED" }
	end
	if not ok then
		log.debug("Checkout", res.code, player.Name)
		return { ok = false, code = res.code }
	end
	return { ok = true }
end

-- 5c2. Ownership: { assets = { id }, bundles = { id } } -> { ok, unowned, unownedBundles }.
-- Untuk panel "Owned / Unowned" sebelum Save to Roblox. Yang dikirim balik hanya id yang BELUM
-- dimiliki (array angka biasa): client sudah tahu daftar yang ia tanyakan, dan peta ber-kunci angka
-- lewat remote gampang berubah bentuk. YIELD (PlayerOwnsAsset serentak, 876 ms untuk 16 panggilan).
Remotes.func(RemoteNames.Functions.Ownership).OnServerInvoke = function(player: Player, raw: any)
	if not ownershipLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	if type(raw) ~= "table" then
		return { ok = false, code = "BAD_ARG" }
	end
	local pOk, ownedAssets, ownedBundles = pcall(function()
		return checkout:owned(player, raw.assets, raw.bundles)
	end)
	if not pOk then
		log.error("Ownership error", ownedAssets, player.Name)
		return { ok = false, code = "FAILED" }
	end
	local unowned, unownedBundles = {}, {}
	for id, has in ownedAssets do
		if not has then
			table.insert(unowned, id)
		end
	end
	for id, has in ownedBundles do
		if not has then
			table.insert(unownedBundles, id)
		end
	end
	-- Sekalian nama & harga item yang dipakai: panel menampilkan keduanya, dan tanpa ini semua
	-- kartu bertuliskan "N/A" karena client cuma kenal item yang pernah ia tampilkan di katalog.
	-- Gagal di sini TIDAK menggagalkan kepemilikan -- panel tetap berguna tanpa harga.
	local items = {}
	local pOkItems, okList, listRes = pcall(outfitItems.list, outfitItems, avatar:getState(player))
	if pOkItems and okList and type(listRes) == "table" then
		for _, entry in listRes.items do
			table.insert(items, {
				id = entry.id,
				name = entry.name,
				price = entry.price,
				resalePrice = entry.resalePrice,
				limited = entry.limited,
				offSale = entry.offSale,
				priceStatus = entry.priceStatus,
			})
		end
	else
		log.debug("Ownership: detail item tidak terambil", player.Name)
	end

	-- Bagian tubuh & animasi datang dari BUNDLE dan tidak dijual satuan: harga satuannya memang
	-- tidak ada. Yang punya harga adalah bundle-nya, jadi detail bundle diambil terpisah
	-- (GetBatchItemDetailsAsync dengan AvatarItemType.Bundle) dan panel menampilkan bundle itu
	-- sebagai SATU kartu, bukan lima part tanpa harga.
	local bundleIds = {}
	for id in ownedBundles do
		table.insert(bundleIds, id)
	end
	local bundleInfo = {}
	if #bundleIds > 0 then
		-- pcall MEMBUNGKUS dua nilai kembalian gateway (ok, hasil) -> tiga variabel, bukan dua.
		local pOkB, okB, bDetails = pcall(function()
			return api:getBatchItemDetails(bundleIds, Enum.AvatarItemType.Bundle)
		end)
		if pOkB and okB and type(bDetails) == "table" then
			for id, detail in bDetails do
				if type(detail) == "table" then
					-- Aturan harga yang sama dengan aset (ItemDetail): bundle pun bisa limited.
					local bPrice, bResale, bLimited, bOffSale, bResellers = ItemDetail.priceFields(detail)
					table.insert(bundleInfo, {
						id = id,
						name = if type(detail.Name) == "string" then detail.Name else nil,
						price = bPrice,
						resalePrice = if bResellers and bResale ~= nil and bResale > 0 then bResale else nil,
						limited = if bLimited then true else nil,
						offSale = if bOffSale then true else nil,
						priceStatus = if type(detail.PriceStatus) == "string" then detail.PriceStatus else nil,
					})
				end
			end
		else
			log.debug("Ownership: detail bundle tidak terambil", player.Name)
		end
	end

	log.debug("Ownership", #unowned, "aset belum dimiliki", player.Name)
	return {
		ok = true,
		unowned = unowned,
		unownedBundles = unownedBundles,
		items = items,
		bundles = bundleInfo,
	}
end

-- 5d. Wardrobe: { op, ... } -> { ok, outfits?, outfit?, settings?, max? } | { ok = false, code }.
-- Flag mati / data pemain mati -> DISABLED. save & rename YIELD (filter teks).
Remotes.func(RemoteNames.Functions.Wardrobe).OnServerInvoke = function(player: Player, raw: any)
	if not wardrobeLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	if wardrobe == nil then
		return { ok = false, code = "DISABLED" }
	end
	local req, err = WardrobeValidator.validate(raw)
	if not req then
		log.debug("Wardrobe ditolak", err, player.Name)
		return { ok = false, code = err or "BAD_ARG" }
	end
	local pOk, res = pcall(wardrobe.handle, wardrobe, player, req)
	if not pOk then
		log.error("Wardrobe error", res, player.Name)
		return { ok = false, code = "FAILED" }
	end
	if not res.ok then
		log.debug("Wardrobe", req.op, res.code, player.Name)
	end
	return res
end

-- 5d2. RobloxOutfit: { op = "state" | "wear", outfitId } -> { ok, state? } | { ok = false, code }.
-- Daftar outfit Roblox HANYA bisa diambil di client (spike 19 Sep 2026: GetOutfits di server ->
-- "This method can only be called on the client"), tapi description-nya JUSTRU bisa di server
-- (266 ms). Jadi client cukup mengirim outfitId; server yang mengubahnya jadi OutfitState, dan
-- server tetap sumber kebenaran (client tidak pernah mengirim state jadi).
--   op = "state"    -> untuk menggambar kartu loader (outfit TERENKODE, siap dipakai OutfitPreview)
--   op = "wear"     -> pakai look-nya (bisa di-Undo)
--   op = "user"     -> { name } / { userId } -> avatar yang SEDANG dipakai pemain lain
--   op = "wearUser" -> pakai avatar pemain lain itu
--   op = "userOutfits" -> { userId } -> daftar outfit tersimpan pemain lain (lewat proxy)
local function robloxOutfitState(outfitId: number): (boolean, any)
	local ok, desc = api:getDescriptionFromOutfitId(outfitId) -- yield
	if not ok then
		local code = if type(desc) == "table" and type(desc.code) == "string" then desc.code else "FAILED"
		return false, code
	end
	local sOk, state = pcall(DescriptionBuilder.fromDescription, desc)
	if not sOk then
		log.error("RobloxOutfit fromDescription gagal", state)
		return false, "FAILED"
	end
	return true, state
end

-- Avatar yang SEDANG dipakai pemain lain. Daftar OUTFIT tersimpan milik orang lain TIDAK bisa
-- diambil dari dalam game (GetOutfits hanya untuk pemain sendiri, dan API web avatar.roblox.com
-- tidak bisa dipanggil HttpService) -> loader hanya menawarkan "Current Avatar" orang itu.
local function robloxUser(player: Player, op: string, raw: any): any
	local userId = raw.userId
	if type(userId) ~= "number" then
		local name = raw.name
		if type(name) ~= "string" then
			return { ok = false, code = "BAD_ARG" }
		end
		name = string.match(name, "^%s*(.-)%s*$") or name
		if #name < 3 or #name > 20 then
			return { ok = false, code = "BAD_NAME" }
		end
		local okId, id = api:getUserIdFromName(name)
		if not okId then
			return { ok = false, code = "NO_USER" }
		end
		userId = id
	end
	if userId <= 0 or userId % 1 ~= 0 then
		return { ok = false, code = "BAD_ARG" }
	end
	local okDesc, desc = api:getDescriptionFromUserId(userId) -- yield
	if not okDesc then
		return { ok = false, code = "NOT_FOUND" }
	end
	local sOk, state = pcall(DescriptionBuilder.fromDescription, desc)
	if not sOk then
		log.error("RobloxOutfit user fromDescription gagal", state)
		return { ok = false, code = "FAILED" }
	end
	if op == "wearUser" then
		local wOk, code = avatar:wearOutfit(player, state)
		if not wOk then
			return { ok = false, code = code or "FAILED" }
		end
		log.info("RobloxOutfit wearUser", userId, player.Name)
	end
	return { ok = true, userId = userId, state = PlayerData.encodeOutfit(state) }
end

Remotes.func(RemoteNames.Functions.RobloxOutfit).OnServerInvoke = function(player: Player, raw: any)
	if not robloxOutfitLimiter:take(player.UserId) then
		return { ok = false, code = "RATE_LIMITED" }
	end
	if type(raw) ~= "table" then
		return { ok = false, code = "BAD_ARG" }
	end
	local op, outfitId = raw.op, raw.outfitId
	if op == "user" or op == "wearUser" then
		return robloxUser(player, op, raw)
	end
	if op == "userOutfits" then
		-- daftar outfit tersimpan pemain lain (lewat proxy; boleh gagal tanpa merusak panel)
		local uid = raw.userId
		if type(uid) ~= "number" or uid <= 0 or uid % 1 ~= 0 or uid > 2 ^ 53 then
			return { ok = false, code = "BAD_ARG" }
		end
		local okList, list = api:getUserOutfits(uid) -- yield
		if not okList then
			log.debug("RobloxOutfit userOutfits gagal", uid, player.Name)
			return { ok = false, code = "PROXY" }
		end
		return { ok = true, outfits = list }
	end
	if op ~= "state" and op ~= "wear" then
		return { ok = false, code = "BAD_ARG" }
	end
	if type(outfitId) ~= "number" or outfitId <= 0 or outfitId % 1 ~= 0 or outfitId > 2 ^ 53 then
		return { ok = false, code = "BAD_ARG" }
	end
	local ok, res = robloxOutfitState(outfitId)
	if not ok then
		log.debug("RobloxOutfit", op, outfitId, res, player.Name)
		return { ok = false, code = res }
	end
	if op == "state" then
		-- kartu memakai OutfitPreview, yang menunggu outfit TERENKODE (PlayerData.encodeOutfit),
		-- bukan OutfitState mentah. Kirim state mentah -> "outfit tidak valid: version".
		return { ok = true, state = PlayerData.encodeOutfit(res) }
	end
	-- outfit Roblox tidak membawa makeup (makeup = Decal, di luar HumanoidDescription) -> makeup
	-- yang sedang dipakai dibersihkan, sama seperti memakai slot wardrobe tanpa makeup.
	local wOk, code = avatar:wearOutfit(player, res)
	if not wOk then
		return { ok = false, code = code or "FAILED" }
	end
	log.info("RobloxOutfit wear", outfitId, player.Name)
	return { ok = true, state = PlayerData.encodeOutfit(res) }
end

-- 5e. Muat data pemain lalu pasang outfit terakhir (YIELD). Gagal -> tetap avatar asli.
local function loadPlayerData(player: Player)
	if playerData == nil or not playerData:load(player) then
		return
	end
	local settings = playerData:getSettings(player)
	local wants = settings ~= nil and settings.restoreOutfit
	local saved = if wants then playerData:getLastOutfit(player) else nil
	-- baris makeup tersimpan -> texture & template diambil ulang (YIELD) supaya versi terbaru dipakai
	local savedMakeup = nil
	if wants then
		local rows = playerData:getLastMakeup(player)
		if #rows > 0 then
			savedMakeup = makeup:resolveRows(rows)
		end
	end
	if saved or savedMakeup then
		local ok, code = avatar:restore(player, saved, savedMakeup)
		log.info("restore look", ok, code, player.Name)
		if ok then
			return -- onState sudah menyimpan
		end
	end
	-- tidak di-restore (tidak ada / setting mati / pemain sudah mengubah): simpan yang sekarang
	local current = avatar:getState(player)
	if current then
		saveLook(player, current, avatar:getMakeup(player))
	end
end

-- 5e-2. Template makeup untuk PREVIEW 3D (kartu wardrobe, hover katalog, Community Outfits).
-- Spike preview-rig: rig preview dibangun DI CLIENT dan meng-clone template Decal dari
-- ReplicatedStorage/MakeupTemplates. Template hanya ada di sana kalau server pernah me-resolve-nya,
-- jadi saat pemain join kita resolve dulu semua makeup yang dia punya (30 slot + look terakhir).
-- YIELD ke InsertService -> WAJIB di task.spawn sendiri supaya tidak menahan restore look.
local function prewarmPreviewMakeup(player: Player)
	if playerData == nil then
		return
	end
	local ids: { number } = {}
	local function collect(rows: any)
		if type(rows) ~= "table" then
			return
		end
		for _, row in rows do
			if type(row) == "table" and type(row.assetId) == "number" then
				table.insert(ids, row.assetId)
			end
		end
	end
	collect(playerData:getLastMakeup(player))
	local summaries = playerData:listOutfits(player)
	if summaries then
		for _, summary in summaries do
			local _state, rows = playerData:getOutfitLook(player, summary.id)
			collect(rows)
		end
	end
	if #ids == 0 then
		return
	end
	local ready = makeup:prewarm(ids) -- yield; id ganda & yang sudah punya template dilewati
	log.info("prewarm makeup preview", ready, #ids, player.Name)
end

-- 5e-3. Latar area preview yang tersimpan: kirim ulang saat pemain join.
-- YIELD (InsertService) -> ikut task.spawn yang sama dengan prewarm makeup.
local function restoreBackground(player: Player)
	if playerData == nil then
		return
	end
	local assetId = playerData:getBackground(player)
	if assetId == nil then
		return
	end
	local ok, code = pushBackground(player, assetId)
	log.info("restore latar", ok, code, player.Name)
end

-- 5f. Sesi avatar per pemain. attach yield (ambil avatar asli) -> task.spawn.
local function onPlayerAdded(player: Player)
	makeup:attach(player) -- sebelum avatar: onApplied bisa terpanggil saat attach
	local ok, err = pcall(avatar.attach, avatar, player)
	if not ok then
		log.error("attach gagal", err, player.Name)
	end
	local dOk, dErr = pcall(loadPlayerData, player)
	if not dOk then
		log.error("data pemain gagal", dErr, player.Name)
	end
	task.spawn(function()
		local bOk, bErr = pcall(restoreBackground, player)
		if not bOk then
			log.warn("restore latar gagal", bErr, player.Name)
		end
		local pOk, pErr = pcall(prewarmPreviewMakeup, player)
		if not pOk then
			log.warn("prewarm makeup gagal", pErr, player.Name)
		end
	end)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	avatar:detach(player)
	makeup:detach(player)
	lastMakeupSent[player] = nil
	if playerData then
		playerData:release(player) -- outfit terakhir sudah ada di profil (saveOutfit)
	end
	intentLimiter:reset(player.UserId)
	searchLimiter:reset(player.UserId)
	stateLimiter:reset(player.UserId)
	bundleLimiter:reset(player.UserId)
	detailLimiter:reset(player.UserId)
	recLimiter:reset(player.UserId)
	checkoutLimiter:reset(player.UserId)
	wardrobeLimiter:reset(player.UserId)
	ownershipLimiter:reset(player.UserId)
	checkout:forget(player)
	if wardrobe then
		wardrobe:forget(player)
	end
end)

-- Ambil rules avatar sekali di awal supaya klik pertama tidak menunggu.
task.spawn(function()
	rules:maxPerType()
end)

-- 6. Inspeksi API asli: hanya Studio + Play + Features.DevInspect (cek di dalam Inspect.run).
task.spawn(Inspect.run, api)

log.info("siap")
