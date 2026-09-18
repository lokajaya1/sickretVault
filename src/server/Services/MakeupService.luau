--!strict
-- Layanan makeup (server): RESOLVER + RENDERER. Pemilik state-nya AvatarService.
--   local makeup = MakeupService.new({ decals = assetDecal, itemInfo = itemInfo })
--   makeup:attach(player)                       -- PlayerAdded
--   local ok, entry = makeup:resolve(assetId)   -- YIELD: id item -> { assetId, slot, textureId }
--   local state = makeup:resolveRows(rows)      -- YIELD: baris tersimpan -> Makeup.State
--   makeup:apply(player, state)                 -- TANPA yield: tempel Decal ke Head
--   makeup:reapply(player)                      -- Head berganti: pasang ulang yang terakhir
--   makeup:detach(player)                       -- PlayerRemoving
--
-- Kenapa state-nya TIDAK di sini (PR makeup-wardrobe):
--   makeup harus ikut Undo/Redo dan ikut slot Saved Outfits. Keduanya hidup di satu timeline
--   milik AvatarService (look = outfit + makeup), jadi kalau service ini juga menyimpan state,
--   ada dua sumber kebenaran yang bisa berbeda. Di sini tinggal CERMIN dari yang menempel di Head.
--
-- Kenapa tetap butuh service sendiri (spike #18):
--   - Makeup TIDAK bisa lewat HumanoidDescription -> tidak boleh masuk DescriptionBuilder.
--   - ApplyDescriptionAsync yang mengganti Head MENGHANCURKAN decal (terbukti: 3/3 hilang),
--     jadi makeup harus dipasang ULANG setiap Head baru -> :reapply().
--   - Decal yang dipasang WAJIB clone dari template asli hasil LoadAsset: template membawa anak
--     `WrapTextureTransfer` yang memetakan tekstur mengikuti bentuk kepala.
-- Template disimpan per SERVICE (bukan per pemain) dan tidak dibuang selama server hidup:
-- Undo/Redo ke look bermakeup harus bisa jalan TANPA yield ke InsertService.
-- Semua akses engine lewat `deps` supaya bisa dites di Lune.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Makeup = require(Shared.Domain.Makeup)
local Log = require(Shared.Util.Log)

local log = Log.new("MakeupService")

local DECAL_PREFIX = "SV_Makeup_"

export type Code = "NOT_READY" | "NOT_FOUND" | "FAILED" | "UNSUPPORTED_TYPE"

export type Deps = {
	decals: any, -- AssetDecal (getMakeup)
	itemInfo: any, -- ItemInfoService (get -> assetType)
	-- engine (default Roblox; diganti saat test)
	getHead: ((player: any) -> any)?,
	face: any?, -- default Enum.NormalId.Front
}

-- `rendered` = apa yang (seharusnya) menempel di Head sekarang.
type Session = { rendered: Makeup.State }

local MakeupService = {}
MakeupService.__index = MakeupService

export type MakeupService = typeof(setmetatable(
	{} :: {
		_decals: any,
		_itemInfo: any,
		_getHead: (any) -> any,
		_face: any,
		_templates: { [number]: any }, -- assetId -> Decal template (SELALU di-Clone sebelum dipasang)
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
		_getHead = deps.getHead or defaultGetHead,
		_face = if deps.face ~= nil then deps.face else Enum.NormalId.Front,
		_templates = {},
		_sessions = {},
	}, MakeupService)
end

function MakeupService.attach(self: MakeupService, player: any)
	if self._sessions[player] == nil then
		self._sessions[player] = { rendered = Makeup.empty() }
	end
end

function MakeupService.detach(self: MakeupService, player: any)
	self._sessions[player] = nil
end

function MakeupService.isReady(self: MakeupService, player: any): boolean
	return self._sessions[player] ~= nil
end

-- Yang sedang menempel (cermin). Sumber kebenaran tetap AvatarService.
function MakeupService.get(self: MakeupService, player: any): Makeup.State
	local session = self._sessions[player]
	return if session then session.rendered else Makeup.empty()
end

function MakeupService.dto(self: MakeupService, player: any): { any }
	return Makeup.toDto(self:get(player))
end

function MakeupService.isWorn(self: MakeupService, player: any, assetId: number): boolean
	return Makeup.hasAsset(self:get(player), assetId)
end

-- ===== Resolve (YIELD) =====

-- id item -> Makeup.Entry ({ assetId, slot, textureId }) + template di-cache.
-- (false, "UNSUPPORTED_TYPE") berarti bukan makeup -> penelepon meneruskannya ke jalur outfit biasa.
function MakeupService.resolve(self: MakeupService, assetId: number): (boolean, any)
	local okInfo, info = self._itemInfo:get(assetId) -- yield
	if not okInfo then
		return false, if info and info.code == "FAILED" then "FAILED" else "NOT_FOUND"
	end

	local slot = Makeup.slotOf(info.assetType)
	if slot == nil then
		return false, "UNSUPPORTED_TYPE"
	end

	local okDecal, decalInfo = self._decals:getMakeup(info.assetId) -- yield (di-cache gateway)
	if not okDecal then
		log.warn("decal makeup gagal", info.assetId, decalInfo and decalInfo.code)
		return false, if decalInfo and decalInfo.code == "FAILED" then "FAILED" else "NOT_FOUND"
	end

	self._templates[info.assetId] = decalInfo.template
	return true, { assetId = info.assetId, slot = slot, textureId = decalInfo.textureId }
end

-- Baris tersimpan ({ assetId, slot }) -> Makeup.State. Baris yang gagal dimuat DILEWATI.
-- Slot yang dipakai = slot hasil resolve (tipe aset), bukan yang tersimpan: tipe aset yang benar.
function MakeupService.resolveRows(self: MakeupService, rows: any): Makeup.State
	local state = Makeup.empty()
	if type(rows) ~= "table" then
		return state
	end
	for _, row in rows do
		local id = if type(row) == "table" then row.assetId else nil
		if type(id) ~= "number" then
			continue
		end
		local ok, entry = self:resolve(id) -- yield
		if not ok then
			log.warn("makeup tersimpan dilewati", id, entry)
			continue
		end
		local next_, err = Makeup.set(state, entry)
		if next_ then
			state = next_
		else
			log.warn("makeup tersimpan ditolak", id, err)
		end
	end
	return state
end

-- Sudah pernah di-resolve? (AvatarService memakainya untuk tahu perlu yield atau tidak)
function MakeupService.hasTemplate(self: MakeupService, assetId: number): boolean
	return self._templates[assetId] ~= nil
end

-- ===== Render (TANPA yield) =====

-- Buang SEMUA decal milik kita di Head; decal bawaan (mis. 'face') tidak disentuh.
local function stripDecals(head: any)
	for _, child in head:GetChildren() do
		if string.sub(tostring(child.Name), 1, #DECAL_PREFIX) == DECAL_PREFIX then
			child:Destroy()
		end
	end
end

function MakeupService._render(self: MakeupService, player: any, state: Makeup.State): boolean
	local head = self._getHead(player)
	if head == nil then
		return false -- belum ada Head; reapply dipanggil lagi saat karakter siap
	end
	stripDecals(head)
	-- Urutan list = face -> eye -> lip (ZIndex tidak terbukti berpengaruh, jadi urutan tempel yang dipakai).
	for _, entry in Makeup.list(state) do
		local template = self._templates[entry.assetId]
		if template == nil then
			log.warn("template makeup belum ada", entry.assetId, entry.slot)
			continue
		end
		local decal = template:Clone() -- WAJIB clone: template dipakai bersama semua pemain
		decal.Name = DECAL_PREFIX .. entry.slot
		decal.Face = self._face
		decal.Parent = head
	end
	return true
end

-- Pasang state makeup dari AvatarService. Head belum ada -> state tetap dicatat (return false).
function MakeupService.apply(self: MakeupService, player: any, state: Makeup.State?): boolean
	local session = self._sessions[player]
	if session == nil then
		return false
	end
	session.rendered = state or Makeup.empty()
	return self:_render(player, session.rendered)
end

-- Head berganti (respawn / ApplyDescription berhasil): pasang ulang yang terakhir diminta.
function MakeupService.reapply(self: MakeupService, player: any): boolean
	local session = self._sessions[player]
	if session == nil then
		return false
	end
	return self:_render(player, session.rendered)
end

return MakeupService
