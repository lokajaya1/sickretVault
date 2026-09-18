--!strict
-- Render avatar 3D dari outfit tersimpan ke ViewportFrame (kartu Saved Outfits).
--   local previews = OutfitPreview.new()
--   local handle = previews:mount(viewport, key, look, function() ... tampilkan cadangan ... end)
--   look = { outfit = <outfit ringkas>, makeup = { { assetId = n, slot = "face" }, ... } }
--   Outfit ringkas polos juga diterima: makeup-nya dibaca dari field `mk` di dalamnya
--   (Wardrobe.summarize mengirim outfit utuh), jadi kartu wardrobe tidak perlu diubah.
--   handle.cancel()          -- kartu dihapus / dibangun ulang
--   previews:destroy()
-- key = "<id>:<updatedAt>" -> model dibuat ulang hanya bila isi outfit berubah.
-- Uji Studio 17 Sep 2026: Players:CreateHumanoidModelFromDescriptionAsync JALAN DI CLIENT (0.44s,
-- layered clothing tampil) walau docs menulis "Server only" -> WAJIB diuji di game live.
-- Gagal membuat model -> onFallback() (kartu menampilkan thumbnail item).
-- Model dibuat BERGANTIAN (antrean, satu per satu) supaya 30 kartu tidak membekukan layar.
-- Quirk: label nama Humanoid dari model di WorldModel ikut tampil di kamera utama -> DisplayDistanceType None.
-- TEMUAN 18 Sep 2026: model hasil API ini di CLIENT hanya "badan pajangan" -> 20 part TANPA Motor6D/attachment;
-- Humanoid:BuildRigFromAttachments() pun tidak membuat sendi. Jadi avatar preview TIDAK BISA dianimasikan.
-- Gantinya: kamera diputar mengelilingi model (handle.setSpin / handle.addYaw) -> terasa hidup, tanpa animasi.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerData = require(Shared.Domain.PlayerData)
local DescriptionBuilder = require(Shared.Avatar.DescriptionBuilder)
local Makeup = require(Shared.Domain.Makeup)
local Log = require(Shared.Util.Log)

local log = Log.new("OutfitPreview")

local CACHE_SIZE = 40
local FOV = 30
local MARGIN = 1.12 -- ruang kosong di atas/bawah avatar
local MAX_EXTENT = 12 -- stud; batas ukuran avatar yang dianggap wajar (R15 ~5.5)
local SPIN_SPEED = 0.35 -- radian per detik (putaran otomatis)

