--!strict
-- Render avatar 3D dari outfit tersimpan ke ViewportFrame (kartu Saved Outfits).
--   local previews = OutfitPreview.new()
--   local handle = previews:mount(viewport, key, look, function() ... end, { background = true })
--   look = { outfit = <outfit ringkas>, makeup = { { assetId = n, slot = "face" }, ... } }
--   Outfit ringkas polos juga diterima: makeup-nya dibaca dari field `mk` di dalamnya
--   (Wardrobe.summarize mengirim outfit utuh), jadi kartu wardrobe tidak perlu diubah.
--   handle.cancel()          -- kartu dihapus / dibangun ulang
--   local live = previews:mountCurrent(viewport, { background = true }) -- AVATAR SEKARANG
--   live.refresh()           -- look berubah (outfit / makeup) -> ambil ulang dari karakter
--   live.setLive(true)       -- cermin pose: kartu meniru gerak karakter asli tiap frame
--   previews:setBackground({ image = "rbxassetid://...", color = Color3? } | nil)
--   Latar hanya terpasang di mount yang MEMINTANYA (`{ background = true }`), yaitu preview yang
--   mewakili avatar SEKARANG. Kartu Saved Outfits & halaman detail TIDAK memakainya: kartu itu
--   menggambarkan look yang TERSIMPAN, sedangkan latar adalah pilihan pemain saat ini.
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
local MARGIN = 1.04 -- ruang kosong di atas/bawah avatar (uji 19 Sep: 1.12 terlalu longgar)
local MAX_EXTENT = 12 -- stud; batas ukuran avatar yang dianggap wajar (R15 ~5.5)
local SPIN_SPEED = 0.35 -- radian per detik (putaran otomatis)
-- Batas kontrol kartu (PR bar aksi). Spike 18 Sep: Camera.NearPlaneZ = 0,5 stud dengan jarak awal
-- 17,75 stud -> faktor aman >= 0,08, jadi MIN_ZOOM 0,5 masih jauh dari kepala terpotong.
local MIN_ZOOM = 0.5 -- makin kecil = makin dekat (jarak kamera dikalikan faktor ini)
local MAX_ZOOM = 1.6
local ZOOM_STEP = 0.85 -- satu ketuk tombol zoom
local MAX_PITCH = math.rad(35)
local MAX_PAN = 2.5 -- stud; cukup untuk membawa kepala atau kaki ke tengah kartu
local PAN_RATE = 0.0007 -- stud per piksel per stud jarak (geser terasa sama di semua zoom)

