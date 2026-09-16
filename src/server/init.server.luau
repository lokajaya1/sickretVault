--!strict
-- Titik masuk server: buat remote, rakit service, sambungkan handler remote.
-- Urutan penting: Remotes.init() dulu, baru service & handler.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local RemoteNames = require(Shared.Net.RemoteNames)
local RateLimiter = require(Shared.Util.RateLimiter)
local Log = require(Shared.Util.Log)
local IntentValidator = require(script.Validators.IntentValidator)
local RobloxApi = require(script.Gateways.RobloxApi)
local CatalogService = require(script.Services.CatalogService)
local ItemInfoService = require(script.Services.ItemInfoService)
local BundleService = require(script.Services.BundleService)
local ItemDetailService = require(script.Services.ItemDetailService)
local CheckoutService = require(script.Services.CheckoutService)
local AvatarService = require(script.Services.AvatarService)
local AvatarRules = require(script.Services.AvatarRules)
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

local stateChanged = Remotes.event(RemoteNames.Events.StateChanged)
local notify = Remotes.event(RemoteNames.Events.Notify)
local checkoutResult = Remotes.event(RemoteNames.Events.CheckoutResult)

-- Checkout keranjang: PromptBulkPurchase dari server, hasil akhir -> CheckoutResult (hanya untuk UI).
local checkout = CheckoutService.new({
	onResult = function(player: Player, summary)
		if player.Parent == Players then
			checkoutResult:FireClient(player, summary)
		end
	end,
})

local avatar = AvatarService.new({
	api = api,
	itemInfo = itemInfo,
	rules = rules,
	bundles = bundles,
	onState = function(player: Player, state)
		if player.Parent == Players then
			stateChanged:FireClient(player, state)
		end
	end,
	onError = function(player: Player, code: string)
		if player.Parent == Players then
			notify:FireClient(player, { code = code })
		end
	end,
})

-- 3. Rate limiter per remote (preset dari Limits.Rate).
local intentLimiter = RateLimiter.fromLimits(RemoteNames.Events.AvatarIntent)
local searchLimiter = RateLimiter.fromLimits(RemoteNames.Functions.CatalogSearch)
local stateLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetState)
local bundleLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetBundle)
local detailLimiter = RateLimiter.fromLimits(RemoteNames.Functions.GetItemDetail)
local checkoutLimiter = RateLimiter.fromLimits(RemoteNames.Functions.Checkout)

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
	local pOk, ok, code = pcall(avatar.handle, avatar, player, intent)
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
	return { ok = true, state = state }
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
-- ok = true artinya prompt tampil; hasil pembelian menyusul lewat event CheckoutResult.
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

-- 5d. Sesi avatar per pemain. attach yield (ambil avatar asli) -> task.spawn.
local function onPlayerAdded(player: Player)
	local ok, err = pcall(avatar.attach, avatar, player)
	if not ok then
		log.error("attach gagal", err, player.Name)
	end
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	avatar:detach(player)
	checkout:release(player)
	intentLimiter:reset(player.UserId)
	searchLimiter:reset(player.UserId)
	stateLimiter:reset(player.UserId)
	bundleLimiter:reset(player.UserId)
	detailLimiter:reset(player.UserId)
	checkoutLimiter:reset(player.UserId)
end)

-- Ambil rules avatar sekali di awal supaya klik pertama tidak menunggu.
task.spawn(function()
	rules:maxPerType()
end)

-- 6. Inspeksi API asli: hanya Studio + Play + Features.DevInspect (cek di dalam Inspect.run).
task.spawn(Inspect.run, api)

log.info("siap")
