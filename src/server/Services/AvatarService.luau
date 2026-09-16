--!strict
-- Layanan avatar (server): simpan OutfitState per pemain, jalankan intent, terapkan ke karakter.
--   local avatar = AvatarService.new({ api = api, itemInfo = itemInfo, bundles = bundles, onState = kirimKeClient })
--   avatar:attach(player)                        -- saat PlayerAdded (yield: ambil avatar asli)
--   local ok, code = avatar:handle(player, intent) -- intent SUDAH lolos IntentValidator
--   avatar:detach(player)                        -- saat PlayerRemoving
-- Alur: intent -> state baru (murni) -> onState(player, state) -> apply ter-debounce (Limits.ApplyDebounce).
-- Apply gagal -> state dikembalikan ke state terakhir yang berhasil, onState dipanggil lagi + onError.
-- Semua akses engine lewat `deps` supaya bisa dites di Lune.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Types = require(Shared.Domain.Types)
local OutfitState = require(Shared.Domain.OutfitState)
local DescriptionBuilder = require(Shared.Avatar.DescriptionBuilder)
local Limits = require(Shared.Config.Limits)
local Log = require(Shared.Util.Log)

local log = Log.new("AvatarService")

type State = Types.OutfitState

export type Code =
	"NOT_READY"
	| "NOT_FOUND"
	| "FAILED"
	| "UNSUPPORTED_TYPE"
	| "LIMIT_RIGID"
	| "LIMIT_LAYERED"
	| "LIMIT_TYPE"
	| "NOT_IMPLEMENTED"
	| "NOTHING"
	| "BAD_OP"

export type Deps = {
	api: any, -- RobloxApi (getDescriptionFromUserId, applyDescription)
	itemInfo: any, -- ItemInfoService
	rules: any?, -- AvatarRules (batas per tipe); nil = tanpa batas per tipe
	bundles: any?, -- BundleService (get); nil = bundle belum didukung (NOT_IMPLEMENTED)
	onState: ((player: any, state: State) -> ())?, -- kirim StateChanged
	onError: ((player: any, code: string) -> ())?, -- kirim Notify
	-- engine (default Roblox; diganti saat test)
	build: ((state: State) -> any)?, -- default DescriptionBuilder.toDescription
	fromDescription: ((desc: any, rig: string?) -> State)?,
	getHumanoid: ((player: any) -> any)?,
	delay: ((seconds: number, fn: () -> ()) -> ())?, -- default task.delay
}

type Session = {
	ready: boolean,
	baseline: State, -- avatar asli pemain
	state: State, -- yang diinginkan
	applied: State, -- terakhir berhasil diterapkan (untuk rollback)
	undo: { State },
	redo: { State },
	scheduled: boolean,
	applying: boolean,
	dirty: boolean,
	gen: number, -- naik setiap respawn (hasil apply ke karakter lama diabaikan)
	conns: { any },
}

local AvatarService = {}
AvatarService.__index = AvatarService

export type AvatarService = typeof(setmetatable(
	{} :: {
		_api: any,
		_itemInfo: any,
		_rules: any?,
		_bundles: any?,
		_onState: (any, State) -> (),
		_onError: (any, string) -> (),
		_build: (State) -> any,
		_fromDescription: (any, string?) -> State,
		_getHumanoid: (any) -> any,
		_delay: (number, () -> ()) -> (),
		_sessions: { [any]: Session },
	},
	AvatarService
))

local function defaultGetHumanoid(player: any): any
	local character = player.Character
	if character == nil or character.Parent == nil then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function defaultBuild(state: State): any
	local desc, skipped = DescriptionBuilder.toDescription(state)
	if #skipped > 0 then
		log.warn("aksesori dilewati:", table.concat(skipped, ","))
	end
	return desc
end

function AvatarService.new(deps: Deps): AvatarService
	assert(deps and deps.api and deps.itemInfo, "AvatarService butuh deps.api & deps.itemInfo")
	return setmetatable({
		_api = deps.api,
		_itemInfo = deps.itemInfo,
		_rules = deps.rules,
		_bundles = deps.bundles,
		_onState = deps.onState or function() end,
		_onError = deps.onError or function() end,
		_build = deps.build or defaultBuild,
		_fromDescription = deps.fromDescription or DescriptionBuilder.fromDescription,
		_getHumanoid = deps.getHumanoid or defaultGetHumanoid,
		_delay = deps.delay or function(s: number, fn: () -> ())
			task.delay(s, fn)
		end,
		_sessions = {},
	}, AvatarService)
end

local function sameLook(a: State, b: State): boolean
	local sa = DescriptionBuilder.toSpec(a)
	local sb = DescriptionBuilder.toSpec(b)
	return (DescriptionBuilder.specEquals(sa, sb))
