--!strict
-- Render avatar 3D dari outfit tersimpan ke ViewportFrame (kartu Saved Outfits).
--   local previews = OutfitPreview.new()
--   local handle = previews:mount(viewport, key, outfit, function() ... tampilkan cadangan ... end)
--   handle.cancel()          -- kartu dihapus / dibangun ulang
--   previews:destroy()
-- key = "<id>:<updatedAt>" -> model dibuat ulang hanya bila isi outfit berubah.
-- Uji Studio 17 Sep 2026: Players:CreateHumanoidModelFromDescriptionAsync JALAN DI CLIENT (0.44s,
-- layered clothing tampil) walau docs menulis "Server only" -> WAJIB diuji di game live.
-- Gagal membuat model -> onFallback() (kartu menampilkan thumbnail item).
-- Model dibuat BERGANTIAN (antrean, satu per satu) supaya 30 kartu tidak membekukan layar.
-- Quirk: label nama Humanoid dari model di WorldModel ikut tampil di kamera utama -> DisplayDistanceType None.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local PlayerData = require(Shared.Domain.PlayerData)
local DescriptionBuilder = require(Shared.Avatar.DescriptionBuilder)
local Log = require(Shared.Util.Log)

local log = Log.new("OutfitPreview")

local CACHE_SIZE = 40
local FOV = 30
local MARGIN = 1.12 -- ruang kosong di atas/bawah avatar

export type Handle = { cancel: () -> () }

export type Deps = {
	-- (outfit ringkas) -> Model | error. Default: decode -> HumanoidDescription -> CreateHumanoidModelFromDescriptionAsync
	create: ((outfit: any) -> Model)?,
}

type Job = { key: string, outfit: any, waiters: { (Model?) -> () } }

local OutfitPreview = {}
OutfitPreview.__index = OutfitPreview

export type OutfitPreview = typeof(setmetatable(
	{} :: {
		_create: (any) -> Model,
		_cache: { [string]: Model }, -- template (tidak di-parent)
		_order: { string }, -- urutan pakai (paling lama di depan)
		_failed: { [string]: boolean },
		_jobs: { [string]: Job },
		_queue: { string },
		_running: boolean,
		_destroyed: boolean,
	},
	OutfitPreview
))

local function defaultCreate(outfit: any): Model
	local state, err = PlayerData.decodeOutfit(outfit)
	if state == nil then
		error("outfit tidak valid: " .. tostring(err))
	end
	local desc = DescriptionBuilder.toDescription(state)
	local rig = if state.rig == "R6" then Enum.HumanoidRigType.R6 else Enum.HumanoidRigType.R15
	local model = Players:CreateHumanoidModelFromDescriptionAsync(desc, rig)
	desc:Destroy()
	return model
end

-- Siapkan model untuk dipajang: tanpa script, tanpa label nama, tidak bergerak.
local function prepare(model: Model)
	for _, x in model:GetDescendants() do
		if x:IsA("BaseScript") then
			x:Destroy()
		elseif x:IsA("BasePart") then
			x.Anchored = true
			x.CanCollide = false
			x.CanQuery = false
			x.CanTouch = false
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
	end
end

-- Kamera dari depan, seluruh badan masuk bingkai (lebar juga diperhitungkan).
function OutfitPreview.frame(model: Model, camera: Camera, aspect: number)
	local cf, size = model:GetBoundingBox()
	local halfV = math.rad(FOV / 2)
	local halfH = math.atan(math.tan(halfV) * math.max(aspect, 0.1))
	local distV = (size.Y / 2) / math.tan(halfV)
	local distH = (math.max(size.X, size.Z) / 2) / math.tan(halfH)
	local dist = math.max(distV, distH) * MARGIN + size.Z / 2
	camera.FieldOfView = FOV
	camera.CFrame = CFrame.lookAt(cf.Position + cf.LookVector * dist, cf.Position)
end

function OutfitPreview.new(deps: Deps?): OutfitPreview
	local d = deps or {}
	return setmetatable({
		_create = d.create or defaultCreate,
		_cache = {},
		_order = {},
		_failed = {},
		_jobs = {},
		_queue = {},
		_running = false,
		_destroyed = false,
	}, OutfitPreview)