-- ===== Makeup di preview (spike PR preview-rig, 18 Sep 2026) =====
-- Server mereplikasi TEMPLATE Decal ke ReplicatedStorage/MakeupTemplates (MakeupService), lengkap
-- dengan anak WrapTextureTransfer; client tinggal meng-clone-nya ke Head model preview.
-- TEMUAN PENTING: rig yang dibangun di client merender decal itu dengan PRESISI selama rig berada
-- di dalam ViewportFrame; di workspace decal yang sama TIDAK digambar sama sekali (itulah tembok
-- yang salah disimpulkan di PR #21 sebagai "rig client tidak bisa"). Rig server tidak diperlukan.
-- Decal buatan sendiri dari texture id saja TIDAK boleh dipakai: proyeksi datar -> melar ke dahi.
local MAKEUP_FOLDER = "MakeupTemplates"
local MAKEUP_PREFIX = "CL_Makeup_"

-- ===== Latar area preview (PR avatar-background, 18 Sep 2026) =====
-- KOREKSI UJI STUDIO: di spike panel ANAK (ImageLabel anak ViewportFrame) rig masih terlihat,
-- TAPI di panel produksi gambar itu MENUTUPI rig -- kartu Saved Outfits jadi gradient polos tanpa
-- avatar. Jadi latar dipasang sebagai SAUDARA tepat di belakang ViewportFrame (varian SAUDARA
-- yang juga terbukti di spike): geometri disalin dari viewport, ZIndex satu tingkat di bawahnya,
-- dan viewport dibuat tembus selama latar terpasang. Pemakai tetap tidak perlu diubah karena
-- layanan ini sendiri yang menaruh ImageLabel di induk viewport (induknya tidak ber-UILayout).
-- `Color` aset TIDAK dipakai sebagai tint (ImageColor3): di spike panel TINT tampak kusam.
-- Ia dipakai sebagai warna DASAR di belakang gambar (berguna sebelum gambar termuat).
local BACKDROP_NAME = "Backdrop"

type Backdrop = {
	image: ImageLabel,
	viewport: ViewportFrame,
	original: number,
	conns: { RBXScriptConnection },
}

local function applyBackdrop(entry: Backdrop, bg: any)
	local image = if type(bg) == "table" then bg.image else nil
	if type(image) ~= "string" or image == "" then
		entry.image.Visible = false
		entry.image.Image = ""
		entry.viewport.BackgroundTransparency = entry.original
		return
	end
	entry.image.Image = image
	if typeof(bg.color) == "Color3" then
		entry.image.BackgroundColor3 = bg.color
		entry.image.BackgroundTransparency = 0
	else
		entry.image.BackgroundTransparency = 1
	end
	entry.image.Visible = true
	entry.viewport.BackgroundTransparency = 1 -- tanpa ini gambarnya tertutup latar viewport
end

-- ImageLabel saudara yang menempel persis di belakang viewport. nil = viewport belum punya induk
-- GuiObject (tidak ada tempat menaruh latar) -> preview tetap jalan, cuma tanpa latar.
local function newBackdrop(viewport: ViewportFrame): Backdrop?
	local holder = viewport.Parent
	if holder == nil or not holder:IsA("GuiObject") then
		return nil
	end
	local image = Instance.new("ImageLabel")
	image.Name = BACKDROP_NAME
	image.BackgroundTransparency = 1
	image.BorderSizePixel = 0
	image.ScaleType = Enum.ScaleType.Crop
	image.AnchorPoint = viewport.AnchorPoint
	image.Position = viewport.Position
	image.Size = viewport.Size
	image.ZIndex = viewport.ZIndex - 1
	image.Visible = false
	local corner = viewport:FindFirstChildOfClass("UICorner")
	if corner then
		corner:Clone().Parent = image -- sudut membulat viewport ikut, supaya gambar tidak mencuat
	end
	image.Parent = holder
	local entry: Backdrop = {
		image = image,
		viewport = viewport,
		original = viewport.BackgroundTransparency,
		conns = {},
	}
	-- Panel bisa mengubah ukuran/posisi viewport (mis. layout responsif) -> latar ikut.
	for _, prop in { "AnchorPoint", "Position", "Size", "ZIndex" } do
		table.insert(
			entry.conns,
			viewport:GetPropertyChangedSignal(prop):Connect(function()
				image.AnchorPoint = viewport.AnchorPoint
				image.Position = viewport.Position
				image.Size = viewport.Size
				image.ZIndex = viewport.ZIndex - 1
			end)
		)
	end
	return entry
end

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

-- Opsi per-mount. `background = true` hanya untuk preview avatar SEKARANG (lihat catatan di atas).
export type MountOptions = { background: boolean? }

export type Handle = {
	cancel: () -> (),
	setSpin: (boolean) -> (), -- putar otomatis (halaman detail)
	addYaw: (number) -> (), -- putar manual (drag); menghentikan sementara efek putaran otomatis
	addPitch: (number) -> (), -- dongak/tunduk (drag tegak), dibatasi MAX_PITCH
	addZoom: (number) -> (), -- +1 = satu ketuk mendekat, -1 = menjauh
	addPan: (number, number) -> (), -- geser avatar di dalam kartu (piksel geser layar)
	resetView: () -> (), -- kembali ke sudut & jarak bawaan
	refresh: (() -> ())?, -- hanya ada di mountCurrent: ambil ulang rupa karakter
	setLive: ((boolean) -> ())?, -- hanya ada di mountCurrent: cermin pose hidup/mati
}

-- Satu viewport yang sedang dipajang (kamera mengelilingi model).
-- PENTING: `center`/`dir`/`dist` dihitung ULANG dari model tiap kali kartu di-refit (ganti item,
-- kartu berubah ukuran), sedangkan `yaw`/`pitch`/`zoom`/`pan` adalah PILIHAN PEMAIN dan tidak
-- pernah disentuh refit -- itulah sebabnya keduanya dipisah. Kalau zoom ikut dihitung dari model,
-- setiap ganti topi kamera akan melompat balik ke jarak bawaan.
type View = {
	center: Vector3,
	dir: Vector3, -- arah kamera saat sudut 0
	dist: number, -- jarak bawaan hasil OutfitPreview.frame
	yaw: number,
	pitch: number,
	zoom: number, -- pengali `dist`
	panX: number, -- geser kamera ke samping/atas (stud), avatar ikut bergeser di dalam kartu
	panY: number,
	ready: boolean,
	apply: () -> (),
}

local function newView(camera: Camera): View
	local view: View = {
		center = Vector3.zero,
		dir = Vector3.new(0, 0, 1),
		dist = 12,
		yaw = 0,
		pitch = 0,
		zoom = 1,
		panX = 0,
		panY = 0,
		ready = false,
		apply = function() end,
	}
	view.apply = function()
		if not view.ready then
			return
		end
		local rot = CFrame.Angles(0, view.yaw, 0) * CFrame.Angles(view.pitch, 0, 0)
		local eye = view.center + (rot * view.dir) * (view.dist * view.zoom)
		-- Geser dilakukan pada MATA dan TITIK BIDIK sekaligus supaya avatar bergeser di dalam
		-- bingkai tanpa ikut berputar (kalau hanya mata yang digeser, kartu jadi miring).
		local aim = CFrame.lookAt(eye, view.center)
		local shift = aim.RightVector * view.panX + aim.UpVector * view.panY
		camera.CFrame = CFrame.lookAt(eye + shift, view.center + shift)
	end
	return view
end

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
		_backdrops: { [ImageLabel]: Backdrop }, -- satu per viewport yang sedang dipajang
		_background: any?, -- latar yang sedang berlaku untuk SEMUA preview
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
-- UJI STUDIO 19 Sep 2026: avatar tampak KECIL di kartu karena kamera mundur DUA KALI untuk hal
-- yang sama -- lebar diukur dari `max(size.X, size.Z)` padahal kedalaman sudah dihitung terpisah
-- lewat `+ size.Z / 2`. Rambut jambul & tas punggung membuat Z besar, jadi avatar ikut menyusut
-- padahal lebarnya biasa saja. Lebar sekarang diukur dari `size.X` saja.
function OutfitPreview.frame(model: Model, camera: Camera, aspect: number): (Vector3, Vector3, number)
	local cf, raw = model:GetBoundingBox()
	-- pengaman: kalau ada part nyasar, jangan biarkan kamera mundur jauh
	local size = Vector3.new(math.min(raw.X, MAX_EXTENT), math.min(raw.Y, MAX_EXTENT), math.min(raw.Z, MAX_EXTENT))
	local halfV = math.rad(FOV / 2)
	local halfH = math.atan(math.tan(halfV) * math.max(aspect, 0.1))
	local distV = (size.Y / 2) / math.tan(halfV)
	local distH = (size.X / 2) / math.tan(halfH)
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
		_backdrops = {},
		_background = nil,
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
	onFallback: (() -> ())?,
	opts: MountOptions?
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
	local wantsBackdrop = type(opts) == "table" and opts.background == true
	local entry = if wantsBackdrop then newBackdrop(viewport) else nil
	if entry ~= nil then
		self._backdrops[entry.image] = entry
		applyBackdrop(entry, self._background)
	end

	local world = Instance.new("WorldModel")
	world.Name = "Preview"
	world.Parent = viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local view = newView(camera)
	local applyCamera = view.apply

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
			if entry ~= nil then
				self._backdrops[entry.image] = nil
				viewport.BackgroundTransparency = entry.original
				for _, c in entry.conns do
					c:Disconnect()
				end
				entry.image:Destroy()
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
		addPitch = function(delta: number)
			if not alive then
				return
			end
			view.pitch = math.clamp(view.pitch + delta, -MAX_PITCH, MAX_PITCH)
			applyCamera()
		end,
		addZoom = function(steps: number)
			if not alive then
				return
			end
			view.zoom = math.clamp(view.zoom * ZOOM_STEP ^ steps, MIN_ZOOM, MAX_ZOOM)
			applyCamera()
		end,
		addPan = function(dx: number, dy: number)
			if not alive then
				return
			end
			-- Piksel geser layar -> stud, diskalakan dengan jarak kamera supaya satu jari menempuh
			-- bagian layar yang sama baik saat kartu di-zoom dekat maupun jauh.
			local rate = view.dist * view.zoom * PAN_RATE
			view.panX = math.clamp(view.panX - dx * rate, -MAX_PAN, MAX_PAN)
			view.panY = math.clamp(view.panY + dy * rate, -MAX_PAN, MAX_PAN)
			applyCamera()
		end,
		resetView = function()
			if not alive then
				return
			end
			view.yaw = 0
			view.pitch = 0
			view.zoom = 1
			view.panX = 0
			view.panY = 0
			applyCamera()
		end,
	}
