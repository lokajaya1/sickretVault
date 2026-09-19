--!strict
-- SPIKE HumanoidDescription — HANYA di Studio (nama tidak berakhiran .spec, jadi Lune melewatinya).
--
-- Dua kelompok isi:
--   (a) mode `db` lama: avatar asli -> OutfitState -> description baru, cek sama.
--   (b) SPIKE save-to-roblox (PR berikutnya). Pertanyaan yang HARUS dijawab sebelum kode produksi:
--       Q1. `PromptSaveAvatar` / `PromptCreateOutfit` jalan dari CLIENT saja, atau server juga?
--           (pola #13: PromptBulkPurchaseFinished hanya bisa di-subscribe dari LocalScript)
--       Q2. Apa yang terjadi kalau look memuat item yang TIDAK DIMILIKI pemain? Ini inti produk:
--           katalog kita justru untuk mencoba barang yang belum dibeli. Success / PermissionDenied /
--           Failed? Kalau selalu gagal, tombol "Save to Roblox" hanya boleh menyala untuk look
--           yang seluruh itemnya dimiliki.
--       Q3. Daftar outfit Roblox pemain bisa diambil dari dalam game (`GetOutfits`)? Bentuk datanya
--           apa (id, nama, thumbnail?), butuh izin inventory (#28: izinnya PER SESI), berapa ms,
--           dan kena 429 setelah berapa panggilan?
--       Q4. `GetHumanoidDescriptionFromOutfitId` jalan di client atau server saja, berapa ms?
--
-- CARA PAKAI (Play dulu; `local S = ...` TIDAK bertahan antar eksekusi -> tulis lengkap tiap baris,
-- dan KOSONGKAN Command Bar (Cmd+A, Delete) sebelum menempel SATU baris):
--   tab CLIENT:
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).caps()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).save()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).outfit()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).unowned()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).perm()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).outfits()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).load()
--   tab SERVER (pembanding: HARUS ditolak / atau justru jalan — itulah yang diukur):
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).caps()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).save()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).load()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).db(1, false)
--
-- CATATAN: `save()` dan `outfit()` MENULIS ke akun Roblox yang sedang dipakai Studio (avatar /
-- daftar outfit sungguhan). Itu memang yang diuji; siapkan diri untuk merapikan outfit sisa uji.

