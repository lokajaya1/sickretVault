--!strict
-- Wardrobe di client: cache daftar slot + setting, semua perubahan lewat remote Wardrobe (server memutuskan).
--   local wardrobe = WardrobeController.new()
--   wardrobe:onChanged(function(snap) ... end)  -- snap = { loaded, loading, busy, error, outfits, max, restoreOutfit }
--   wardrobe:refresh()                          -- YIELD (list). Panggil saat panel dibuka
--   local ok, code = wardrobe:save(name?)       -- YIELD; nil = nama bawaan "Outfit N"
--   wardrobe:wear(id) / overwrite(id) / rename(id, name) / delete(id) / favorite(id, bool)
--   wardrobe:setRestoreOutfit(bool)                                                         -- YIELD
--   wardrobe:setSort("az")   wardrobe:setQuery("pesta")  -- tanpa server; snap.visible = hasil cari + urut
-- Semua aksi YIELD (InvokeServer) -> panggil dari task.spawn di UI.
-- Satu aksi pada satu waktu (busy); aksi lain saat busy -> (false, "BUSY") tanpa memanggil server.
-- Kode gagal: kode server (NOT_LOADED, FULL, FILTERED, ...) atau "NETWORK" (invoke error).
-- `invoke` bisa diganti saat test (tanpa remote).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared.Util.Log)
local OutfitSort = require(Shared.Domain.OutfitSort)

local log = Log.new("WardrobeController")

export type Summary = {
	id: number,
	name: string,
	createdAt: number,
	updatedAt: number,
	favorite: boolean,
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
	max: number,
	isFull: boolean,
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
		_restore: boolean?,
		_sortKey: string,
		_query: string,
		_listeners: { (Snapshot) -> () },
	},
	WardrobeController
))

local DEFAULT_MAX = 30

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
		_restore = nil,
		_sortKey = OutfitSort.DEFAULT,
		_query = "",
		_listeners = {},
	}, WardrobeController)
end

function WardrobeController.getSnapshot(self: WardrobeController): Snapshot
	return {
		loaded = self._loaded,
		loading = self._loading,
		busy = self._busy,
		busyId = self._busyId,
		error = self._error,
		outfits = table.clone(self._outfits),
		visible = OutfitSort.apply(self._outfits, self._sortKey, self._query),
		sortKey = self._sortKey,
		query = self._query,
		max = self._max,
		isFull = #self._outfits >= self._max,
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
	if type(res.max) == "number" then
		self._max = res.max
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

-- Jalankan satu aksi (busy selama menunggu server).
function WardrobeController._run(self: WardrobeController, request: { [string]: any }): (boolean, string?)
	if self._busy then
		return false, "BUSY"
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
	return res ~= nil, code
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

-- Setting "pakai outfit terakhir saat join".
function WardrobeController.setRestoreOutfit(self: WardrobeController, value: boolean): (boolean, string?)
	return self:_run({ op = "setSetting", key = "restoreOutfit", value = value })
end

return WardrobeController