end

-- ===== Sesi =====

-- Buat sesi & ambil avatar asli (yield). Aman dipanggil dua kali.
-- Mengembalikan true bila sesi siap (baseline asli atau fallback kosong).
function AvatarService.load(self: AvatarService, player: any): boolean
	if self._sessions[player] then
		return true
	end
	local empty = OutfitState.empty()
	local session: Session = {
		ready = false,
		baseline = empty,
		state = empty,
		applied = empty,
		undo = {},
		redo = {},
		scheduled = false,
		applying = false,
		dirty = false,
		gen = 0,
		conns = {},
	}
	self._sessions[player] = session

	local ok, desc = self._api:getDescriptionFromUserId(player.UserId)
	if self._sessions[player] ~= session then
		return false -- pemain keluar saat menunggu
	end
	if ok and desc ~= nil then
		local convOk, base = pcall(self._fromDescription, desc, nil)
		if convOk then
			session.baseline = base
		else
			log.warn("gagal membaca avatar asli", player.Name, base)
		end
		if typeof(desc) == "Instance" then
			desc:Destroy()
		end
	else
		log.warn("avatar asli tidak didapat, pakai kosong", player.Name)
	end
	session.state = OutfitState.clone(session.baseline)
	session.applied = OutfitState.clone(session.baseline)
	session.ready = true
	self._onState(player, session.state)
	return true
end

-- Engine: load + pasang ulang outfit setiap respawn.
function AvatarService.attach(self: AvatarService, player: Player)
	if not self:load(player) then
		return
	end
	local session = self._sessions[player]
	table.insert(
		session.conns,
		player.CharacterAppearanceLoaded:Connect(function()
			self:onRespawn(player)
		end)
	)
	-- karakter sudah ada sebelum listener terpasang -> terapkan juga
	if player.Character and player:HasAppearanceLoaded() then
		self:onRespawn(player)
	end
end

function AvatarService.detach(self: AvatarService, player: any)
	local session = self._sessions[player]
	if session == nil then
		return
	end
	for _, c in session.conns do
		c:Disconnect()
	end
	self._sessions[player] = nil
end

-- Karakter baru: Roblox memasang avatar asli -> pasang ulang jika outfit berbeda.
function AvatarService.onRespawn(self: AvatarService, player: any)
	local session = self._sessions[player]
	if session == nil or not session.ready then
		return
	end
	session.gen += 1
	session.applied = OutfitState.clone(session.baseline)
	if not sameLook(session.state, session.baseline) then
		self:_schedule(player)
	end
end

function AvatarService.getState(self: AvatarService, player: any): State?
	local session = self._sessions[player]
	return if session and session.ready then session.state else nil
end

-- ===== Intent =====

-- Ada part bundle yang bisa dipakai (tipe dikenal & termasuk partIds bila diberikan)?
local function hasWearablePart(parts: { Types.BundlePart }, partIds: { number }?): boolean
	local wanted: { [number]: boolean }? = nil
	if partIds then
		local set: { [number]: boolean } = {}
		for _, id in partIds do
			set[id] = true
		end
		wanted = set
	end
	for _, p in parts do
		if p.kind ~= "unknown" and (wanted == nil or (wanted :: { [number]: boolean })[p.assetId]) then
			return true
		end
	end
	return false
end

local function commit(self: AvatarService, player: any, session: Session, nextState: State)
	table.insert(session.undo, session.state)
	while #session.undo > Limits.UndoDepth do
		table.remove(session.undo, 1)
	end
	table.clear(session.redo)
	session.state = nextState
	self._onState(player, nextState)
	self:_schedule(player)
end

