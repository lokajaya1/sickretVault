--!strict
-- State panel detail item di client. Memanggil remote GetItemDetail + cache hasil sukses.
--   local detail = DetailController.new()
--   detail:onChanged(function(state) ... end)
--   detail:open(123, "Asset")    -- YIELD saat memuat -> panggil dari task.spawn di UI
--   detail:close()               -- tombol Back
--   detail:retry()               -- tombol "Coba lagi" setelah error
-- Rekomendasi (#17d) dimuat SESUDAH detail (butuh assetType dari detail) lewat remote terpisah,
-- jadi panel muncul dulu dan baris Recommended menyusul; gagalnya cukup menyembunyikan barisnya.
-- Balasan lama diabaikan (buka item lain / tutup saat masih memuat).
-- `invoke` bisa diganti saat test (tanpa remote).
-- Controller ini juga memegang FAVORIT item (bagian bawah file): keadaannya per item, sama seperti
-- halaman detail, jadi tidak dibuatkan controller sendiri.
--   detail:favoriteOf(id, "Asset")   -- yang SUDAH diketahui; nil = belum pernah dibaca
--   detail:loadFavorite(id, "Asset") -- YIELD, baca sekali untuk item yang sedang dibuka
--   detail:setFavorite(id, "Asset", true) -- YIELD, prompt Roblox
--   detail:onFavoriteChanged(function(id, itemType, value) ... end)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cache = require(Shared.Util.Cache)
local Log = require(Shared.Util.Log)

local log = Log.new("DetailController")

local CACHE_TTL = 600 -- detik
local CACHE_SIZE = 100
local FAV_TIMEOUT = 30 -- detik menunggu pemain menjawab prompt favorit / izin

local function favKey(id: number, itemType: string): string
	return itemType .. ":" .. tostring(id)
end

-- Picu satu prompt Roblox lalu tunggu eventnya. nil = tidak dijawab dalam FAV_TIMEOUT detik
-- (termasuk bila promptnya tidak muncul sama sekali) -> pemanggil tidak menggantung.
local function favWaitPrompt(editor: any, eventName: string, fire: () -> ()): any
	local okSignal, signal = pcall(function()
		return editor[eventName]
	end)
	local got: any = nil
	local done = false
	local conn: RBXScriptConnection? = nil
	if okSignal and typeof(signal) == "RBXScriptSignal" then
		conn = signal:Connect(function(value: any)
			got = value
			done = true
		end)
	end
	local okFire, err = pcall(fire)
	if not okFire then
		if conn then
			conn:Disconnect()
		end
		log.warn("prompt gagal", eventName, err)
		return nil
	end
	local started = os.clock()
	while not done and os.clock() - started < FAV_TIMEOUT do
		task.wait(0.1)
	end
	if conn then
		conn:Disconnect()
	end
	return got
end

export type State = {
	isOpen: boolean,
	id: number?,
	itemType: string?, -- "Asset" | "Bundle"
	detail: any?, -- ItemDetail.Detail dari server (nil saat memuat / error)
	loading: boolean,
	error: string?, -- "RATE_LIMITED" | "NOT_FOUND" | "FAILED" | "BAD_ARG" | "NETWORK"
	recommended: { any }?, -- daftar ItemDto untuk baris Recommended; nil = belum ada / gagal
	recLoading: boolean,
}

export type Invoke = (request: { id: number, itemType: string }) -> any
export type InvokeRec = (request: { id: number, itemType: string, assetType: string? }) -> any

local DetailController = {}
DetailController.__index = DetailController

export type DetailController = typeof(setmetatable(
	{} :: {
		_invoke: Invoke,
		_invokeRec: InvokeRec,
		_invokeClip: (request: { assetId: number }) -> any,
		_state: State,
		_cache: Cache.Cache,
		_token: number,
		_listeners: { (State) -> () },
		_editor: any, -- AvatarEditorService (bisa diganti saat test)
		_fav: { [string]: boolean }, -- ingatan favorit sepanjang sesi; tidak ada kunci = belum tahu
		_favPerm: boolean?, -- izin membaca inventory: nil = belum diminta
		_favBusy: boolean, -- satu prompt favorit pada satu waktu
		_favLoading: { [string]: boolean },
		_favListeners: { (number, string, boolean?) -> () },
	},
	DetailController
))

local function defaultInvoke(request: { id: number, itemType: string }): any
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes.func(RemoteNames.Functions.GetItemDetail):InvokeServer(request)
end

local function defaultInvokeRec(request: any): any
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes.func(RemoteNames.Functions.GetRecommended):InvokeServer(request)
end

local function defaultInvokeClip(request: any): any
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes.func(RemoteNames.Functions.GetAnimationClip):InvokeServer(request)
end

local function closedState(): State
	return {
		isOpen = false,
		id = nil,
		itemType = nil,
		detail = nil,
		loading = false,
		error = nil,
		recommended = nil,
		recLoading = false,
	}
end

function DetailController.new(
	invoke: Invoke?,
	clock: (() -> number)?,
	invokeRec: InvokeRec?,
	editor: any?
): DetailController
	return setmetatable({
		_invoke = invoke or defaultInvoke,
		_invokeRec = invokeRec or defaultInvokeRec,
		_invokeClip = defaultInvokeClip,
		_state = closedState(),
		_cache = Cache.new({ ttl = CACHE_TTL, maxSize = CACHE_SIZE, clock = clock }),
		_token = 0,
		_listeners = {},
		_editor = editor or game:GetService("AvatarEditorService"),
		_fav = {},
		_favPerm = nil,
		_favBusy = false,
		_favLoading = {},
		_favListeners = {},
	}, DetailController)
end

function DetailController.getState(self: DetailController): State
	return self._state
end

-- Daftarkan listener; kembalikan fungsi untuk berhenti mendengarkan.
function DetailController.onChanged(self: DetailController, fn: (State) -> ()): () -> ()
	table.insert(self._listeners, fn)
	return function()
		local i = table.find(self._listeners, fn)
		if i then
			table.remove(self._listeners, i)
		end
	end
end

function DetailController._emit(self: DetailController)
	for _, fn in table.clone(self._listeners) do
		local ok, err = pcall(fn, self._state)
		if not ok then
			log.warn("listener error", err)
		end
	end
end

function DetailController._load(self: DetailController)
	local s = self._state
	local id, itemType = s.id :: number, s.itemType :: string
	local key = itemType .. ":" .. tostring(id)

	self._token += 1
	local token = self._token
	local hit = self._cache:get(key)
	if hit ~= nil then
		s.detail, s.loading, s.error = hit, false, nil
		self:_emit()
		self:_loadRecommended(token)
		return
	end
	s.detail, s.loading, s.error = nil, true, nil
	self:_emit()

	local ok, res = pcall(self._invoke, { id = id, itemType = itemType })

	if token ~= self._token then
		return -- sudah buka item lain / ditutup
	end
	s.loading = false
	if not ok or type(res) ~= "table" then
		log.warn("invoke gagal", res)
		s.error = "NETWORK"
	elseif not res.ok or type(res.detail) ~= "table" then
		s.error = if type(res.code) == "string" then res.code else "FAILED"
	else
		s.detail = res.detail
		self._cache:set(key, res.detail)
	end
	self:_emit()
	if s.detail ~= nil then
		self:_loadRecommended(token)
	end
end

-- Baris Recommended. Dipanggil SESUDAH detail ada (assetType-nya dari situ). Gagal = baris
-- disembunyikan, bukan pesan error: rekomendasi bukan isi utama halaman.
function DetailController._loadRecommended(self: DetailController, token: number)
	local s = self._state
	local id, itemType = s.id :: number, s.itemType :: string
	local assetType = if type(s.detail) == "table" then s.detail.assetType else nil
	if itemType == "Asset" and type(assetType) ~= "string" then
		return -- aset tanpa tipe: server pasti menolak, jangan buang panggilan
	end
	local key = "rec:" .. itemType .. ":" .. tostring(id)
	local hit = self._cache:get(key)
	if hit ~= nil then
		s.recommended, s.recLoading = hit, false
		self:_emit()
		return
	end
	s.recommended, s.recLoading = nil, true
	self:_emit()

	local ok, res = pcall(self._invokeRec, { id = id, itemType = itemType, assetType = assetType })
	if token ~= self._token then
		return -- sudah buka item lain / ditutup
	end
	s.recLoading = false
	if ok and type(res) == "table" and res.ok and type(res.items) == "table" then
		s.recommended = res.items
		self._cache:set(key, res.items)
	else
		log.debug("rekomendasi tidak tersedia", itemType, id)
	end
	self:_emit()
end

-- Buka panel untuk item. Item yang sama & sudah termuat/sedang dimuat -> tidak memanggil ulang.
function DetailController.open(self: DetailController, id: number, itemType: string)
	if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 then
		log.warn("id tidak valid", id)
		return
	end
	if itemType ~= "Asset" and itemType ~= "Bundle" then
		log.warn("itemType tidak valid", itemType)
		return
	end
	local s = self._state
	if s.isOpen and s.id == id and s.itemType == itemType and s.error == nil then
		return
	end
	self._state = {
		isOpen = true,
		id = id,
		itemType = itemType,
		detail = nil,
		loading = false,
		error = nil,
		recommended = nil,
		recLoading = false,
	}
	self:_load()
end

function DetailController.close(self: DetailController)
	if not self._state.isOpen then
		return
	end
	self._token += 1 -- balasan yang masih ditunggu akan diabaikan
	self._state = closedState()
	self:_emit()
end

-- Ulangi setelah error (mis. tombol "Coba lagi").
function DetailController.retry(self: DetailController)
	local s = self._state
	if not s.isOpen or s.error == nil or s.loading then
		return
	end
	self:_load()
end

-- ===== FAVORIT ITEM (PR #28) =====
-- Dijalankan di CLIENT lewat AvatarEditorService. Spike 19 Sep 2026
-- (tests/PreviewRig.studio -> S.favorite, S.favoriteBatch) menemukan dua batas keras:
--   1. GetFavorite DITOLAK ("Permission must be obtained with PromptAllowInventoryReadAccess")
--      sampai pemain menjawab prompt izin, dan izin itu berlaku PER SESI (sesi Play berikutnya
--      diminta lagi) -> izin diminta saat pemain MENYENTUH bintang, bukan saat panel dibuka.
--   2. Membaca MAHAL: 416 ms per item, dan kuota habis di ~26 bacaan beruntun (HTTP 429; 30 bacaan
--      serentak malah 16 yang gagal). Kuota ini dipakai bersama pencarian katalog yang sudah pernah
--      kena 429 di #17b. Karena itu status TIDAK PERNAH diambil untuk seluruh grid: hanya untuk
--      item yang sedang dibuka pemain (overlay kartu / halaman detail), sekali, lalu diingat
--      sepanjang sesi. Item yang belum pernah dibaca statusnya `nil` = BELUM DIKETAHUI, dan UI
--      wajib menggambarnya berbeda dari "bukan favorit" supaya bintangnya tidak berbohong.
-- MENULIS tidak butuh izin itu: PromptSetFavorite memunculkan dialog Roblox sendiri, dan hasil
-- Success langsung dipakai memperbarui ingatan -> tidak perlu membaca ulang (hemat 416 ms).

-- Ambil detail sebuah item TANPA menyentuh state panel (panel detail punya alurnya sendiri).
-- Dipakai preview hover kartu bundle: yang dibutuhkan cuma daftar part-nya. YIELD -> panggil dari
-- task.spawn. Cache yang sama dengan panel dipakai, jadi item yang pernah dibuka tidak diminta lagi.
function DetailController.fetchDetail(self: DetailController, id: number, itemType: string): any?
	local key = itemType .. ":" .. tostring(id)
	local hit = self._cache:get(key)
	if hit ~= nil then
		return hit
	end
	local ok, res = pcall(self._invoke, { id = id, itemType = itemType })
	if not ok or type(res) ~= "table" or not res.ok or type(res.detail) ~= "table" then
		log.debug("fetchDetail gagal", itemType, id)
		return nil
	end
	self._cache:set(key, res.detail)
	return res.detail
end

-- Id KLIP animasi untuk item animasi/emote. Id katalog tidak bisa diputar langsung: klip aslinya
-- ada di dalam asetnya, dan hanya server yang boleh membukanya (InsertService menolak client,
-- temuan #18 no. 4). YIELD -> panggil dari task.spawn. Hasilnya di-cache di sini DAN di gateway.
-- Kembalian: "rbxassetid://<n>" atau nil.
function DetailController.fetchAnimationClip(self: DetailController, assetId: number): string?
	local key = "clip:" .. tostring(assetId)
	local hit = self._cache:get(key)
	if hit ~= nil then
		return if hit == false then nil else hit
	end
	local ok, res = pcall(self._invokeClip, { assetId = assetId })
	if not ok or type(res) ~= "table" or not res.ok or type(res.animationId) ~= "string" then
		-- Gagal permanen (aset tanpa Animation) maupun sementara sama-sama diingat sebentar supaya
		-- hover berulang di kartu yang sama tidak memanggil remote terus-menerus.
		self._cache:set(key, false)
		log.debug("klip animasi tidak tersedia", assetId)
		return nil
	end
	self._cache:set(key, res.animationId)
	return res.animationId
end

-- Status favorit yang SUDAH diketahui. nil = belum pernah dibaca/ditulis di sesi ini.
function DetailController.favoriteOf(self: DetailController, id: number, itemType: string): boolean?
	return self._fav[favKey(id, itemType)]
end

-- Dipanggil setiap status favorit sebuah item diketahui / berubah.
function DetailController.onFavoriteChanged(self: DetailController, fn: (number, string, boolean?) -> ()): () -> ()
	table.insert(self._favListeners, fn)
	return function()
		local i = table.find(self._favListeners, fn)
		if i then
			table.remove(self._favListeners, i)
		end
	end
end

function DetailController._rememberFavorite(self: DetailController, id: number, itemType: string, value: boolean)
	self._fav[favKey(id, itemType)] = value
	for _, fn in table.clone(self._favListeners) do
		local ok, err = pcall(fn, id, itemType, value)
		if not ok then
			log.warn("listener favorit error", err)
		end
	end
end

-- Izin membaca inventory, diminta sekali per sesi. YIELD. true = boleh membaca.
function DetailController._favPermit(self: DetailController): boolean
	if self._favPerm ~= nil then
		return self._favPerm
	end
	local editor = self._editor
	local result = favWaitPrompt(editor, "PromptAllowInventoryReadAccessCompleted", function()
		editor:PromptAllowInventoryReadAccess()
	end)
	local granted = result == Enum.AvatarPromptResult.Success
	self._favPerm = granted
	if not granted then
		log.debug("izin inventory tidak diberikan", tostring(result))
	end
	return granted
end

-- Baca status favorit SATU item. YIELD (416 ms, plus satu prompt izin bila belum ada) -> panggil
-- dari task.spawn. Hanya untuk item yang sedang dibuka pemain; JANGAN dipakai per kartu grid.
-- `quiet` = true: MENYERAH kalau izin inventory belum ada, tanpa memunculkan prompt. Dipakai saat
-- pemain cuma membuka overlay kartu — prompt izin di situ mengagetkan; izin diminta hanya kalau
-- pemain benar-benar menyentuh bintang.
-- Kembalian: true/false, atau nil bila tidak bisa diketahui (izin ditolak / API gagal).
function DetailController.loadFavorite(self: DetailController, id: number, itemType: string, quiet: boolean?): boolean?
	local key = favKey(id, itemType)
	local known = self._fav[key]
	if known ~= nil then
		return known
	end
	if self._favLoading[key] then
		return nil -- bacaan untuk item ini sedang berjalan
	end
	if quiet and self._favPerm ~= true then
		return nil -- izin belum ada dan tidak boleh bertanya sekarang
	end
	if not self:_favPermit() then
		return nil
	end
	self._favLoading[key] = true
	local ok, value = pcall(function()
		local kind = if itemType == "Bundle" then Enum.AvatarItemType.Bundle else Enum.AvatarItemType.Asset
		return self._editor:GetFavorite(id, kind)
	end)
	self._favLoading[key] = nil
	if not ok then
		log.warn("baca favorit gagal", id, value)
		return nil
	end
	local state = value == true
	self:_rememberFavorite(id, itemType, state)
	return state
end

-- Tulis favorit lewat prompt Roblox. YIELD -> panggil dari task.spawn.
-- Kembalian: status baru, atau nil bila pemain membatalkan / prompt gagal.
function DetailController.setFavorite(self: DetailController, id: number, itemType: string, on: boolean): boolean?
	if self._favBusy then
		return nil -- prompt bertumpuk membingungkan pemain
	end
	self._favBusy = true
	local editor = self._editor
	local result = favWaitPrompt(editor, "PromptSetFavoriteCompleted", function()
		local kind = if itemType == "Bundle" then Enum.AvatarItemType.Bundle else Enum.AvatarItemType.Asset
		editor:PromptSetFavorite(id, kind, on)
	end)
	self._favBusy = false
	if result ~= Enum.AvatarPromptResult.Success then
		log.debug("favorit tidak jadi", id, tostring(result))
		return nil
	end
	self:_rememberFavorite(id, itemType, on)
	return on
end

return DetailController