end

-- Latar untuk SEMUA preview (kartu wardrobe, halaman detail, pemakai berikutnya).
-- bg = { image = "rbxassetid://...", color = Color3? } atau nil untuk melepas latar.
function OutfitPreview.setBackground(self: OutfitPreview, bg: any)
	self._background = bg
	for _, entry in self._backdrops do
		applyBackdrop(entry, bg)
	end
end

-- ===== Preview AVATAR SEKARANG (PR kolom kiri, 18 Sep 2026) =====
-- Spike `S.current()`: meng-CLONE karakter asli butuh **0,005 detik** dan makeup IKUT SENDIRI
-- (Decal-nya memang menempel di Head karakter, `decal di Head = 2`), sedangkan membangun rig dari
-- `GetAppliedDescription` makan **0,46 detik** dan datang tanpa makeup (`= 0`). Jadi kartu avatar
-- sekarang TIDAK memakai antrean/cache rig: cukup clone ulang tiap look berubah.
-- Quirk: `Player.Character` datang dengan `Archivable = false` -> `Clone()` mengembalikan nil.
local function cloneCharacter(): Model?
	local player = Players.LocalPlayer
	local char = if player then player.Character else nil
	if char == nil then
		return nil
	end
	local wasArchivable = char.Archivable
	char.Archivable = true
	local ok, copy = pcall(function()
		return char:Clone()
	end)
	char.Archivable = wasArchivable
	if not ok or typeof(copy) ~= "Instance" then
		log.warn("clone karakter gagal", copy)
		return nil
	end
	return copy :: Model
