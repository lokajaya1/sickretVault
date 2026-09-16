--!strict
-- State panel detail item di client. Memanggil remote GetItemDetail + cache hasil sukses.
--   local detail = DetailController.new()
--   detail:onChanged(function(state) ... end)
--   detail:open(123, "Asset")    -- YIELD saat memuat -> panggil dari task.spawn di UI
--   detail:close()               -- tombol Back
--   detail:retry()               -- tombol "Coba lagi" setelah error
-- Balasan lama diabaikan (buka item lain / tutup saat masih memuat).
-- `invoke` bisa diganti saat test (tanpa remote).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cache = require(Shared.Util.Cache)
local Log = require(Shared.Util.Log)

local log = Log.new("DetailController")

local CACHE_TTL = 600 -- detik
local CACHE_SIZE = 100

export type State = {
	isOpen: boolean,
	id: number?,
	itemType: string?, -- "Asset" | "Bundle"
	detail: any?, -- ItemDetail.Detail dari server (nil saat memuat / error)
	loading: boolean,
	error: string?, -- "RATE_LIMITED" | "NOT_FOUND" | "FAILED" | "BAD_ARG" | "NETWORK"
}

export type Invoke = (request: { id: number, itemType: string }) -> any

local DetailController = {}
DetailController.__index = DetailController

export type DetailController = typeof(setmetatable(
	{} :: {
		_invoke: Invoke,
		_state: State,
		_cache: Cache.Cache,
		_token: number,
		_listeners: { (State) -> () },
	},
	DetailController
))

local function defaultInvoke(request: { id: number, itemType: string }): any
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes.func(RemoteNames.Functions.GetItemDetail):InvokeServer(request)
end

local function closedState(): State
	return { isOpen = false, id = nil, itemType = nil, detail = nil, loading = false, error = nil }
end

function DetailController.new(invoke: Invoke?, clock: (() -> number)?): DetailController
	return setmetatable({
		_invoke = invoke or defaultInvoke,
		_state = closedState(),
		_cache = Cache.new({ ttl = CACHE_TTL, maxSize = CACHE_SIZE, clock = clock }),
		_token = 0,
		_listeners = {},
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
	self._state = { isOpen = true, id = id, itemType = itemType, detail = nil, loading = false, error = nil }
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

return DetailController
