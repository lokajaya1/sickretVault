--!strict
-- State katalog di client: kategori, keyword, sort, daftar item (gabungan semua halaman).
-- Memanggil remote CatalogSearch; UI cukup membaca :getState() dan mendengarkan :onChanged().
--   local catalog = CatalogController.new()
--   catalog:onChanged(function(state) ... end)
--   catalog:setCategory("hats")      -- muat halaman 1
--   catalog:loadMore()               -- halaman berikutnya (abaikan jika sedang memuat / habis)
-- `invoke` bisa diganti saat test (tanpa remote).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Categories = require(Shared.Config.Categories)
local Log = require(Shared.Util.Log)

local log = Log.new("CatalogController")

export type Item = {
	id: number,
	itemType: string,
	assetType: string?,
	bundleType: string?,
	name: string,
	creatorName: string?,
	price: number?,
}

export type State = {
	categoryId: string,
	keyword: string,
	sort: string,
	items: { Item },
	page: number, -- halaman terakhir yang sudah dimuat (0 = belum ada)
	hasMore: boolean,
	loading: boolean,
	error: string?, -- kode error terakhir: "RATE_LIMITED" | "FAILED" | "BAD_ARG" | "NETWORK"
}

export type Invoke = (request: { [string]: any }) -> any

local CatalogController = {}
CatalogController.__index = CatalogController

export type CatalogController = typeof(setmetatable(
	{} :: {
		_invoke: Invoke,
		_state: State,
		_seen: { [string]: boolean },
		_token: number,
		_listeners: { (State) -> () },
	},
	CatalogController
))

local function defaultInvoke(request: { [string]: any }): any
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes.func(RemoteNames.Functions.CatalogSearch):InvokeServer(request)
end

function CatalogController.new(invoke: Invoke?): CatalogController
	local first = Categories.list[1]
	return setmetatable({
		_invoke = invoke or defaultInvoke,
		_state = {
			categoryId = first.id,
			keyword = "",
			sort = "Relevance",
			items = {},
			page = 0,
			hasMore = true,
			loading = false,
			error = nil,
		},
		_seen = {},
		_token = 0,
		_listeners = {},
	}, CatalogController)
end

function CatalogController.getState(self: CatalogController): State
	return self._state
end

-- Daftarkan listener; kembalikan fungsi untuk berhenti mendengarkan.
function CatalogController.onChanged(self: CatalogController, fn: (State) -> ()): () -> ()
	table.insert(self._listeners, fn)
	return function()
		local i = table.find(self._listeners, fn)
		if i then
			table.remove(self._listeners, i)
		end
	end
end

function CatalogController._emit(self: CatalogController)
	for _, fn in table.clone(self._listeners) do
		local ok, err = pcall(fn, self._state)
		if not ok then
			log.warn("listener error", err)
		end
	end
end

-- Mulai ulang dari halaman 1 (dipanggil saat kategori/keyword/sort berubah).
function CatalogController._reset(self: CatalogController)
	self._token += 1 -- balasan permintaan lama akan diabaikan
	self._state.items = {}
	self._state.page = 0
	self._state.hasMore = true
	self._state.loading = false
	self._state.error = nil
	self._seen = {}
end

function CatalogController._fetch(self: CatalogController)
	local s = self._state
	if s.loading or not s.hasMore then
		return
	end
	self._token += 1
	local token = self._token
	local page = s.page + 1
	s.loading = true
	s.error = nil
	self:_emit()

	local ok, res = pcall(self._invoke, {
		categoryId = s.categoryId,
		keyword = s.keyword,
		sort = s.sort,
		page = page,
	})

	if token ~= self._token then
		return -- permintaan sudah usang (kategori/keyword berganti)
	end
	s.loading = false
	if not ok or type(res) ~= "table" then
		log.warn("invoke gagal", res)
		s.error = "NETWORK"
	elseif not res.ok then
		s.error = if type(res.code) == "string" then res.code else "FAILED"
	else
		for _, item in (res.items or {}) :: { Item } do
			local key = item.itemType .. ":" .. tostring(item.id)
			if not self._seen[key] then -- API kadang mengulang item antar halaman
				self._seen[key] = true
				table.insert(s.items, item)
			end
		end
		s.page = page
		s.hasMore = res.hasMore == true
	end
	self:_emit()
end

function CatalogController.setCategory(self: CatalogController, categoryId: string)
	if Categories.byId[categoryId] == nil then
		log.warn("kategori tidak dikenal", categoryId)
		return
	end
	self._state.categoryId = categoryId
	self:_reset()
	self:_fetch()
end

function CatalogController.setKeyword(self: CatalogController, keyword: string)
	keyword = string.sub(keyword, 1, 50)
	while utf8.len(keyword) == nil do -- jangan potong di tengah huruf UTF-8
		keyword = string.sub(keyword, 1, -2)
	end
	if keyword == self._state.keyword and self._state.page > 0 then
		return
	end
	self._state.keyword = keyword
	self:_reset()
	self:_fetch()
end

function CatalogController.setSort(self: CatalogController, sort: string)
	if sort == self._state.sort and self._state.page > 0 then
		return
	end
	self._state.sort = sort
	self:_reset()
	self:_fetch()
end

function CatalogController.loadMore(self: CatalogController)
	self:_fetch()
end

-- Ulangi permintaan terakhir yang gagal (mis. tombol "Coba lagi").
function CatalogController.retry(self: CatalogController)
	if self._state.error == nil then
		return
	end
	self._state.error = nil
	self:_fetch()
end

return CatalogController
