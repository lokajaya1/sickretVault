--!strict
-- Layanan makeup (server): simpan makeup per pemain + tempel Decal-nya ke Head.
--   local makeup = MakeupService.new({ decals = assetDecal, itemInfo = itemInfo, onState = kirimKeClient })
--   makeup:attach(player)                         -- saat PlayerAdded
--   local ok, code = makeup:wear(player, assetId) -- yield (itemInfo + InsertService)
--   makeup:reapply(player)                        -- setiap Head berganti (respawn / ApplyDescription)
--   makeup:detach(player)                         -- saat PlayerRemoving
--
-- Kenapa terpisah dari AvatarService/OutfitState (spike 18 Sep 2026):
--   - Makeup TIDAK bisa lewat HumanoidDescription, jadi tidak boleh masuk DescriptionBuilder.
--   - ApplyDescriptionAsync yang mengganti Head MENGHANCURKAN decal (terbukti: decal hidup 0/3),
--     jadi makeup harus dipasang ULANG setiap Head baru -> :reapply().
-- Decal yang dipasang adalah CLONE dari template asli hasil LoadAsset (bukan Decal buatan
-- sendiri): template membawa anak `WrapTextureTransfer` yang memetakan tekstur mengikuti bentuk
-- kepala. Template disimpan per sesi supaya :reapply() tidak perlu menyentuh gateway (tanpa yield).
-- Semua akses engine lewat `deps` supaya bisa dites di Lune.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Makeup = require(Shared.Domain.Makeup)
local Log = require(Shared.Util.Log)

local log = Log.new("MakeupService")

local DECAL_PREFIX = "SV_Makeup_"

export type Code = "NOT_READY" | "NOT_FOUND" | "FAILED" | "UNSUPPORTED_TYPE" | "NOTHING" | "NO_HEAD"

export type Deps = {
	decals: any, -- AssetDecal (getMakeup)
	itemInfo: any, -- ItemInfoService (get -> assetType)
	onState: ((player: any, dto: { any }) -> ())?, -- kirim MakeupChanged
	-- engine (default Roblox; diganti saat test)
	getHead: ((player: any) -> any)?,
	face: any?, -- default Enum.NormalId.Front
}

-- templates[slot] = Decal template (milik gateway; SELALU di-Clone sebelum dipasang)
type Session = { makeup: Makeup.State, templates: { [string]: any } }

local MakeupService = {}
MakeupService.__index = MakeupService

export type MakeupService = typeof(setmetatable(
	{} :: {
		_decals: any,
		_itemInfo: any,
		_onState: (any, { any }) -> (),
		_getHead: (any) -> any,
		_face: any,
		_sessions: { [any]: Session },
	},
	MakeupService
))

local function defaultGetHead(player: any): any
	local character = player.Character
	if character == nil or character.Parent == nil then
		return nil
	end
	return character:FindFirstChild("Head")
end

function MakeupService.new(deps: Deps): MakeupService
	assert(deps and deps.decals and deps.itemInfo, "MakeupService butuh deps.decals & deps.itemInfo")
	return setmetatable({
		_decals = deps.decals,
		_itemInfo = deps.itemInfo,
		_onState = deps.onState or function() end,
		_getHead = deps.getHead or defaultGetHead,
		_face = if deps.face ~= nil then deps.face else Enum.NormalId.Front,
		_sessions = {},
	}, MakeupService)
end

function MakeupService.attach(self: MakeupService, player: any)
	if self._sessions[player] == nil then
		self._sessions[player] = { makeup = Makeup.empty(), templates = {} }
	end
end

function MakeupService.detach(self: MakeupService, player: any)
	self._sessions[player] = nil
end

function MakeupService.get(self: MakeupService, player: any): Makeup.State
	local session = self._sessions[player]
	return if session then session.makeup else Makeup.empty()
end

function MakeupService.dto(self: MakeupService, player: any): { any }
	return Makeup.toDto(self:get(player))
end

