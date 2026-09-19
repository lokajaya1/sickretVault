--!strict
-- State outfit di client (cermin dari server). Server = sumber kebenaran; client hanya
-- mengirim intent dan menampilkan state terakhir yang diterima lewat StateChanged.
--   local outfit = OutfitController.new()
--   outfit:start()                          -- dengarkan StateChanged/Notify + minta GetState
--   outfit:onChanged(function(state) ... end)
--   outfit:onNotify(function(msg) ... end)  -- msg = { code, op? }
--   outfit:onBackground(function(bg) ... end) -- bg = { assetId, image, color } | nil (latar preview)
--   outfit:toggle(item)                     -- kartu katalog: pakai / lepas
--   outfit:isWorn(assetId) -> boolean
--   outfit:isBundleWorn(bundleId) -> boolean   -- ada part bundle itu yang sedang dipakai
-- `deps` bisa diganti saat test (tanpa remote).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared.Util.Log)

local log = Log.new("OutfitController")

export type Notice = { code: string, op: string? }

export type Deps = {
	fire: ((intent: { [string]: any }) -> ())?, -- AvatarIntent:FireServer
	getState: (() -> any)?, -- GetState:InvokeServer
	onState: ((fn: (state: any) -> ()) -> any)?, -- StateChanged.OnClientEvent:Connect
	onNotice: ((fn: (msg: any) -> ()) -> any)?, -- Notify.OnClientEvent:Connect
	onMakeup: ((fn: (dto: any) -> ()) -> any)?, -- MakeupChanged.OnClientEvent:Connect
	onBackgroundEvent: ((fn: (dto: any) -> ()) -> any)?, -- BackgroundChanged.OnClientEvent:Connect
}

local OutfitController = {}
OutfitController.__index = OutfitController

export type OutfitController = typeof(setmetatable(
	{} :: {
		_deps: Deps,
		_state: any?,
		_baseline: any?, -- avatar asli akun (tujuan `reset`); datang sekali lewat GetState
		_baselineAsked: boolean, -- GetState susulan sudah diminta (jangan berulang-ulang)
		_worn: { [number]: boolean },
		_makeup: { [number]: boolean }, -- makeup dipasang sebagai Decal, di luar OutfitState
		_makeupRows: { any }, -- Makeup.toDto apa adanya: dibutuhkan pratinjau (assetId + slot)
		_background: any?, -- latar area preview: { assetId, image, color }; di luar OutfitState juga
		_bundles: { [number]: boolean },
		_listeners: { (any) -> () },
		_noticeListeners: { (Notice) -> () },
		_backgroundListeners: { (any) -> () },
		_conns: { any },
		_started: boolean,
	},
	OutfitController
))

local function remotes()
	local Remotes = require(Shared.Net.Remotes)
	local RemoteNames = require(Shared.Net.RemoteNames)
	return Remotes, RemoteNames
end

local function defaultDeps(): Deps
	return {
		fire = function(intent)
			local Remotes, Names = remotes()
			Remotes.event(Names.Events.AvatarIntent):FireServer(intent)
		end,
		getState = function()
			local Remotes, Names = remotes()
			return Remotes.func(Names.Functions.GetState):InvokeServer()
		end,
		onState = function(fn)
			local Remotes, Names = remotes()
			return Remotes.event(Names.Events.StateChanged).OnClientEvent:Connect(fn)
		end,
		onNotice = function(fn)
			local Remotes, Names = remotes()
			return Remotes.event(Names.Events.Notify).OnClientEvent:Connect(fn)
		end,
		onMakeup = function(fn)
			local Remotes, Names = remotes()
			return Remotes.event(Names.Events.MakeupChanged).OnClientEvent:Connect(fn)
		end,
		onBackgroundEvent = function(fn)
			local Remotes, Names = remotes()
			return Remotes.event(Names.Events.BackgroundChanged).OnClientEvent:Connect(fn)
		end,
	}
end

function OutfitController.new(deps: Deps?): OutfitController
	local d = defaultDeps()
	for k, v in (deps or {}) :: any do
		(d :: any)[k] = v
	end
	return setmetatable({
		_deps = d,
		_state = nil,
		_baseline = nil,
		_baselineAsked = false,
		_worn = {},
		_makeup = {},
		_makeupRows = {},
		_background = nil,
		_bundles = {},
		_listeners = {},
		_noticeListeners = {},
		_backgroundListeners = {},
		_conns = {},
		_started = false,
	}, OutfitController)
end

