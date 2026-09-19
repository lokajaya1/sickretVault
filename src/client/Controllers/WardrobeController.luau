--!strict
-- Wardrobe di client: cache daftar slot + setting, semua perubahan lewat remote Wardrobe (server memutuskan).
--   local wardrobe = WardrobeController.new()
--   wardrobe:onChanged(function(snap) ... end)  -- snap = { loaded, loading, busy, error, outfits, max, restoreOutfit }
--   wardrobe:refresh()                          -- YIELD (list). Panggil saat panel dibuka
--   local ok, code = wardrobe:save(name?)       -- YIELD; nil = nama bawaan "Outfit N"
--   wardrobe:wear(id) / overwrite(id) / rename(id, name) / delete(id) / favorite(id, bool)
--   wardrobe:setRestoreOutfit(bool)                                                         -- YIELD
--   wardrobe:setSort("az")   wardrobe:setQuery("pesta")  -- tanpa server; snap.visible = hasil cari + urut
--   wardrobe:setFolderFilter(id | OutfitSort.ALL | OutfitSort.NONE)  -- tab folder (tanpa server)
--   wardrobe:folderAdd(name) / folderRename(id, name) / folderDelete(id)  -- YIELD
--   wardrobe:setFolders(outfitId, { 1, 2 })                               -- YIELD ("Modify Folders")
--   local ok, code, res = wardrobe:bulkDelete({ 1, 2 })   -- res.removed
--   local ok, code, res = wardrobe:bulkFolder({ 1, 2 }, folderId, true) -- res.changed / res.skipped
--   local ok, data = wardrobe:items(id)         -- YIELD; { items = { {id,name,price,...} }, total, missing }
--   local ok, unowned = wardrobe:ownership({ id }, { bundleId }) -- YIELD; { [id] = true } yang BELUM dimiliki
--   local ok, code = wardrobe:saveToRoblox("avatar")   -- YIELD; prompt Roblox ("outfit" = buat outfit baru)
--   local ok, list = wardrobe:robloxOutfits()          -- YIELD; { { id, name, editable } } (Outfit Loader)
--   local ok, state = wardrobe:robloxState(outfitId)   -- YIELD; OutfitState untuk kartu loader (di-cache)
--   local ok, code = wardrobe:wearRoblox(outfitId)     -- YIELD; pakai outfit Roblox itu
--   local ok, res = wardrobe:robloxUser("nama")        -- YIELD; avatar pemain lain { userId, state }
--   local ok, code = wardrobe:wearRobloxUser(userId)   -- YIELD; pakai avatar pemain itu
--   local ok, list = wardrobe:robloxUserOutfits(uid)   -- YIELD; outfit tersimpan pemain itu (proxy)
-- Semua aksi YIELD (InvokeServer) -> panggil dari task.spawn di UI.
-- Satu aksi pada satu waktu (busy); aksi lain saat busy -> (false, "BUSY") tanpa memanggil server.
-- Kode gagal: kode server (NOT_LOADED, FULL, FILTERED, ...) atau "NETWORK" (invoke error).
-- `invoke` bisa diganti saat test (tanpa remote).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AvatarEditorService = game:GetService("AvatarEditorService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared.Util.Log)
local OutfitSort = require(Shared.Domain.OutfitSort)

local log = Log.new("WardrobeController")

export type Folder = {
	id: number,
	name: string,
	createdAt: number,
	count: number,
}

-- Satu baris daftar outfit akun Roblox (AvatarEditorService:GetOutfits). BUKAN slot wardrobe kita:
-- tidak punya folder/favorit, dan tidak memakan kuota 30 slot.
export type RobloxOutfit = {
	id: number,
	name: string,
	editable: boolean, -- IsEditable=false = preset bawaan Roblox ("ROBLOX Boy")
}

export type Summary = {
	id: number,
	name: string,
	createdAt: number,
	updatedAt: number,
	favorite: boolean,
	folders: { number },
	count: number,
	makeup: number, -- jumlah makeup di look (Wardrobe.summarize)
	thumbs: { number },
	outfit: any, -- outfit ringkas (PlayerData.decodeOutfit) untuk render kartu
}

export type Snapshot = {
	loaded: boolean, -- daftar pernah berhasil dimuat
	loading: boolean, -- refresh sedang berjalan
	busy: string?, -- op yang sedang berjalan ("save", "wear", ...)
	busyId: number?, -- slot yang sedang diproses
	error: string?, -- kode gagal refresh terakhir
	outfits: { Summary }, -- urutan server (terbaru disimpan dulu)
	visible: { Summary }, -- hasil cari + urut (yang ditampilkan panel)
	sortKey: string,
	query: string,
	folders: { Folder }, -- folder pemain (urut dibuat)
	folderFilter: OutfitSort.Folder, -- tab aktif: ALL | NONE | id folder
	unfiled: number, -- jumlah outfit tanpa folder (label tab "Not In Any Folders")
	max: number,
	maxFolders: number,
	isFull: boolean,
	foldersFull: boolean,
	restoreOutfit: boolean?, -- nil = belum diketahui
	robloxBusy: string?, -- aksi akun Roblox yang sedang jalan: saveAvatar | createOutfit | list | wear
}

-- Daftar id (aset / bundle). Alias supaya tanda tangan ownership() pendek.
type Ids = { number }

export type Invoke = (request: { [string]: any }) -> any

local WardrobeController = {}
WardrobeController.__index = WardrobeController

export type WardrobeController = typeof(setmetatable(
	{} :: {
		_invoke: Invoke,
		_loaded: boolean,
		_loading: boolean,
		_busy: string?,
		_busyId: number?,
		_error: string?,
		_outfits: { Summary },
		_max: number,
		_maxFolders: number,
		_restore: boolean?,
		_sortKey: string,
		_query: string,
		_folders: { Folder },
		_folderFilter: OutfitSort.Folder,
		_items: { [string]: any },
		_itemsBusy: { [string]: boolean },
		_listeners: { (Snapshot) -> () },
		_robloxBusy: string?,
		_robloxOutfits: { RobloxOutfit }?,
		_robloxStates: { [number]: any },
		_inventoryOk: boolean,
	},
	WardrobeController
))

local DEFAULT_MAX = 30
local DEFAULT_MAX_FOLDERS = 12
local ITEMS_CACHE_MAX = 20

-- Kunci cache detail item: ikut updatedAt supaya "update" otomatis memuat ulang.
local function itemsKey(o: Summary): string
	return ("%d:%d"):format(o.id, o.updatedAt)
end

local function defaultInvoke(request: { [string]: any }): any
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes.func(RemoteNames.Functions.Wardrobe):InvokeServer(request)
end

function WardrobeController.new(invoke: Invoke?): WardrobeController
	return setmetatable({
		_invoke = invoke or defaultInvoke,
		_loaded = false,
		_loading = false,
		_busy = nil,
		_busyId = nil,
		_error = nil,
		_outfits = {},
		_max = DEFAULT_MAX,
		_maxFolders = DEFAULT_MAX_FOLDERS,
		_restore = nil,
		_sortKey = OutfitSort.DEFAULT,
		_query = "",
		_folders = {},
		_folderFilter = OutfitSort.ALL,
		_items = {},
		_itemsBusy = {},
		_listeners = {},
		_robloxBusy = nil,
		_robloxOutfits = nil,
		_robloxStates = {},
		_inventoryOk = false,
	}, WardrobeController)
end

-- Id folder yang masih ada (untuk memvalidasi tab aktif).
function WardrobeController._folderSet(self: WardrobeController): { [number]: boolean }
	local set: { [number]: boolean } = {}
	for _, f in self._folders do
		set[f.id] = true
	end
	return set
end

function WardrobeController.getSnapshot(self: WardrobeController): Snapshot
	local unfiled = 0
	for _, o in self._outfits do
		if type(o.folders) ~= "table" or #o.folders == 0 then
			unfiled += 1
		end
	end
	return {
		loaded = self._loaded,
		loading = self._loading,
		busy = self._busy,
		busyId = self._busyId,
		error = self._error,
		outfits = table.clone(self._outfits),
		visible = OutfitSort.apply(self._outfits, self._sortKey, self._query, self._folderFilter),
		sortKey = self._sortKey,
		query = self._query,
		folders = table.clone(self._folders),
		folderFilter = self._folderFilter,
		unfiled = unfiled,
		max = self._max,
		maxFolders = self._maxFolders,
		isFull = #self._outfits >= self._max,
		foldersFull = #self._folders >= self._maxFolders,
		restoreOutfit = self._restore,
		robloxBusy = self._robloxBusy,
	}
end

function WardrobeController._emit(self: WardrobeController)
	local snap = self:getSnapshot()
	for _, fn in table.clone(self._listeners) do
		local ok, err = pcall(fn, snap)
		if not ok then
			log.warn("listener error", err)
		end
	end
end

-- Return fungsi untuk berhenti.
function WardrobeController.onChanged(self: WardrobeController, fn: (Snapshot) -> ()): () -> ()
	table.insert(self._listeners, fn)
	return function()
		local i = table.find(self._listeners, fn)
		if i then
			table.remove(self._listeners, i)
		end
	end
end

function WardrobeController.get(self: WardrobeController, id: number): Summary?
	for _, o in self._outfits do
		if o.id == id then
			return o
		end
	end
	return nil
end

-- InvokeServer aman: (res, nil) | (nil, kode).
function WardrobeController._call(self: WardrobeController, request: { [string]: any }): (any, string?)
	local ok, res = pcall(self._invoke, request)
	if not ok or type(res) ~= "table" then
		log.warn("Wardrobe invoke gagal", request.op, res)
		return nil, "NETWORK"
	end
	if res.ok ~= true then
		return nil, if type(res.code) == "string" then res.code else "FAILED"
	end
	return res, nil
end

-- Terapkan balasan server (daftar / setting) ke cache.
function WardrobeController._apply(self: WardrobeController, res: any)
	if type(res.outfits) == "table" then
		self._outfits = res.outfits
		self._loaded = true
		self._error = nil
	end
	if type(res.folders) == "table" then
		self._folders = res.folders
		-- folder yang dihapus (mungkin dari perangkat lain) -> tab kembali ke All
		self._folderFilter = OutfitSort.normalizeFolder(self._folderFilter, self:_folderSet())
	end
	if type(res.max) == "number" then
		self._max = res.max
	end
	if type(res.maxFolders) == "number" then
		self._maxFolders = res.maxFolders
	end
	if type(res.settings) == "table" and type(res.settings.restoreOutfit) == "boolean" then
		self._restore = res.settings.restoreOutfit
	end
end

-- YIELD. Muat daftar + setting. Return (true) | (false, kode).
function WardrobeController.refresh(self: WardrobeController): (boolean, string?)
	if self._loading then
		return false, "BUSY"
	end
	self._loading = true
	self:_emit()
	local res, code = self:_call({ op = "list" })
	self._loading = false
	if res then
		self:_apply(res)
	else
		self._error = code
	end
	self:_emit()
	return res ~= nil, code
end

-- Jalankan satu aksi (busy selama menunggu server). Nilai ketiga = balasan server (untuk jumlah bulk).
function WardrobeController._run(self: WardrobeController, request: { [string]: any }): (boolean, string?, any)
	if self._busy then
		return false, "BUSY", nil
	end
	self._busy = request.op
	self._busyId = request.id
	self:_emit()
	local res, code = self:_call(request)
	self._busy = nil
	self._busyId = nil
	if res then
		self:_apply(res)
	end
	self:_emit()
	return res ~= nil, code, res
end

-- Simpan outfit yang sedang dipakai. name nil / kosong -> nama bawaan.
function WardrobeController.save(self: WardrobeController, name: string?): (boolean, string?)
	if self._loaded and #self._outfits >= self._max then
		return false, "FULL" -- tidak perlu tanya server
	end
	local trimmed = if name then string.match(name, "^%s*(.-)%s*$") else nil
	return self:_run({ op = "save", name = if trimmed ~= "" then trimmed else nil })
end

function WardrobeController.wear(self: WardrobeController, id: number): (boolean, string?)
	return self:_run({ op = "wear", id = id })
end

function WardrobeController.overwrite(self: WardrobeController, id: number): (boolean, string?)
	return self:_run({ op = "overwrite", id = id })
end

function WardrobeController.rename(self: WardrobeController, id: number, name: string): (boolean, string?)
	return self:_run({ op = "rename", id = id, name = name })
end

function WardrobeController.delete(self: WardrobeController, id: number): (boolean, string?)
	return self:_run({ op = "delete", id = id })
end

function WardrobeController.favorite(self: WardrobeController, id: number, value: boolean): (boolean, string?)
	return self:_run({ op = "favorite", id = id, value = value })
end

-- ===== Folder =====

-- Tab folder (tanpa server). Folder yang tidak dikenal -> All.
function WardrobeController.setFolderFilter(self: WardrobeController, value: any)
	local nextFilter = OutfitSort.normalizeFolder(value, self:_folderSet())
	if nextFilter ~= self._folderFilter then
		self._folderFilter = nextFilter
		self:_emit()
	end
end

function WardrobeController.folderAdd(self: WardrobeController, name: string): (boolean, string?)
	if #self._folders >= self._maxFolders then
		return false, "FULL" -- tidak perlu tanya server
	end
	return self:_run({ op = "folderAdd", name = name })
end

function WardrobeController.folderRename(self: WardrobeController, id: number, name: string): (boolean, string?)
	return self:_run({ op = "folderRename", id = id, name = name })
end

-- Hapus folder saja (outfit di dalamnya tetap ada).
function WardrobeController.folderDelete(self: WardrobeController, id: number): (boolean, string?)
	return self:_run({ op = "folderDelete", id = id })
end

-- Ganti total folder satu outfit ("Modify Folders"). `ids` boleh kosong.
function WardrobeController.setFolders(self: WardrobeController, id: number, ids: { number }): (boolean, string?)
	return self:_run({ op = "setFolders", id = id, folders = ids })
end

-- ===== Banyak sekaligus ("Select Outfits") =====

function WardrobeController.bulkDelete(self: WardrobeController, ids: { number }): (boolean, string?, any)
	if #ids == 0 then
		return false, "BAD_ARG", nil
	end
	return self:_run({ op = "bulkDelete", ids = ids })
end

function WardrobeController.bulkFolder(
	self: WardrobeController,
	ids: { number },
	folderId: number,
	value: boolean
): (boolean, string?, any)
	if #ids == 0 then
		return false, "BAD_ARG", nil
	end
	return self:_run({ op = "bulkFolder", ids = ids, id = folderId, value = value })
end

-- Pilihan sort (OutfitSort.OPTIONS). Key asing -> bawaan.
function WardrobeController.setSort(self: WardrobeController, key: string)
	local valid = false
	for _, opt in OutfitSort.OPTIONS do
		valid = valid or opt.key == key
	end
	local nextKey = if valid then key else OutfitSort.DEFAULT
	if nextKey ~= self._sortKey then
		self._sortKey = nextKey
		self:_emit()
	end
end

-- Kata kunci pencarian nama (dirapikan OutfitSort).
function WardrobeController.setQuery(self: WardrobeController, query: string)
	local q = OutfitSort.normalizeQuery(query)
	if q ~= self._query then
		self._query = q
		self:_emit()
	end
end

-- Detail item yang sudah pernah dimuat (tanpa memanggil server). nil = belum ada.
function WardrobeController.itemsCached(self: WardrobeController, id: number): any?
	local o = self:get(id)
	if o == nil then
		return nil
	end
	return self._items[itemsKey(o)]
end

-- YIELD. Nama & harga item di dalam satu outfit (untuk halaman detail).
-- Return (true, { items, total, missing }) | (false, kode). Hasil di-cache per "<id>:<updatedAt>".
function WardrobeController.items(self: WardrobeController, id: number): (boolean, any)
	local o = self:get(id)
	if o == nil then
		return false, "NOT_FOUND"
	end
	local key = itemsKey(o)
	local hit = self._items[key]
	if hit ~= nil then
		return true, hit
	end
	if self._itemsBusy[key] then
		return false, "BUSY"
	end
	self._itemsBusy[key] = true
	local res, code = self:_call({ op = "items", id = id })
	self._itemsBusy[key] = nil
	if res == nil then
		return false, code or "FAILED"
	end
	local data = {
		items = if type(res.items) == "table" then res.items else {},
		total = if type(res.total) == "number" then res.total else 0,
		missing = if type(res.missing) == "number" then res.missing else 0,
	}
	local n = 0
	for _ in self._items do
		n += 1
	end
	if n >= ITEMS_CACHE_MAX then
		table.clear(self._items)
	end
	self._items[key] = data
	return true, data
end

-- ===== Akun Roblox (di luar wardrobe kita) =====
-- Spike 19 Sep 2026: prompt AvatarEditorService & GetOutfits HANYA jalan di client
-- (di server: "This method can only be called on the client"), sedangkan
-- GetHumanoidDescriptionFromOutfitId jalan di dua-duanya -> description diambil di SERVER
-- lewat remote RobloxOutfit supaya server tetap sumber kebenaran.
-- Prompt TIDAK yield (0-1 ms) dan hasilnya datang lewat event ~2,9 detik kemudian, jadi di sini
-- dibungkus jadi panggilan yang YIELD supaya UI tinggal task.spawn + toast.

local PROMPT_TIMEOUT = 90 -- detik; manusia harus sempat membaca dialog Roblox
local PROMPT_POLL = 0.1
local MAX_OUTFIT_PAGES = 4 -- 8 entri per halaman; lebih dari ini tidak muat di panel

-- Jalankan prompt lalu tunggu hasilnya. Return (true, "OK") | (false, "DENIED"|"FAILED"|"TIMEOUT").
local function awaitPrompt(signal: any, run: () -> ()): (boolean, string)
	local done = false
	local result: any = nil
	local conn: RBXScriptConnection? = nil
	conn = signal:Connect(function(res: any)
		if done then
			return
		end
		done = true
		result = res
		if conn then
			conn:Disconnect()
		end
	end)
	local okCall, err = pcall(run)
	if not okCall then
		if conn then
			conn:Disconnect()
		end
		log.warn("prompt Roblox gagal dipanggil", err)
		return false, "FAILED"
	end
	local waited = 0
	while not done and waited < PROMPT_TIMEOUT do
		waited += task.wait(PROMPT_POLL)
	end
	if not done then
		if conn then
			conn:Disconnect()
		end
		return false, "TIMEOUT"
	end
	if result == Enum.AvatarPromptResult.Success then
		return true, "OK"
	end
	if result == Enum.AvatarPromptResult.PermissionDenied then
		return false, "DENIED"
	end
	return false, "FAILED"
end

-- Look yang SEDANG dipakai karakter. Tidak perlu remote: karakternya sudah memakai look-nya.
local function appliedDescription(): (any?, any?)
	local player = Players.LocalPlayer
	local character = if player then player.Character else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return nil, nil
	end
	local ok, desc = pcall(function()
		return humanoid:GetAppliedDescription()
	end)
	if not ok then
		log.warn("GetAppliedDescription gagal", desc)
		return nil, nil
	end
	return desc, humanoid.RigType
end

local function robloxInvoke(request: { [string]: any }): any
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes.func(RemoteNames.Functions.RobloxOutfit):InvokeServer(request)
end

-- Daftar GetOutfits campur: ada OutfitType "DynamicHead" (Man Face, Stevie Standard) yang BUKAN
-- outfit. Nilainya datang sebagai string, tapi diterima juga kalau suatu saat jadi EnumItem.
local function isAvatarOutfit(value: any): boolean
	if value == nil then
		return true -- field tidak ada -> jangan buang datanya
	end
	return tostring(value):match("Avatar$") ~= nil
end

function WardrobeController._setRobloxBusy(self: WardrobeController, op: string?)
	self._robloxBusy = op
	self:_emit()
end

-- YIELD. Tanya server item mana yang BELUM dimiliki (panel review sebelum Save to Roblox).
--   assets  = { assetId }   bundles = { bundleId }
--   -> (true, { unowned = { [id] = true }, details = { [id] = { name, price } } })
--   `unowned` memuat id ASET maupun id BUNDLE; `details` = nama & harga item yang sedang dipakai.
-- Server menjawab dengan daftar id, bukan peta: peta ber-kunci angka lewat remote gampang berubah
-- bentuk. Kepemilikan diambil di server karena jalur inventory client tidak lengkap DAN minta izin
-- per sesi (spike 19 Sep 2026); di server 16 panggilan serentak selesai 876 ms tanpa gagal.
function WardrobeController.ownership(_self: WardrobeController, assets: Ids, bundles: Ids): (boolean, any)
	local ok, res = pcall(function()
		local Remotes = require(Shared.Net.Remotes)
		local RemoteNames = require(Shared.Net.RemoteNames)
		return Remotes.func(RemoteNames.Functions.Ownership):InvokeServer({ assets = assets, bundles = bundles })
	end)
	if not ok or type(res) ~= "table" then
		log.warn("Ownership invoke gagal", res)
		return false, "NETWORK"
	end
	if res.ok ~= true then
		return false, if type(res.code) == "string" then res.code else "FAILED"
	end
	local unowned: { [number]: boolean } = {}
	for _, id in res.unowned or {} do
		if type(id) == "number" then
			unowned[id] = true
		end
	end
	for _, id in res.unownedBundles or {} do
		if type(id) == "number" then
			unowned[id] = true
		end
	end
	-- Nama & harga item yang dipakai, ikut di jawaban yang sama supaya panel tidak perlu
	-- permintaan kedua. Boleh kosong: kepemilikan tetap berlaku tanpa harga.
	local details: { [number]: any } = {}
	for _, entry in res.items or {} do
		if type(entry) == "table" and type(entry.id) == "number" then
			details[entry.id] = entry
		end
	end
	-- Detail BUNDLE dipisah dari detail aset: id bundle dan id aset hidup di ruang nomor yang
	-- berbeda dan bisa kebetulan sama (bundle 239 vs aset 239), jadi satu peta saja tidak aman.
	local bundleDetails: { [number]: any } = {}
	for _, entry in res.bundles or {} do
		if type(entry) == "table" and type(entry.id) == "number" then
			bundleDetails[entry.id] = entry
		end
	end
	return true, { unowned = unowned, details = details, bundleDetails = bundleDetails }
end

-- YIELD. Simpan look sekarang ke akun Roblox.
--   kind = "avatar" -> PromptSaveAvatar (mengganti avatar akun)
--   kind = "outfit" -> PromptCreateOutfit (menambah outfit baru di akun)
-- Roblox sendiri yang menampilkan daftar item yang akan dipasang, jadi UI tidak perlu konfirmasi.
-- Item yang belum dimiliki TIDAK membuat prompt gagal (spike: tetap Success).
function WardrobeController.saveToRoblox(self: WardrobeController, kind: string?): (boolean, string?)
	if self._robloxBusy then
		return false, "BUSY"
	end
	local desc, rig = appliedDescription()
	if desc == nil then
		return false, "NOT_READY"
	end
	local makeOutfit = kind == "outfit"
	self:_setRobloxBusy(if makeOutfit then "createOutfit" else "saveAvatar")
	local rigType = rig or Enum.HumanoidRigType.R15
	local ok, code
	if makeOutfit then
		ok, code = awaitPrompt(AvatarEditorService.PromptCreateOutfitCompleted, function()
			AvatarEditorService:PromptCreateOutfit(desc, rigType)
		end)
	else
		ok, code = awaitPrompt(AvatarEditorService.PromptSaveAvatarCompleted, function()
			AvatarEditorService:PromptSaveAvatar(desc, rigType)
		end)
	end
	if ok and makeOutfit then
		self._robloxOutfits = nil -- daftar loader kedaluwarsa: ada outfit baru
	end
	self:_setRobloxBusy(nil)
	return ok, if ok then nil else code
end

-- YIELD. Daftar outfit akun Roblox untuk Outfit Loader. Izin baca inventory berlaku PER SESI (#28),
-- jadi promptnya hanya muncul sekali. Return (true, { RobloxOutfit }) | (false, kode).
function WardrobeController.robloxOutfits(self: WardrobeController, force: boolean?): (boolean, any)
	if self._robloxOutfits ~= nil and not force then
		return true, self._robloxOutfits
	end
	if self._robloxBusy then
		return false, "BUSY"
	end
	self:_setRobloxBusy("list")
	if not self._inventoryOk then
		local okPerm, codePerm = awaitPrompt(AvatarEditorService.PromptAllowInventoryReadAccessCompleted, function()
			AvatarEditorService:PromptAllowInventoryReadAccess()
		end)
		if not okPerm then
			self:_setRobloxBusy(nil)
			return false, codePerm
		end
		self._inventoryOk = true
	end
	local okPages, pages = pcall(function()
		return AvatarEditorService:GetOutfits()
	end)
	if not okPages or pages == nil then
		log.warn("GetOutfits gagal", pages)
		self:_setRobloxBusy(nil)
		return false, "FAILED"
	end
	local list: { RobloxOutfit } = {}
	for _ = 1, MAX_OUTFIT_PAGES do
		local okPage, entries = pcall(function()
			return pages:GetCurrentPage()
		end)
		if not okPage or type(entries) ~= "table" then
			break
		end
		for _, entry in entries do
			if type(entry) == "table" and type(entry.Id) == "number" and isAvatarOutfit(entry.OutfitType) then
				table.insert(list, {
					id = entry.Id,
					name = if type(entry.Name) == "string" and entry.Name ~= "" then entry.Name else "Outfit",
					editable = entry.IsEditable == true,
				})
			end
		end
		if pages.IsFinished then
			break
		end
		local okNext = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not okNext then
			break
		end
	end
	self._robloxOutfits = list
	self:_setRobloxBusy(nil)
	return true, list
end

-- YIELD. OutfitState satu outfit Roblox (untuk menggambar kartu). 266 ms per id di server ->
-- hasilnya di-cache, dan UI memanggilnya satu per satu (antrean), bukan sekaligus.
function WardrobeController.robloxState(self: WardrobeController, outfitId: number): (boolean, any)
	local cached = self._robloxStates[outfitId]
	if cached ~= nil then
		return true, cached
	end
	local ok, res = pcall(robloxInvoke, { op = "state", outfitId = outfitId })
	if not ok or type(res) ~= "table" then
		log.warn("RobloxOutfit state gagal", res)
		return false, "NETWORK"
	end
	if res.ok ~= true or type(res.state) ~= "table" then
		return false, if type(res.code) == "string" then res.code else "FAILED"
	end
	self._robloxStates[outfitId] = res.state
	return true, res.state
end

-- YIELD. Pakai outfit Roblox itu (server yang memasang; bisa di-Undo seperti slot wardrobe).
function WardrobeController.wearRoblox(self: WardrobeController, outfitId: number): (boolean, string?)
	if self._robloxBusy then
		return false, "BUSY"
	end
	self:_setRobloxBusy("wear")
	local ok, res = pcall(robloxInvoke, { op = "wear", outfitId = outfitId })
	self:_setRobloxBusy(nil)
	if not ok or type(res) ~= "table" then
		log.warn("RobloxOutfit wear gagal", res)
		return false, "NETWORK"
	end
	if res.ok ~= true then
		return false, if type(res.code) == "string" then res.code else "FAILED"
	end
	if type(res.state) == "table" then
		self._robloxStates[outfitId] = res.state
	end
	return true, nil
end

-- YIELD. Avatar yang SEDANG dipakai pemain lain (Outfit Loader mencari username — pola CAC).
-- Daftar outfit TERSIMPAN milik orang lain tidak bisa diambil dari dalam game: GetOutfits hanya
-- untuk pemain sendiri. Jadi yang ditawarkan cuma avatar yang sedang ia pakai.
-- Return (true, { userId, state }) | (false, "NO_USER" | "BAD_NAME" | kode lain).
function WardrobeController.robloxUser(self: WardrobeController, name: string): (boolean, any)
	if self._robloxBusy then
		return false, "BUSY"
	end
	self:_setRobloxBusy("user")
	local ok, res = pcall(robloxInvoke, { op = "user", name = name })
	self:_setRobloxBusy(nil)
	if not ok or type(res) ~= "table" then
		log.warn("RobloxOutfit user gagal", res)
		return false, "NETWORK"
	end
	if res.ok ~= true or type(res.userId) ~= "number" then
		return false, if type(res.code) == "string" then res.code else "FAILED"
	end
	return true, { userId = res.userId, state = res.state }
end

-- YIELD. Pakai avatar pemain lain itu (server yang memasang; bisa di-Undo).
function WardrobeController.wearRobloxUser(self: WardrobeController, userId: number): (boolean, string?)
	if self._robloxBusy then
		return false, "BUSY"
	end
	self:_setRobloxBusy("wear")
	local ok, res = pcall(robloxInvoke, { op = "wearUser", userId = userId })
	self:_setRobloxBusy(nil)
	if not ok or type(res) ~= "table" then
		log.warn("RobloxOutfit wearUser gagal", res)
		return false, "NETWORK"
	end
	if res.ok ~= true then
		return false, if type(res.code) == "string" then res.code else "FAILED"
	end
	return true, nil
end

-- YIELD. Outfit TERSIMPAN milik pemain lain (server mengambilnya lewat proxy — GetOutfits engine
-- hanya untuk pemain sendiri). Gagal itu WAJAR (proxy publik sering 429) -> pemanggil cukup
-- menyembunyikan daftarnya; kartu "Current Avatar" tidak bergantung pada ini.
function WardrobeController.robloxUserOutfits(_self: WardrobeController, userId: number): (boolean, any)
	local ok, res = pcall(robloxInvoke, { op = "userOutfits", userId = userId })
	if not ok or type(res) ~= "table" then
		log.warn("RobloxOutfit userOutfits gagal", res)
		return false, "NETWORK"
	end
	if res.ok ~= true or type(res.outfits) ~= "table" then
		return false, if type(res.code) == "string" then res.code else "FAILED"
	end
	return true, res.outfits
end

-- Setting "pakai outfit terakhir saat join".
function WardrobeController.setRestoreOutfit(self: WardrobeController, value: boolean): (boolean, string?)
	return self:_run({ op = "setSetting", key = "restoreOutfit", value = value })
end

return WardrobeController
