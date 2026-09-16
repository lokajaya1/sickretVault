--!strict
-- State outfit di client (cermin dari server). Server = sumber kebenaran; client hanya
-- mengirim intent dan menampilkan state terakhir yang diterima lewat StateChanged.
--   local outfit = OutfitController.new()
--   outfit:start()                          -- dengarkan StateChanged/Notify + minta GetState
--   outfit:onChanged(function(state) ... end)
--   outfit:onNotify(function(msg) ... end)  -- msg = { code, op? }
--   outfit:toggle(item)                     -- kartu katalog: pakai / lepas
--   outfit:isWorn(assetId) -> boolean
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
}

local OutfitController = {}
OutfitController.__index = OutfitController

export type OutfitController = typeof(setmetatable(
	{} :: {
		_deps: Deps,
		_state: any?,
		_worn: { [number]: boolean },
		_listeners: { (any) -> () },
		_noticeListeners: { (Notice) -> () },
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
		_worn = {},
		_listeners = {},
		_noticeListeners = {},
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

local function emit(list: { any }, value: any)
	for _, fn in table.clone(list) do
		local ok, err = pcall(fn, value)
		if not ok then
			log.warn("listener error", err)
		end
	end
end

function OutfitController._setState(self: OutfitController, state: any)
	if type(state) ~= "table" then
		return
	end
	self._state = state
	self._worn = collectWorn(state)
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
	-- StateChanged awal mungkin sudah lewat (atau tertunda) -> minta juga secara eksplisit.
	local ok, res = pcall(d.getState :: any)
	if ok and type(res) == "table" and res.ok and self._state == nil then
		self:_setState(res.state)
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

function OutfitController.getState(self: OutfitController): any?
	return self._state
end

function OutfitController.isWorn(self: OutfitController, assetId: number): boolean
	return self._worn[assetId] == true
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

function OutfitController.onChanged(self: OutfitController, fn: (any) -> ()): () -> ()
	return subscribe(self._listeners, fn)
end

function OutfitController.onNotify(self: OutfitController, fn: (Notice) -> ()): () -> ()
	return subscribe(self._noticeListeners, fn)
end

function OutfitController.send(self: OutfitController, intent: { [string]: any })
	local ok, err = pcall(self._deps.fire :: any, intent)
	if not ok then
		log.warn("gagal kirim intent", err)
	end
end

-- Kartu katalog diklik: aset -> pakai/lepas, bundle -> wearBundle (server: menyusul).
function OutfitController.toggle(self: OutfitController, item: any)
	if type(item) ~= "table" or type(item.id) ~= "number" then
		return
	end
	if item.itemType == "Bundle" then
		self:send({ op = "wearBundle", bundleId = item.id })
	elseif self:isWorn(item.id) then
		self:send({ op = "remove", assetId = item.id })
	else
		self:send({ op = "wear", assetId = item.id })
	end
end

return OutfitController