-- ===== Makeup di preview (spike PR preview-rig, 18 Sep 2026) =====
-- Server mereplikasi TEMPLATE Decal ke ReplicatedStorage/MakeupTemplates (MakeupService), lengkap
-- dengan anak WrapTextureTransfer; client tinggal meng-clone-nya ke Head model preview.
-- TEMUAN PENTING: rig yang dibangun di client merender decal itu dengan PRESISI selama rig berada
-- di dalam ViewportFrame; di workspace decal yang sama TIDAK digambar sama sekali (itulah tembok
-- yang salah disimpulkan di PR #21 sebagai "rig client tidak bisa"). Rig server tidak diperlukan.
-- Decal buatan sendiri dari texture id saja TIDAK boleh dipakai: proyeksi datar -> melar ke dahi.
local MAKEUP_FOLDER = "MakeupTemplates"
local MAKEUP_PREFIX = "CL_Makeup_"

local function makeupFolder(): Instance?
	return ReplicatedStorage:FindFirstChild(MAKEUP_FOLDER)
end

-- Satu slot. false = templatenya belum ter-replikasi (dicoba lagi saat template datang).
local function attachSlot(head: Instance, assetId: number, slot: string): boolean
	local folder = makeupFolder()
	local template = if folder then folder:FindFirstChild(tostring(assetId)) else nil
	if template == nil or not template:IsA("Decal") then
		return false
	end
	local old = head:FindFirstChild(MAKEUP_PREFIX .. slot)
	if old then
		old:Destroy()
	end
	local decal = template:Clone()
	decal.Name = MAKEUP_PREFIX .. slot
	decal.Face = Enum.NormalId.Front
	decal.Parent = head
	return true
end

-- Tempel semua baris makeup ke Head; urutan tetap face -> eye -> lip. Template yang belum sampai
-- DITUNGGU (server mengisi folder saat pemain join / memakai item baru) supaya kartu cukup
-- ditambal, tidak perlu dibangun ulang. Return fungsi penghenti penantian.
local function attachMakeup(model: Model, rows: any): () -> ()
	local head = model:FindFirstChild("Head")
	if head == nil or type(rows) ~= "table" or #rows == 0 then
		return function() end
	end
	local bySlot: { [string]: number } = {}
	for _, row in rows do
		if type(row) == "table" and type(row.assetId) == "number" and Makeup.isValidSlot(row.slot) then
			bySlot[row.slot] = row.assetId
		end
	end
	local pending: { [string]: number } = {}
	for _, slot in Makeup.Slots do
		local assetId = bySlot[slot]
		if assetId ~= nil and not attachSlot(head, assetId, slot) then
			pending[slot] = assetId
		end
	end
	if next(pending) == nil then
		return function() end
	end
	local conn: RBXScriptConnection? = nil
	local function disconnect()
		if conn then
			conn:Disconnect()
			conn = nil
		end
	end
	conn = ReplicatedStorage.DescendantAdded:Connect(function(added: Instance)
		local parent = added.Parent
		if parent == nil or parent.Name ~= MAKEUP_FOLDER then
			return
		end
		if model.Parent == nil then
			disconnect() -- kartunya sudah dibuang
			return
		end
		for _, slot in Makeup.Slots do
			local waiting = pending[slot]
			if waiting ~= nil and attachSlot(head, waiting, slot) then
				pending[slot] = nil
			end
		end
		if next(pending) == nil then
			disconnect()
		end
	end)
	return disconnect
end

export type Handle = {
	cancel: () -> (),
	setSpin: (boolean) -> (), -- putar otomatis (halaman detail)
	addYaw: (number) -> (), -- putar manual (drag); menghentikan sementara efek putaran otomatis
}

-- Satu viewport yang sedang dipajang (kamera mengelilingi model).
type View = {
	center: Vector3,
	dir: Vector3, -- arah kamera saat sudut 0
	dist: number,
	yaw: number,
	ready: boolean,
	apply: () -> (),
}

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
		_spin: { [View]: boolean },
		_conn: RBXScriptConnection?,
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
			-- JANGAN anchor semua part: badan & aksesori dirakit Motor6D/Weld setelah dibuat.
			-- Uji Studio 18 Sep 2026: anchor semua -> part berserakan, bounding box 326x21x282 stud.
			x.Massless = true
			x.CanCollide = false
			x.CanQuery = false
			x.CanTouch = false
		end
	end
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true -- cukup root; sisanya menempel lewat weld
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
	end
end

-- Kamera dari depan, seluruh badan masuk bingkai (lebar juga diperhitungkan).
-- Return posisi tengah, arah kamera pada sudut 0, dan jaraknya (dipakai untuk memutar kamera).
function OutfitPreview.frame(model: Model, camera: Camera, aspect: number): (Vector3, Vector3, number)
	local cf, raw = model:GetBoundingBox()
	-- pengaman: kalau ada part nyasar, jangan biarkan kamera mundur jauh
	local size = Vector3.new(math.min(raw.X, MAX_EXTENT), math.min(raw.Y, MAX_EXTENT), math.min(raw.Z, MAX_EXTENT))
	local halfV = math.rad(FOV / 2)
	local halfH = math.atan(math.tan(halfV) * math.max(aspect, 0.1))
	local distV = (size.Y / 2) / math.tan(halfV)
	local distH = (math.max(size.X, size.Z) / 2) / math.tan(halfH)
	local dist = math.max(distV, distH) * MARGIN + size.Z / 2
	camera.FieldOfView = FOV
	camera.CFrame = CFrame.lookAt(cf.Position + cf.LookVector * dist, cf.Position)
	return cf.Position, cf.LookVector, dist
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
		_spin = {},
		_conn = nil,
	}, OutfitPreview)
end

