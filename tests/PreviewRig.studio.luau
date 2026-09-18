--!strict
-- SPIKE preview-rig (PR feature/preview-rig) — HANYA di Studio.
--
-- DUA PERTANYAAN yang harus dijawab SEBELUM satu baris layanan preview ditulis:
--   Q1. Rig yang dibangun di SERVER (CreateHumanoidModelFromDescriptionAsync di server) + clone
--       template Decal dari gateway AssetDecal -> apakah makeup merender PRESISI di mata client?
--       (Di client rig itu GAGAL total: spike #21, decal ber-WrapTextureTransfer tidak digambar.)
--   Q2. Rig itu masih benar kalau dilihat lewat ViewportFrame (kartu outfit), atau hanya benar
--       kalau berdiri di workspace? Jawaban Q2 mengunci arsitektur preview:
--         ViewportFrame  -> kartu bisa tetap UI biasa, murah, banyak kartu sekaligus.
--         panggung 3D    -> preview harus jadi tempat sungguhan di dunia + kamera sendiri,
--                           dan AvatarBackground (PR berikutnya) jadi Part/Billboard, bukan ImageLabel.
--
-- CARA PAKAI (Play, lalu Command Bar; ingat: `local S = ...` TIDAK bertahan antar eksekusi)
--   tab SERVER:
--     local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.stage()
--   tab CLIENT (setelah boneka server terlihat):
--     local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.viewport()
--   bersih-bersih (tab mana pun):
--     local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.clear()
--
-- YANG DILIHAT
--   S.stage()   -> dua boneka lahir-SERVER berjajar di depan pemain, JAWABAN Q1:
--                    SRVTPL = clone template Decal (ikut WrapTextureTransfer)   <- yang kita harapkan
--                    SRVTEX = Decal dari texture saja (pembanding: pasti MELAR menutupi dahi)
--                  Foto DEKAT wajah kedua boneka. "tidak merender" dan "presisi" terlihat sama dari jauh.
--   S.viewport() -> tiga ViewportFrame berjajar di layar (kamera sudah mepet wajah), JAWABAN Q2:
--                    VP   = clone rig SERVER, langsung di dalam ViewportFrame
--                    VPW  = clone rig SERVER, di dalam WorldModel di dalam ViewportFrame
--                    CLI  = rig yang dibangun DI CLIENT + template yang sama (kontrol; menurut
--                           spike #21 ini harus tetap kosong — kalau ternyata muncul, temuan #21 salah)
--
-- FOTO: panel viewport sekarang di BAWAH KIRI layar, jadi jalan mendekat ke wajah
-- SRVTPL/SRVTEX dulu; satu screenshot bisa memuat Q1 (boneka) dan Q2 (viewport) sekaligus.
--
-- Kalau makeup hanya benar di SRVTPL (workspace) tapi hilang/meleset di VP dan VPW, maka
-- ViewportFrame TIDAK bisa dipakai untuk kartu bermakeup -> arsitektur panggung 3D.
-- Kalau VPW benar tapi VP tidak, jawabannya: ViewportFrame boleh, WAJIB pakai WorldModel.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local UserInputService = game:GetService("UserInputService")

local TAG = "[SPIKEPREVIEW]"
local RIG_PREFIX = "PREVIEW_RIG_"
local GUI_NAME = "PREVIEW_RIG_SPIKE_GUI"
local DEFAULT_MAKEUP = 123316458229208 -- Cute Light Blush (dipakai di spike #18/#21)

local M = {}

local function say(fmt: string, ...: any)
	print(TAG .. " " .. string.format(fmt, ...))
end

local PROBE_PROPS = { "Texture", "Face", "ZIndex", "Transparency", "CageMeshId", "CageOrigin", "ImportOrigin" }

local function describe(inst: Instance): string
	local out = {}
	for _, prop in PROBE_PROPS do
		local ok, value = pcall(function()
			return (inst :: any)[prop]
		end)
		if ok and value ~= nil then
			table.insert(out, ("%s=%s"):format(prop, tostring(value)))
		end
	end
	return ("%s '%s' [%s]"):format(inst.ClassName, inst.Name, table.concat(out, " "))
end

-- Apa yang menempel di Head sebuah rig: WrapTarget ada? decal-nya bawa WrapTextureTransfer?
local function dumpHead(label: string, head: Instance)
	say("%s head %s", label, describe(head))
	for _, child in head:GetChildren() do
		say("%s head anak: %s", label, describe(child))
		for _, grand in child:GetChildren() do
			say("%s head cucu: %s", label, describe(grand))
		end
	end
end

local function labelOf(model: Model, text: string)
	local head = model:FindFirstChild("Head")
	if head == nil then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "SPIKE_LABEL"
	gui.Size = UDim2.fromScale(4, 1.5)
	gui.StudsOffset = Vector3.new(0, 2.5, 0)
	gui.AlwaysOnTop = true
	local text_ = Instance.new("TextLabel")
	text_.Size = UDim2.fromScale(1, 1)
	text_.BackgroundTransparency = 1
	text_.Text = text
	text_.TextScaled = true
	text_.TextColor3 = Color3.fromRGB(255, 255, 255)
	text_.TextStrokeTransparency = 0
	text_.Parent = gui
	gui.Parent = head
end

local function firstCharacter(): Model?
	local player = if RunService:IsClient() then Players.LocalPlayer else Players:GetPlayers()[1]
	local char = if player then player.Character else nil
	if char == nil then
		say("karakter belum ada. Play ulang / tunggu spawn, lalu coba lagi.")
		return nil
	end
	return char
end

local function appliedDescription(): HumanoidDescription?
	local char = firstCharacter()
	local humanoid = if char then char:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return nil
	end
	return (humanoid :: Humanoid):GetAppliedDescription()
end

local function buildRig(desc: HumanoidDescription): Model?
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok then
		say("rig gagal dibuat: %s", tostring(model))
		return nil
	end
	local rig = model :: Model
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		(humanoid :: Humanoid).DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	local root = rig:FindFirstChild("HumanoidRootPart")
	if root then
		(root :: BasePart).Anchored = true -- hanya root; meng-anchor semua part merusak rakitan
	end
	return rig
end

-- Template Decal asli (ikut WrapTextureTransfer) dari gateway yang SUDAH dipakai produksi.
local function loadTemplate(assetId: number): Decal?
	local server = ServerScriptService:FindFirstChild("Server")
	local gateways = if server then server:FindFirstChild("Gateways") else nil
	local moduleScript = if gateways then gateways:FindFirstChild("AssetDecal") else nil
	if moduleScript == nil then
		say("AssetDecal tidak ditemukan (jalankan S.stage() dari tab SERVER)")
		return nil
	end
	local AssetDecal = require(moduleScript :: ModuleScript) :: any
	local gateway = AssetDecal.new()
	local ok, info = gateway:getMakeup(assetId)
	if not ok then
		say("getMakeup(%d) GAGAL: %s", assetId, tostring(info and info.message))
		return nil
	end
	say("getMakeup(%d) OK, textureId=%s", assetId, tostring(info.textureId))
	return info.template :: Decal
end

local function attachTemplate(head: BasePart, template: Decal, name: string)
	local decal = template:Clone()
	decal.Name = name
	decal.Face = Enum.NormalId.Front
	decal.Parent = head
end

local function attachTexture(head: BasePart, template: Decal, name: string)
	local decal = Instance.new("Decal")
	decal.Name = name
	decal.Texture = template.Texture
	decal.Face = Enum.NormalId.Front
	decal.Parent = head
end

-- ===== Q1: rig lahir-SERVER, dilihat langsung di workspace =====
-- SRVTPL vs SRVTEX berdampingan; minta screenshot DEKAT wajah.
function M.stage(assetId: number?)
	if not RunService:IsServer() then
		say("S.stage() HARUS dari tab SERVER (InsertService ditolak di client)")
		return
	end
	local id = assetId or DEFAULT_MAKEUP
	M.clear()

	local desc = appliedDescription()
	if desc == nil then
		return
	end
	local template = loadTemplate(id)
	if template == nil then
		return
	end

	local char = firstCharacter()
	local charRoot = if char then char:FindFirstChild("HumanoidRootPart") else nil
	if charRoot == nil then
		return
	end
	local base = (charRoot :: BasePart).CFrame

	local variants = { "SRVTPL", "SRVTEX" }
	for i, variant in variants do
		local rig = buildRig(desc)
		if rig == nil then
			continue
		end
		rig.Name = RIG_PREFIX .. variant
		local head = rig:FindFirstChild("Head")
		if head then
			if variant == "SRVTPL" then
				attachTemplate(head :: BasePart, template, "SPIKE_" .. variant)
			else
				attachTexture(head :: BasePart, template, "SPIKE_" .. variant)
			end
		end
		labelOf(rig, variant)
		-- berjajar 3.5 stud, 7 stud di depan pemain, menghadap pemain
		rig:PivotTo(base * CFrame.new((i - 1.5) * 3.5, 0, -7) * CFrame.Angles(0, math.pi, 0))
		rig.Parent = workspace
		if head then
			dumpHead(variant, head)
		end
		say("boneka %s siap (lahir di SERVER, ikut ter-replikasi ke semua client)", variant)
	end

	say("stage: SRVTPL (template) vs SRVTEX (texture saja). FOTO DEKAT wajahnya. Hapus: S.clear()")
end

-- ===== Q2: rig yang sama dilihat lewat ViewportFrame =====
local function makeViewport(parent: Instance, index: number, title: string): ViewportFrame
	local holder = Instance.new("Frame")
	holder.Name = "VP_" .. title
	holder.Size = UDim2.fromOffset(180, 230)
	holder.Position = UDim2.new(0, 16 + (index - 1) * 190, 1, -246)
	holder.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	holder.BorderSizePixel = 0
	holder.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 24)
	label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	label.Text = title
	label.TextColor3 = Color3.fromRGB(255, 215, 0)
	label.TextScaled = true
	label.Parent = holder

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Size = UDim2.new(1, 0, 1, -24)
	viewport.Position = UDim2.fromOffset(0, 24)
	viewport.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	viewport.Ambient = Color3.fromRGB(200, 200, 200)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.Parent = holder
	return viewport
end

-- Kamera mepet wajah: presisi/meleset harus kelihatan tanpa zoom tambahan.
local function frameHead(viewport: ViewportFrame, rig: Model)
	local head = rig:FindFirstChild("Head")
	if head == nil then
		return
	end
	local headCFrame = (head :: BasePart).CFrame
	local pos = headCFrame.Position
	local cam = Instance.new("Camera")
	-- Avatar menghadap -Z (NormalId.Front = sisi -Z) -> kamera WAJIB di depan wajah.
	-- Putaran 1 memotret belakang kepala karena kamera ditaruh di +Z.
	cam.CFrame = CFrame.lookAt(headCFrame * Vector3.new(0, 0.1, -2), pos)
	cam.FieldOfView = 40
	cam.Parent = viewport
	viewport.CurrentCamera = cam
end

function M.viewport(assetId: number?)
	if not RunService:IsClient() then
		say("S.viewport() HARUS dari tab CLIENT")
		return
	end
	local id = assetId or DEFAULT_MAKEUP
	local source = workspace:FindFirstChild(RIG_PREFIX .. "SRVTPL")
	if source == nil then
		say("rig server belum ada -> jalankan S.stage(%d) dari tab SERVER dulu", id)
		return
	end
	local sourceHead = (source :: Model):FindFirstChild("Head")
	local sourceDecal = if sourceHead then sourceHead:FindFirstChildWhichIsA("Decal") else nil
	if sourceDecal == nil then
		say("rig server tidak punya Decal di Head — cek hasil S.stage()")
		return
	end
	local wrap = sourceDecal:FindFirstChildWhichIsA("WrapTextureTransfer" :: any, true)
	say("client: decal rig server bawa WrapTextureTransfer? %s", tostring(wrap ~= nil))
	if sourceHead then
		dumpHead("client-srvrig", sourceHead)
	end

	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		say("PlayerGui belum siap")
		return
	end
	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	-- 1. VP  : clone rig server langsung di ViewportFrame
	local vp1 = makeViewport(gui, 1, "VP (clone server, tanpa WorldModel)")
	local rig1 = (source :: Model):Clone()
	rig1:PivotTo(CFrame.new(0, 0, 0))
	rig1.Parent = vp1
	frameHead(vp1, rig1)

	-- 2. VPW : clone rig server di dalam WorldModel
	local vp2 = makeViewport(gui, 2, "VPW (clone server + WorldModel)")
	local world = Instance.new("WorldModel")
	world.Parent = vp2
	local rig2 = (source :: Model):Clone()
	rig2:PivotTo(CFrame.new(0, 0, 0))
	rig2.Parent = world
	frameHead(vp2, rig2)

	-- 3. CLI : rig dibangun DI CLIENT + template yang sama (kontrol temuan #21)
	local vp3 = makeViewport(gui, 3, "CLI (rig client + template)")
	local desc = appliedDescription()
	if desc ~= nil then
		local rig3 = buildRig(desc)
		if rig3 then
			local head3 = rig3:FindFirstChild("Head")
			if head3 then
				attachTemplate(head3 :: BasePart, sourceDecal :: Decal, "SPIKE_CLI")
			end
			local world3 = Instance.new("WorldModel")
			world3.Parent = vp3
			rig3:PivotTo(CFrame.new(0, 0, 0))
			rig3.Parent = world3
			frameHead(vp3, rig3)
		end
	end

	say("viewport: VP / VPW / CLI berjajar di layar. FOTO DEKAT. Hapus: S.clear()")
end

-- ===== PUTARAN 3: apakah rig SERVER benar-benar perlu? =====
-- Putaran 2 menunjukkan CLI (rig client + template) IKUT merender presisi — padahal spike #21
-- bilang mustahil. Bedanya: template-nya di-clone dari decal yang SUDAH menempel di rig
-- lahir-server yang berdiri di workspace. Kalau rig server itu tidak ada, apakah tetap jadi?
-- Jawabannya menentukan arsitektur: rig client saja = tidak perlu replikasi & siklus hidup rig.
--
--   LANGKAH A (tanpa rig server sama sekali — Stop lalu Play ulang dulu!)
--     tab SERVER: local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.publishOnly()
--     tab CLIENT: local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.decide()
--     -> yang berisi hanya CTPL & CTEX; CSRV/STPL sengaja kosong karena rig server belum ada.
--   LANGKAH B (rig server dihadirkan, tanpa Stop)
--     tab SERVER: S.stage()
--     tab CLIENT: S.decide()
--     -> keempat panel terisi. Bandingkan CTPL langkah A vs langkah B.
--
--   CTPL = rig CLIENT + template dari ReplicatedStorage   <- penentu
--   CSRV = rig CLIENT + template dari decal rig server di workspace
--   STPL = clone rig SERVER (kontrol: sudah terbukti benar di putaran 2)
--   CTEX = rig CLIENT + Decal texture saja (kontrol: harus MELAR)
--   CWM  = rig CLIENT + template, TAPI di dalam WorldModel  <- jalur kartu yang SUDAH ADA
--          (OutfitPreview.mount sekarang mem-parent model ke WorldModel). Kalau CWM kosong,
--          OutfitPreview WAJIB berhenti memakai WorldModel.
local TEMPLATE_FOLDER = "SPIKE_PreviewTemplates"

-- [SERVER] taruh template di ReplicatedStorage, TANPA membuat rig apa pun di workspace.
function M.publishOnly(assetId: number?)
	if not RunService:IsServer() then
		say("S.publishOnly() HARUS dari tab SERVER")
		return
	end
	local id = assetId or DEFAULT_MAKEUP
	local template = loadTemplate(id)
	if template == nil then
		return
	end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:FindFirstChild(TEMPLATE_FOLDER)
	if folder == nil then
		local f = Instance.new("Folder")
		f.Name = TEMPLATE_FOLDER
		f.Parent = ReplicatedStorage
		folder = f
	end
	local old = (folder :: Instance):FindFirstChild(tostring(id))
	if old then
		old:Destroy()
	end
	local copy = template:Clone()
	copy.Name = tostring(id)
	copy.Parent = folder
	say("publishOnly: template %d ada di ReplicatedStorage.%s (TIDAK ada rig di workspace)", id, TEMPLATE_FOLDER)
end

-- [CLIENT] empat viewport berjajar: CTPL / CSRV / STPL / CTEX.
function M.decide(assetId: number?)
	if not RunService:IsClient() then
		say("S.decide() HARUS dari tab CLIENT")
		return
	end
	local id = assetId or DEFAULT_MAKEUP
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:FindFirstChild(TEMPLATE_FOLDER)
	local rsTemplate = if folder then folder:FindFirstChild(tostring(id)) else nil
	if rsTemplate == nil then
		say("template %d belum ada -> jalankan S.publishOnly(%d) dari tab SERVER dulu", id, id)
		return
	end
	local rsWrap = rsTemplate:FindFirstChildWhichIsA("WrapTextureTransfer" :: any, true)
	say("decide: template ReplicatedStorage bawa WrapTextureTransfer? %s", tostring(rsWrap ~= nil))

	local serverRig = workspace:FindFirstChild(RIG_PREFIX .. "SRVTPL")
	local serverHead = if serverRig then (serverRig :: Model):FindFirstChild("Head") else nil
	local serverDecal = if serverHead then serverHead:FindFirstChildWhichIsA("Decal") else nil
	say("decide: rig server di workspace? %s", tostring(serverRig ~= nil))

	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		say("PlayerGui belum siap")
		return
	end
	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local desc = appliedDescription()
	if desc == nil then
		return
	end

	local panels = { "CTPL", "CSRV", "STPL", "CTEX", "CWM" }
	for i, kind in panels do
		local viewport = makeViewport(gui, i, kind)
		local rig: Model? = nil
		if kind == "STPL" then
			rig = if serverRig then (serverRig :: Model):Clone() else nil
		elseif kind == "CSRV" then
			if serverDecal ~= nil then
				rig = buildRig(desc)
			end
		else
			rig = buildRig(desc)
		end
		if rig == nil then
			say("panel %s dilewati (rig server belum ada)", kind)
			continue
		end
		local model = rig :: Model
		local head = model:FindFirstChild("Head")
		if head then
			-- CTPL & CWM memakai template yang sama; bedanya hanya WorldModel saat di-parent.
			if kind == "CTPL" or kind == "CWM" then
				attachTemplate(head :: BasePart, rsTemplate :: Decal, "SPIKE_" .. kind)
			elseif kind == "CSRV" then
				attachTemplate(head :: BasePart, serverDecal :: Decal, "SPIKE_" .. kind)
			elseif kind == "CTEX" then
				attachTexture(head :: BasePart, rsTemplate :: Decal, "SPIKE_" .. kind)
			end
		end
		local label = model:FindFirstChild("SPIKE_LABEL", true)
		if label then
			label:Destroy()
		end
		model:PivotTo(CFrame.new(0, 0, 0))
		if kind == "CWM" then
			local world = Instance.new("WorldModel") -- persis seperti OutfitPreview.mount sekarang
			world.Name = "Preview"
			world.Parent = viewport
			model.Parent = world
		else
			model.Parent = viewport
		end
		frameHead(viewport, model)
		say("panel %s siap", kind)
	end
	say("decide: CTPL / CSRV / STPL / CTEX / CWM berjajar di bawah layar. FOTO DEKAT. Hapus: S.clear()")
end

-- Bersih-bersih; aman dipanggil dari tab mana pun (masing-masing membersihkan sisinya).
function M.clear()
	for _, obj in workspace:GetChildren() do
		if string.sub(obj.Name, 1, #RIG_PREFIX) == RIG_PREFIX then
			obj:Destroy()
		end
	end
	if RunService:IsClient() then
		local player = Players.LocalPlayer
		local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
		local gui = if playerGui then playerGui:FindFirstChild(GUI_NAME) else nil
		if gui then
			gui:Destroy()
		end
	end
	say("clear: boneka & panel spike dihapus")
end

-- ===== PR kolom kiri: preview AVATAR SEKARANG (18 Sep 2026) =====
-- Kolom kiri akan jadi kartu ViewportFrame supaya latar AvatarBackground punya tempat.
-- Yang belum pasti: isi kartunya dibuat bagaimana?
--   CLONE = clone karakter ASLI pemain (makeup Decal & layered clothing sudah menempel di situ)
--   BUILD = bangun rig baru dari GetAppliedDescription (jalur OutfitPreview sekarang, ~0,44 dtk
--           dan makeup harus ditempel ulang dari template)
-- Diukur: waktu, makeup ikut atau tidak, rakitan/pose benar atau berantakan, dan apakah latar
-- (ImageLabel SAUDARA di belakang viewport, seperti produksi) tetap tergambar di belakang avatar.
-- Cara pakai (tab CLIENT):
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.current()
--   S.currentOff()
local CURRENT_GUI = "SPIKE_Current"
local CURRENT_IMAGE = 139431817156818 -- Prism Skies

local function frameFullBody(viewport: ViewportFrame, rig: Model)
	local cf, size = rig:GetBoundingBox()
	local half = math.rad(15)
	local dist = (math.min(size.Y, 12) / 2) / math.tan(half) * 1.15 + size.Z / 2
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.CFrame = CFrame.lookAt(cf.Position + cf.LookVector * dist, cf.Position)
	cam.Parent = viewport
	viewport.CurrentCamera = cam
end

-- Siapkan model untuk dipajang (sama seperti OutfitPreview.prepare di produksi).
local function tidyForPreview(rig: Model)
	for _, x in rig:GetDescendants() do
		if x:IsA("BaseScript") then
			x:Destroy()
		elseif x:IsA("BasePart") then
			local part = x :: BasePart
			part.Massless = true
			part.CanCollide = false
			part.CanQuery = false
		end
	end
	local root = rig.PrimaryPart or rig:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		(humanoid :: Humanoid).DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
end

local function countDecals(rig: Model): number
	local head = rig:FindFirstChild("Head")
	if head == nil then
		return 0
	end
	local n = 0
	for _, child in (head :: Instance):GetChildren() do
		if child:IsA("Decal") then
			n += 1
		end
	end
	return n
end

function M.currentOff()
	local player = Players.LocalPlayer
	local gui = if player then player:FindFirstChild("PlayerGui") else nil
	local old = if gui then gui:FindFirstChild(CURRENT_GUI) else nil
	if old then
		old:Destroy()
		say("currentOff: panel dihapus")
	end
end

function M.current()
	if not RunService:IsClient() then
		say("S.current() HARUS dari tab CLIENT")
		return
	end
	local char = firstCharacter()
	local desc = appliedDescription()
	if char == nil or desc == nil then
		return
	end
	M.currentOff()

	local screen = Instance.new("ScreenGui")
	screen.Name = CURRENT_GUI
	screen.ResetOnSpawn = false
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	for index, mode in { "CLONE", "BUILD" } do
		local viewport = makeViewport(screen, index, mode)
		viewport.BackgroundTransparency = 1
		-- latar: ImageLabel SAUDARA di belakang viewport (persis cara produksi)
		local backdrop = Instance.new("ImageLabel")
		backdrop.Name = "Backdrop"
		backdrop.Image = "rbxassetid://" .. tostring(CURRENT_IMAGE)
		backdrop.ScaleType = Enum.ScaleType.Crop
		backdrop.BackgroundTransparency = 1
		backdrop.BorderSizePixel = 0
		backdrop.Position = viewport.Position
		backdrop.Size = viewport.Size
		backdrop.ZIndex = viewport.ZIndex - 1
		backdrop.Parent = viewport.Parent

		local world = Instance.new("WorldModel")
		world.Name = "Preview"
		world.Parent = viewport

		local t0 = os.clock()
		local rig: Model? = nil
		if mode == "CLONE" then
			-- TEMUAN: `Player.Character` datang dengan Archivable = false -> Clone() mengembalikan nil.
			-- Dinyalakan sebentar, lalu dikembalikan seperti semula.
			local target = char :: Model
			local wasArchivable = target.Archivable
			target.Archivable = true
			local okClone, copy = pcall(function()
				return target:Clone()
			end)
			target.Archivable = wasArchivable
			rig = if okClone and typeof(copy) == "Instance" then copy :: Model else nil
			if rig == nil then
				say("CLONE tetap gagal: %s", tostring(copy))
			end
		else
			rig = buildRig(desc)
		end
		if rig ~= nil then
			tidyForPreview(rig)
			rig:PivotTo(CFrame.new())
			rig.Parent = world
			frameFullBody(viewport, rig)
			say("%s siap dalam %.3f detik, decal di Head = %d", mode, os.clock() - t0, countDecals(rig))
		end
	end
	-- Latar hitam bisa berarti gambar BELUM TERMUAT, bukan tidak tergambar -> laporkan statusnya.
	task.delay(1.5, function()
		for _, holder in screen:GetChildren() do
			local img = holder:FindFirstChild("Backdrop")
			if img and img:IsA("ImageLabel") then
				say("latar %s IsLoaded=%s ZIndex=%d", holder.Name, tostring(img.IsLoaded), img.ZIndex)
			end
		end
	end)
	say("current: CLONE vs BUILD berdampingan (kiri bawah). Hapus: S.currentOff()")
end

-- ===== PR kolom kiri: bisakah avatar di KARTU bergerak? (18 Sep 2026) =====
-- Isi ViewportFrame tidak di-update engine, jadi animasi diam walau track-nya :Play().
-- Dugaan: harus dipanggil `Animator:StepAnimation(dt)` sendiri tiap frame.
--   PLAY = LoadAnimation + Play saja (pembanding: harusnya tetap patung)
--   STEP = sama + RenderStepped -> animator:StepAnimation(dt)
-- Animasinya diambil dari track yang SEDANG dimainkan karakter asli, jadi animation pack
-- milik pemain ikut terpakai (bukan idle bawaan yang dipaksakan).
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.anim()
--   S.animOff()
-- HASIL (18 Sep 2026): PLAY = tangan bergerak 0.000 stud dalam 3 detik -> rig di ViewportFrame
-- BEKU, dan `Animator:StepAnimation` SUDAH TIDAK ADA di API (mengaksesnya saja melempar error).
-- Kesimpulan: animasi di dalam kartu preview TIDAK BISA lewat jalur ini. Kesan hidup diambil dari
-- kamera yang berputar pelan (OutfitPreview.setSpin), bukan dari animasi rig.
local ANIM_GUI = "SPIKE_Anim"
local animConns: { RBXScriptConnection } = {}

local function playingAnimationId(char: Model): string?
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		return nil
	end
	for _, track in (animator :: Animator):GetPlayingAnimationTracks() do
		local anim = track.Animation
		if anim ~= nil and anim.AnimationId ~= "" then
			return anim.AnimationId
		end
	end
	return nil
end

function M.animOff()
	for _, conn in animConns do
		conn:Disconnect()
	end
	table.clear(animConns)
	local player = Players.LocalPlayer
	local gui = if player then player:FindFirstChild("PlayerGui") else nil
	local old = if gui then gui:FindFirstChild(ANIM_GUI) else nil
	if old then
		old:Destroy()
		say("animOff: panel animasi dihapus")
	end
end

function M.anim()
	if not RunService:IsClient() then
		say("S.anim() HARUS dari tab CLIENT")
		return
	end
	local char = firstCharacter()
	if char == nil then
		return
	end
	M.animOff()
	local animId = playingAnimationId(char)
	say("animasi yang sedang dimainkan karakter: %s", tostring(animId))
	if animId == nil then
		say("tidak ada track yang jalan -> coba gerakkan karakter dulu, lalu ulangi")
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = ANIM_GUI
	screen.ResetOnSpawn = false
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	for index, mode in { "PLAY", "STEP" } do
		local viewport = makeViewport(screen, index, mode)
		local world = Instance.new("WorldModel")
		world.Name = "Preview"
		world.Parent = viewport

		local target = char :: Model
		local wasArchivable = target.Archivable
		target.Archivable = true
		local okClone, copy = pcall(function()
			return target:Clone()
		end)
		target.Archivable = wasArchivable
		if not okClone or typeof(copy) ~= "Instance" then
			say("%s: clone gagal %s", mode, tostring(copy))
			continue
		end
		local rig = copy :: Model
		tidyForPreview(rig)
		rig:PivotTo(CFrame.new())
		rig.Parent = world
		frameFullBody(viewport, rig)

		local humanoid = rig:FindFirstChildOfClass("Humanoid")
		local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
		if animator == nil then
			say("%s: rig clone TIDAK punya Animator -> animasi mustahil di jalur ini", mode)
			continue
		end
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local okTrack, track = pcall(function()
			return (animator :: Animator):LoadAnimation(anim)
		end)
		if not okTrack then
			say("%s: LoadAnimation gagal %s", mode, tostring(track))
			continue
		end
		local playing = track :: AnimationTrack
		playing.Looped = true
		playing:Play()
		if mode == "STEP" then
			-- TEMUAN: `Animator:StepAnimation` SUDAH TIDAK ADA di API sekarang (ribuan error
			-- "not a valid member"). Jadi kalau rig di ViewportFrame bergerak, itu karena WorldModel
			-- yang mensimulasikannya sendiri -- bukan karena kita men-step manual.
			local okStep, stepFn = pcall(function()
				return (animator :: any).StepAnimation
			end)
			say("%s: StepAnimation tersedia? %s", mode, tostring(okStep and typeof(stepFn) == "function"))
		end

		-- Ukur GERAK secara objektif: bandingkan posisi tangan tiap 0,5 detik selama 3 detik.
		local hand = rig:FindFirstChild("LeftHand", true) or rig:FindFirstChild("Left Arm", true)
		if hand and hand:IsA("BasePart") then
			task.spawn(function()
				local part = hand :: BasePart
				local last = part.Position
				local moved = 0
				for _ = 1, 6 do
					task.wait(0.5)
					if part.Parent == nil then
						return
					end
					moved += (part.Position - last).Magnitude
					last = part.Position
				end
				say("%s: tangan bergerak total %.3f stud dalam 3 detik", mode, moved)
			end)
		end
		say("%s siap (track %s)", mode, animId)
	end
	say("anim: PLAY vs STEP berdampingan. Hapus: S.animOff()")
end

-- ===== PR kolom kiri: animasi lewat CERMIN POSE (18 Sep 2026) =====
-- Spike sebelumnya membuktikan rig di ViewportFrame BEKU (0,000 stud) dan `Animator:StepAnimation`
-- sudah tidak ada. Tapi karakter ASLI di workspace jelas beranimasi (animation pack pemain).
-- Ide: clone di kartu tidak perlu "hidup" sendiri -- cukup MENYALIN pose karakter asli tiap frame.
--   STATIC = clone diam (pembanding, seperti produksi sekarang)
--   MIRROR = tiap RenderStepped, CFrame tiap part disalin relatif HumanoidRootPart
-- Semua part clone di-anchor supaya weld/constraint tidak menarik balik CFrame yang kita setel.
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.mirror()
--   S.mirrorOff()
local MIRROR_GUI = "SPIKE_Mirror"
local mirrorConns: { RBXScriptConnection } = {}

-- Pasangan part asli <-> part clone. Clone dibuat dari model yang sama, jadi urutan anaknya identik.
local function pairParts(src: Instance, dst: Instance): { { s: BasePart, d: BasePart } }
	local out: { { s: BasePart, d: BasePart } } = {}
	local function walk(a: Instance, b: Instance)
		local bc = b:GetChildren()
		for i, child in a:GetChildren() do
			local mate = bc[i]
			if mate == nil or mate.ClassName ~= child.ClassName then
				continue
			end
			if child:IsA("BasePart") and mate:IsA("BasePart") then
				table.insert(out, { s = child :: BasePart, d = mate :: BasePart })
			end
			walk(child, mate)
		end
	end
	walk(src, dst)
	return out
end

function M.mirrorOff()
	for _, conn in mirrorConns do
		conn:Disconnect()
	end
	table.clear(mirrorConns)
	local player = Players.LocalPlayer
	local gui = if player then player:FindFirstChild("PlayerGui") else nil
	local old = if gui then gui:FindFirstChild(MIRROR_GUI) else nil
	if old then
		old:Destroy()
		say("mirrorOff: panel cermin dihapus")
	end
end

function M.mirror()
	if not RunService:IsClient() then
		say("S.mirror() HARUS dari tab CLIENT")
		return
	end
	local char = firstCharacter()
	if char == nil then
		return
	end
	M.mirrorOff()

	local screen = Instance.new("ScreenGui")
	screen.Name = MIRROR_GUI
	screen.ResetOnSpawn = false
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	for index, mode in { "STATIC", "MIRROR" } do
		local viewport = makeViewport(screen, index, mode)
		local world = Instance.new("WorldModel")
		world.Name = "Preview"
		world.Parent = viewport

		local target = char :: Model
		local wasArchivable = target.Archivable
		target.Archivable = true
		local okClone, copy = pcall(function()
			return target:Clone()
		end)
		target.Archivable = wasArchivable
		if not okClone or typeof(copy) ~= "Instance" then
			say("%s: clone gagal %s", mode, tostring(copy))
			continue
		end
		local rig = copy :: Model
		tidyForPreview(rig)
		if mode == "MIRROR" then
			-- anchor SEMUA: pose diatur penuh oleh kita, bukan oleh weld/constraint
			for _, x in rig:GetDescendants() do
				if x:IsA("BasePart") then
					(x :: BasePart).Anchored = true
				end
			end
		end
		rig:PivotTo(CFrame.new())
		rig.Parent = world
		frameFullBody(viewport, rig)

		if mode == "MIRROR" then
			local pairs_ = pairParts(target, rig)
			local srcRoot = target:FindFirstChild("HumanoidRootPart")
			local dstRoot = rig:FindFirstChild("HumanoidRootPart")
			say(
				"MIRROR: %d pasang part, root asli %s / clone %s",
				#pairs_,
				tostring(srcRoot ~= nil),
				tostring(dstRoot ~= nil)
			)
			if srcRoot and dstRoot then
				local from = srcRoot :: BasePart
				local to = dstRoot :: BasePart
				table.insert(
					mirrorConns,
					RunService.RenderStepped:Connect(function()
						if to.Parent == nil or from.Parent == nil then
							return
						end
						local base = to.CFrame
						local inv = from.CFrame:Inverse()
						for _, pair in pairs_ do
							if pair.d ~= to then
								pair.d.CFrame = base * (inv * pair.s.CFrame)
							end
						end
					end)
				)
			end
		end

		local hand = rig:FindFirstChild("LeftHand", true) or rig:FindFirstChild("Left Arm", true)
		if hand and hand:IsA("BasePart") then
			task.spawn(function()
				local part = hand :: BasePart
				local last = part.Position
				local moved = 0
				for _ = 1, 6 do
					task.wait(0.5)
					if part.Parent == nil then
						return
					end
					moved += (part.Position - last).Magnitude
					last = part.Position
				end
				say("%s: tangan bergerak total %.3f stud dalam 3 detik", mode, moved)
			end)
		end
		say("%s siap", mode)
	end
	say("mirror: STATIC vs MIRROR berdampingan. Hapus: S.mirrorOff()")
end

-- ===== PR bar aksi kartu preview: SIAPA yang menerima drag? (18 Sep 2026) =====
-- Kartu preview menutupi PERSIS area tempat karakter dunia berdiri, sementara TryOnCamera masih
-- mendengarkan drag di layar. Kalau drag di atas kartu TIDAK tersedot GUI, satu gerakan jari
-- memutar DUA hal sekaligus: kamera dunia (tak terlihat, di belakang kartu) dan kartu itu sendiri.
-- Itulah yang harus diukur SEBELUM bar aksi dibuat, karena jawabannya mengunci cara pasang input:
--   FRAME  = Frame biasa (persis kartu produksi sekarang)
--   ACTIVE = Frame yang sama + `Active = true`
--   BUTTON = ImageButton menutupi viewport
-- Yang diukur saat satu kali drag di atas tiap kartu:
--   processed true/false  -> apakah GUI menyedot input (true = tersedot, TryOnCamera diam)
--   kamera DUNIA bergeser berapa DERAJAT selama drag itu (0 = bersih, >0 = input bocor)
-- Sekalian dijawab: batas zoom (Camera.NearPlaneZ -> jarak aman minimum) dan apakah pitch/pan
-- di dalam ViewportFrame masih terlihat wajar.
--
-- CARA PAKAI (tab CLIENT, dan BUKA KATALOG dulu supaya TryOnCamera hidup):
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.controls()
--   -> drag kiri di atas kartu FRAME, lepas. Ulangi di ACTIVE, lalu BUTTON. Baca 3 baris laporan.
--   -> scroll di atas kartu = zoom (cetak faktor + jarak). Shift+drag = geser (pan).
--   S.controlsOff()
local CONTROLS_GUI = "SPIKE_Controls"
local CONTROLS_SPECS = {
	{ name = "FRAME", active = false, button = false },
	{ name = "ACTIVE", active = true, button = false },
	{ name = "BUTTON", active = false, button = true },
}
local CONTROLS_W = 200
local CONTROLS_H = 260
local CONTROLS_GAP = 12
local CONTROLS_SENS = 0.008 -- radian per piksel (sama dengan OrbitMath.DEFAULTS.sensitivity)
local CONTROLS_PAN = 0.01 -- stud per piksel
local controlConns: { RBXScriptConnection } = {}

type ControlCard = {
	name: string,
	holder: GuiObject,
	camera: Camera,
	center: Vector3,
	dir: Vector3,
	dist: number,
	yaw: number,
	pitch: number,
	zoom: number,
	panX: number,
	panY: number,
	apply: () -> (),
}

-- Kartu di bawah kursor. ScreenGui spike memakai IgnoreGuiInset supaya AbsolutePosition dan
-- input.Position memakai titik nol yang SAMA (tanpa itu selisihnya setinggi topbar Roblox).
local function controlCardAt(cards: { ControlCard }, x: number, y: number): ControlCard?
	for _, card in cards do
		local p = card.holder.AbsolutePosition
		local s = card.holder.AbsoluteSize
		if x >= p.X and x <= p.X + s.X and y >= p.Y and y <= p.Y + s.Y then
			return card
		end
	end
	return nil
end

local function controlAngleBetween(a: Vector3, b: Vector3): number
	return math.deg(math.acos(math.clamp(a:Dot(b), -1, 1)))
end

function M.controlsOff()
	for _, conn in controlConns do
		conn:Disconnect()
	end
	table.clear(controlConns)
	local player = Players.LocalPlayer
	local gui = if player then player:FindFirstChild("PlayerGui") else nil
	local old = if gui then gui:FindFirstChild(CONTROLS_GUI) else nil
	if old then
		old:Destroy()
		say("controlsOff: panel kontrol dihapus")
	end
end

function M.controls()
	if not RunService:IsClient() then
		say("S.controls() HARUS dari tab CLIENT")
		return
	end
	local char = firstCharacter()
	if char == nil then
		return
	end
	M.controlsOff()
	local target = char :: Model

	local screen = Instance.new("ScreenGui")
	screen.Name = CONTROLS_GUI
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true -- titik nol AbsolutePosition = titik nol input.Position
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local cards: { ControlCard } = {}
	local total = #CONTROLS_SPECS * CONTROLS_W + (#CONTROLS_SPECS - 1) * CONTROLS_GAP

	for index, spec in CONTROLS_SPECS do
		local holder = Instance.new("Frame")
		holder.Name = spec.name
		holder.BackgroundColor3 = Color3.fromRGB(16, 16, 19)
		holder.BorderSizePixel = 0
		holder.AnchorPoint = Vector2.new(0, 1)
		holder.Position = UDim2.new(0.5, -total / 2 + (index - 1) * (CONTROLS_W + CONTROLS_GAP), 1, -16)
		holder.Size = UDim2.fromOffset(CONTROLS_W, CONTROLS_H)
		holder.Active = spec.active
		holder.Parent = screen

		local caption = Instance.new("TextLabel")
		caption.BackgroundTransparency = 1
		caption.Size = UDim2.new(1, 0, 0, 18)
		caption.Text = spec.name
		caption.TextColor3 = Color3.fromRGB(226, 183, 77)
		caption.TextSize = 14
		caption.ZIndex = 5
		caption.Parent = holder

		local viewport = Instance.new("ViewportFrame")
		viewport.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
		viewport.Position = UDim2.fromOffset(0, 18)
		viewport.Size = UDim2.new(1, 0, 1, -18)
		viewport.Ambient = Color3.fromRGB(120, 120, 134)
		viewport.LightColor = Color3.fromRGB(236, 236, 245)
		viewport.LightDirection = Vector3.new(-0.4, -1, -0.65)
		viewport.Parent = holder

		if spec.button then
			-- Penutup transparan: yang menyedot input, bukan viewport-nya.
			local cover = Instance.new("ImageButton")
			cover.Name = "Cover"
			cover.BackgroundTransparency = 1
			cover.Size = UDim2.fromScale(1, 1)
			cover.ZIndex = 4
			cover.AutoButtonColor = false
			cover.Parent = viewport
		end

		local world = Instance.new("WorldModel")
		world.Name = "Preview"
		world.Parent = viewport

		local wasArchivable = target.Archivable
		target.Archivable = true
		local okClone, copy = pcall(function()
			return target:Clone()
		end)
		target.Archivable = wasArchivable
		local rig = if okClone and typeof(copy) == "Instance" then copy :: Model else nil
		if rig == nil then
			say("%s: clone karakter gagal (%s)", spec.name, tostring(copy))
			continue
		end
		local body = rig :: Model
		tidyForPreview(body)
		for _, x in body:GetDescendants() do
			if x:IsA("BasePart") then
				(x :: BasePart).Anchored = true -- pose diatur penuh oleh cermin
			end
		end
		body:PivotTo(CFrame.new())
		body.Parent = world

		local camera = Instance.new("Camera")
		camera.FieldOfView = 30
		camera.Parent = viewport
		viewport.CurrentCamera = camera

		local box, size = body:GetBoundingBox()
		local half = math.rad(15)
		local baseDist = (math.min(size.Y, 12) / 2) / math.tan(half) * 1.15 + size.Z / 2

		local card: ControlCard = {
			name = spec.name,
			holder = holder,
			camera = camera,
			center = box.Position,
			dir = box.LookVector,
			dist = baseDist,
			yaw = 0,
			pitch = 0,
			zoom = 1,
			panX = 0,
			panY = 0,
			apply = function() end,
		}
		card.apply = function()
			local rot = CFrame.Angles(0, card.yaw, 0) * CFrame.Angles(card.pitch, 0, 0)
			local eye = card.center + (rot * card.dir) * (card.dist * card.zoom)
			local aim = CFrame.lookAt(eye, card.center)
			local shift = aim.RightVector * card.panX + aim.UpVector * card.panY
			camera.CFrame = CFrame.lookAt(eye + shift, card.center + shift)
		end
		card.apply()
		table.insert(cards, card)

		local poses = pairParts(target, body)
		local srcRoot = target:FindFirstChild("HumanoidRootPart")
		local dstRoot = body:FindFirstChild("HumanoidRootPart")
		if srcRoot and dstRoot then
			local from = srcRoot :: BasePart
			local to = dstRoot :: BasePart
			table.insert(
				controlConns,
				RunService.RenderStepped:Connect(function()
					if from.Parent == nil or to.Parent == nil then
						return
					end
					local base = to.CFrame
					local inv = from.CFrame:Inverse()
					for _, pose in poses do
						if pose.d ~= to then
							pose.d.CFrame = base * (inv * pose.s.CFrame)
						end
					end
				end)
			)
		end
	end

	if #cards == 0 then
		say("controls: tidak ada kartu yang jadi")
		return
	end
	local first = cards[1]
	-- Camera.NearPlaneZ = jarak terdekat yang masih digambar -> batas bawah zoom yang aman.
	local nearOk, near = pcall(function()
		return first.camera.NearPlaneZ
	end)
	local nearZ = if nearOk and type(near) == "number" then math.abs(near) else 0.1
	say(
		"zoom: NearPlaneZ=%.3f stud, jarak awal=%.2f stud -> faktor aman >= %.2f",
		nearZ,
		first.dist,
		(nearZ + 1) / first.dist
	)

	-- ===== pengukuran drag =====
	local held: ControlCard? = nil
	local lastX, lastY = 0, 0
	local okCount, leakCount = 0, 0
	local startLook = Vector3.new(0, 0, 1)

	local function worldLook(): Vector3
		local cam = workspace.CurrentCamera
		return if cam then cam.CFrame.LookVector else Vector3.new(0, 0, 1)
	end

	table.insert(
		controlConns,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
				return
			end
			local card = controlCardAt(cards, input.Position.X, input.Position.Y)
			if card == nil then
				return
			end
			held = card
			lastX, lastY = input.Position.X, input.Position.Y
			okCount, leakCount = 0, 0
			if processed then
				okCount += 1
			else
				leakCount += 1
			end
			startLook = worldLook()
		end)
	)

	table.insert(
		controlConns,
		UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
			local t = input.UserInputType
			if t == Enum.UserInputType.MouseWheel then
				local card = controlCardAt(cards, input.Position.X, input.Position.Y)
				if card ~= nil then
					card.zoom = math.clamp(card.zoom * 0.9 ^ input.Position.Z, 0.25, 2)
					card.apply()
					say("%s zoom: faktor %.2f -> jarak %.2f stud", card.name, card.zoom, card.dist * card.zoom)
				end
				return
			end
			if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then
				return
			end
			local card = held
			if card == nil then
				return
			end
			if processed then
				okCount += 1
			else
				leakCount += 1
			end
			local dx = input.Position.X - lastX
			local dy = input.Position.Y - lastY
			lastX, lastY = input.Position.X, input.Position.Y
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
				card.panX -= dx * CONTROLS_PAN
				card.panY += dy * CONTROLS_PAN
			else
				card.yaw -= dx * CONTROLS_SENS
				card.pitch = math.clamp(card.pitch - dy * CONTROLS_SENS, math.rad(-35), math.rad(35))
			end
			card.apply()
		end)
	)

	table.insert(
		controlConns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
				return
			end
			local card = held
			if card == nil then
				return
			end
			held = nil
			say(
				"%s: processed true=%d false=%d, kamera DUNIA bergeser %.2f derajat, pan=(%.2f, %.2f)",
				card.name,
				okCount,
				leakCount,
				controlAngleBetween(startLook, worldLook()),
				card.panX,
				card.panY
			)
		end)
	)

	say("controls: 3 kartu di bawah layar. Drag di tiap kartu lalu LEPAS -> 1 baris laporan per kartu.")
	say("controls: 0 derajat = input tersedot GUI (bersih). >0 derajat = drag BOCOR ke TryOnCamera.")
	say("controls: scroll = zoom, Shift+drag = geser avatar. Hapus: S.controlsOff()")
end

-- ===== SPIKE FAVORIT ITEM (PR #28 kartu item, 19 Sep 2026) =====
-- Bintang favorit di kartu item boleh memakai favorit ASLI Roblox, atau harus disimpan sendiri
-- di PlayerData? Empat pertanyaan, dijawab dengan MENULIS bukan cuma membaca (pelajaran #26 no. 2):
--   1. Method favorit apa yang ADA di AvatarEditorService (dan Enum.AvatarItemType isinya apa)?
--   2. Membaca status favorit dari CLIENT jalan, atau ditolak sampai pemain memberi izin inventory?
--   3. PromptSetFavorite: promptnya MUNCUL di Studio, dan hasilnya apa?
--   4. Sesudah ditulis, bacaan no. 2 IKUT BERUBAH? Kalau tidak, bintangnya tidak bisa jujur
--      (kartu tak bisa tahu item ini sudah difavoritkan atau belum) -> jatuh ke PlayerData v6.
-- CARA PAKAI (tab CLIENT, karena favorit milik pemain — bukan server):
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.favorite()
--   S.favorite(123316458229208)        -- id lain
--   S.favorite(123316458229208, false) -- BATALKAN favorit (kembalikan keadaan semula)
local FAV_METHODS = {
	"PromptSetFavorite",
	"GetFavorite",
	"PromptAllowInventoryReadAccess",
	"GetItemDetails",
	"SearchCatalog",
}
local FAV_TIMEOUT = 25 -- detik menunggu pemain menjawab prompt

local function favHasMethod(service: any, name: string): boolean
	local ok, value = pcall(function()
		return service[name]
	end)
	return ok and typeof(value) == "function"
end

-- Baca status favorit dari client. Kembalian: (berhasil, nilai | pesan error)
local function favRead(service: any, assetId: number): (boolean, any)
	return pcall(function()
		return service:GetFavorite(assetId, Enum.AvatarItemType.Asset)
	end)
end

-- Picu sebuah prompt lalu tunggu eventnya. Kembalian: ("ok" | "timeout" | "error", nilai).
-- Prompt yang TIDAK muncul di Studio akan terlihat sebagai "timeout", bukan menggantung.
local function favWait(signal: any, fire: () -> ()): (string, any)
	local got: any = nil
	local done = false
	local conn: RBXScriptConnection? = nil
	if signal ~= nil then
		conn = signal:Connect(function(value: any)
			got = value
			done = true
		end)
	end
	local okFire, err = pcall(fire)
	if not okFire then
		if conn then
			conn:Disconnect()
		end
		return "error", err
	end
	local started = os.clock()
	while not done and os.clock() - started < FAV_TIMEOUT do
		task.wait(0.2)
	end
	if conn then
		conn:Disconnect()
	end
	return (if done then "ok" else "timeout"), got
end

function M.favorite(assetId: number?, on: boolean?)
	if not RunService:IsClient() then
		say("favorit: jalankan dari tab CLIENT — favorit milik pemain, bukan server")
		return
	end
	local id = assetId or DEFAULT_MAKEUP
	local want = on ~= false
	local aes = game:GetService("AvatarEditorService")

	-- 1. method yang ada
	local found = {}
	for _, name in FAV_METHODS do
		table.insert(found, ("%s=%s"):format(name, if favHasMethod(aes, name) then "ADA" else "TIDAK"))
	end
	say("favorit 1 method: %s", table.concat(found, " "))

	local typeNames = {}
	local okEnum, enumItems = pcall(function()
		return Enum.AvatarItemType:GetEnumItems()
	end)
	if okEnum then
		for _, item in enumItems do
			table.insert(typeNames, item.Name)
		end
	end
	say("favorit 1b AvatarItemType: %s", if okEnum then table.concat(typeNames, ", ") else "TIDAK ADA")

	-- 2. baca status sekarang
	local okBefore, before = favRead(aes, id)
	say("favorit 2 baca (id %d) -> %s %s", id, if okBefore then "OK" else "GAGAL", tostring(before))

	-- 2b. ditolak -> minta izin inventory, lalu baca ulang
	if not okBefore then
		local askStatus, granted = favWait((aes :: any).PromptAllowInventoryReadAccessCompleted, function()
			aes:PromptAllowInventoryReadAccess()
		end)
		say("favorit 2b izin inventory -> %s %s", askStatus, tostring(granted))
		local okRetry, retry = favRead(aes, id)
		say("favorit 2c baca ulang -> %s %s", if okRetry then "OK" else "GAGAL", tostring(retry))
		okBefore = okRetry
		before = retry
	end

	-- 3. TULIS favorit
	local setStatus, result = favWait((aes :: any).PromptSetFavoriteCompleted, function()
		aes:PromptSetFavorite(id, Enum.AvatarItemType.Asset, want)
	end)
	say("favorit 3 PromptSetFavorite(%s) -> %s %s", tostring(want), setStatus, tostring(result))

	-- 4. bacaan ikut berubah?
	local okAfter, after = favRead(aes, id)
	say("favorit 4 baca sesudah -> %s %s", if okAfter then "OK" else "GAGAL", tostring(after))
	if okBefore and okAfter then
		say(
			"favorit 4b bacaan berubah? %s (sebelum=%s sesudah=%s)",
			tostring(before ~= after),
			tostring(before),
			tostring(after)
		)
	else
		say("favorit 4b tidak bisa dibandingkan: bacaan favorit tidak tersedia dari client")
	end
	say("favorit: batalkan dengan S.favorite(%d, false)", id)
end

-- ===== SPIKE FAVORIT putaran 2: BIAYA SATU GRID (PR #28, 19 Sep 2026) =====
-- Putaran 1 membuktikan GetFavorite jalan dari client sesudah izin inventory. Yang BELUM diukur:
-- satu grid = 30 kartu = 30 bacaan. Itu murah, atau jalan cepat ke HTTP 429 seperti #17b?
-- Diukur, bukan ditebak (pelajaran #25). Dua cara dibandingkan di ID YANG SAMA:
--   A. beruntun  (satu per satu)  -> aman tapi mungkin lambat
--   B. serentak  (30 thread)      -> cepat tapi mungkin kena throttle
-- CARA PAKAI (tab CLIENT):
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.favoriteBatch()
--   S.favoriteBatch(10)
local FAV_BATCH_TIMEOUT = 30

-- Id nyata dari pencarian katalog (client boleh memanggil SearchCatalog — putaran 1 no. 1).
local function favSampleIds(service: any, count: number): { number }
	local ok, page = pcall(function()
		local params = CatalogSearchParams.new()
		params.SearchKeyword = "hat"
		return service:SearchCatalog(params)
	end)
	if not ok then
		say("favoritBatch: SearchCatalog GAGAL %s", tostring(page))
		return {}
	end
	local okPage, items = pcall(function()
		return page:GetCurrentPage()
	end)
	if not okPage then
		say("favoritBatch: GetCurrentPage GAGAL %s", tostring(items))
		return {}
	end
	local ids = {}
	for _, item in items do
		local id = (item :: any).Id
		if typeof(id) == "number" and #ids < count then
			table.insert(ids, id)
		end
	end
	return ids
end

function M.favoriteBatch(count: number?)
	if not RunService:IsClient() then
		say("favoritBatch: jalankan dari tab CLIENT")
		return
	end
	local aes = game:GetService("AvatarEditorService")
	local ids = favSampleIds(aes, count or 30)
	say("favoritBatch: %d id dari pencarian katalog", #ids)
	if #ids == 0 then
		return
	end

	-- Izin inventory dulu (per sesi — putaran 1 membuktikan izin sesi lama tidak terbawa).
	local okFirst = favRead(aes, ids[1])
	if not okFirst then
		local askStatus, granted = favWait((aes :: any).PromptAllowInventoryReadAccessCompleted, function()
			aes:PromptAllowInventoryReadAccess()
		end)
		say("favoritBatch izin inventory -> %s %s", askStatus, tostring(granted))
	end

	-- A. beruntun
	local startA = os.clock()
	local okA, failA, trueA = 0, 0, 0
	local errA: string? = nil
	for _, id in ids do
		local ok, value = favRead(aes, id)
		if ok then
			okA += 1
			if value == true then
				trueA += 1
			end
		else
			failA += 1
			errA = errA or tostring(value)
		end
	end
	local spentA = os.clock() - startA
	say(
		"favoritBatch A beruntun %d id -> %.2f detik (%.0f ms/item) ok=%d gagal=%d favorit=%d %s",
		#ids,
		spentA,
		spentA / #ids * 1000,
		okA,
		failA,
		trueA,
		if errA then "| error pertama: " .. errA else ""
	)

	-- B. serentak (id yang SAMA, jadi selisihnya murni soal cara memanggil)
	local startB = os.clock()
	local doneB, okB, failB = 0, 0, 0
	local errB: string? = nil
	for _, id in ids do
		task.spawn(function()
			local ok, value = favRead(aes, id)
			if ok then
				okB += 1
			else
				failB += 1
				errB = errB or tostring(value)
			end
			doneB += 1
		end)
	end
	while doneB < #ids and os.clock() - startB < FAV_BATCH_TIMEOUT do
		task.wait(0.1)
	end
	local spentB = os.clock() - startB
	say(
		"favoritBatch B serentak %d id -> %.2f detik selesai=%d ok=%d gagal=%d %s",
		#ids,
		spentB,
		doneB,
		okB,
		failB,
		if errB then "| error pertama: " .. errB else ""
	)
	say("favoritBatch: gagal=0 di keduanya berarti aman; pesan 429 / 'too many' berarti harus dijeda")
end

-- ===== SPIKE PREVIEW HOVER: BERAPA MAHAL "avatar memakai item ini"? (PR #28, 19 Sep 2026) =====
-- Rencana: kursor lewat kartu -> thumbnail kartu berubah jadi avatar pemain YANG MEMAKAI item itu.
-- Sebelum satu baris kodenya ditulis, tiga hal harus diukur (pelajaran #25: jangan menebak):
--   1. Berapa lama satu model "outfit sekarang + item" jadi? (#22 mencatat 0,44 detik untuk model
--      polos; belum pernah diukur untuk deskripsi pemain yang sudah penuh 22 item.)
--   2. Apakah panggilan itu MEMBEKUKAN layar? Diukur dari delta frame TERBESAR selama pembuatan.
--      Hover yang bikin grid patah-patah lebih buruk daripada tidak ada preview sama sekali.
--   3. Item yang SAMA dibangun dua kali: lebih cepat (ada cache di engine) atau sama saja?
--      Kalau sama saja, kita WAJIB menyimpan modelnya sendiri.
-- Hasilnya menentukan bentuk: hover langsung, hover + jeda, atau tidak pakai hover sama sekali.
-- CARA PAKAI (tab CLIENT):
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.hoverCost()
--   S.hoverCost(4)     -- lebih sedikit item
--   S.hoverClear()     -- hapus kartu contoh
local HOVER_GUI = "SPIKE_HoverCost"
local HOVER_CARD = 150 -- kartu contoh di layar, sekadar bukti mata bahwa itemnya benar terpakai
local HOVER_DIST = 3.4 -- stud dari wajah; kartu ~100 px tidak sanggup menampilkan seluruh badan

-- Kamera kartu preview: DEPAN avatar dan DEKAT ke bagian tempat item menempel.
-- Front avatar = sisi -Z (temuan #22 no. 5) -> kamera di head.CFrame * (0, y, -jarak). Memakai
-- CFrame kepala, bukan koordinat dunia, supaya ikut arah hadap walau avatarnya diputar.
-- Spike ini semuanya topi -> bidikannya kepala. Di produksi nanti bagian tubuh dipilih dari
-- assetType item (AssetTypeMap): kepala / badan / kaki.
local function hoverFocus(model: Model, camera: Camera)
	local head = model:FindFirstChild("Head") :: BasePart?
	if head then
		local target = head.CFrame * Vector3.new(0, 0.35, 0)
		camera.CFrame = CFrame.lookAt(head.CFrame * Vector3.new(0, 0.35, -HOVER_DIST), target)
		return
	end
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local base = if root then root.CFrame else CFrame.new()
	camera.CFrame = CFrame.lookAt(base * Vector3.new(0, 1.5, -9), base * Vector3.new(0, 1.5, 0))
end

-- Deskripsi avatar pemain sekarang + satu topi tambahan.
local function hoverDescWith(assetId: number): HumanoidDescription?
	local player = Players.LocalPlayer
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil
	end
	local ok, desc = pcall(function()
		return (humanoid :: Humanoid):GetAppliedDescription()
	end)
	if not ok or desc == nil then
		return nil
	end
	local copy = desc:Clone()
	local hats = copy.HatAccessory
	copy.HatAccessory = if hats == "" then tostring(assetId) else hats .. "," .. tostring(assetId)
	return copy
end

function M.hoverClear()
	local player = Players.LocalPlayer
	local gui = player and player:FindFirstChild("PlayerGui")
	local old = gui and gui:FindFirstChild(HOVER_GUI)
	if old then
		old:Destroy()
		say("hoverCost: kartu contoh dihapus")
	end
end

function M.hoverCost(count: number?)
	if not RunService:IsClient() then
		say("hoverCost: jalankan dari tab CLIENT")
		return
	end
	M.hoverClear()
	local aes = game:GetService("AvatarEditorService")
	local ids = favSampleIds(aes, count or 8)
	if #ids == 0 then
		say("hoverCost: tidak dapat id dari pencarian")
		return
	end
	if hoverDescWith(ids[1]) == nil then
		say("hoverCost: karakter pemain belum ada")
		return
	end

	-- Pengukur kebekuan layar: delta frame TERBESAR selama pembuatan model.
	local worst = 0
	local frameConn = RunService.RenderStepped:Connect(function(dt: number)
		if dt > worst then
			worst = dt
		end
	end)

	local screen = Instance.new("ScreenGui")
	screen.Name = HOVER_GUI
	screen.IgnoreGuiInset = true
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local times: { number } = {}
	local failed = 0
	local shown = 0
	for index, id in ids do
		local desc = hoverDescWith(id)
		local started = os.clock()
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R15)
		end)
		local spent = os.clock() - started
		if ok and model then
			table.insert(times, spent)
			if shown < 3 then
				-- Bukti mata: tiga model pertama ditaruh di ViewportFrame + WorldModel (#22 no. 3).
				local holder = Instance.new("ViewportFrame")
				holder.Size = UDim2.fromOffset(HOVER_CARD, HOVER_CARD)
				holder.Position = UDim2.fromOffset(20 + shown * (HOVER_CARD + 8), 120)
				holder.BackgroundColor3 = Color3.new(0, 0, 0)
				holder.Parent = screen
				local world = Instance.new("WorldModel")
				world.Parent = holder
				model.Parent = world
				local cam = Instance.new("Camera")
				cam.Parent = holder
				holder.CurrentCamera = cam
				hoverFocus(model, cam)
				shown += 1
			else
				model:Destroy()
			end
		else
			failed += 1
			say("hoverCost: item %d (%d) GAGAL %s", index, id, tostring(model))
		end
		task.wait(0.05)
	end

	-- Item PERTAMA dibangun sekali lagi: ada cache di engine atau tidak?
	local again = 0
	local descAgain = hoverDescWith(ids[1])
	local startedAgain = os.clock()
	local okAgain, modelAgain = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(descAgain, Enum.HumanoidRigType.R15)
	end)
	if okAgain then
		again = os.clock() - startedAgain
		if modelAgain then
			modelAgain:Destroy()
		end
	end
	frameConn:Disconnect()

	local total, slowest = 0, 0
	for _, t in times do
		total += t
		if t > slowest then
			slowest = t
		end
	end
	local avg = if #times > 0 then total / #times else 0
	say(
		"hoverCost 1 %d model -> rata-rata %.0f ms, terlama %.0f ms, gagal=%d",
		#times,
		avg * 1000,
		slowest * 1000,
		failed
	)
	say("hoverCost 2 frame TERLAMA selama pembuatan: %.0f ms (16 ms = 60 FPS; >100 ms = terasa patah)", worst * 1000)
	say("hoverCost 3 item pertama dibangun ULANG -> %.0f ms (jauh lebih cepat = engine menyimpan cache)", again * 1000)
	say("hoverCost: 3 kartu contoh di layar — WAJAH menghadap kamera & topi terlihat? Hapus: S.hoverClear()")
end

-- ===== SPIKE PREVIEW ANIMASI (PR #28, 19 Sep 2026) =====
-- Kartu animasi belum punya preview. #24 no. 3 menyimpulkan "rig di ViewportFrame TIDAK BISA
-- dianimasikan" — TAPI rig yang diuji waktu itu dibuat CreateHumanoidModelFromDescriptionAsync,
-- dan #24 no. 3 juga mencatat rig itu tidak punya satu pun Motor6D. Jadi yang terbukti mungkin
-- "rig tanpa sendi tidak bisa bergerak", bukan "ViewportFrame melarang animasi".
-- CLONE karakter asli PUNYA Motor6D (itulah yang membuat cermin pose #24 no. 4 berhasil).
-- Yang diukur di sini, dengan ANGKA bukan mata (pelajaran #24):
--   1. Track-nya benar termuat? (Length > 0 = aset animasi terbaca)
--   2. Sendi CLONE benar-benar bergerak di dalam ViewportFrame? Diukur dari jarak tempuh tangan
--      relatif HumanoidRootPart selama 3 detik. Patokan #24: 4,071 stud = bergerak, 0,352 = diam.
--   3. Berapa Motor6D yang ada di clone (0 = jalan buntu, sama seperti rig deskripsi).
-- Kalau no. 2 besar -> preview animasi tinggal disambungkan seperti preview item biasa.
-- Kalau no. 2 nol -> jalan satu-satunya adalah menggerakkan sendi sendiri dari KeyframeSequence
-- (butuh InsertService di SERVER, karena client ditolak — temuan #18 no. 4).
-- CARA PAKAI (tab CLIENT):
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.animCard()
--   S.animCard(3576823880)   -- id animasi lain (default: Point2, dari katalog FEATURED)
--   S.animClear()
local ACARD_GUI = "SPIKE_AnimCard"
local ACARD_SIZE = 260
local ACARD_DEFAULT = 3576823880 -- "Point2", item animasi di katalog FEATURED
local ACARD_SAMPLE = 3 -- detik pengukuran

function M.animClear()
	local player = Players.LocalPlayer
	local gui = player and player:FindFirstChild("PlayerGui")
	local old = gui and gui:FindFirstChild(ACARD_GUI)
	if old then
		old:Destroy()
		say("animCard: kartu dihapus")
	end
end

function M.animCard(assetId: number?)
	if not RunService:IsClient() then
		say("animCard: jalankan dari tab CLIENT")
		return
	end
	M.animClear()
	local id = assetId or ACARD_DEFAULT
	local player = Players.LocalPlayer
	local character = player and player.Character
	if character == nil then
		say("animCard: karakter belum ada")
		return
	end

	-- Clone karakter asli (punya Motor6D). Archivable dinyalakan sebentar — temuan #24 no. 2.
	local wasArchivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = wasArchivable
	if clone == nil then
		say("animCard: clone gagal")
		return
	end

	-- Putaran 2 membuktikan rig ini memakai AnimationConstraint, BUKAN Motor6D (place ber-rig
	-- sendi generasi baru) -> dua-duanya dihitung, supaya angkanya tidak menyesatkan lagi.
	local motors, constraints = 0, 0
	for _, d in clone:GetDescendants() do
		if d:IsA("Motor6D") then
			motors += 1
		elseif d:IsA("AnimationConstraint") then
			constraints += 1
		end
	end
	say("animCard 3 sendi di clone: Motor6D=%d AnimationConstraint=%d", motors, constraints)

	local screen = Instance.new("ScreenGui")
	screen.Name = ACARD_GUI
	screen.IgnoreGuiInset = true
	screen.Parent = player:WaitForChild("PlayerGui")
	local holder = Instance.new("ViewportFrame")
	holder.Size = UDim2.fromOffset(ACARD_SIZE, ACARD_SIZE)
	holder.Position = UDim2.fromOffset(20, 120)
	holder.BackgroundColor3 = Color3.new(0, 0, 0)
	holder.Parent = screen
	local world = Instance.new("WorldModel")
	world.Parent = holder

	-- Part TIDAK di-anchor supaya sendi bisa menggerakkannya, KECUALI HumanoidRootPart: tanpa
	-- penahan itu seluruh boneka melorot kena gravitasi, dan putaran 1 salah membaca jatuhnya
	-- part sebagai "animasi jalan" (3,742 stud padahal track-nya Length=0).
	local ACARD_ROOT_ANCHOR = "HumanoidRootPart"
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = d.Name == ACARD_ROOT_ANCHOR
		end
	end
	clone.Parent = world

	local root = clone:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hand = (clone:FindFirstChild("RightHand") or clone:FindFirstChild("Right Arm")) :: BasePart?
	local head = clone:FindFirstChild("Head") :: BasePart?
	local cam = Instance.new("Camera")
	cam.Parent = holder
	holder.CurrentCamera = cam
	if head then
		cam.CFrame = CFrame.lookAt(head.CFrame * Vector3.new(0, -1.5, -9), head.CFrame * Vector3.new(0, -1.5, 0))
	end

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if humanoid and animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	if animator == nil then
		say("animCard: clone tidak punya Humanoid/Animator")
		return
	end

	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. tostring(id)
	local okTrack, track = pcall(function()
		return (animator :: Animator):LoadAnimation(anim)
	end)
	if not okTrack or track == nil then
		say("animCard 1 LoadAnimation GAGAL: %s", tostring(track))
		return
	end
	track.Looped = true
	track:Play()
	task.wait(0.3)
	say("animCard 1 track: Length=%.2f detik IsPlaying=%s", track.Length, tostring(track.IsPlaying))

	-- 2. Jarak tempuh tangan RELATIF root selama ACARD_SAMPLE detik (patokan #24: 4,07 vs 0,35).
	local travelled = 0
	local last: Vector3? = nil
	local started = os.clock()
	while os.clock() - started < ACARD_SAMPLE do
		if root and hand then
			local now = root.CFrame:PointToObjectSpace(hand.Position)
			if last then
				travelled += (now - last).Magnitude
			end
			last = now
		end
		task.wait()
	end
	say(
		"animCard 2 tangan menempuh %.3f stud dalam %d detik (#24: 4,07 = bergerak, 0,35 = diam)",
		travelled,
		ACARD_SAMPLE
	)
	say("animCard: gerak SAH hanya kalau Length>0 DAN IsPlaying=true. Hapus: S.animClear()")
end

-- ===== SPIKE ANIMASI putaran 2: SENDI & ID KLIP (PR #28, 19 Sep 2026) =====
-- Putaran 1 menghasilkan DUA kejutan, dan pengukurannya sendiri tercemar:
--   * "tangan menempuh 3,742 stud" TIDAK berarti animasi jalan — track-nya `Length=0 IsPlaying=false`
--     dan Studio menolak asetnya ("AnimationClip loaded is not valid"). Yang bergerak itu part yang
--     JATUH karena spike meng-unanchor semuanya sementara tidak ada sendi sama sekali.
--     (Pelajaran lama terulang: pastikan yang diukur benar-benar hal yang dimaksud.)
--   * `Motor6D di clone: 0`. R15 biasa punya belasan. Dugaan: place ini memakai rig sendi generasi
--     baru (AnimationConstraint/Bone). Kalau benar, temuan #24 no. 3 selama ini salah baca.
-- Dua hal yang diukur sekarang, BUKAN ditebak:
--   1. [CLIENT] Kelas apa saja yang menghubungkan part karakter: Motor6D, AnimationConstraint,
--      Bone, Weld, WeldConstraint, Attachment? Berapa banyak masing-masing, di karakter ASLI
--      maupun di CLONE-nya (kalau clone kehilangan sendi, itu masalah tersendiri).
--   2. [SERVER] Aset animasi katalog (mis. 3576823880 "Point2") isinya apa? Yang dicari: objek
--      `Animation` di dalamnya dan nilai `AnimationId` SESUNGGUHNYA — id katalog tidak bisa
--      dipakai langsung, itu sebabnya track putaran 1 kosong.
-- CARA PAKAI:
--   tab CLIENT: local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.animJoints()
--   tab SERVER: local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.animAsset()
--               S.animAsset(3576968026)   -- "Shrug"
local AJOINT_CLASSES = { "Motor6D", "AnimationConstraint", "Bone", "Weld", "WeldConstraint", "Attachment" }

local function ajointCount(root: Instance): string
	local counts: { [string]: number } = {}
	for _, d in root:GetDescendants() do
		for _, class in AJOINT_CLASSES do
			if d:IsA(class) then
				counts[class] = (counts[class] or 0) + 1
			end
		end
	end
	local out = {}
	for _, class in AJOINT_CLASSES do
		table.insert(out, ("%s=%d"):format(class, counts[class] or 0))
	end
	return table.concat(out, " ")
end

function M.animJoints()
	if not RunService:IsClient() then
		say("animJoints: jalankan dari tab CLIENT")
		return
	end
	local player = Players.LocalPlayer
	local character = player and player.Character
	if character == nil then
		say("animJoints: karakter belum ada")
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	say("animJoints 1 karakter ASLI: %s", ajointCount(character))
	say(
		"animJoints 1b RigType=%s bagian=%d",
		if humanoid then tostring(humanoid.RigType) else "tanpa Humanoid",
		#character:GetChildren()
	)

	local wasArchivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = wasArchivable
	if clone == nil then
		say("animJoints 2 clone GAGAL (nil)")
		return
	end
	say("animJoints 2 CLONE: %s", ajointCount(clone))
	clone:Destroy()
	say("animJoints: sendi di baris 1 yang jumlahnya besar = kelas yang dipakai rig ini")
end

function M.animAsset(assetId: number?)
	if not RunService:IsServer() then
		say("animAsset: jalankan dari tab SERVER (InsertService ditolak client — temuan #18 no. 4)")
		return
	end
	local id = assetId or ACARD_DEFAULT
	local ok, model = pcall(function()
		return game:GetService("InsertService"):LoadAsset(id)
	end)
	if not ok or model == nil then
		say("animAsset: LoadAsset(%d) GAGAL %s", id, tostring(model))
		return
	end
	local lines = {}
	local clipId: string? = nil
	for _, d in model:GetDescendants() do
		table.insert(lines, ("%s '%s'"):format(d.ClassName, d.Name))
		if d:IsA("Animation") then
			clipId = d.AnimationId
		end
	end
	say("animAsset %d isi: %s", id, table.concat(lines, " | "))
	if clipId then
		say("animAsset %d AnimationId SESUNGGUHNYA = %s  <- pakai ini, bukan id katalog", id, clipId)
		say("animAsset: uji di tab CLIENT -> S.animCard(%s)", (clipId:gsub("%D", "")))
	else
		say("animAsset %d TIDAK berisi objek Animation -> jalur lain (KeyframeSequence?)", id)
	end
	model:Destroy()
end

-- ===== SPIKE ANIMASI putaran 3: KONTROL vs VIEWPORT (PR #28, 19 Sep 2026) =====
-- Putaran 2 memakai id klip yang BENAR (10714395441) dan tetap `Length=0 IsPlaying=false`, kali ini
-- tanpa error apa pun dari Studio. Dua tersangka, dan putaran ini memisahkannya alih-alih menebak:
--   A. KONTROL: animasi yang sama dimuat ke Animator karakter ASLI di workspace. Kalau di sini
--      Length > 0, asetnya sehat dan tersangkanya viewport. Kalau nol juga, asetnya/izinnya.
--   B. VIEWPORT: clone di WorldModel dalam ViewportFrame, Length ditunggu sampai 5 detik (bukan
--      0,3 detik seperti putaran 2 — Length baru terisi setelah aset selesai diunduh).
-- Sekalian: GARIS DASAR gerakan. Jarak tempuh tangan diukur 3 detik TANPA memutar apa pun, lalu
-- 3 detik dengan track diputar. Putaran 1 & 2 sama-sama melaporkan ~3,7 stud padahal track diam,
-- jadi angka itu jelas bukan animasi; garis dasar membuat perbandingannya jujur.
-- Kontrol TIDAK mengganggu avatar pemain: track-nya dimuat lalu dihentikan, tidak pernah diputar.
-- CARA PAKAI (tab CLIENT):
--   local S = require(game.ReplicatedStorage.Tests["PreviewRig.studio"]) S.animAB(10714395441)
local AAB_WAIT = 5 -- detik menunggu Length terisi
local AAB_SAMPLE = 3

-- Tunggu sampai track punya Length (aset selesai diunduh). Kembalian: Length terakhir.
local function aabWaitLength(track: AnimationTrack): number
	local started = os.clock()
	while track.Length <= 0 and os.clock() - started < AAB_WAIT do
		task.wait(0.1)
	end
	return track.Length
end

-- Jarak tempuh tangan RELATIF root selama `secs` detik.
local function aabTravel(model: Model, secs: number): number
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hand = (model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm")) :: BasePart?
	if root == nil or hand == nil then
		return -1
	end
	local travelled = 0
	local last: Vector3? = nil
	local started = os.clock()
	while os.clock() - started < secs do
		local now = root.CFrame:PointToObjectSpace(hand.Position)
		if last then
			travelled += (now - last).Magnitude
		end
		last = now
		task.wait()
	end
	return travelled
end

function M.animAB(assetId: number?)
	if not RunService:IsClient() then
		say("animAB: jalankan dari tab CLIENT")
		return
	end
	local id = assetId or ACARD_DEFAULT
	local player = Players.LocalPlayer
	local character = player and player.Character
	local liveHumanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if character == nil or liveHumanoid == nil then
		say("animAB: karakter belum ada")
		return
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. tostring(id)

	-- A. KONTROL di workspace (hanya DIMUAT, tidak diputar -> avatar pemain tidak terganggu)
	local liveAnimator = liveHumanoid:FindFirstChildOfClass("Animator")
	if liveAnimator == nil then
		say("animAB A: karakter asli tidak punya Animator")
	else
		local okA, trackA = pcall(function()
			return (liveAnimator :: Animator):LoadAnimation(anim)
		end)
		if okA and trackA then
			local lenA = aabWaitLength(trackA)
			say("animAB A KONTROL (karakter asli di workspace): Length=%.2f detik", lenA)
			trackA:Destroy()
		else
			say("animAB A KONTROL GAGAL: %s", tostring(trackA))
		end
	end

	-- B. VIEWPORT
	M.animClear()
	local wasArchivable = character.Archivable
	character.Archivable = true
	local clone = character:Clone()
	character.Archivable = wasArchivable
	if clone == nil then
		say("animAB B: clone gagal")
		return
	end
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = d.Name == "HumanoidRootPart"
		end
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = ACARD_GUI
	screen.IgnoreGuiInset = true
	screen.Parent = player:WaitForChild("PlayerGui")
	local holder = Instance.new("ViewportFrame")
	holder.Size = UDim2.fromOffset(ACARD_SIZE, ACARD_SIZE)
	holder.Position = UDim2.fromOffset(20, 120)
	holder.BackgroundColor3 = Color3.new(0, 0, 0)
	holder.Parent = screen
	local world = Instance.new("WorldModel")
	world.Parent = holder
	clone.Parent = world
	local head = clone:FindFirstChild("Head") :: BasePart?
	local cam = Instance.new("Camera")
	cam.Parent = holder
	holder.CurrentCamera = cam
	if head then
		cam.CFrame = CFrame.lookAt(head.CFrame * Vector3.new(0, -1.5, -9), head.CFrame * Vector3.new(0, -1.5, 0))
	end

	-- GARIS DASAR: tanpa memutar apa pun
	local baseline = aabTravel(clone, AAB_SAMPLE)
	say("animAB B1 GARIS DASAR (tanpa animasi): tangan menempuh %.3f stud dalam %d detik", baseline, AAB_SAMPLE)

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	local animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	if humanoid and animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	if animator == nil then
		say("animAB B: clone tidak punya Humanoid/Animator")
		return
	end
	local okB, trackB = pcall(function()
		return (animator :: Animator):LoadAnimation(anim)
	end)
	if not okB or trackB == nil then
		say("animAB B LoadAnimation GAGAL: %s", tostring(trackB))
		return
	end
	local lenB = aabWaitLength(trackB)
	trackB.Looped = true
	trackB:Play()
	task.wait(0.2)
	say("animAB B2 VIEWPORT: Length=%.2f detik IsPlaying=%s", lenB, tostring(trackB.IsPlaying))
	local moving = aabTravel(clone, AAB_SAMPLE)
	say("animAB B3 dengan animasi: tangan menempuh %.3f stud (garis dasar %.3f)", moving, baseline)
	say("animAB: gerak NYATA hanya kalau B3 jauh di atas B1. Hapus: S.animClear()")
end

return M
