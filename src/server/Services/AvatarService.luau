--!strict
-- Layanan avatar (server): simpan OutfitState per pemain, jalankan intent, terapkan ke karakter.
--   local avatar = AvatarService.new({ api = api, itemInfo = itemInfo, bundles = bundles, onState = kirimKeClient })
--   avatar:attach(player)                        -- saat PlayerAdded (yield: ambil avatar asli)
--   local ok, code = avatar:handle(player, intent) -- intent SUDAH lolos IntentValidator
--   avatar:detach(player)                        -- saat PlayerRemoving
-- LOOK = outfit (OutfitState, bisa ke HumanoidDescription) + makeup (Decal di Head, tidak bisa).
-- Keduanya satu timeline undo/redo supaya tombol Undo jujur; OutfitState sendiri TETAP murni
-- cermin HumanoidDescription (makeup tidak pernah masuk DescriptionBuilder).
-- Apply description hanya dipicu perubahan OUTFIT: ganti makeup tidak boleh mengganti Head.
-- Alur: intent -> look baru (murni) -> onState(player, state, makeup) -> apply ter-debounce.
-- Apply gagal -> state dikembalikan ke state terakhir yang berhasil, onState dipanggil lagi + onError.
-- Semua akses engine lewat `deps` supaya bisa dites di Lune.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Types = require(Shared.Domain.Types)
local OutfitState = require(Shared.Domain.OutfitState)
local Makeup = require(Shared.Domain.Makeup)
local DescriptionBuilder = require(Shared.Avatar.DescriptionBuilder)
local Limits = require(Shared.Config.Limits)
local Log = require(Shared.Util.Log)

local log = Log.new("AvatarService")

type State = Types.OutfitState
type MakeupState = Makeup.State

-- Satu titik di timeline undo/redo.
export type Look = { state: State, makeup: MakeupState }

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
	| "CHANGED"

