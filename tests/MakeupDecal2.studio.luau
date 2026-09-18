--!strict
-- SPIKE makeup-decal BAGIAN 2 (PR #18) — HANYA di Studio.
-- Bagian 1 sudah membuktikan: Decal buatan sendiri (Face=Front) tampil rapi di Head,
-- texture id HARUS diambil dari InsertService:LoadAsset (id item != id texture).
--
-- SERVER: Play -> tab Server -> Command Bar:
--   require(game.ReplicatedStorage.Tests["MakeupDecal2.studio"]).server()
-- CLIENT: tab Client -> Command Bar (angka dari cetakan server nomor 1):
--   require(game.ReplicatedStorage.Tests["MakeupDecal2.studio"]).client(133520807586498)
--
-- Sisa yang harus terjawab:
--   A. Urutan lapis: apakah ZIndex Decal menentukan siapa di atas? (jeda 6 detik, dua kali)
--   B. AvatarBackground: berapa isi ImageId & Color di dalam Folder-nya?
--   C. Bisakah CLIENT memanggil InsertService:LoadAsset? (menentukan perlu remote atau tidak)
--   D. Kalau Head DIGANTI (apply description pemain lain), decal ikut hilang sendiri atau menggantung?

local TAG = "[SPIKE18b]"

local M = {}

local function say(fmt: string, ...: any)
	print(TAG .. " " .. string.format(fmt, ...))
end

-- Hitung mundur supaya sempat dilihat mata.
local function hold(seconds: number, what: string)
	for i = seconds, 1, -1 do
		say("%s ... %d", what, i)
		task.wait(1)
	end
end

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

-- Texture id di dalam Model hasil LoadAsset (makeup).
local function textureOf(root: Instance): string?
	local found = root:FindFirstChildWhichIsA("Decal", true)
	return if found then (found :: Decal).Texture else nil
end

function M.server()
	local ServerScriptService = game:GetService("ServerScriptService")
	local Players = game:GetService("Players")
	local RobloxApi = require(ServerScriptService:WaitForChild("Server").Gateways.RobloxApi) :: any

	local api = RobloxApi.new()
	local A = Enum.AvatarAssetType

	local player = Players:GetPlayers()[1]
	local char = if player then player.Character else nil
	local headFound = if char then char:FindFirstChild("Head") else nil
	if char == nil or headFound == nil then
		say("TIDAK ada Head. Play ulang lalu jalankan lagi.")
		return
	end
	local character = char :: Instance
	local head = headFound :: BasePart
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	-- 1. Dua makeup yang saling bertumpuk: FaceMakeup (lebar) + LipMakeup (kecil, di bibir).
	local picks: { { label: string, id: number, texture: string } } = {}
	for _, probe in
		{
			{ label = "FaceMakeup", assetType = A.FaceMakeup },
			{ label = "LipMakeup", assetType = A.LipMakeup },
		}
	do
		local okSearch, page = api:searchCatalog({ assetTypes = { probe.assetType }, limit = 10 })
		if okSearch and page.items[1] then
			local it = page.items[1]
			local root = loadAsset(it.Id)
			local tex = if root then textureOf(root) else nil
			if root then
				root:Destroy()
			end
			if tex then
				table.insert(picks, { label = probe.label, id = it.Id, texture = tex })
				say("1 %s: %s id=%d texture=%s", probe.label, tostring(it.Name), it.Id, tex)
			else
				say("1 %s: texture tidak ketemu", probe.label)
			end
		else
			say("1 %s: tidak dapat contoh", probe.label)
		end
		task.wait(0.3)
	end

	-- A. Urutan lapis. Dua kali tampil, masing-masing 6 detik, ZIndex ditukar.
	local decals: { Decal } = {}
	for i, p in picks do
		local d = Instance.new("Decal")
		d.Name = "SV_Makeup_" .. p.label
		d.Texture = p.texture
		d.Face = Enum.NormalId.Front
		d.ZIndex = i
		d.Parent = head
		table.insert(decals, d)
	end
	if #decals >= 2 then
		say(
			"A RONDE 1 — %s ZIndex=1, %s ZIndex=2 (yang ZIndex besar harusnya DI ATAS)",
			picks[1].label,
			picks[2].label
		)
		hold(6, "A ronde 1")
		decals[1].ZIndex = 2
		decals[2].ZIndex = 1
		say("A RONDE 2 — DITUKAR: %s ZIndex=2, %s ZIndex=1", picks[1].label, picks[2].label)
		hold(6, "A ronde 2")
	else
		say("A kurang dari 2 decal, uji lapis dilewati")
	end

	-- B. AvatarBackground: isi Folder-nya.
	local okBg, bgPage = api:searchCatalog({ assetTypes = { A.AvatarBackground }, limit = 10 })
	if okBg and bgPage.items[1] then
		local it = bgPage.items[1]
		local root = loadAsset(it.Id)
		if root then
			local folder = root:FindFirstChild("AvatarBackground", true)
			if folder then
				local imageId = folder:FindFirstChild("ImageId")
				local color = folder:FindFirstChild("Color")
				say(
					"B background '%s' id=%d -> ImageId=%s Color=%s",
					tostring(it.Name),
					it.Id,
					if imageId then tostring((imageId :: IntValue).Value) else "nil",
					if color then tostring((color :: Color3Value).Value) else "nil"
				)
				for _, child in folder:GetChildren() do
					say("B   isi folder: %s '%s'", child.ClassName, child.Name)
				end
			else
				say("B folder AvatarBackground tidak ketemu di dalam model")
			end
			root:Destroy()
		else
			say("B LoadAsset background gagal")
		end
	else
		say("B tidak dapat contoh background")
	end

	-- D. Head diganti sungguhan: pakai description pemain lain, lihat nasib decal.
	if humanoid then
		local before = humanoid:GetAppliedDescription()
		local okDesc, other = api:getDescriptionFromUserId(1)
		if okDesc then
			local okApply, errApply = pcall(function()
				humanoid:ApplyDescriptionAsync(other)
			end)
			task.wait(2)
			local newHead = character:FindFirstChild("Head")
			local alive, orphan = 0, 0
			for _, d in decals do
				if d.Parent ~= nil then
					alive += 1
					if d.Parent ~= newHead then
						orphan += 1
					end
				end
			end
			say(
				"D ganti avatar ok=%s err=%s | Head instance sama? %s | decal hidup %d (menggantung di Head lama: %d)",
				tostring(okApply),
				tostring(errApply),
				tostring(newHead == head),
				alive,
				orphan
			)
			say("D LIHAT: makeup masih menempel di wajah baru, atau hilang?")
			hold(5, "D amati")
			-- kembalikan avatar semula
			pcall(function()
				humanoid:ApplyDescriptionAsync(before)
			end)
			task.wait(1)
			say("D avatar dikembalikan ke semula")
		else
			say("D gagal ambil description pemain lain: %s", tostring(other))
		end
	end

	-- Bersihkan apa pun yang tersisa.
	for _, d in decals do
		if d.Parent then
			d:Destroy()
		end
	end
	local liveHead = character:FindFirstChild("Head")
	if liveHead then
		for _, child in liveHead:GetChildren() do
			if child.Name:match("^SV_Makeup_") then
				child:Destroy()
			end
		end
	end
	say("SELESAI server. Sekarang: .client(<id makeup dari nomor 1>) di tab Client.")
end

-- C. Dipanggil dari tab Client: .client(133520807586498)
function M.client(itemId: number)
	if type(itemId) ~= "number" or itemId <= 0 then
		say('C pakai: require(game.ReplicatedStorage.Tests["MakeupDecal2.studio"]).client(<id makeup>)')
		return
	end
	local root, info = loadAsset(itemId)
	if root then
		local tex = textureOf(root)
		say("C CLIENT LoadAsset BERHASIL dalam %.2f detik, texture=%s", info :: number, tostring(tex))
		say("C -> makeup bisa diurus client sendiri, tanpa remote tambahan")
		root:Destroy()
	else
		say("C CLIENT LoadAsset DITOLAK: %s", tostring(info))
		say("C -> texture id harus dikirim dari server (perlu cache + remote)")
	end
end

return M
