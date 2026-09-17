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
-- Semua aksi YIELD (InvokeServer) -> panggil dari task.spawn di UI.
-- Satu aksi pada satu waktu (busy); aksi lain saat busy -> (false, "BUSY") tanpa memanggil server.
-- Kode gagal: kode server (NOT_LOADED, FULL, FILTERED, ...) atau "NETWORK" (invoke error).
-- `invoke` bisa diganti saat test (tanpa remote).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

export type Summary = {
	id: number,
	name: string,
	createdAt: number,
	updatedAt: number,
	favorite: boolean,
	folders: { number },
	count: number,
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
}

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

-- Setting "pakai outfit terakhir saat join".
function WardrobeController.setRestoreOutfit(self: WardrobeController, value: boolean): (boolean, string?)
	return self:_run({ op = "setSetting", key = "restoreOutfit", value = value })
end

return WardrobeController