end

function OutfitPreview._touch(self: OutfitPreview, key: string)
	local i = table.find(self._order, key)
	if i then
		table.remove(self._order, i)
	end
	table.insert(self._order, key)
	while #self._order > CACHE_SIZE do
		local old = table.remove(self._order, 1) :: string
		local model = self._cache[old]
		self._cache[old] = nil
		if model then
			model:Destroy()
		end
	end
end

function OutfitPreview._work(self: OutfitPreview)
	if self._running then
		return
	end
	self._running = true
	task.spawn(function()
		while #self._queue > 0 and not self._destroyed do
			local key = table.remove(self._queue, 1) :: string
			local job = self._jobs[key]
			if job and #job.waiters > 0 then
				local ok, result = pcall(self._create, job.outfit)
				local model: Model? = nil
				if ok and typeof(result) == "Instance" and result:IsA("Model") then
					prepare(result)
					if self._destroyed then
						result:Destroy()
					else
						model = result
						self._cache[key] = result
						self:_touch(key)
					end
				else
					self._failed[key] = true
					log.warn("preview gagal", key, if ok then "bukan Model" else result)
				end
				self._jobs[key] = nil
				for _, waiter in job.waiters do
					task.spawn(waiter, model)
				end
			else
				self._jobs[key] = nil -- semua kartu yang meminta sudah batal
			end
		end
		self._running = false
	end)
end

-- Minta template (async). fn(Model?) dipanggil sekali. Return fungsi batal.
function OutfitPreview._request(self: OutfitPreview, key: string, outfit: any, fn: (Model?) -> ()): () -> ()
	local cached = self._cache[key]
	if cached then
		self:_touch(key)
		task.defer(fn, cached)
		return function() end
	end
	if self._failed[key] then
		task.defer(fn, nil)
		return function() end
	end
	local job = self._jobs[key]
	if job == nil then
		job = { key = key, outfit = outfit, waiters = {} }
		self._jobs[key] = job
		table.insert(self._queue, key)
	end
	table.insert(job.waiters, fn)
	self:_work()
	local j = job
	return function()
		local i = table.find(j.waiters, fn)
		if i then
			table.remove(j.waiters, i)
		end
	end
end

-- Pasang avatar ke viewport. onFallback dipanggil bila model gagal dibuat.
function OutfitPreview.mount(
	self: OutfitPreview,
	viewport: ViewportFrame,
	key: string,
	outfit: any,
	onFallback: (() -> ())?
): Handle
	local world = Instance.new("WorldModel")
	world.Name = "Preview"
	world.Parent = viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local alive = true
	local conn: RBXScriptConnection? = nil
	local stop = self:_request(key, outfit, function(template: Model?)
		if not alive or viewport.Parent == nil then
			return
		end
		if template == nil then
			if onFallback then
				onFallback()
			end
			return
		end
		local model = template:Clone()
		model.Parent = world
		local function refit()
			local s = viewport.AbsoluteSize
			OutfitPreview.frame(model, camera, if s.Y > 0 then s.X / s.Y else 1)
		end
		refit()
		conn = viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	end)

	return {
		cancel = function()
			if not alive then
				return
			end
			alive = false
			stop()
			if conn then
				conn:Disconnect()
			end
			world:Destroy()
			camera:Destroy()
		end,
	}
end

function OutfitPreview.forget(self: OutfitPreview, key: string)
	self._failed[key] = nil
	local model = self._cache[key]
	if model then
		self._cache[key] = nil
		local i = table.find(self._order, key)
		if i then
			table.remove(self._order, i)
		end
		model:Destroy()
	end
end

function OutfitPreview.destroy(self: OutfitPreview)
	self._destroyed = true
	table.clear(self._queue)
	table.clear(self._jobs)
	for _, model in self._cache do
		model:Destroy()
	end
	table.clear(self._cache)
	table.clear(self._order)
end

return OutfitPreview