local AvatarEditorService = game:GetService("AvatarEditorService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local DB = require(Shared.Avatar.DescriptionBuilder)

local TAG = "[SPIKESAVE]"
-- Aksesori Roblox gratis yang dipakai sebagai "item asing" di unowned(); ganti lewat argumen
-- kalau kebetulan pemain sudah memilikinya (lognya akan menyebut kepemilikan).
local FOREIGN_HAT = 4819740796 -- "Red Roblox Cap" (aksesori Hat, gratis)

local M = {}
M._conns = {} :: { RBXScriptConnection }

local function say(fmt: string, ...: any)
	print(TAG .. " " .. string.format(fmt, ...))
end

local function where(): string
	return if RunService:IsClient() then "CLIENT" else "SERVER"
end

local function ms(t0: number): number
	return (os.clock() - t0) * 1000
end

-- Ada tidaknya anggota (method / event). Mengindeks anggota yang tidak ada bisa MELEMPAR,
-- jadi selalu lewat pcall. Sengaja TIDAK memanggilnya: memanggil diuji terpisah (pelajaran #26
-- no. 2 — membaca properti tidak membuktikan apa pun tentang memakainya).
local function has(obj: any, name: string): string
	local ok, value = pcall(function()
		return obj[name]
	end)
	if not ok then
		return "TIDAK ADA"
	end
	return typeof(value)
end

local function localPlayer(): Player?
	if RunService:IsClient() then
		return Players.LocalPlayer
	end
	return Players:GetPlayers()[1]
end

-- Description yang SEDANG dipakai karakter (look hasil try-on kita). Inilah yang akan dikirim ke
-- prompt: tidak perlu remote apa pun, karena karakternya sudah memakai look-nya.
local function appliedDescription(): (any?, Player?)
	local player = localPlayer()
	if player == nil then
		say("tidak ada pemain")
		return nil, nil
	end
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		say("karakter/Humanoid belum ada")
		return nil, player
	end
	local ok, desc = pcall(function()
		return (humanoid :: Humanoid):GetAppliedDescription()
	end)
	if not ok then
		say("GetAppliedDescription GAGAL: %s", tostring(desc))
		return nil, player
	end
	return desc, player
end

local function summarize(desc: any): string
	local ok, text = pcall(function()
		local d = desc :: HumanoidDescription
		return ("Hat=%s Shirt=%d Pants=%d Face=%d Torso=%d Scale(H=%.2f W=%.2f)"):format(
			tostring(d.HatAccessory),
			d.Shirt,
			d.Pants,
			d.Face,
			d.Torso,
			d.HeightScale,
			d.WidthScale
		)
	end)
	return if ok then text else "tidak terbaca: " .. tostring(text)
end

-- Satu tempat untuk menyambungkan event hasil prompt. Disimpan di M supaya tidak ikut dibuang
-- saat eksekusi Command Bar selesai.
local function listen(signalName: string)
	local ok, signal = pcall(function()
		return (AvatarEditorService :: any)[signalName]
	end)
	if not ok or signal == nil then
		say("event %s TIDAK ADA di %s", signalName, where())
		return
	end
	local t0 = os.clock()
	local conn
	conn = signal:Connect(function(result: any)
		say("%s -> %s (setelah %.0f ms)", signalName, tostring(result), ms(t0))
		conn:Disconnect()
	end)
	table.insert(M._conns, conn)
end

--------------------------------------------------------------------------------
-- Q1/Q3/Q4 tahap 0: anggota apa saja yang ADA di konteks ini
--------------------------------------------------------------------------------
function M.caps()
	say("=== caps di %s ===", where())
	for _, name in
		{
			"PromptSaveAvatar",
			"PromptCreateOutfit",
			"PromptAllowInventoryReadAccess",
			"GetOutfits",
			"GetInventoryAsync",
			"PromptSaveAvatarCompleted",
			"PromptCreateOutfitCompleted",
			"PromptCreateOutfitFailed",
			"PromptAllowInventoryReadAccessCompleted",
			"OpenAllowInventoryReadAccess",
		}
	do
		say("AvatarEditorService.%s = %s", name, has(AvatarEditorService, name))
	end
	for _, name in { "GetHumanoidDescriptionFromOutfitId", "GetHumanoidDescriptionFromUserId" } do
		say("Players.%s = %s", name, has(Players, name))
	end
	local okEnum, values = pcall(function()
		local out = {}
		for _, item in Enum.AvatarPromptResult:GetEnumItems() do
			table.insert(out, item.Name)
		end
		return table.concat(out, ", ")
	end)
	say("Enum.AvatarPromptResult = %s", if okEnum then values else "TIDAK ADA")
end

--------------------------------------------------------------------------------
-- Q1: simpan look sekarang ke AVATAR Roblox pemain
--------------------------------------------------------------------------------
function M.save()
	local desc, player = appliedDescription()
	if desc == nil or player == nil then
		return
	end
	say("save() di %s, look: %s", where(), summarize(desc))
	listen("PromptSaveAvatarCompleted")
	local rig = if player.Character
			and player.Character:FindFirstChildOfClass("Humanoid")
			and (player.Character:FindFirstChildOfClass("Humanoid") :: Humanoid).RigType == Enum.HumanoidRigType.R6
		then Enum.HumanoidRigType.R6
		else Enum.HumanoidRigType.R15
	local t0 = os.clock()
	local ok, err = pcall(function()
		(AvatarEditorService :: any):PromptSaveAvatar(desc, rig)
	end)
	say("PromptSaveAvatar dipanggil: ok=%s %s (%.0f ms) rig=%s", tostring(ok), tostring(err), ms(t0), rig.Name)
	if ok then
		say("-> lihat prompt di layar; hasilnya menyusul lewat PromptSaveAvatarCompleted")
	end
end

--------------------------------------------------------------------------------
-- Q1: simpan look sekarang sebagai OUTFIT baru di akun Roblox
--------------------------------------------------------------------------------
function M.outfit()
	local desc, player = appliedDescription()
	if desc == nil or player == nil then
		return
	end
	say("outfit() di %s, look: %s", where(), summarize(desc))
	listen("PromptCreateOutfitCompleted")
	listen("PromptCreateOutfitFailed")
	local t0 = os.clock()
	local ok, err = pcall(function()
		(AvatarEditorService :: any):PromptCreateOutfit(desc, Enum.HumanoidRigType.R15)
	end)
	say("PromptCreateOutfit dipanggil: ok=%s %s (%.0f ms)", tostring(ok), tostring(err), ms(t0))
end

--------------------------------------------------------------------------------
-- Q2: look yang memuat item yang (mungkin) TIDAK dimiliki pemain
--------------------------------------------------------------------------------
function M.unowned(assetId: number?)
	local desc, player = appliedDescription()
	if desc == nil or player == nil then
		return
	end
	local id = assetId or FOREIGN_HAT
	local okOwn, owns = pcall(function()
		return game:GetService("MarketplaceService"):PlayerOwnsAsset(player, id)
	end)
	say("unowned(): assetId=%d dimiliki=%s (cek=%s)", id, tostring(owns), tostring(okOwn))

	local copy = (desc :: HumanoidDescription):Clone()
	local accessories = copy:GetAccessories(true)
	table.insert(
		accessories,
		{
			AccessoryType = Enum.AccessoryType.Hat,
			AssetId = id,
			IsLayered = false,
			Order = 1,
		} :: any
	)
	local okSet, errSet = pcall(function()
		copy:SetAccessories(accessories, true)
	end)
	say("SetAccessories ok=%s %s", tostring(okSet), tostring(errSet))

	listen("PromptSaveAvatarCompleted")
	local t0 = os.clock()
	local ok, err = pcall(function()
		(AvatarEditorService :: any):PromptSaveAvatar(copy, Enum.HumanoidRigType.R15)
	end)
	say("PromptSaveAvatar(item asing) dipanggil: ok=%s %s (%.0f ms)", tostring(ok), tostring(err), ms(t0))
	say("-> INI JAWABAN Q2: lihat hasil PromptSaveAvatarCompleted di atas (Success/PermissionDenied/Failed)")
end

--------------------------------------------------------------------------------
-- Q3: izin baca inventory (#28: izin ini berlaku PER SESI)
--------------------------------------------------------------------------------
function M.perm()
	say("perm() di %s", where())
	listen("PromptAllowInventoryReadAccessCompleted")
	local ok, err = pcall(function()
		(AvatarEditorService :: any):PromptAllowInventoryReadAccess()
	end)
	say("PromptAllowInventoryReadAccess dipanggil: ok=%s %s", tostring(ok), tostring(err))
end

--------------------------------------------------------------------------------
-- Q3: daftar outfit Roblox pemain + BENTUK datanya + biaya
--------------------------------------------------------------------------------
function M.outfits(pageCount: number?)
	say("outfits() di %s", where())
	local t0 = os.clock()
	local ok, pages = pcall(function()
		return (AvatarEditorService :: any):GetOutfits()
	end)
	if not ok then
		say("GetOutfits GAGAL (%.0f ms): %s", ms(t0), tostring(pages))
		say("-> kalau pesannya soal izin, jalankan perm() dulu di tab CLIENT")
		return
	end
	say("GetOutfits OK (%.0f ms) typeof=%s", ms(t0), typeof(pages))

	local wanted = pageCount or 2
	local shown = 0
	local page = 1
	while true do
		local okPage, items = pcall(function()
			return (pages :: any):GetCurrentPage()
		end)
		if not okPage then
			say("GetCurrentPage GAGAL: %s", tostring(items))
			return
		end
		say("halaman %d: %d entri", page, #(items :: any))
		for _, entry in items :: any do
			shown += 1
			if shown <= 6 then
				local keys = {}
				if type(entry) == "table" then
					for k, v in entry do
						table.insert(keys, ("%s=%s"):format(tostring(k), tostring(v)))
					end
					table.sort(keys)
				end
				say("  entri %d: %s", shown, table.concat(keys, " "))
			end
		end
		if page >= wanted or (pages :: any).IsFinished then
			break
		end
		local okNext, errNext = pcall(function()
			(pages :: any):AdvanceToNextPageAsync()
		end)
		if not okNext then
			say("AdvanceToNextPageAsync GAGAL: %s", tostring(errNext))
			break
		end
		page += 1
	end
	say("-> catat: field id & nama outfit ada di baris 'entri' di atas (itu yang dipakai loader)")
end

--------------------------------------------------------------------------------
-- Q4: outfitId -> HumanoidDescription (biaya + konteks + apakah bisa dipakai loader)
--------------------------------------------------------------------------------
function M.load(outfitId: number?)
	local id = outfitId
	if id == nil then
		local ok, pages = pcall(function()
			return (AvatarEditorService :: any):GetOutfits()
		end)
		if ok then
			local okPage, items = pcall(function()
				return (pages :: any):GetCurrentPage()
			end)
			if okPage and type(items) == "table" and items[1] ~= nil then
				id = (items[1] :: any).Id or (items[1] :: any).id
			end
		end
	end
	if id == nil then
		say("load(): tidak dapat outfitId — jalankan outfits() dulu lalu load(<id>)")
		return
	end

	local t0 = os.clock()
	local ok, desc = pcall(function()
		return Players:GetHumanoidDescriptionFromOutfitId(id :: number)
	end)
	if not ok then
		say("load(%d) di %s GAGAL (%.0f ms): %s", id, where(), ms(t0), tostring(desc))
		return
	end
	say("load(%d) di %s OK (%.0f ms): %s", id, where(), ms(t0), summarize(desc))

	-- Bisakah description itu masuk ke OutfitState kita apa adanya? (jalur loader produksi)
	local okState, state = pcall(function()
		return DB.fromDescription(desc)
	end)
	if not okState then
		say("DB.fromDescription GAGAL: %s", tostring(state))
		return
	end
	local count = 0
	if type(state) == "table" and type((state :: any).accessories) == "table" then
		count = #(state :: any).accessories
	end
	say("-> DB.fromDescription OK: %d aksesori; loader tinggal memakai jalur restore yang sudah ada", count)
end

--------------------------------------------------------------------------------
-- mode lama: avatar asli -> state -> description baru (uji DescriptionBuilder)
--------------------------------------------------------------------------------
function M.db(userId: number?, spawnModels: boolean?)
	local id = userId or 1
	local original = Players:GetHumanoidDescriptionFromUserId(id)

	local state = DB.fromDescription(original)
	local rebuilt, skipped = DB.toDescription(state)

	local same, diff = DB.sameAppearance(original, rebuilt)
	print(
		("[DescriptionBuilder] userId=%d sama=%s diff=%s skipped=%d"):format(
			id,
			tostring(same),
			tostring(diff),
			#skipped
		)
	)
	assert(same, "tampilan berbeda: " .. tostring(diff))

	if spawnModels then
		for i, desc in { original, rebuilt } do
			local model = Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
			model.Name = if i == 1 then "DB_Original" else "DB_Rebuilt"
			model:PivotTo(CFrame.new((i - 1.5) * 6, 5, -10))
			model.Parent = workspace
		end
		print("[DescriptionBuilder] cek visual: DB_Original (kiri) vs DB_Rebuilt (kanan)")
	end
	print("[DescriptionBuilder] LULUS")
end

return M
