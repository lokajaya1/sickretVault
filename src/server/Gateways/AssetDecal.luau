--!strict
-- Gateway InsertService: SATU-SATUNYA tempat yang memanggil InsertService:LoadAsset.
--
--   local AssetDecal = require(ServerScriptService.Server.Gateways.AssetDecal)
--   local decals = AssetDecal.new()
--   local ok, info = decals:getMakeup(133520807586498)   -- info = { textureId, template }
--   local ok, bg = decals:getBackground(121199209890990) -- bg   = { imageId, image, color }
--   local ok, an = decals:getAnimationClip(3576823880)   -- an   = { animationId = "rbxassetid://..." }
--
-- Kenapa gateway sendiri (spike 18 Sep 2026, tests/MakeupDecal*.studio):
--   1. Makeup TIDAK bisa dipakai lewat HumanoidDescription; jalurnya Decal yang ditempel ke Head.
--   2. Id item BUKAN id texture (133520807586498 -> rbxassetid://98880692903650), jadi id item
--      tidak bisa langsung dipakai sebagai Texture -> LoadAsset wajib.
--   3. CLIENT DITOLAK: "InsertService cannot be used to load assets from the client" -> server saja.
--   4. Satu LoadAsset ~0,4-0,6 detik -> hasilnya di-cache, dan permintaan id yang sama yang
--      datang bersamaan menunggu hasil yang sedang berjalan (tidak memanggil LoadAsset dua kali).
--   5. Yang disimpan bukan cuma texture id, tapi TEMPLATE Decal-nya (Parent nil, di memori server).
--      Decal asli membawa anak `WrapTextureTransfer` — itulah yang memetakan tekstur mengikuti
--      bentuk kepala (HeadWrapTarget). Decal buatan sendiri tanpa anak itu hanya proyeksi datar
--      ke bidang depan kotak pembatas Head, jadi makeup melenceng di kepala non-standar.
--      textureId tetap disimpan karena dikirim ke client untuk penanda "sedang dipakai".
--
-- Semua fungsi return (true, data) atau (false, DecalError). Tidak pernah error().

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Limits = require(Shared.Config.Limits)
local Cache = require(Shared.Util.Cache)
local Retry = require(Shared.Util.Retry)
local Log = require(Shared.Util.Log)
local Makeup = require(Shared.Domain.Makeup)

local log = Log.new("AssetDecal")

export type ErrorCode = "BAD_ARG" | "NOT_FOUND" | "NO_DECAL" | "NO_BACKGROUND" | "FAILED"
export type DecalError = { code: ErrorCode, message: string, assetId: number }

-- Latar area preview (AvatarBackground). Nilai polos: tidak ada Instance yang perlu di-Clone.
export type Background = { imageId: number, image: string, color: Color3? }

export type Deps = {
	insertService: any?,
	retry: Retry.Options?,
	clock: (() -> number)?,
	sleep: ((number) -> ())?, -- dipakai saat menunggu permintaan yang sedang berjalan
}

-- Pesan yang percuma diulang (id salah / aset tidak ada / tidak diizinkan).
local PERMANENT_PATTERNS = {
	"[Nn]ot [Ff]ound",
	"HTTP 400",
	"HTTP 404",
	"[Ii]nvalid",
	"does not exist",
	"not allowed",
	"cannot be used to load assets from the client",
}

local WAIT_STEP = 0.05
local WAIT_MAX = 10

local AssetDecal = {}
AssetDecal.__index = AssetDecal

export type AssetDecal = typeof(setmetatable(
	{} :: {
		_insert: any,
		_retry: Retry.Options,
		_sleep: (number) -> (),
		_textures: Cache.Cache, -- assetId -> { textureId, template } | { code, message }
		_inflight: { [number]: boolean },
		_backgrounds: Cache.Cache, -- assetId -> Background | { code, message }
		_bgInflight: { [number]: boolean },
		_clips: Cache.Cache, -- assetId -> { animationId } | { code, message }
		_clipInflight: { [number]: boolean },
	},
	AssetDecal
))

function AssetDecal.isPermanentError(err: any): boolean
	local text = tostring(err)
	for _, pattern in PERMANENT_PATTERNS do
		if string.find(text, pattern) then
			return true
		end
	end
	return false
end

local function makeError(assetId: number, code: ErrorCode, message: string): DecalError
	return { code = code, message = message, assetId = assetId }
end

local function isId(v: any): boolean
	return type(v) == "number" and v > 0 and v % 1 == 0 and v <= 2 ^ 53
end

function AssetDecal.new(deps: Deps?): AssetDecal
	local d = deps or {}
	local retry: Retry.Options = table.clone(d.retry or {})
	if retry.shouldRetry == nil then
		retry.shouldRetry = function(err)
			return not AssetDecal.isPermanentError(err)
		end
	end
	return setmetatable({
		_insert = d.insertService or game:GetService("InsertService"),
		_retry = retry,
		_sleep = d.sleep or function(t: number)
			task.wait(t)
		end,
		_textures = Cache.new({
			ttl = Limits.ItemCacheTTL,
			maxSize = 500,
			clock = d.clock or os.clock,
		}),
		_inflight = {},
		_backgrounds = Cache.new({
			ttl = Limits.ItemCacheTTL,
			maxSize = 200,
			clock = d.clock or os.clock,
		}),
		_bgInflight = {},
		_clips = Cache.new({
			ttl = Limits.ItemCacheTTL,
			maxSize = 200,
			clock = d.clock or os.clock,
		}),
		_clipInflight = {},
	}, AssetDecal)
end

-- Ambil TEMPLATE Decal (beserta anak WrapTextureTransfer) dari model hasil LoadAsset.
-- Model selalu dibuang; template hidup tanpa Parent selama masih ada di cache.
local function readDecal(model: any): any
	local found = model:FindFirstChildWhichIsA("Decal", true)
	local template = if found then found:Clone() else nil
	local texture = if template then template.Texture else nil
	model:Destroy()
	if template ~= nil and Makeup.isValidTexture(texture) then
		return { textureId = texture, template = template }
	end
	if template then
		template:Destroy()
	end
	return nil
end

-- AvatarBackground TIDAK berisi Decal: isinya Folder 'AvatarBackground' dengan IntValue `ImageId`
-- + Color3Value `Color` (spike #18 no. 9; Prism Skies 121199209890990 -> ImageId 139431817156818,
-- Color 0.663/0.835/0.836). Model hasil LoadAsset selalu dibuang -- yang disimpan cuma dua nilai.
local function readBackground(model: any): Background?
	local folder = model:FindFirstChild("AvatarBackground", true)
	local imageValue = if folder then folder:FindFirstChild("ImageId") else nil
	local colorValue = if folder then folder:FindFirstChild("Color") else nil
	local imageId = if imageValue then imageValue.Value else nil
	local color = if colorValue then colorValue.Value else nil
	model:Destroy()
	if not isId(imageId) then
		return nil
	end
	return { imageId = imageId, image = "rbxassetid://" .. tostring(imageId), color = color }
end

-- Aset animasi/emote katalog berisi objek `Animation`, dan AnimationId-nya menunjuk KLIP yang
-- sesungguhnya -- bukan id katalognya. Spike 19 Sep 2026 (PreviewRig.studio S.animAsset): aset
-- 3576823880 "Point2" berisi Animation 'Point 2 Face' dengan AnimationId
-- "http://www.roblox.com/asset/?id=10714395441". Bentuknya URL, bukan "rbxassetid://", jadi
-- angkanya diambil dan dirakit ulang. Memutar id katalog langsung ditolak engine
-- ("AnimationClip loaded is not valid" -- putaran 1 spike).
local function readAnimation(model: any): any?
	local found = model:FindFirstChildWhichIsA("Animation", true)
	local raw = if found then found.AnimationId else nil
	model:Destroy()
	local digits = if type(raw) == "string" then raw:match("%d+") else nil
	if digits == nil then
		return nil
	end
	return { animationId = "rbxassetid://" .. digits }
end

-- Menunggu permintaan id yang sama yang sedang berjalan. Return hasil cache-nya (bisa nil).
function AssetDecal._waitInflight(self: AssetDecal, assetId: number, inflight: any, cache: Cache.Cache): any
	local waited = 0
	while inflight[assetId] and waited < WAIT_MAX do
		self._sleep(WAIT_STEP)
		waited += WAIT_STEP
	end
	return cache:get(assetId)
end

-- Template Decal + texture id untuk satu item makeup.
-- (true, { textureId = "rbxassetid://...", template = Decal }) atau (false, DecalError).
-- Penelepon WAJIB meng-Clone template, bukan memakainya langsung (satu template dipakai bersama).
-- Hasil gagal permanen ikut disimpan supaya tidak dicoba berulang kali.
function AssetDecal.getMakeup(self: AssetDecal, assetId: number): (boolean, any)
	if not isId(assetId) then
		return false, makeError(0, "BAD_ARG", "assetId harus angka bulat positif")
	end

	local hit = self._textures:get(assetId)
	if hit == nil and self._inflight[assetId] then
		hit = self:_waitInflight(assetId, self._inflight, self._textures)
	end
	if hit ~= nil then
		if hit.template then
			return true, hit
		end
		return false, makeError(assetId, hit.code or "FAILED", hit.message or "gagal sebelumnya")
	end

	self._inflight[assetId] = true
	local ok, result = Retry.run(function()
		return self._insert:LoadAsset(assetId)
	end, self._retry)

	if not ok then
		local message = tostring(result)
		local code: ErrorCode = if AssetDecal.isPermanentError(result) then "NOT_FOUND" else "FAILED"
		if code == "NOT_FOUND" then
			self._textures:set(assetId, { template = nil, code = code, message = message })
		end
		self._inflight[assetId] = nil
		log.warn("LoadAsset gagal", assetId, code, message)
		return false, makeError(assetId, code, message)
	end

	local entry = readDecal(result)
	if entry == nil then
		self._textures:set(assetId, { template = nil, code = "NO_DECAL", message = "aset tidak berisi Decal" })
		self._inflight[assetId] = nil
		log.warn("aset tanpa Decal", assetId)
		return false, makeError(assetId, "NO_DECAL", "aset tidak berisi Decal")
	end

	self._textures:set(assetId, entry)
	self._inflight[assetId] = nil
	return true, entry
end

-- Latar area preview untuk satu item AvatarBackground.
-- (true, Background) atau (false, DecalError). Jalannya sama persis dengan getMakeup
-- (retry, cache, permintaan berbarengan menunggu yang sedang berjalan) tapi cache-nya TERPISAH
-- karena isinya beda bentuk: nilai polos, bukan Instance yang harus di-Clone.
function AssetDecal.getBackground(self: AssetDecal, assetId: number): (boolean, any)
	if not isId(assetId) then
		return false, makeError(0, "BAD_ARG", "assetId harus angka bulat positif")
	end

	local hit = self._backgrounds:get(assetId)
	if hit == nil and self._bgInflight[assetId] then
		hit = self:_waitInflight(assetId, self._bgInflight, self._backgrounds)
	end
	if hit ~= nil then
		if hit.imageId then
			return true, hit
		end
		return false, makeError(assetId, hit.code or "FAILED", hit.message or "gagal sebelumnya")
	end

	self._bgInflight[assetId] = true
	local ok, result = Retry.run(function()
		return self._insert:LoadAsset(assetId)
	end, self._retry)

	if not ok then
		local message = tostring(result)
		local code: ErrorCode = if AssetDecal.isPermanentError(result) then "NOT_FOUND" else "FAILED"
		if code == "NOT_FOUND" then
			self._backgrounds:set(assetId, { imageId = nil, code = code, message = message })
		end
		self._bgInflight[assetId] = nil
		log.warn("LoadAsset latar gagal", assetId, code, message)
		return false, makeError(assetId, code, message)
	end

	local entry = readBackground(result)
	if entry == nil then
		self._backgrounds:set(
			assetId,
			{ imageId = nil, code = "NO_BACKGROUND", message = "aset bukan AvatarBackground" }
		)
		self._bgInflight[assetId] = nil
		log.warn("aset tanpa AvatarBackground", assetId)
		return false, makeError(assetId, "NO_BACKGROUND", "aset bukan AvatarBackground")
	end

	self._backgrounds:set(assetId, entry)
	self._bgInflight[assetId] = nil
	return true, entry
end

-- Id klip animasi untuk satu item animasi/emote. Jalannya sama dengan getMakeup/getBackground
-- (retry, cache, permintaan berbarengan menunggu yang sedang berjalan), cache-nya terpisah.
function AssetDecal.getAnimationClip(self: AssetDecal, assetId: number): (boolean, any)
	if not isId(assetId) then
		return false, makeError(0, "BAD_ARG", "assetId harus angka bulat positif")
	end

	local hit = self._clips:get(assetId)
	if hit == nil and self._clipInflight[assetId] then
		hit = self:_waitInflight(assetId, self._clipInflight, self._clips)
	end
	if hit ~= nil then
		if hit.animationId then
			return true, hit
		end
		return false, makeError(assetId, hit.code or "FAILED", hit.message or "gagal sebelumnya")
	end

	self._clipInflight[assetId] = true
	local ok, result = Retry.run(function()
		return self._insert:LoadAsset(assetId)
	end, self._retry)

	if not ok then
		local message = tostring(result)
		local code: ErrorCode = if AssetDecal.isPermanentError(result) then "NOT_FOUND" else "FAILED"
		if code == "NOT_FOUND" then
			self._clips:set(assetId, { animationId = nil, code = code, message = message })
		end
		self._clipInflight[assetId] = nil
		log.warn("LoadAsset animasi gagal", assetId, code, message)
		return false, makeError(assetId, code, message)
	end

	local entry = readAnimation(result)
	if entry == nil then
		self._clips:set(assetId, { animationId = nil, code = "NO_ANIMATION", message = "aset tanpa Animation" })
		self._clipInflight[assetId] = nil
		log.warn("aset tanpa Animation", assetId)
		return false, makeError(assetId, "NO_ANIMATION", "aset tanpa Animation")
	end

	self._clips:set(assetId, entry)
	self._clipInflight[assetId] = nil
	return true, entry
end

function AssetDecal.clear(self: AssetDecal)
	self._textures:clear()
	self._inflight = {}
	self._backgrounds:clear()
	self._bgInflight = {}
	self._clips:clear()
	self._clipInflight = {}
end

return AssetDecal
