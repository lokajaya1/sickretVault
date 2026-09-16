--!strict
-- Data pemain (DataStore) lewat ProfileStore (loleris): session lock, auto save berkala, BindToClose.
--   local store = ProfileStore.New(PlayerDataService.STORE_NAME, PlayerData.TEMPLATE)
--   local data = PlayerDataService.new({ store = store })
--   data:load(player)                       -- saat join (YIELD). false = main tanpa simpan
--   data:getLastOutfit(player)              -- OutfitState? (sudah divalidasi)
--   data:setLastOutfit(player, state | nil) -- dipanggil setiap state berubah (murah, tanpa yield)
--   data:release(player)                    -- saat PlayerRemoving (ProfileStore menyimpan & melepas lock)
-- Auto save berkala (AUTO_SAVE_PERIOD, bawaan 300 dtk), simpan saat EndSession & saat server mati
-- sudah ditangani ProfileStore sendiri.
-- Di Studio tanpa "Enable Studio Access to API Services", ProfileStore otomatis memakai
-- penyimpanan palsu (data hilang saat Stop).

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Types = require(Shared.Domain.Types)
local PlayerData = require(Shared.Domain.PlayerData)
local Log = require(Shared.Util.Log)

local log = Log.new("PlayerData")

type State = Types.OutfitState

export type Deps = {
	store: any, -- ProfileStore (StartSessionAsync) atau ProfileStore.Mock
	kick: ((player: any, message: string) -> ())?, -- default player:Kick
}

type Session = {
	profile: any,
	newer: boolean, -- data dari versi server lebih baru -> jangan ditulis
}

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

-- Ganti nama store = mulai dari data kosong. Jangan diubah setelah rilis.
PlayerDataService.STORE_NAME = "PlayerData_v1"

export type PlayerDataService = typeof(setmetatable(
	{} :: {
		_store: any,
		_kick: (any, string) -> (),
		_sessions: { [any]: Session },
		_loading: { [any]: boolean },
	},
	PlayerDataService
))

function PlayerDataService.new(deps: Deps): PlayerDataService
	assert(deps and deps.store, "PlayerDataService butuh deps.store")
	return setmetatable({
		_store = deps.store,
		_kick = deps.kick or function(player: any, message: string)
			player:Kick(message)
		end,
		_sessions = {},
		_loading = {},
	}, PlayerDataService)
end

function PlayerDataService.keyFor(userId: number): string
	return "Player_" .. tostring(userId)
end

-- Muat profil (YIELD). Return (true) | (false, "LOAD_FAILED" | "LEFT" | "BUSY").
function PlayerDataService.load(self: PlayerDataService, player: any): (boolean, string?)
	if self._sessions[player] then
		return true, nil
	end
	if self._loading[player] then
		return false, "BUSY"
	end
	self._loading[player] = true
	-- Bila profil masih terkunci server lain, ProfileStore meminta server itu menyimpan & melepas dulu.
	-- Cancel: berhenti mencoba bila pemain sudah keluar.
	local ok, profile = pcall(self._store.StartSessionAsync, self._store, PlayerDataService.keyFor(player.UserId), {
		Cancel = function()
			return player.Parent == nil
		end,
	})
	self._loading[player] = nil
	if player.Parent == nil then
		if ok and profile ~= nil then
			profile:EndSession() -- keluar saat menunggu
		end
		return false, "LEFT"
	end
	if not ok or profile == nil then
		-- tidak di-kick: game tetap bisa dipakai, hanya outfit tidak tersimpan
		log.warn("profil gagal dimuat", player.Name, if ok then "nil" else profile)
		return false, "LOAD_FAILED"
	end
	profile:AddUserId(player.UserId) -- GDPR
	profile:Reconcile()
	local _, newer = PlayerData.migrate(profile.Data)
	if newer then
		log.warn("data dari versi lebih baru, tidak akan ditulis", player.Name, profile.Data.v)
	end
	local session: Session = { profile = profile, newer = newer }
	self._sessions[player] = session
	profile.OnSessionEnd:Connect(function()
		-- berakhir BUKAN lewat release() kita -> sesi diambil server lain
		if self._sessions[player] == session then
			self._sessions[player] = nil
			self._kick(player, "Data kamu dibuka di server lain. Silakan join ulang.")
		end
	end)
	return true, nil
end

function PlayerDataService.isLoaded(self: PlayerDataService, player: any): boolean
	return self._sessions[player] ~= nil
end

function PlayerDataService.getSettings(self: PlayerDataService, player: any): PlayerData.Settings?
	local session = self._sessions[player]
	if session == nil or session.newer then
		return nil
	end
	return table.clone(session.profile.Data.settings)
end

-- Outfit terakhir yang tersimpan (nil = tidak ada / tidak valid).
function PlayerDataService.getLastOutfit(self: PlayerDataService, player: any): State?
	local session = self._sessions[player]
	if session == nil or session.newer then
		return nil
	end
	local raw = session.profile.Data.lastOutfit
	if raw == nil then
		return nil
	end
	local state, err = PlayerData.decodeOutfit(raw)
	if state == nil then
		log.warn("outfit tersimpan tidak valid, diabaikan", player.Name, err)
	end
	return state
end

-- Tulis ke profile.Data (di memori). ProfileStore yang menyimpan ke DataStore.
-- state = nil -> hapus (pemain memakai avatar asli). Return true bila ditulis.
function PlayerDataService.setLastOutfit(self: PlayerDataService, player: any, state: State?): boolean
	local session = self._sessions[player]
	if session == nil or session.newer or not session.profile:IsActive() then
		return false
	end
	session.profile.Data.lastOutfit = if state then PlayerData.encodeOutfit(state) else nil
	return true
end

function PlayerDataService.release(self: PlayerDataService, player: any)
	local session = self._sessions[player]
	if session == nil then
		return
	end
	self._sessions[player] = nil
	session.profile:EndSession()
end

return PlayerDataService