-- Kumpulan assetId yang sedang dipakai (aksesori + slot non-kosong).
local function collectWorn(state: any): { [number]: boolean }
	local worn: { [number]: boolean } = {}
	if type(state) ~= "table" then
		return worn
	end
	if type(state.accessories) == "table" then
		for _, a in state.accessories do
			if type(a) == "table" and type(a.assetId) == "number" then
				worn[a.assetId] = true
			end
		end
	end
	for _, group in { state.bodyParts, state.animations, state.classic } do
		if type(group) == "table" then
			for _, v in group do
				if type(v) == "table" and type(v.id) == "number" and v.id ~= 0 then
					worn[v.id] = true
				end
			end
		end
	end
	return worn
end

-- Kumpulan bundleId yang sedang dipakai (minimal satu part ber-source bundle itu).
local function collectBundles(state: any): { [number]: boolean }
	local out: { [number]: boolean } = {}
	if type(state) ~= "table" then
		return out
	end
	local function add(src: any)
		if type(src) == "number" then
			out[src] = true
		end
	end
	if type(state.accessories) == "table" then
		for _, a in state.accessories do
			if type(a) == "table" then
				add(a.source)
			end
		end
	end
	for _, group in { state.bodyParts, state.animations, state.classic } do
		if type(group) == "table" then
			for _, v in group do
				if type(v) == "table" and type(v.id) == "number" and v.id ~= 0 then
					add(v.source)
				end
			end
		end
	end
	return out
end

local function emit(list: { any }, value: any)
	for _, fn in table.clone(list) do
		local ok, err = pcall(fn, value)
		if not ok then
			log.warn("listener error", err)
		end
	end
end

-- Daftar makeup dari server (Makeup.toDto). Di luar OutfitState, jadi disimpan terpisah.
function OutfitController._setMakeup(self: OutfitController, dto: any)
	local set: { [number]: boolean } = {}
	local rows: { any } = {}
	if type(dto) == "table" then
		for _, row in dto do
			if type(row) == "table" and type(row.assetId) == "number" then
				set[row.assetId] = true
				table.insert(rows, row)
			end
		end
	end
	self._makeup = set
	-- Barisnya disimpan utuh (bukan cuma assetId): pratinjau butuh slotnya juga.
	self._makeupRows = rows
	if self._state ~= nil then
		emit(self._listeners, self._state) -- kartu perlu digambar ulang (tanda dipakai)
	end
end

-- Latar area preview dari server ({ assetId, image, color } | nil). BUKAN bagian OutfitState:
-- ia tidak menempel di avatar, cuma gambar di belakang ViewportFrame preview. Kartu tetap
-- digambar ulang supaya tombol item latar ikut berubah jadi "sedang dipakai".
function OutfitController._setBackground(self: OutfitController, dto: any)
	local valid = if type(dto) == "table" and type(dto.assetId) == "number" then dto else nil
	self._background = valid
	emit(self._backgroundListeners, valid)
	if self._state ~= nil then
		emit(self._listeners, self._state)
	end
end

-- Avatar asli akun HANYA ada di jawaban GetState. Kalau sesi server belum siap saat `start()`
-- memanggilnya, jawabannya NOT_READY -- state-nya sendiri menyusul lewat StateChanged, dan
-- baseline tidak pernah datang. Diukur 19 Sep 2026: itulah yang terjadi di Studio, panel
-- "Reset to Roblox Avatar?" selalu jatuh ke cadangan (avatar sekarang). Jadi begitu state pertama
-- tiba tanpa baseline, GetState diminta SEKALI lagi di thread sendiri (ia yield).
function OutfitController._ensureBaseline(self: OutfitController)
	if self._baseline ~= nil or self._baselineAsked then
		return
	end
	self._baselineAsked = true
	local getState = self._deps.getState
	if getState == nil then
		return
	end
	task.spawn(function()
		local ok, res = pcall(getState :: any)
		if ok and type(res) == "table" and res.ok and type(res.baseline) == "table" then
			self._baseline = res.baseline
		else
			log.warn("avatar asli tidak terambil", if ok then "jawaban tanpa baseline" else res)
		end
	end)
end

function OutfitController._setState(self: OutfitController, state: any)
	if type(state) ~= "table" then
		return
	end
	self._state = state
	self._worn = collectWorn(state)
	self._bundles = collectBundles(state)
	self:_ensureBaseline()
	emit(self._listeners, state)
end