-- Loop tunggal untuk semua viewport yang berputar (bukan satu loop per kartu).
function OutfitPreview._spinStart(self: OutfitPreview)
	if self._conn ~= nil then
		return
	end
	self._conn = RunService.RenderStepped:Connect(function(dt: number)
		for view in self._spin do
			view.yaw += SPIN_SPEED * dt
			view.apply()
		end
	end)
end

function OutfitPreview._spinStop(self: OutfitPreview)
	local conn = self._conn
	if conn ~= nil and next(self._spin) == nil then
		conn:Disconnect()
		self._conn = nil
	end
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
					result:PivotTo(CFrame.new()) -- posisi pasti di titik nol
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
	look: any,
	onFallback: (() -> ())?
): Handle
	-- look = { outfit, makeup } ; outfit ringkas polos = look tanpa makeup (pemakai lama).
	local isLook = type(look) == "table" and look.outfit ~= nil
	local outfit = if isLook then look.outfit else look
	local makeupRows = if isLook then look.makeup else nil
	if makeupRows == nil then
		makeupRows = PlayerData.makeupOf(outfit) -- slot menyimpan look utuh: makeup ada di field `mk`
	end
	-- WorldModel DIPERTAHANKAN. Uji Studio 18 Sep 2026: tanpa WorldModel rakitan rig preview
	-- berantakan (part berserakan -> bounding box melar -> kamera mundur jauh -> avatar jadi titik),
	-- sama seperti gejala "anchor semua part" di PR #15. Di spike preview-rig rig di dalam
	-- WorldModel memang bergerak sedikit, tapi di sini kamera dihitung dari bounding box + refit,
	-- jadi tidak mengganggu. Makeup TETAP merender: yang menentukan adalah rig ada di ViewportFrame.
	local world = Instance.new("WorldModel")
	world.Name = "Preview"
	world.Parent = viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local view: View = {
		center = Vector3.zero,
		dir = Vector3.new(0, 0, 1),
		dist = 12,
		yaw = 0,
		ready = false,
		apply = function() end,
	}
	local function applyCamera()
		if not view.ready then
			return
		end
		local offset = (CFrame.Angles(0, view.yaw, 0) * view.dir) * view.dist
		camera.CFrame = CFrame.lookAt(view.center + offset, view.center)
	end
	view.apply = applyCamera

	local alive = true
	local conn: RBXScriptConnection? = nil
	local stopMakeup: (() -> ())? = nil
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
			local center, dir, dist = OutfitPreview.frame(model, camera, if s.Y > 0 then s.X / s.Y else 1)
			view.center = center
			view.dir = dir
			view.dist = dist
			view.ready = true
			applyCamera()
		end
		refit()
		conn = viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
		-- Makeup PALING AKHIR dan dibungkus pcall: kamera harus sudah terpasang lebih dulu,
		-- kalau tidak, gagal menempel decal = kamera tertinggal di titik nol (kartu hitam).
		local okMakeup, errMakeup = pcall(function()
			stopMakeup = attachMakeup(model, makeupRows)
		end)
		if not okMakeup then
			log.warn("makeup preview gagal", errMakeup)
		end
	end)

	return {
		cancel = function()
			if not alive then
				return
			end
			alive = false
			self._spin[view] = nil
			self:_spinStop()
			stop()
			if conn then
				conn:Disconnect()
			end
			if stopMakeup then
				stopMakeup()
			end
			world:Destroy()
			camera:Destroy()
		end,
		setSpin = function(on: boolean)
			if not alive then
				return
			end
			if on then
				self._spin[view] = true
				self:_spinStart()
			else
				self._spin[view] = nil
				self:_spinStop()
			end
		end,
		addYaw = function(delta: number)
			if not alive then
				return
			end
			view.yaw += delta
			applyCamera()
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
	table.clear(self._spin)
	local conn = self._conn
	if conn ~= nil then
		conn:Disconnect()
		self._conn = nil
	end
	table.clear(self._queue)
	table.clear(self._jobs)
	for _, model in self._cache do
		model:Destroy()
	end
	table.clear(self._cache)
	table.clear(self._order)
end

return OutfitPreview
