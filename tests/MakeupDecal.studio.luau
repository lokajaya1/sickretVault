--!strict
-- SPIKE makeup / background (PR #18) — HANYA di Studio, dijalankan dari SERVER.
-- Play -> tab Server -> Command Bar:
--   local S = require(game.ReplicatedStorage.Tests["MakeupDecal.studio"])
--   S.parts(133520807586498)   -- isi aset: Decal, texture id, anak-anaknya
--   S.head()                   -- Head pemain: jenis, WrapTarget, decal yang menempel
--   S.background(121199209890990) -- AvatarBackground: ImageId + Color
--   S.wear("A")                -- pasang varian, DIBIARKAN sampai S.off()
--   S.wear("B") / S.wear("C") / S.wear("D")
--   S.off()                    -- lepas semua pasangan spike
--
-- ===== TEMUAN YANG SUDAH TETAP (jangan diulang) =====
-- 1. Makeup TIDAK bisa lewat HumanoidDescription (spike #17c): SetAccessories + Apply
--    mengembalikan true tapi item tidak pernah muncul di GetAppliedDescription.
-- 2. InsertService:LoadAsset(<id makeup>) -> Model > Decal (+ anak WrapTextureTransfer,
--    Configuration). Id item BUKAN id texture: 133520807586498 -> rbxassetid://98880692903650.
-- 3. LoadAsset DITOLAK dari client ("cannot be used to load assets from the client") -> server saja.
--    Satu panggilan ~0,4-0,6 detik -> wajib di-cache.
-- 4. ApplyDescriptionAsync yang MENGGANTI Head menghancurkan decal (3/3 hilang, tidak ada
--    yang menggantung) -> makeup wajib dipasang ULANG setiap Head baru.
-- 5. ZIndex Decal tidak terbukti berpengaruh -> 1 item per slot, urutan tempel face->eye->lip.
-- 6. AvatarBackground -> Model > Folder 'AvatarBackground' > IntValue ImageId + Color3Value Color.
--    Bukan barang yang dipakai avatar; jadi latar area preview (PR #19).
-- 7. BELUM TERJAWAB: varian mana yang PRESISI di wajah (lihat S.wear di bawah).

local TAG = "[SPIKE18]"
local PREFIX = "SPIKE_"

local M = {}

local function say(fmt: string, ...: any)
	print(TAG .. " " .. string.format(fmt, ...))
end

-- Properti yang mungkin ada; dibaca dengan pcall supaya kelas apa pun aman.
local PROBE_PROPS = {
	"Texture",
	"TextureId",
	"Face",
	"ZIndex",
	"Transparency",
	"Color3",
	"Value",
	"Enabled",
	"Order",
	"CageMeshId",
	"CageOrigin",
	"ImportOrigin",
	"Stiffness",
}

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

local function dumpTree(label: string, root: Instance, depth: number)
	say("%s%s%s", label, string.rep("  ", depth + 1), describe(root))
	for _, child in root:GetChildren() do
		dumpTree(label, child, depth + 1)
	end
end

local function loadAsset(id: number): Instance?
	local InsertService = game:GetService("InsertService")
	local t0 = os.clock()
	local ok, res = pcall(function()
		return InsertService:LoadAsset(id)
	end)
	if not ok then
		say("LoadAsset(%d) GAGAL: %s", id, tostring(res))
		return nil
	end
	say("LoadAsset(%d) OK dalam %.2f detik", id, os.clock() - t0)
	return res :: Instance
end

local function playerHead(): BasePart?
	local Players = game:GetService("Players")
	local player = Players:GetPlayers()[1]
	local char = if player then player.Character else nil
	local head = if char then char:FindFirstChild("Head") else nil
	if head == nil then
		say("TIDAK ada Head (pemain belum spawn). Play ulang lalu coba lagi.")
		return nil
	end
	return head :: BasePart
end

local function findDecal(root: Instance): Decal?
	local found = root:FindFirstChildWhichIsA("Decal", true)
	return if found then found :: Decal else nil
end

-- ===== Pemeriksaan =====

-- Isi satu aset makeup apa adanya.
function M.parts(assetId: number)
	local root = loadAsset(assetId)
	if root == nil then
		return
	end
	dumpTree("parts", root, 0)
	local decal = findDecal(root)
	say("parts texture id = %s (id item %d -> BEDA, LoadAsset wajib)", tostring(decal and decal.Texture), assetId)
	root:Destroy()
end

-- Head pemain sekarang: jenis, WrapTarget, dan apa saja yang menempel.
function M.head()
	local head = playerHead()
	if head == nil then
		return
	end
	say("head %s", describe(head))
	for _, child in head:GetChildren() do
		say("head anak: %s", describe(child))
	end
end

-- AvatarBackground: bukan Decal, tapi ImageId + Color di dalam Folder (untuk PR #19).
function M.background(assetId: number)
	local root = loadAsset(assetId)
	if root == nil then
		return
	end
	local folder = root:FindFirstChild("AvatarBackground", true)
	if folder then
		local imageId = folder:FindFirstChild("ImageId")
		local color = folder:FindFirstChild("Color")
		say(
			"background ImageId=%s Color=%s",
			if imageId then tostring((imageId :: IntValue).Value) else "nil",
			if color then tostring((color :: Color3Value).Value) else "nil"
		)
	else
		dumpTree("background", root, 0)
	end
	root:Destroy()
end

-- ===== Uji presisi: pasang satu varian, BIARKAN, nilai dengan tenang, lalu S.off() =====
--   A = Decal BARU, hanya texture id (cara MakeupService sekarang)
--   B = Decal ASLI di-Clone apa adanya (ikut WrapTextureTransfer + Configuration)
--   C = seluruh isi Model hasil LoadAsset dipindah ke Head
--   D = Decal BARU + WrapTextureTransfer BUATAN SENDIRI (kalau sama presisinya dengan B,
--       kita cukup menyimpan texture id, tidak perlu menyimpan Instance di cache server)
function M.wear(variant: string, assetId: number?)
	local id = assetId or 123316458229208 -- Cute Light Blush
	local head = playerHead()
	if head == nil then
		return
	end
	M.off()

	local root = loadAsset(id)
	if root == nil then
		return
	end
	local decal = findDecal(root)
	if decal == nil then
		say("aset %d tidak berisi Decal", id)
		root:Destroy()
		return
	end

	local v = string.upper(variant)
	if v == "A" or v == "D" then
		local d = Instance.new("Decal")
		d.Name = PREFIX .. v
		d.Texture = decal.Texture
		d.Face = Enum.NormalId.Front
		if v == "D" then
			local okWrap, wrap = pcall(function()
				return Instance.new("WrapTextureTransfer" :: any)
			end)
			if okWrap then
				(wrap :: Instance).Parent = d
				say("D WrapTextureTransfer buatan sendiri berhasil dibuat")
			else
				say("D Instance.new('WrapTextureTransfer') DITOLAK: %s -> varian D tidak mungkin", tostring(wrap))
			end
		end
		d.Parent = head
	elseif v == "B" then
		local b = decal:Clone()
		b.Name = PREFIX .. "B"
		b.Parent = head
		say("B anak ikut: %d", #b:GetChildren())
	elseif v == "C" then
		for _, child in root:GetChildren() do
			local c = child:Clone()
			c.Name = PREFIX .. "C_" .. child.Name
			c.Parent = head
		end
	else
		say("varian tidak dikenal: %s (pakai A, B, C, atau D)", variant)
		root:Destroy()
		return
	end

	root:Destroy()
	say("varian %s TERPASANG di Head — nilai dengan tenang, lalu S.off()", v)
end

-- Lepas semua pasangan spike (decal bawaan & makeup asli tidak disentuh).
function M.off()
	local head = playerHead()
	if head == nil then
		return
	end
	local n = 0
	for _, child in head:GetChildren() do
		if string.sub(child.Name, 1, #PREFIX) == PREFIX then
			child:Destroy()
			n += 1
		end
	end
	say("off: %d pasangan spike dilepas", n)
end

-- ===== Bandingkan A / B / D BERSAMAAN pada tiga boneka kembar =====
-- Tiga salinan avatar pemain berdiri berjajar di depanmu, masing-masing memakai satu varian.
-- Satu layar, satu screenshot, sudut kamera sama -> tidak ada lagi tebak-tebakan.
--   S.compare(106390919006817)  -- default: Cute Light Blush
--   S.clear()                   -- hapus bonekanya
local DUMMY_PREFIX = "SPIKE_DUMMY_"

local function labelOf(model: Instance, text: string)
	local head = model:FindFirstChild("Head")
	if head == nil then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "SPIKE_LABEL"
	gui.Size = UDim2.fromScale(4, 1.5)
	gui.StudsOffset = Vector3.new(0, 2.5, 0)
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0
	label.Parent = gui
	gui.Parent = head
end

-- Pasang satu varian ke Head sebuah model (dipakai untuk boneka maupun pemain).
local function attachVariant(head: BasePart, variant: string, decal: Decal, root: Instance)
	if variant == "B" then
		local b = decal:Clone()
		b.Name = PREFIX .. "B"
		b.Parent = head
	elseif variant == "C" then
		for _, child in root:GetChildren() do
			local c = child:Clone()
			c.Name = PREFIX .. "C_" .. child.Name
			c.Parent = head
		end
	else
		local d = Instance.new("Decal")
		d.Name = PREFIX .. variant
		d.Texture = decal.Texture
		d.Face = Enum.NormalId.Front
		if variant == "D" then
			local okWrap, wrap = pcall(function()
				return Instance.new("WrapTextureTransfer" :: any)
			end)
			if okWrap then
				(wrap :: Instance).Parent = d
			end
		end
		d.Parent = head
	end
end

function M.clear()
	for _, obj in workspace:GetChildren() do
		if string.sub(obj.Name, 1, #DUMMY_PREFIX) == DUMMY_PREFIX then
			obj:Destroy()
		end
	end
	say("clear: boneka spike dihapus")
end

function M.compare(assetId: number?)
	local Players = game:GetService("Players")
	local id = assetId or 123316458229208
	local player = Players:GetPlayers()[1]
	local char = if player then player.Character else nil
	local humanoid = if char then char:FindFirstChildOfClass("Humanoid") else nil
	local rootPart = if char then char:FindFirstChild("HumanoidRootPart") else nil
	if humanoid == nil or rootPart == nil then
		say("TIDAK ada karakter. Play ulang lalu coba lagi.")
		return
	end

	M.clear()
	local root = loadAsset(id)
	if root == nil then
		return
	end
	local decal = findDecal(root)
	if decal == nil then
		say("aset %d tidak berisi Decal", id)
		root:Destroy()
		return
	end

	local desc = humanoid:GetAppliedDescription()
	local variants = { "A", "B", "D" }
	local base = (rootPart :: BasePart).CFrame
	for i, variant in variants do
		local okModel, model = pcall(function()
			return Players:CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R15)
		end)
		if not okModel then
			say("boneka %s gagal dibuat: %s", variant, tostring(model))
		else
			local dummy = model :: Model
			dummy.Name = DUMMY_PREFIX .. variant
			local head = dummy:FindFirstChild("Head")
			if head then
				attachVariant(head :: BasePart, variant, decal, root)
			end
			labelOf(dummy, variant)
			-- berjajar 4 stud, 8 stud di depan pemain, menghadap pemain
			dummy:PivotTo(base * CFrame.new((i - 2) * 4, 0, -8) * CFrame.Angles(0, math.pi, 0))
			local dummyRoot = dummy:FindFirstChild("HumanoidRootPart")
			if dummyRoot then
				(dummyRoot :: BasePart).Anchored = true -- hanya root (anchor semua part merusak rakitan)
			end
			local dummyHumanoid = dummy:FindFirstChildOfClass("Humanoid")
			if dummyHumanoid then
				(dummyHumanoid :: Humanoid).DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			end
			dummy.Parent = workspace
			say("boneka %s siap", variant)
		end
	end
	root:Destroy()
	say("compare: A / B / D berjajar di depanmu — satu screenshot cukup. Hapus dengan S.clear()")
end

return M