-- Mulai mendengarkan server. Aman dipanggil dua kali. Yield sebentar (GetState).
function OutfitController.start(self: OutfitController)
	if self._started then
		return
	end
	self._started = true
	local d = self._deps
	table.insert(
		self._conns,
		(d.onState :: any)(function(state)
			self:_setState(state)
		end)
	)
	table.insert(
		self._conns,
		(d.onNotice :: any)(function(msg)
			if type(msg) == "table" and type(msg.code) == "string" then
				emit(self._noticeListeners, { code = msg.code, op = msg.op })
			end
		end)
	)
	if d.onMakeup then
		table.insert(
			self._conns,
			(d.onMakeup :: any)(function(dto)
				self:_setMakeup(dto)
			end)
		)
	end
	if d.onBackgroundEvent then
		table.insert(
			self._conns,
			(d.onBackgroundEvent :: any)(function(dto)
				self:_setBackground(dto)
			end)
		)
	end
	-- StateChanged awal mungkin sudah lewat (atau tertunda) -> minta juga secara eksplisit.
	local ok, res = pcall(d.getState :: any)
	if ok and type(res) == "table" and res.ok then
		-- BASELINE DIAMBIL DI LUAR penjaga `self._state == nil`. Penjaga itu ada supaya jawaban
		-- GetState tidak menimpa state yang lebih baru dari StateChanged -- dan StateChanged
		-- biasanya MENDAHULUI panggilan ini. Baseline tidak pernah ikut StateChanged, jadi dulu ia
		-- selalu ikut terbuang bersama jawaban ini: panel "Reset to Roblox Avatar?" pun kosong.
		if type(res.baseline) == "table" then
			self._baseline = res.baseline
		end
		if self._state == nil then
			self:_setState(res.state)
			self:_setMakeup(res.makeup)
			self:_setBackground(res.background)
		end
	elseif not ok then
		log.warn("GetState gagal", res)
	end
end

function OutfitController.stop(self: OutfitController)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self._started = false
end

-- Avatar asli akun pemain. nil = server belum sempat mengirimnya (UI harus tahan terhadap itu).
function OutfitController.getBaseline(self: OutfitController): any?
	return self._baseline
end

function OutfitController.getState(self: OutfitController): any?
	return self._state
end

function OutfitController.isWorn(self: OutfitController, assetId: number): boolean
	if self._background ~= nil and self._background.assetId == assetId then
		return true -- latar yang sedang terpasang: tombolnya jadi "lepas"
	end
	return self._worn[assetId] == true or self._makeup[assetId] == true
end

function OutfitController.isBundleWorn(self: OutfitController, bundleId: number): boolean
	return self._bundles[bundleId] == true
end

local function subscribe(list: { any }, fn: any): () -> ()
	table.insert(list, fn)
	return function()
		local i = table.find(list, fn)
		if i then
			table.remove(list, i)
		end
	end
end

-- Berapa makeup yang sedang dipakai. Dipakai dialog Item Removal untuk angka barisnya;
-- makeup tidak ada di OutfitState, jadi ia tidak bisa dihitung lewat OutfitState.removeKind.
-- Baris makeup apa adanya (assetId + slot + textureId), untuk pratinjau look.
function OutfitController.makeupRows(self: OutfitController): { any }
	return self._makeupRows
end

function OutfitController.makeupCount(self: OutfitController): number
	local n = 0
	for _ in self._makeup do
		n += 1
	end
	return n
end

function OutfitController.onChanged(self: OutfitController, fn: (any) -> ()): () -> ()
	return subscribe(self._listeners, fn)
end

function OutfitController.onNotify(self: OutfitController, fn: (Notice) -> ()): () -> ()
	return subscribe(self._noticeListeners, fn)
end

-- Latar area preview. Dipanggil LANGSUNG dengan nilai sekarang supaya pemasang yang datang
-- setelah start() (mis. UI dibangun ulang) tidak kehilangan latar yang sudah berlaku.
function OutfitController.onBackground(self: OutfitController, fn: (any) -> ()): () -> ()
	local off = subscribe(self._backgroundListeners, fn)
	if self._background ~= nil then
		task.spawn(fn, self._background)
	end
	return off
end

function OutfitController.getBackground(self: OutfitController): any?
	return self._background
end

function OutfitController.send(self: OutfitController, intent: { [string]: any })
	local ok, err = pcall(self._deps.fire :: any, intent)
	if not ok then
		log.warn("gagal kirim intent", err)
	end
end

-- Kartu katalog diklik: pakai / lepas (aset maupun bundle).
function OutfitController.toggle(self: OutfitController, item: any)
	if type(item) ~= "table" or type(item.id) ~= "number" then
		return
	end
	if item.itemType == "Bundle" then
		if self:isBundleWorn(item.id) then
			self:send({ op = "removeBundle", bundleId = item.id })
		else
			self:send({ op = "wearBundle", bundleId = item.id })
		end
	elseif self:isWorn(item.id) then
		self:send({ op = "remove", assetId = item.id })
	else
		self:send({ op = "wear", assetId = item.id })
	end
end

return OutfitController