end

-- ===== Cermin pose =====
-- Spike 18 Sep: rig di ViewportFrame BEKU (0,000 stud) dan `Animator:StepAnimation` sudah tidak
-- ada -> animasi tidak bisa diputar di dalam kartu. Tapi karakter ASLI di workspace memang
-- beranimasi (animation pack pemain), jadi kartu cukup MENYALIN posenya tiap frame:
-- MIRROR 4,071 stud vs STATIC 0,352 stud dalam 3 detik. Efeknya animation pack apa pun ikut,
-- tanpa memuat satu Animation pun.
type Pose = { s: BasePart, d: BasePart }

-- Pasangan dicocokkan lewat NAMA JALUR ("RightLowerLeg", "Fedora/Handle"), BUKAN urutan anak:
-- uji Studio 18 Sep membuktikan urutan `GetChildren` model asli dan clone-nya TIDAK selalu sama,
-- sehingga part bisa dipasangkan ke part yang salah -- gejalanya kaki meregang saat lompat dan
-- satu kaki diam. Nama yang kembar (mis. dua "Handle") dipasangkan berurutan.
local function keyOf(part: Instance, root: Instance): string
	local names: { string } = {}
	local node: Instance? = part
	while node ~= nil and node ~= root do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	return table.concat(names, "/")
