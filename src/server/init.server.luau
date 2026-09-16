--!strict
-- Titik masuk server (SEMENTARA). Akan diganti loader service di feature/catalog-browse.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local RemoteNames = require(Shared.Net.RemoteNames)
local RateLimiter = require(Shared.Util.RateLimiter)
local Log = require(Shared.Util.Log)
local IntentValidator = require(script.Validators.IntentValidator)
local RobloxApi = require(script.Gateways.RobloxApi)
local Inspect = require(script.Dev.Inspect)

local log = Log.new("Server")

-- 1. Buat semua remote sebelum client membutuhkannya.
Remotes.init()

-- 2. Penjaga AvatarIntent: rate limit -> validasi. (AvatarService menyusul di feature/tryon-layered)
local intentLimiter = RateLimiter.fromLimits(RemoteNames.Events.AvatarIntent)

Remotes.event(RemoteNames.Events.AvatarIntent).OnServerEvent:Connect(function(player: Player, raw: any)
	if not intentLimiter:take(player.UserId) then
		log.warn("DITOLAK RATE_LIMITED", player.Name)
		return
	end
	local intent, err = IntentValidator.validate(raw)
	if not intent then
		log.warn("DITOLAK", err, player.Name)
		return
	end
	log.info("DITERIMA", intent.op, player.Name)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	intentLimiter:reset(player.UserId)
end)

-- 3. Gateway API Roblox (satu instance untuk seluruh server).
local api = RobloxApi.new()

-- 4. Inspeksi API asli: hanya Studio + Play + Features.DevInspect (cek di dalam Inspect.run).
task.spawn(Inspect.run, api)

log.info("siap")
