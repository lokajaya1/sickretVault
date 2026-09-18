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

return M
