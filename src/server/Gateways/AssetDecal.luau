--!strict
-- Gateway InsertService: SATU-SATUNYA tempat yang memanggil InsertService:LoadAsset.
--
--   local AssetDecal = require(ServerScriptService.Server.Gateways.AssetDecal)
--   local decals = AssetDecal.new()
--   local ok, info = decals:getMakeup(133520807586498)   -- info = { textureId, template }
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

export type ErrorCode = "BAD_ARG" | "NOT_FOUND" | "NO_DECAL" | "FAILED"
export type DecalError = { code: ErrorCode, message: string, assetId: number }

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

-- Menunggu permintaan id yang sama yang sedang berjalan. Return hasil cache-nya (bisa nil).
function AssetDecal._waitInflight(self: AssetDecal, assetId: number): any
	local waited = 0
	while self._inflight[assetId] and waited < WAIT_MAX do
		self._sleep(WAIT_STEP)
		waited += WAIT_STEP
	end
	return self._textures:get(assetId)
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
		hit = self:_waitInflight(assetId)
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

function AssetDecal.clear(self: AssetDecal)
	self._textures:clear()
	self._inflight = {}
end

return AssetDecal