-- Buang SEMUA decal milik kita di Head; decal bawaan (mis. 'face') tidak disentuh.
local function stripDecals(head: any)
	for _, child in head:GetChildren() do
		if string.sub(child.Name, 1, #DECAL_PREFIX) == DECAL_PREFIX then
			child:Destroy()
		end
	end
end

-- Pasang ulang semua decal sesuai state. Head belum ada -> dilewati (reapply dipanggil lagi nanti).
function MakeupService.reapply(self: MakeupService, player: any): boolean
	local session = self._sessions[player]
	if session == nil then
		return false
	end
	local head = self._getHead(player)
	if head == nil then
		return false
	end
	stripDecals(head)
	-- Urutan list = face -> eye -> lip (ZIndex tidak terbukti berpengaruh, jadi urutan tempel yang dipakai).
	for _, entry in Makeup.list(session.makeup) do
		local template = session.templates[entry.slot]
		if template == nil then
			log.warn("template makeup hilang", entry.assetId, entry.slot)
			continue
		end
		local decal = template:Clone() -- WAJIB clone: template dipakai bersama semua pemain
		decal.Name = DECAL_PREFIX .. entry.slot
		decal.Face = self._face
		decal.Parent = head
	end
	return true
end

function MakeupService._publish(self: MakeupService, player: any)
	self._onState(player, self:dto(player))
end

-- Pakai satu makeup. YIELD (itemInfo + InsertService). Return (true, nil) | (false, Code).
function MakeupService.wear(self: MakeupService, player: any, assetId: number): (boolean, Code?)
	local session = self._sessions[player]
	if session == nil then
		return false, "NOT_READY"
	end

	local okInfo, info = self._itemInfo:get(assetId) -- yield
	if self._sessions[player] ~= session then
		return false, "NOT_READY"
	end
	if not okInfo then
		return false, if info and info.code == "FAILED" then "FAILED" else "NOT_FOUND"
	end

	local slot = Makeup.slotOf(info.assetType)
	if slot == nil then
		return false, "UNSUPPORTED_TYPE" -- bukan makeup; penelepon salah alamat
	end

	local current = Makeup.get(session.makeup, slot)
	if current and current.assetId == info.assetId then
		return false, "NOTHING" -- sudah dipakai di slot itu
	end

	local okDecal, decalInfo = self._decals:getMakeup(info.assetId) -- yield
	if self._sessions[player] ~= session then
		return false, "NOT_READY"
	end
	if not okDecal then
		local code = if decalInfo and decalInfo.code == "FAILED" then "FAILED" else "NOT_FOUND"
		log.warn("decal makeup gagal", info.assetId, decalInfo and decalInfo.code)
		return false, code :: Code
	end

	local nextState, err = Makeup.set(session.makeup, {
		assetId = info.assetId,
		slot = slot,
		textureId = decalInfo.textureId,
	})
	if nextState == nil then
		log.warn("state makeup ditolak", info.assetId, err)
		return false, "FAILED"
	end

	session.makeup = nextState
	session.templates[slot] = decalInfo.template
	self:reapply(player)
	self:_publish(player)
	return true, nil
end

-- Lepas satu makeup berdasarkan id item. Return (true, nil) | (false, Code).
function MakeupService.remove(self: MakeupService, player: any, assetId: number): (boolean, Code?)
	local session = self._sessions[player]
	if session == nil then
		return false, "NOT_READY"
	end
	if not Makeup.hasAsset(session.makeup, assetId) then
		return false, "NOTHING"
	end
	for _, entry in Makeup.list(session.makeup) do
		if entry.assetId == assetId then
			session.templates[entry.slot] = nil
		end
	end
	session.makeup = Makeup.removeAsset(session.makeup, assetId)
	self:reapply(player)
	self:_publish(player)
	return true, nil
end

-- Lepas semua (dipakai oleh intent reset). Return (true, nil) | (false, "NOTHING").
function MakeupService.clear(self: MakeupService, player: any): (boolean, Code?)
	local session = self._sessions[player]
	if session == nil then
		return false, "NOT_READY"
	end
	if Makeup.isEmpty(session.makeup) then
		return false, "NOTHING"
	end
	session.makeup = Makeup.empty()
	session.templates = {}
	self:reapply(player)
	self:_publish(player)
	return true, nil
end

-- Apakah id ini sedang dipakai sebagai makeup? (dipakai router intent remove)
function MakeupService.isWorn(self: MakeupService, player: any, assetId: number): boolean
	return Makeup.hasAsset(self:get(player), assetId)
end

return MakeupService
