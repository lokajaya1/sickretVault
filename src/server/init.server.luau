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

-- Makeup TIDAK bisa lewat HumanoidDescription (spike #18) -> Decal di Head, service sendiri.
local makeup: MakeupService.MakeupService
makeup = MakeupService.new({
	decals = assetDecals,
	itemInfo = itemInfo,
	onState = function(player: Player, dto)
		if player.Parent == Players then
			makeupChanged:FireClient(player, dto)
		end
		if playerData then
			-- yang disimpan cuma assetId + slot; texture diambil ulang saat join
			playerData:setLastMakeup(player, makeup:get(player))
		end
	end,
})

local avatar: AvatarService.AvatarService

-- Simpan outfit terakhir ke profil (di memori; ProfileStore yang menulis ke DataStore).
-- Sama dengan avatar asli -> hapus, supaya ganti avatar di website tetap terlihat saat join.
local function saveOutfit(player: Player, state)
	if playerData then
		playerData:setLastOutfit(player, if avatar:isBaseline(player) then nil else state)
	end
end

avatar = AvatarService.new({
	api = api,
	itemInfo = itemInfo,
	rules = rules,
	bundles = bundles,
	onState = function(player: Player, state)
		if player.Parent == Players then
			stateChanged:FireClient(player, state)
		end
		saveOutfit(player, state)
	end,
	onError = function(player: Player, code: string)
		if player.Parent == Players then
			notify:FireClient(player, { code = code })
		end
	end,
	-- Head bisa berganti saat respawn / apply berhasil -> decal makeup dipasang ulang.
	onApplied = function(player: Player)
		makeup:reapply(player)
	end,
})

-- Wardrobe (slot outfit) butuh data pemain.
local wardrobe = if playerData and Features.Wardrobe
	then WardrobeService.new({ playerData = playerData, avatar = avatar, items = OutfitItemsService.new({ api = api }) })
	else nil

-- 3. Rate limiter per remote (preset dari Limits.Rate).
local intentLimiter = RateLimiter.fromLimits(RemoteNames.Events.AvatarIntent)
local searchLimiter = RateLimiter.fromLimits(RemoteNames.Functions.CatalogSearch)
local stateLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetState)
local bundleLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetBundle)
local detailLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetItemDetail)
local checkoutLimiter = RateLimiter.fromLimits(RemoteNames.Functions.Checkout)
local wardrobeLimiter = RateLimiter.fromLimits(RemoteNames.Functions.Wardrobe)

-- 4a. Intent makeup dibelokkan ke MakeupService (tidak bisa lewat HumanoidDescription).
--     wear : dicoba ke makeup dulu; UNSUPPORTED_TYPE = bukan makeup -> diteruskan ke AvatarService.
--            (ItemInfoService punya cache, jadi pemeriksaan tipe dua kali tidak menambah request)
--     remove: hanya dibelokkan bila id itu memang sedang dipakai sebagai makeup.
--     reset : makeup dibersihkan, lalu outfit direset seperti biasa.
local function routeIntent(player: Player, intent: any): (boolean, string?)
	local op = intent.op
	if op == "wear" then
		local ok, code = makeup:wear(player, intent.assetId)
		if ok or code ~= "UNSUPPORTED_TYPE" then
			return ok, code
		end
	elseif op == "remove" then
		if makeup:isWorn(player, intent.assetId) then
			return makeup:remove(player, intent.assetId)
		end
	elseif op == "reset" then
		local okMakeup = makeup:clear(player)
		local okAvatar, code = avatar:handle(player, intent)
		if okMakeup and not okAvatar and code == "NOTHING" then
			return true, nil -- makeup memang dibersihkan, walau outfit sudah sama dengan avatar asli
		end
		return okAvatar, code
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
	return { ok = true, state = state, makeup = makeup:dto(player) }
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

-- 5e. Muat data pemain lalu pasang outfit terakhir (YIELD). Gagal -> tetap avatar asli.
local function loadPlayerData(player: Player)
	if playerData == nil or not playerData:load(player) then
		return
	end
	local settings = playerData:getSettings(player)
	local saved = if settings and settings.restoreOutfit then playerData:getLastOutfit(player) else nil
	-- makeup dipasang duluan: ia tidak ikut OutfitState, jadi tidak terpengaruh restore/apply di bawah
	if settings and settings.restoreOutfit then
		local okMakeup, codeMakeup = makeup:restore(player, playerData:getLastMakeup(player))
		if okMakeup or codeMakeup ~= "NOTHING" then
			log.info("restore makeup", okMakeup, codeMakeup, player.Name)
		end
	end
	if saved then
		local ok, code = avatar:restore(player, saved)
		log.info("restore outfit", ok, code, player.Name)
		if ok then
			return -- onState sudah menyimpan
		end
	end
	-- tidak di-restore (tidak ada / setting mati / pemain sudah mengubah): simpan yang sekarang
	local current = avatar:getState(player)
	if current then
		saveOutfit(player, current)
	end
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
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	avatar:detach(player)
	makeup:detach(player)
	if playerData then
		playerData:release(player) -- outfit terakhir sudah ada di profil (saveOutfit)
	end
	intentLimiter:reset(player.UserId)
	searchLimiter:reset(player.UserId)
	stateLimiter:reset(player.UserId)
	bundleLimiter:reset(player.UserId)
	detailLimiter:reset(player.UserId)
	checkoutLimiter:reset(player.UserId)
	wardrobeLimiter:reset(player.UserId)
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