export type Deps = {
	api: any, -- RobloxApi (getDescriptionFromUserId, applyDescription)
	itemInfo: any, -- ItemInfoService
	rules: any?, -- AvatarRules (batas per tipe); nil = tanpa batas per tipe
	bundles: any?, -- BundleService (get); nil = bundle belum didukung (NOT_IMPLEMENTED)
	onState: ((player: any, state: State, makeup: MakeupState) -> ())?, -- kirim StateChanged + MakeupChanged
	applyMakeup: ((player: any, makeup: MakeupState) -> ())?, -- MakeupService.apply (TANPA yield)
	onError: ((player: any, code: string) -> ())?, -- kirim Notify
	-- dipanggil setiap Head pemain mungkin berganti (respawn / apply berhasil):
	-- dipakai MakeupService untuk menempelkan ulang Decal makeup.
	onApplied: ((player: any) -> ())?,
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
	makeup: MakeupState, -- makeup yang sedang dipakai (di luar HumanoidDescription)
	undo: { Look },
	redo: { Look },
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
		_onState: (any, State, MakeupState) -> (),
		_applyMakeup: (any, MakeupState) -> (),
		_onError: (any, string) -> (),
		_onApplied: (any) -> (),
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
		_applyMakeup = deps.applyMakeup or function() end,
		_onError = deps.onError or function() end,
		_onApplied = deps.onApplied or function() end,
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
		makeup = Makeup.empty(),
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
	self._onState(player, session.state, session.makeup)
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
	self._onApplied(player) -- Head baru: decal makeup ikut hilang bersama Head lama
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

-- Pindah ke look baru: dorong look sekarang ke undo, kabarkan, lalu kerjakan AKIBATNYA.
-- Outfit berubah -> apply description (debounce). Makeup berubah -> tempel decal (tanpa yield).
-- `nextMakeup` nil = makeup tidak berubah.
local function commit(self: AvatarService, player: any, session: Session, nextState: State, nextMakeup: MakeupState?)
	local makeup = nextMakeup or session.makeup
	table.insert(session.undo, { state = session.state, makeup = session.makeup })
	while #session.undo > Limits.UndoDepth do
		table.remove(session.undo, 1)
	end
	table.clear(session.redo)
	local outfitChanged = not sameLook(nextState, session.state)
	local makeupChanged = not Makeup.equals(makeup, session.makeup)
	session.state = nextState
	session.makeup = makeup
	self._onState(player, nextState, makeup)
	if makeupChanged then
		self._applyMakeup(player, makeup)
	end
	if outfitChanged then
		self:_schedule(player)
	end
end

-- Pindah ke look dari tumpukan undo/redo (tanpa mendorong apa pun ke tumpukan).
local function jumpTo(self: AvatarService, player: any, session: Session, target: Look)
	local outfitChanged = not sameLook(target.state, session.state)
	local makeupChanged = not Makeup.equals(target.makeup, session.makeup)
	session.state = target.state
	session.makeup = target.makeup
	self._onState(player, session.state, session.makeup)
	if makeupChanged then
		self._applyMakeup(player, session.makeup)
	end
	if outfitChanged then
		self:_schedule(player)
	end
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
		-- makeup hidup di luar OutfitState -> dicek lebih dulu
		if Makeup.hasAsset(session.makeup, i.assetId) then
			commit(self, player, session, session.state, Makeup.removeAsset(session.makeup, i.assetId))
			return true, nil
		end
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
		if sameLook(session.state, session.baseline) and Makeup.isEmpty(session.makeup) then
			return false, "NOTHING"
		end
		commit(self, player, session, OutfitState.clone(session.baseline), Makeup.empty())
		return true, nil
	elseif op == "undo" or op == "redo" then
		local from = if op == "undo" then session.undo else session.redo
		local to = if op == "undo" then session.redo else session.undo
		local target = table.remove(from)
		if target == nil then
			return false, "NOTHING"
		end
		table.insert(to, { state = session.state, makeup = session.makeup })
		jumpTo(self, player, session, target)
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

-- ===== Makeup (di luar HumanoidDescription, satu timeline dengan outfit) =====

-- `entry` = hasil MakeupService.resolve ({ assetId, slot, textureId }). Bisa di-Undo seperti item lain.
function AvatarService.wearMakeup(self: AvatarService, player: any, entry: any): (boolean, Code?)
	local session = self._sessions[player]
	if session == nil or not session.ready then
		return false, "NOT_READY"
	end
	if type(entry) ~= "table" then
		return false, "FAILED"
	end
	local current = Makeup.get(session.makeup, entry.slot)
	if current and current.assetId == entry.assetId then
		return false, "NOTHING" -- sudah dipakai di slot itu
	end
	local nextMakeup, err = Makeup.set(session.makeup, entry)
	if nextMakeup == nil then
		log.warn("entry makeup ditolak", entry.assetId, err)
		return false, "FAILED"
	end
	commit(self, player, session, session.state, nextMakeup)
	return true, nil
end

function AvatarService.getMakeup(self: AvatarService, player: any): MakeupState
	local session = self._sessions[player]
	return if session and session.ready then session.makeup else Makeup.empty()
end

function AvatarService.isMakeupWorn(self: AvatarService, player: any, assetId: number): boolean
	return Makeup.hasAsset(self:getMakeup(player), assetId)
end

-- true bila look sekarang tampak sama dengan avatar asli (tidak perlu disimpan).
function AvatarService.isBaseline(self: AvatarService, player: any): boolean
	local session = self._sessions[player]
	return session ~= nil
		and session.ready
		and sameLook(session.state, session.baseline)
		and Makeup.isEmpty(session.makeup)
end

-- Pasang look tersimpan saat join (Undo kembali ke avatar asli).
-- Hanya bila pemain BELUM mengubah apa pun, supaya data yang telat dimuat tidak menimpa pilihannya.
-- `state` nil = outfit tidak berubah (mis. cuma makeup yang tersimpan).
function AvatarService.restore(self: AvatarService, player: any, state: State?, makeup: MakeupState?): (boolean, Code?)
	local session = self._sessions[player]
	if session == nil or not session.ready then
		return false, "NOT_READY"
	end
	if
		#session.undo > 0
		or #session.redo > 0
		or not sameLook(session.state, session.baseline)
		or not Makeup.isEmpty(session.makeup)
	then
		return false, "CHANGED"
	end
	local target = state or session.state
	local nextMakeup = makeup or Makeup.empty()
	if sameLook(target, session.state) and Makeup.equals(nextMakeup, session.makeup) then
		return false, "NOTHING"
	end
	commit(self, player, session, OutfitState.clone(target), nextMakeup)
	return true, nil
end

-- Pakai LOOK dari slot wardrobe (sudah divalidasi PlayerData.decodeOutfit + resolveRows). Bisa di-Undo.
-- `makeup` nil = slot tanpa makeup -> makeup yang sedang dipakai DIBERSIHKAN (slot = look utuh).
-- Return (true) | (false, "NOT_READY" | "NOTHING").
function AvatarService.wearOutfit(
	self: AvatarService,
	player: any,
	state: State,
	makeup: MakeupState?
): (boolean, Code?)
	local session = self._sessions[player]
	if session == nil or not session.ready then
		return false, "NOT_READY"
	end
	local nextMakeup = makeup or Makeup.empty()
	if sameLook(state, session.state) and Makeup.equals(nextMakeup, session.makeup) then
		return false, "NOTHING" -- sudah dipakai
	end
	commit(self, player, session, OutfitState.clone(state), nextMakeup)
	return true, nil
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
			self._onApplied(player)
		elseif session.state == target then
			-- gagal & tidak ada perubahan baru: kembalikan ke yang terakhir berhasil
			log.warn("apply gagal, rollback", player.Name, err and err.message)
			session.state = session.applied
			self._onState(player, session.state, session.makeup)
			self._onError(player, "APPLY_FAILED")
		end
	until not session.dirty
	session.applying = false
end

return AvatarService
