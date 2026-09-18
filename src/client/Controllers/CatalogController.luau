--!strict
-- State katalog di client: kategori, keyword, sort, daftar item (gabungan semua halaman).
-- Memanggil remote CatalogSearch; UI cukup membaca :getState() dan mendengarkan :onChanged().
--   local catalog = CatalogController.new()
--   catalog:onChanged(function(state) ... end)
--   catalog:setCategory("hats")      -- muat halaman 1 (kategori tunggal)
--   catalog:setFilter("clothing", "free") -- chip baris kedua: all | free | limited satu grup
--   catalog:loadMore()               -- halaman berikutnya (abaikan jika sedang memuat / habis)
--   catalog:setCreator("94E", "Group") -- nama creator diklik di halaman detail (#17d)
--   catalog:clearCreator()           -- chip "94E x" di header: kembali ke kategori sebelumnya
--   catalog:setOptions({ sort = "PriceLowToHigh", minPrice = 100 }) -- panel "Search Options" (#17e)
--   catalog:clearOptions()           -- tombol Reset di panel itu
-- `invoke` bisa diganti saat test (tanpa remote).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Categories = require(Shared.Config.Categories)
local CatalogMenu = require(Shared.Config.CatalogMenu)
local Log = require(Shared.Util.Log)

local log = Log.new("CatalogController")

-- Cermin MAX_PRICE_INPUT di CatalogService: kalau beda, server yang menolak dan pemain melihat error.
local MAX_PRICE = 1000000

-- Urutan pilihan sort di panel "Search Options". Kuncinya nama Enum.CatalogSortType yang diterima
-- CatalogService.SORTS. Ditaruh di sini, bukan di Config baru, supaya tidak menambah file;
-- dibuka ke panel lewat CatalogController.SORT_OPTIONS.
local SORT_OPTIONS = {
	{ key = "Relevance", label = "Relevance" },
	{ key = "MostFavorited", label = "Most Favorited" },
	{ key = "RecentlyCreated", label = "Recently Created" },
	{ key = "PriceLowToHigh", label = "Price: Low to High" },
	{ key = "PriceHighToLow", label = "Price: High to Low" },
}

local SORTS: { [string]: boolean } = {}
for _, opt in SORT_OPTIONS do
	SORTS[opt.key] = true
end

-- Angka dari kotak teks panel: kosong/ngawur -> nil; sisanya dibulatkan & dijepit ke 0..MAX_PRICE.
local function priceInput(v: any): number?
	local n = if type(v) == "number" then v else tonumber(v)
	if n == nil or n ~= n or n < 0 then
		return nil
	end
	return math.min(math.floor(n), MAX_PRICE)
end

export type Item = {
	id: number,
	itemType: string,
	assetType: string?,
	bundleType: string?,
	name: string,
	creatorName: string?,
	creatorType: string?,
	price: number?,
}

export type State = {
	categoryId: string?, -- kategori tunggal yang aktif (nil saat chip filter dipakai)
	groupId: string?, -- grup mozaik untuk chip filter
	filter: string?, -- "all" | "free" | "limited" (nil = memakai categoryId)
	creatorName: string?, -- mode hasil creator: kategori & grup dilepas, semua tipe ikut
	creatorType: string?, -- "User" | "Group"
	keyword: string,
	sort: string,
	minPrice: number?, -- panel "Search Options"; bertahan saat pindah kategori
	maxPrice: number?,
	includeOffSale: boolean?,
	items: { Item },
	page: number, -- halaman terakhir yang sudah dimuat (0 = belum ada)
	hasMore: boolean,
	loading: boolean,
	error: string?, -- kode error terakhir: "RATE_LIMITED" | "FAILED" | "BAD_ARG" | "NETWORK"
}

export type Invoke = (request: { [string]: any }) -> any

local CatalogController = {}
CatalogController.__index = CatalogController
CatalogController.SORT_OPTIONS = SORT_OPTIONS

export type CatalogController = typeof(setmetatable(
	{} :: {
		_invoke: Invoke,
		_state: State,
		_seen: { [string]: boolean },
		_before: { categoryId: string?, groupId: string?, filter: string? }?,
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
			groupId = nil,
			filter = nil,
			creatorName = nil,
			creatorType = nil,
			keyword = "",
			sort = "Relevance",
			minPrice = nil,
			maxPrice = nil,
			includeOffSale = nil,
			items = {},
			page = 0,
			hasMore = true,
			loading = false,
			error = nil,
		},
		_seen = {},
		_before = nil,
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
		categoryId = if s.filter then nil else s.categoryId,
		groupId = s.groupId,
		filter = s.filter,
		creatorName = s.creatorName,
		creatorType = s.creatorType,
		keyword = s.keyword,
		sort = s.sort,
		minPrice = s.minPrice,
		maxPrice = s.maxPrice,
		includeOffSale = s.includeOffSale,
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
	self._state.groupId = nil
	self._state.filter = nil
	self:_forgetCreator()
	self:_reset()
	self:_fetch()
end

-- Chip filter satu grup (All / Free / Limited). Kategori tunggal dilepas.
function CatalogController.setFilter(self: CatalogController, groupId: string, filter: string)
	if CatalogMenu.byId[groupId] == nil then
		log.warn("grup tidak dikenal", groupId)
		return
	end
	if not CatalogMenu.isFilter(filter) then
		log.warn("filter tidak dikenal", filter)
		return
	end
	self._state.groupId = groupId
	self._state.filter = filter
	self._state.categoryId = nil
	self:_forgetCreator()
	self:_reset()
	self:_fetch()
end

-- Keluar dari mode creator tanpa memuat ulang (dipakai setCategory / setFilter yang sudah memuat).
function CatalogController._forgetCreator(self: CatalogController)
	self._state.creatorName = nil
	self._state.creatorType = nil
	self._before = nil
end

-- Nama creator diklik di halaman detail: kategori & grup dilepas supaya SEMUA tipe karyanya muncul
-- (spike 19 Sep 2026: CreatorName tanpa saringan tipe memberi hasil waras; nama ngawur -> 0 item).
-- Keyword dikosongkan: kata kunci lama + creator baru hampir selalu memberi nol hasil.
function CatalogController.setCreator(self: CatalogController, creatorName: string, creatorType: string?)
	if type(creatorName) ~= "string" or creatorName == "" then
		log.warn("nama creator tidak valid", creatorName)
		return
	end
	if creatorType ~= "User" and creatorType ~= "Group" then
		creatorType = nil -- tipe asing / tidak diketahui: cari dengan nama saja
	end
	local s = self._state
	if s.creatorName == nil then
		self._before = { categoryId = s.categoryId, groupId = s.groupId, filter = s.filter }
	end
	s.creatorName = creatorName
	s.creatorType = creatorType
	s.categoryId = nil
	s.groupId = nil
	s.filter = nil
	s.keyword = ""
	self:_reset()
	self:_fetch()
end

-- Kembali ke kategori/chip sebelum mode creator, TANPA memuat ulang (pemanggil yang memuat).
function CatalogController._restoreBefore(self: CatalogController)
	local s = self._state
	local before = self._before or { categoryId = Categories.list[1].id }
	self:_forgetCreator()
	s.categoryId = before.categoryId
	s.groupId = before.groupId
	s.filter = before.filter
	if s.categoryId == nil and s.groupId == nil then
		s.categoryId = Categories.list[1].id
	end
end

-- Chip "<nama> x" di header: kembali ke kategori/chip yang aktif sebelum masuk mode creator.
function CatalogController.clearCreator(self: CatalogController)
	if self._state.creatorName == nil then
		return
	end
	self:_restoreBefore()
	self:_reset()
	self:_fetch()
end

-- Id chip yang sedang aktif di baris kedua ("all"/"free"/"limited" atau id kategori).
function CatalogController.activeChip(self: CatalogController): string?
	return self._state.filter or self._state.categoryId
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

export type Options = {
	sort: string?,
	minPrice: number?,
	maxPrice: number?,
	includeOffSale: boolean?,
	creatorName: string?,
	creatorType: string?, -- "User" | "Group"; nil = semua pencipta
}

-- Tombol Apply di panel "Search Options": SEMUA pilihan dipasang sekaligus lalu SATU pencarian.
-- Memanggil setSort/setCreator satu per satu akan menembak beberapa pencarian beruntun (HTTP 429
-- sudah kejadian di #17b). Field yang TIDAK disebut dianggap dikosongkan: panel selalu mengirim
-- keadaan lengkapnya, jadi `clearOptions` cukup memanggil ini dengan tabel kosong.
function CatalogController.setOptions(self: CatalogController, opts: Options)
	local s = self._state
	local sort = if type(opts.sort) == "string" and SORTS[opts.sort] then opts.sort else "Relevance"
	local minPrice = priceInput(opts.minPrice)
	local maxPrice = priceInput(opts.maxPrice)
	-- Ditukar di sini juga supaya kotak di panel menampilkan yang benar; server menukarnya lagi
	-- karena API mentah membalas HTTP 400 untuk rentang terbalik (spike 19 Sep 2026 tes 21).
	if minPrice ~= nil and maxPrice ~= nil and minPrice > maxPrice then
		minPrice, maxPrice = maxPrice, minPrice
	end
	local offSale = opts.includeOffSale == true
	local creatorName: string? = nil
	if type(opts.creatorName) == "string" and opts.creatorName ~= "" then
		creatorName = opts.creatorName
	end
	local creatorType: string? = nil
	if creatorName ~= nil and (opts.creatorType == "User" or opts.creatorType == "Group") then
		creatorType = opts.creatorType
	end

	local same = sort == s.sort
		and minPrice == s.minPrice
		and maxPrice == s.maxPrice
		and offSale == (s.includeOffSale == true)
		and creatorName == s.creatorName
		and creatorType == s.creatorType
	if same and s.page > 0 then
		return -- Apply ditekan tanpa mengubah apa pun: jangan buang satu pencarian
	end

	if creatorName ~= nil and s.creatorName == nil then
		self._before = { categoryId = s.categoryId, groupId = s.groupId, filter = s.filter }
	end
	s.sort = sort
	s.minPrice = minPrice
	s.maxPrice = maxPrice
	s.includeOffSale = if offSale then true else nil
	if creatorName ~= nil then
		-- Mode creator melepas kategori & grup supaya SEMUA tipe karyanya muncul (#17d).
		s.creatorName = creatorName
		s.creatorType = creatorType
		s.categoryId = nil
		s.groupId = nil
		s.filter = nil
		s.keyword = ""
	elseif s.creatorName ~= nil then
		self:_restoreBefore()
	end
	self:_reset()
	self:_fetch()
end

-- Tombol Reset di panel: semua pilihan kembali ke bawaan, termasuk keluar dari mode creator.
function CatalogController.clearOptions(self: CatalogController)
	self:setOptions({})
end

-- Panel memakai ini untuk menyalakan ikon pemicu selama ada saringan yang aktif.
function CatalogController.hasOptions(self: CatalogController): boolean
	local s = self._state
	return s.sort ~= "Relevance"
		or s.minPrice ~= nil
		or s.maxPrice ~= nil
		or s.includeOffSale == true
		or s.creatorName ~= nil
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
