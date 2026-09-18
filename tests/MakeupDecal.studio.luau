--!strict
-- SPIKE makeup sebagai Decal (PR #18) — HANYA di Studio.
-- Jalankan BAGIAN SERVER: Play -> tab Server -> Command Bar:
--   require(game.ReplicatedStorage.Tests["MakeupDecal.studio"]).server()
-- Lalu BAGIAN CLIENT: tab Client -> Command Bar:
--   require(game.ReplicatedStorage.Tests["MakeupDecal.studio"]).client()
--
-- Yang harus terjawab SEBELUM kode produksi ditulis:
--   1. InsertService:LoadAsset(<id makeup>) menghasilkan apa persisnya? (class anak, properti Decal)
--   2. Bisakah Decal dibuat SENDIRI dari `rbxassetid://<id makeup>` tanpa LoadAsset? (hemat besar)
--      Kalau tidak, apakah `Decal.Texture` hasil LoadAsset bisa dipakai ulang di Decal baru?
--   3. Menempel ke Head: tampil di atas wajah? Face mana? Head Part vs MeshPart (dynamic head)?
--   4. Dua makeup bertumpuk: apakah ZIndex Decal menentukan urutan lapis?
--   5. Apakah decal selamat / hilang setelah ApplyDescriptionAsync (ganti outfit)?
--   6. Lepas decal: bersih? decal wajah bawaan ("face") ikut kehapus atau tidak?
--   7. LoadAsset bisa dipanggil dari CLIENT atau server saja? Berapa lama satu panggilan (untuk cache)?
--   8. AvatarBackground: LoadAsset menghasilkan apa? Texture-nya bisa dipakai di ImageLabel?

local TAG = "[SPIKE18]"

local M = {}

local function say(fmt: string, ...: any)
	print(TAG .. " " .. string.format(fmt, ...))
end

-- Ringkas satu Instance: class + properti yang menarik untuk kita.
local function describe(inst: Instance): string
	local parts = { inst.ClassName .. " '" .. inst.Name .. "'" }
	if inst:IsA("Decal") then
		local d = inst :: Decal
		table.insert(
			parts,
			("Texture=%s Face=%s ZIndex=%d Transparency=%.2f Color3=%s"):format(
				tostring(d.Texture),
				tostring(d.Face),
				d.ZIndex,
				d.Transparency,
				tostring(d.Color3)
			)
		)
	elseif inst:IsA("Texture") then
		local t = inst :: Texture
		table.insert(parts, ("Texture=%s Face=%s"):format(tostring(t.Texture), tostring(t.Face)))
	elseif inst:IsA("BasePart") then
		table.insert(parts, ("Size=%s"):format(tostring((inst :: BasePart).Size)))
	end
	return table.concat(parts, " | ")
end

-- Cetak seluruh isi model hasil LoadAsset (maks 2 tingkat, cukup untuk aset tunggal).
local function dumpTree(label: string, root: Instance)
	say("%s root: %s", label, describe(root))
	for _, child in root:GetChildren() do
		say("%s   - %s", label, describe(child))
		for _, sub in child:GetChildren() do
			say("%s       - %s", label, describe(sub))
		end
	end
end

-- LoadAsset + ukur waktunya. Mengembalikan (model, detik) atau (nil, pesan error).
local function loadAsset(id: number): (Instance?, any)
	local InsertService = game:GetService("InsertService")
	local t0 = os.clock()
	local ok, res = pcall(function()
		return InsertService:LoadAsset(id)
	end)
	local dt = os.clock() - t0
	if not ok then
		return nil, tostring(res)
	end
	return res :: Instance, dt
end

-- Cari Decal pertama di dalam model hasil LoadAsset.
local function findDecal(root: Instance): Decal?
	if root:IsA("Decal") then
		return root :: Decal
	end
	local found = root:FindFirstChildWhichIsA("Decal", true)
	return if found then found :: Decal else nil
end

--------------------------------------------------------------------------------
-- BAGIAN SERVER
--------------------------------------------------------------------------------
function M.server()
	local ServerScriptService = game:GetService("ServerScriptService")
	local Players = game:GetService("Players")
	local RobloxApi = require(ServerScriptService:WaitForChild("Server").Gateways.RobloxApi) :: any

	local api = RobloxApi.new()
	local A = Enum.AvatarAssetType

	-- 0. Karakter pemain: Head jenis apa, decal apa saja yang SUDAH ada di sana.
	local player = Players:GetPlayers()[1]
	local char = if player then player.Character else nil
	local headFound = if char then char:FindFirstChild("Head") else nil
	if char == nil or headFound == nil then
		say("0 TIDAK ada Head (pemain belum spawn). Hentikan, Play ulang lalu jalankan lagi.")
		return
	end
	local character = char :: Instance
	local head = headFound :: BasePart
	say("0 Head: %s", describe(head))
	for _, child in head:GetChildren() do
		say("0 Head anak: %s", describe(child))
	end

	-- 1. Ambil contoh item tiap tipe makeup + satu background.
	local samples: { { label: string, id: number, name: string } } = {}
	for _, probe in
		{
			{ label = "FaceMakeup", assetType = A.FaceMakeup },
			{ label = "EyeMakeup", assetType = A.EyeMakeup },
			{ label = "LipMakeup", assetType = A.LipMakeup },
			{ label = "AvatarBackground", assetType = A.AvatarBackground },
		}
	do
		local label = probe.label
		local okSearch, page = api:searchCatalog({ assetTypes = { probe.assetType }, limit = 10 })
		if okSearch and page.items[1] then
			local it = page.items[1]
			table.insert(samples, { label = label, id = it.Id, name = tostring(it.Name) })
			say("1 %s contoh: %s (%d)", label, tostring(it.Name), it.Id)
		else
			say("1 %s TIDAK dapat contoh", label)
		end
		task.wait(0.3)
	end

	-- 2. LoadAsset tiap contoh: isinya apa, berapa lama.
	local textures: { [string]: string } = {}
	for _, s in samples do
		local root, info = loadAsset(s.id)
		if not root then
			say("2 %s LoadAsset(%d) GAGAL: %s", s.label, s.id, tostring(info))
		else
			say("2 %s LoadAsset(%d) OK dalam %.2f detik", s.label, s.id, info :: number)
			dumpTree("2 " .. s.label, root)
			local decal = findDecal(root)
			if decal then
				textures[s.label] = decal.Texture
			end
			root:Destroy()
		end
		task.wait(0.3)
	end

	-- 3. Apakah LoadAsset bisa DILEWATI? Bandingkan "rbxassetid://<id item>" dengan Texture aslinya.
	--    Kalau id item langsung bisa dipakai, tidak perlu InsertService sama sekali.
	for _, s in samples do
		local fromLoad = textures[s.label]
		say("3 %s id=%d -> Texture hasil LoadAsset = %s", s.label, s.id, tostring(fromLoad))
		if fromLoad then
			local num = tostring(fromLoad):match("%d+")
			say(
				"3 %s id item %s angka di Texture (%s) -> %s",
				s.label,
				tostring(s.id),
				tostring(num),
				if tostring(num) == tostring(s.id) then "SAMA (LoadAsset bisa dilewati)" else "BEDA (LoadAsset wajib)"
			)
		end
	end

	-- 4. Tempel satu makeup ke Head sebagai Decal buatan sendiri (bukan hasil LoadAsset).
	local makeupLabels = { "FaceMakeup", "EyeMakeup", "LipMakeup" }
	local applied: { Decal } = {}
	for i, label in makeupLabels do
		local tex = textures[label]
		if tex then
			local d = Instance.new("Decal")
			d.Name = "SV_Makeup_" .. label
			d.Texture = tex
			d.Face = Enum.NormalId.Front
			d.ZIndex = i -- uji nomor 5: apakah urutan lapis menurut ZIndex?
			d.Parent = head
			table.insert(applied, d)
			say("4 tempel %s -> %s", label, describe(d))
		end
	end
	say("4 total decal terpasang: %d — LIHAT KEPALA AVATAR SEKARANG (makeup terlihat? menutupi wajah?)", #applied)
	task.wait(3)

	-- 5. Urutan lapis: balik ZIndex-nya, lihat apakah tampilannya berubah.
	for i, d in applied do
		d.ZIndex = #applied - i + 1
	end
	say("5 ZIndex DIBALIK (%d decal). Lihat apakah lapisan bertukar.", #applied)
	task.wait(3)

	-- 6. Bertahan tidak saat outfit diganti (ApplyDescriptionAsync)?
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if humanoid then
		local desc = humanoid:GetAppliedDescription()
		local okApply, errApply = pcall(function()
			humanoid:ApplyDescriptionAsync(desc)
		end)
		task.wait(1)
		local newHead = character:FindFirstChild("Head")
		local stillThere = 0
		for _, d in applied do
			if d.Parent ~= nil then
				stillThere += 1
			end
		end
		say(
			"6 ApplyDescriptionAsync ok=%s err=%s | Head sama? %s | decal tersisa %d/%d",
			tostring(okApply),
			tostring(errApply),
			tostring(newHead == head),
			stillThere,
			#applied
		)
	else
		say("6 tidak ada Humanoid, lewati")
	end

	-- 7. Lepas: hapus hanya decal kita, cek decal wajah bawaan tetap ada.
	for _, d in applied do
		if d.Parent then
			d:Destroy()
		end
	end
	task.wait(0.5)
	local leftover = {}
	local liveHead = character:FindFirstChild("Head")
	if liveHead then
		for _, child in liveHead:GetChildren() do
			if child:IsA("Decal") or child:IsA("Texture") then
				table.insert(leftover, child.Name)
			end
		end
	end
	say(
		"7 setelah dilepas, sisa decal di Head: [%s] (harus ada 'face' bawaan, tanpa SV_Makeup_*)",
		table.concat(leftover, ", ")
	)

	-- 8. Background: Texture-nya dicetak supaya bisa dicoba di ImageLabel pada bagian client.
	say("8 AvatarBackground Texture = %s (pakai ini di ImageLabel bagian client)", tostring(textures.AvatarBackground))
	local bgId: number? = nil
	for _, s in samples do
		if s.label == "AvatarBackground" then
			bgId = s.id
		end
	end
	say("8 AvatarBackground id item = %s", tostring(bgId))
	say("SELESAI bagian server. Sekarang jalankan .client() di tab Client.")
end

--------------------------------------------------------------------------------
-- BAGIAN CLIENT — apakah semuanya bisa dikerjakan tanpa server?
--------------------------------------------------------------------------------
function M.client()
	local Players = game:GetService("Players")
	local player = Players.LocalPlayer
	local char = if player then player.Character else nil
	local head = if char then char:FindFirstChild("Head") else nil

	-- 9. Bisakah CLIENT memanggil InsertService:LoadAsset?
	--    Ganti angka di bawah dengan id makeup yang dicetak bagian server nomor 1.
	local ID_MAKEUP = 0
	if ID_MAKEUP == 0 then
		say("9 isi dulu ID_MAKEUP di file ini dengan id dari cetakan server nomor 1, lalu jalankan lagi.")
	else
		local root, info = loadAsset(ID_MAKEUP)
		if root then
			say("9 CLIENT LoadAsset BERHASIL dalam %.2f detik", info :: number)
			dumpTree("9 client", root)
			root:Destroy()
		else
			say("9 CLIENT LoadAsset DITOLAK: %s -> jalur makeup harus lewat server", tostring(info))
		end
	end

	-- 10. Decal buatan client di Head: kelihatan oleh pemain ini? (cukup untuk preview lokal)
	if head and ID_MAKEUP ~= 0 then
		local d = Instance.new("Decal")
		d.Name = "SV_MakeupClientTest"
		d.Texture = "rbxassetid://" .. tostring(ID_MAKEUP)
		d.Face = Enum.NormalId.Front
		d.Parent = head
		say("10 decal client dipasang di Head — terlihat? (hilang otomatis 5 detik)")
		task.wait(5)
		d:Destroy()
		say("10 decal client dilepas")
	else
		say("10 dilewati (Head tidak ada atau ID_MAKEUP belum diisi)")
	end
end

return M