end

-- Posisi part RELATIF HumanoidRootPart. Dipakai untuk memilih pasangan yang benar; tahan
-- terhadap `PivotTo` karena kedua model diukur dengan patokannya masing-masing.
local function relativeTo(part: BasePart, root: BasePart?): Vector3
	if root == nil then
		return part.Position
	end
	return root.CFrame:PointToObjectSpace(part.Position)
end

-- UJI STUDIO 18 Sep 2026 (KOREKSI temuan #24 no. 5): memasangkan jalur nama yang KEMBAR lewat
-- urutan anak TIDAK aman -- urutan `GetDescendants` model asli dan clone-nya berbeda, sehingga
-- tas bisa dipasangkan ke `Handle` milik topi dan melompat ke kepala begitu topi dipakai.
-- (Bukan part tanpa pasangan: `dropUnpaired` melaporkan 0 saat bug ini muncul.)
-- Yang dipakai sekarang: clone BARU SAJA dibuat, jadi tiap part clone masih persis di posisi
-- aslinya relatif HumanoidRootPart -> untuk jalur kembar, pasangan dipilih dari JARAK TERDEKAT.
-- Urutan anak tidak lagi ikut menentukan apa pun.
local function pairParts(src: Instance, dst: Instance): { Pose }
	local srcRoot = src:FindFirstChild("HumanoidRootPart") :: BasePart?
	local dstRoot = dst:FindFirstChild("HumanoidRootPart") :: BasePart?
	local bySrcKey: { [string]: { BasePart } } = {}
	local twins = 0
	for _, x in src:GetDescendants() do
		if x:IsA("BasePart") then
			local key = keyOf(x, src)
			local list = bySrcKey[key]
			if list == nil then
				list = {}
				bySrcKey[key] = list
			else
				twins += 1
			end
			table.insert(list, x :: BasePart)
		end
	end
	local out: { Pose } = {}
	for _, y in dst:GetDescendants() do
		if y:IsA("BasePart") then
			local list = bySrcKey[keyOf(y, dst)]
			if list ~= nil and #list > 0 then
				local want = relativeTo(y :: BasePart, dstRoot)
				local best, bestDist = 0, math.huge
				for i, cand in list do
					local gap = (relativeTo(cand, srcRoot) - want).Magnitude
					if gap < bestDist then
						best, bestDist = i, gap
					end
				end
				-- Diambil dari daftar supaya satu part asli tidak dipakai dua kali.
				table.insert(out, { s = table.remove(list, best) :: BasePart, d = y :: BasePart })
			end
		end
	end
	if twins > 0 then
		log.info("kartu preview: jalur kembar", twins, "dipasangkan lewat posisi terdekat")
	end
	return out
end

-- UJI STUDIO 18 Sep 2026: sesudah ganti item kadang muncul SATU benda (tas/topi) yang tampak
-- raksasa menempel di dada atau kepala. Sebabnya bukan pemasangan yang salah, melainkan part clone
-- yang TIDAK punya pasangan sama sekali di karakter asli: cermin pose tidak pernah menyentuhnya,
-- jadi ia membeku di CFrame saat di-clone -- dan karena model baru saja di-`PivotTo(CFrame.new())`,
-- tempat beku itu persis di badan avatar. Terjadi kalau sebuah item DILEPAS tepat sesudah clone
-- diambil (urutan lepas-lalu-pakai saat mencoba item). Part seperti itu dibuang; `DescendantRemoving`
-- pada karakter asli sudah menjadwalkan clone ulang, jadi tidak ada yang hilang permanen.
local function dropUnpaired(model: Model, poses: { Pose }, keep: BasePart?): number
	local paired: { [BasePart]: boolean } = {}
	for _, pose in poses do
		paired[pose.d] = true
	end
	-- Dikumpulkan dulu, baru dibuang: menghapus sambil menelusuri bisa ikut membawa part lain.
	local strays: { BasePart } = {}
	for _, x in model:GetDescendants() do
		if x:IsA("BasePart") and x ~= keep and not paired[x :: BasePart] then
			table.insert(strays, x :: BasePart)
		end
	end
	for _, part in strays do
		part:Destroy()
	end
	return #strays
end

-- Kartu avatar SEKARANG. `refresh()` dipanggil pemakai tiap look berubah; karakter baru
-- (respawn / ApplyDescription) ditangani sendiri lewat CharacterAdded.
function OutfitPreview.mountCurrent(self: OutfitPreview, viewport: ViewportFrame, opts: MountOptions?): Handle
	local wantsBackdrop = type(opts) == "table" and opts.background == true
	local entry = if wantsBackdrop then newBackdrop(viewport) else nil
	if entry ~= nil then
		self._backdrops[entry.image] = entry
		applyBackdrop(entry, self._background)
	end

	local world = Instance.new("WorldModel")
	world.Name = "Preview"
	world.Parent = viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local view = newView(camera)
	local applyCamera = view.apply

	local alive = true
	local model: Model? = nil
	local pending = false
	local conns: { RBXScriptConnection } = {}
	local poses: { Pose } = {}
	local srcRoot: BasePart? = nil
	local dstRoot: BasePart? = nil
	local mirrorConn: RBXScriptConnection? = nil
	local charConns: { RBXScriptConnection } = {}
	-- Dideklarasikan lebih dulu: `rebuild` memasang pemantau karakter yang memanggilnya balik.
	local request: () -> ()

	local function refit()
		local shown = model
		if shown == nil then
			return
		end
		local size = viewport.AbsoluteSize
		local center, dir, dist = OutfitPreview.frame(shown, camera, if size.Y > 0 then size.X / size.Y else 1)
		view.center = center
		view.dir = dir
		view.dist = dist
		view.ready = true
		applyCamera()
	end

	local function rebuild()
		if not alive or viewport.Parent == nil then
			return
		end
		local fresh = cloneCharacter()
		if fresh == nil then
			return -- karakter belum ada; CharacterAdded akan memanggil lagi
		end
		prepare(fresh)
		-- Pose diatur PENUH oleh kita (cermin), jadi semua part di-anchor: weld/constraint tidak
		-- boleh menarik balik CFrame yang disetel tiap frame.
		for _, x in fresh:GetDescendants() do
			if x:IsA("BasePart") then
				(x :: BasePart).Anchored = true
			end
		end
		fresh:PivotTo(CFrame.new())
		local old = model
		model = fresh
		fresh.Parent = world
		if old ~= nil then
			old:Destroy() -- yang lama dibuang SETELAH yang baru dipasang (tidak ada kartu kosong)
		end
		local player = Players.LocalPlayer
		local char = if player then player.Character else nil
		-- Sesudah ApplyDescription, part & aksesori karakter menyusul beberapa saat kemudian, jadi
		-- clone pertama bisa ketinggalan item baru -> pantau isi karakter dan clone ulang saat reda.
		for _, c in charConns do
			c:Disconnect()
		end
		table.clear(charConns)
		if char ~= nil then
			table.insert(
				charConns,
				char.DescendantAdded:Connect(function()
					request()
				end)
			)
			table.insert(
				charConns,
				char.DescendantRemoving:Connect(function()
					request()
				end)
			)
		end
		poses = if char then pairParts(char, fresh) else {}
		srcRoot = if char then char:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
		dstRoot = fresh:FindFirstChild("HumanoidRootPart") :: BasePart?
		if char ~= nil then
			-- Dibuang SEBELUM refit: part nyasar juga melarkan bounding box -> kamera mundur jauh.
			local strays = dropUnpaired(fresh, poses, dstRoot)
			if strays > 0 then
				log.warn("kartu preview: part tanpa pasangan dibuang", strays, "terpasang", #poses)
			end
		end
		refit()
	end

	-- Satu koneksi per kartu, hanya selama kartu dipakai (App mematikannya saat kartu tersembunyi).
	local function mirrorStep()
		local from, to = srcRoot, dstRoot
		if from == nil or to == nil or from.Parent == nil or to.Parent == nil then
			return
		end
		local base = to.CFrame
		local inv = from.CFrame:Inverse()
		for _, pose in poses do
			if pose.d ~= to and pose.s.Parent ~= nil and pose.d.Parent ~= nil then
				pose.d.CFrame = base * (inv * pose.s.CFrame)
			end
		end
	end

	local function setLive(on: boolean)
		if not alive then
			return
		end
		if on and mirrorConn == nil then
			mirrorConn = RunService.RenderStepped:Connect(mirrorStep)
		elseif not on and mirrorConn ~= nil then
			mirrorConn:Disconnect()
			mirrorConn = nil
		end
	end

	-- Beberapa perubahan dalam satu frame (mis. lepas + pakai) cukup satu clone.
	request = function()
		if pending or not alive then
			return
		end
		pending = true
		-- Jeda kecil, bukan satu frame: perubahan karakter datang bertubi-tubi (part, aksesori,
		-- layered clothing) dan kita hanya ingin satu clone setelah semuanya reda.
		task.delay(0.15, function()
			pending = false
			local okBuild, err = pcall(rebuild)
			if not okBuild then
				log.warn("preview avatar sekarang gagal", err)
			end
		end)
	end

	table.insert(conns, viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit))
	local player = Players.LocalPlayer
	if player then
		table.insert(
			conns,
			player.CharacterAdded:Connect(function(char: Model)
				char:WaitForChild("Humanoid", 10)
				task.wait(0.2) -- aksesori & layered clothing menyusul sesudah Humanoid
				request()
			end)
		)
	end
	request()

	return {
		cancel = function()
			if not alive then
				return
			end
			alive = false
			self._spin[view] = nil
			self:_spinStop()
			if mirrorConn ~= nil then
				mirrorConn:Disconnect()
				mirrorConn = nil
			end
			for _, c in charConns do
				c:Disconnect()
			end
			table.clear(charConns)
			for _, c in conns do
				c:Disconnect()
			end
			if entry ~= nil then
				self._backdrops[entry.image] = nil
				viewport.BackgroundTransparency = entry.original
				for _, c in entry.conns do
					c:Disconnect()
				end
				entry.image:Destroy()
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
		addPitch = function(delta: number)
			if not alive then
				return
			end
			view.pitch = math.clamp(view.pitch + delta, -MAX_PITCH, MAX_PITCH)
			applyCamera()
		end,
		addZoom = function(steps: number)
			if not alive then
				return
			end
			view.zoom = math.clamp(view.zoom * ZOOM_STEP ^ steps, MIN_ZOOM, MAX_ZOOM)
			applyCamera()
		end,
		addPan = function(dx: number, dy: number)
			if not alive then
				return
			end
			-- Piksel geser layar -> stud, diskalakan dengan jarak kamera supaya satu jari menempuh
			-- bagian layar yang sama baik saat kartu di-zoom dekat maupun jauh.
			local rate = view.dist * view.zoom * PAN_RATE
			view.panX = math.clamp(view.panX - dx * rate, -MAX_PAN, MAX_PAN)
			view.panY = math.clamp(view.panY + dy * rate, -MAX_PAN, MAX_PAN)
			applyCamera()
		end,
		resetView = function()
			if not alive then
				return
			end
			view.yaw = 0
			view.pitch = 0
			view.zoom = 1
			view.panX = 0
			view.panY = 0
			applyCamera()
		end,
		refresh = request,
		setLive = setLive,
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
	table.clear(self._backdrops)
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