-- `intent` harus hasil IntentValidator.validate. Return (true, nil) | (false, Code).
function AvatarService.handle(self: AvatarService, player: any, intent: Types.Intent): (boolean, Code?)
	local session = self._sessions[player]
	if session == nil or not session.ready then
		return false, "NOT_READY"
	end
	local i = intent :: any
	local op = i.op

	if op == "wear" then
		local ok, info = self._itemInfo:get(i.assetId) -- yield
		if self._sessions[player] ~= session then
			return false, "NOT_READY"
		end
		if not ok then
			return false, if info and info.code == "FAILED" then "FAILED" else "NOT_FOUND"
		end
		local limits = if self._rules then self._rules:maxPerType() else nil -- bisa yield (sekali)
		if self._sessions[player] ~= session then
			return false, "NOT_READY"
		end
		local nextState, err = OutfitState.wear(session.state, info.assetId, info.assetType, nil, limits)
		if err then
			return false, err :: any
		end
		if sameLook(nextState, session.state) then
			return false, "NOTHING" -- sudah dipakai
		end
		commit(self, player, session, nextState)
		return true, nil
	elseif op == "remove" then
		local nextState = OutfitState.remove(session.state, i.assetId, session.baseline)
		if sameLook(nextState, session.state) then
			return false, "NOTHING"
		end
		commit(self, player, session, nextState)
		return true, nil
	elseif op == "setLayerOrder" then
		local nextState = OutfitState.setLayerOrder(session.state, i.assetId, i.order)
		if nextState == session.state then
			return false, "NOTHING"
		end
		commit(self, player, session, nextState)
		return true, nil
	elseif op == "reset" then
		if sameLook(session.state, session.baseline) then
			return false, "NOTHING"
		end
		commit(self, player, session, OutfitState.clone(session.baseline))
		return true, nil
	elseif op == "undo" or op == "redo" then
		local from = if op == "undo" then session.undo else session.redo
		local to = if op == "undo" then session.redo else session.undo
		local target = table.remove(from)
		if target == nil then
			return false, "NOTHING"
		end
		table.insert(to, session.state)
		session.state = target
		self._onState(player, target)
		self:_schedule(player)
		return true, nil
	elseif op == "wearBundle" then
		if self._bundles == nil then
			return false, "NOT_IMPLEMENTED"
		end
		local ok, info = self._bundles:get(i.bundleId) -- yield
		if self._sessions[player] ~= session then
			return false, "NOT_READY"
		end
		if not ok then
			return false, if info and info.code == "FAILED" then "FAILED" else "NOT_FOUND"
		end
		if not hasWearablePart(info.parts, i.partIds) then
			return false, "UNSUPPORTED_TYPE"
		end
		local limits = if self._rules then self._rules:maxPerType() else nil -- bisa yield (sekali)
		if self._sessions[player] ~= session then
			return false, "NOT_READY"
		end
		-- skala bundle hanya bila diminta (editor avatar Roblox juga tidak mengubah skala saat pakai bundle)
		local scales = if i.useBundleScales == true then info.outfitScales else nil
		local nextState, errors =
			OutfitState.wearBundle(session.state, info.bundleId, info.parts, i.partIds, scales, limits)
		if sameLook(nextState, session.state) then
			-- tidak ada yang berubah: laporkan error pertama (mis. LIMIT_TYPE), atau sudah dipakai
			return false, (errors[1] or "NOTHING") :: any
		end
		if #errors > 0 then
			log.debug("sebagian part bundle dilewati", info.bundleId, table.concat(errors, ","))
		end
		commit(self, player, session, nextState)
		return true, nil
	elseif op == "removeBundle" then
		-- catatan: skala tidak dikembalikan (P0 tidak memakai skala bundle secara default)
		local nextState = OutfitState.removeBundle(session.state, i.bundleId, session.baseline)
		if sameLook(nextState, session.state) then
			return false, "NOTHING"
		end
		commit(self, player, session, nextState)
		return true, nil
	end
	return false, "BAD_OP"
end

-- ===== Apply (debounce + satu apply per pemain pada satu waktu) =====

function AvatarService._schedule(self: AvatarService, player: any)
	local session = self._sessions[player]
	if session == nil or session.scheduled then
		return
	end
	session.scheduled = true
	self._delay(Limits.ApplyDebounce, function()
		session.scheduled = false
		if self._sessions[player] == session then
			self:_flush(player)
		end
	end)
end

function AvatarService._flush(self: AvatarService, player: any)
	local session = self._sessions[player]
	if session == nil then
		return
	end
	if session.applying then
		session.dirty = true -- apply yang sedang jalan akan mengulang
		return
	end
	session.applying = true
	repeat
		session.dirty = false
		local target = session.state
		if sameLook(target, session.applied) then
			break
		end
		local humanoid = self._getHumanoid(player)
		if humanoid == nil then
			break -- belum ada karakter; onRespawn akan menerapkan nanti
		end
		local gen = session.gen
		local buildOk, desc = pcall(self._build, target)
		local ok, err
		if buildOk then
			ok, err = self._api:applyDescription(humanoid, desc)
			if typeof(desc) == "Instance" then
				desc:Destroy()
			end
		else
			ok, err = false, { code = "FAILED", message = tostring(desc) }
		end
		if self._sessions[player] ~= session then
			return
		end
		if session.gen ~= gen then
			-- karakter berganti saat apply: ulangi untuk karakter baru
			session.dirty = true
		elseif ok then
			session.applied = target
		elseif session.state == target then
			-- gagal & tidak ada perubahan baru: kembalikan ke yang terakhir berhasil
			log.warn("apply gagal, rollback", player.Name, err and err.message)
			session.state = session.applied
			self._onState(player, session.state)
			self._onError(player, "APPLY_FAILED")
		end
	until not session.dirty
	session.applying = false
end

return AvatarService
