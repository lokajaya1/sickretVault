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
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).own()   -- #30, jalur B
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).anim()  -- #30 Langkah 5
--   tab SERVER (pembanding: HARUS ditolak / atau justru jalan — itulah yang diukur):
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).caps()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).save()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).load()
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).db(1, false)
--     require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"]).own()   -- #30, jalur A
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
-- Q5 (#30): dari mana status "sudah dimiliki" per item diambil, dan berapa mahal?
-- Panel CAC ("Owned Items" / "Unowned Items (N)") butuh status untuk SETIAP item yang dipakai --
-- sekitar 20 item. Dua jalur yang mungkin, dan keduanya diukur di sini:
--   A. SERVER: MarketplaceService:PlayerOwnsAsset per item (N panggilan). Yang ditakutkan 429 --
--      #28 no. 6 mencatat 4 dari 12 panggilan favorit beruntun kena 429.
--   B. CLIENT: AvatarEditorService:GetInventoryAsync(assetTypes) -- SATU permintaan berhalaman
--      untuk seluruh inventory, lalu dicocokkan sendiri. Butuh izin (perm(), berlaku per sesi).
-- Jalankan own() di tab SERVER dan tab CLIENT; masing-masing menjalankan jalur yang berlaku.
--------------------------------------------------------------------------------
-- Tipe aset yang dipakai jalur B. Disamakan dengan yang bisa muncul di look kita.
local INVENTORY_TYPES = {
	"Hat",
	"HairAccessory",
	"FaceAccessory",
	"NeckAccessory",
	"ShoulderAccessory",
	"FrontAccessory",
	"BackAccessory",
	"WaistAccessory",
	"Shirt",
	"Pants",
	"TShirt",
	"ShirtAccessory",
	"PantsAccessory",
	"JacketAccessory",
	"SweaterAccessory",
	"ShortsAccessory",
	"DressSkirtAccessory",
	"LeftShoeAccessory",
	"RightShoeAccessory",
}

-- Id aset yang SEDANG DIPAKAI: aksesori + classic clothing. Cukup untuk mengukur biaya.
local function wornAssetIds(desc: any): { number }
	local ids: { number } = {}
	local seen: { [number]: boolean } = {}
	local function add(id: any)
		if typeof(id) == "number" and id > 0 and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	local okAcc, accessories = pcall(function()
		return desc:GetAccessories(true)
	end)
	if okAcc and typeof(accessories) == "table" then
		for _, entry in accessories :: any do
			add(entry.AssetId)
		end
	end
	for _, field in { "Shirt", "Pants", "GraphicTShirt", "Face" } do
		local okField, value = pcall(function()
			return desc[field]
		end)
		if okField then
			add(value)
		end
	end
	return ids
end

function M.own()
	local desc, player = appliedDescription()
	if desc == nil or player == nil then
		return
	end
	local ids = wornAssetIds(desc)
	say("own() di %s: %d item dipakai", where(), #ids)

	if not RunService:IsClient() then
		-- JALUR A: satu panggilan per item.
		local marketplace = game:GetService("MarketplaceService")
		local owned, failed, slowest = 0, 0, 0
		local t0 = os.clock()
		for i, id in ids do
			local tItem = os.clock()
			local ok, result = pcall(function()
				return marketplace:PlayerOwnsAsset(player, id)
			end)
			local took = ms(tItem)
			slowest = math.max(slowest, took)
			if not ok then
				failed += 1
				say("  A #%d id=%d GAGAL (%.0f ms): %s", i, id, took, tostring(result))
			else
				if result then
					owned += 1
				end
				say("  A #%d id=%d dimiliki=%s (%.0f ms)", i, id, tostring(result), took)
			end
		end
		say(
			"JALUR A (PlayerOwnsAsset x%d): dimiliki=%d gagal=%d total=%.0f ms terlama=%.0f ms",
			#ids,
			owned,
			failed,
			ms(t0),
			slowest
		)
		say("-> gagal > 0 berarti kena batas (429): jalur A TIDAK bisa dipakai apa adanya")
		return
	end

	-- JALUR B: satu permintaan berhalaman untuk seluruh inventory.
	local types = {}
	for _, name in INVENTORY_TYPES do
		local okType, value = pcall(function()
			return (Enum.AvatarAssetType :: any)[name]
		end)
		if okType and value ~= nil then
			table.insert(types, value)
		else
			say("  tipe %s TIDAK ADA di Enum.AvatarAssetType", name)
		end
	end
	say("JALUR B: meminta inventory untuk %d tipe", #types)
	local t0 = os.clock()
	local okInv, pages = pcall(function()
		return (AvatarEditorService :: any):GetInventoryAsync(types)
	end)
	if not okInv then
		say("GetInventoryAsync GAGAL (%.0f ms): %s", ms(t0), tostring(pages))
		say("-> kalau soal izin, jalankan perm() dulu di tab Client lalu ulangi own()")
		return
	end
	say("GetInventoryAsync balas dalam %.0f ms", ms(t0))

	local ownedIds: { [number]: boolean } = {}
	local count, pageNo = 0, 0
	local tPages = os.clock()
	while true do
		pageNo += 1
		local okPage, page = pcall(function()
			return pages:GetCurrentPage()
		end)
		if not okPage or typeof(page) ~= "table" then
			say("GetCurrentPage GAGAL di halaman %d: %s", pageNo, tostring(page))
			break
		end
		for _, entry in page :: any do
			count += 1
			if count <= 3 and pageNo == 1 then
				local fields = {}
				for k, v in entry :: any do
					table.insert(fields, string.format("%s=%s", tostring(k), tostring(v)))
				end
				table.sort(fields)
				say("  contoh entri: %s", table.concat(fields, " "))
			end
			local id = (entry :: any).AssetId or (entry :: any).Id
			if typeof(id) == "number" then
				ownedIds[id] = true
			end
		end
		if pages.IsFinished then
			break
		end
		if pageNo >= 20 then
			say("BERHENTI di 20 halaman (inventory besar) -- ini sendiri sudah jawaban soal biaya")
			break
		end
		local okNext, errNext = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not okNext then
			say("AdvanceToNextPageAsync GAGAL di halaman %d: %s", pageNo, tostring(errNext))
			break
		end
	end
	say("JALUR B: %d entri dalam %d halaman, %.0f ms", count, pageNo, ms(tPages))

	local hit, miss = 0, 0
	for _, id in ids do
		if ownedIds[id] then
			hit += 1
		else
			miss += 1
			say("  B: id=%d TIDAK ada di inventory (berarti belum dimiliki -- cocokkan dengan A)", id)
		end
	end
	say("JALUR B vs item dipakai: dimiliki=%d tidak=%d (bandingkan dengan hasil A di tab Server)", hit, miss)
end

--------------------------------------------------------------------------------
-- Q5 putaran 2 (#30). Putaran 1 menjawab: jalur A akurat tapi ~515 ms/item berurutan, jalur B
-- sekali jalan 333 ms TAPI hanya 20 entri 1 halaman dan MELESET (item yang jelas dimiliki menurut
-- A dilaporkan tidak ada). Tiga pertanyaan sisa, dan ketiganya menentukan bentuk panel:
--   a. PlayerOwnsAsset SERENTAK: 16 sekaligus masih lolos, atau 429? (#28 no. 6: 16 panggilan
--      favorit serentak GAGAL SEMUA -- belum tentu berlaku untuk MarketplaceService)
--   b. Item dari BUNDLE tidak punya baris aset sendiri di inventory -> ada PlayerOwnsBundle?
--   c. Inventory berhenti di 20 entri: memang sebesar itu satu halaman, dan IsFinished jujur?
--------------------------------------------------------------------------------
function M.own2(repeats: number?)
	local desc, player = appliedDescription()
	if desc == nil or player == nil then
		return
	end

	if not RunService:IsClient() then
		local marketplace = game:GetService("MarketplaceService")
		-- (a) serentak. Daftar id digandakan sampai `want` supaya bebannya nyata walau look kecil.
		local base = wornAssetIds(desc)
		local want = repeats or 16
		local ids: { number } = {}
		while #ids < want and #base > 0 do
			for _, id in base do
				if #ids >= want then
					break
				end
				table.insert(ids, id)
			end
		end
		say("own2() di SERVER: %d panggilan SERENTAK", #ids)
		local done, failed, owned = 0, 0, 0
		local t0 = os.clock()
		for i, id in ids do
			task.spawn(function()
				local ok, result = pcall(function()
					return marketplace:PlayerOwnsAsset(player, id)
				end)
				if not ok then
					failed += 1
					say("  serentak #%d id=%d GAGAL: %s", i, id, tostring(result))
				elseif result then
					owned += 1
				end
				done += 1
			end)
		end
		while done < #ids and ms(t0) < 20000 do
			task.wait(0.05)
		end
		say("SERENTAK x%d: selesai=%d dimiliki=%d GAGAL=%d dalam %.0f ms", #ids, done, owned, failed, ms(t0))
		say("-> GAGAL=0 berarti kepemilikan boleh diambil serentak (panel muncul dalam < 1 detik)")

		-- (b) bundle: badan & animasi datang dari bundle, bukan aset satuan.
		say("MarketplaceService.PlayerOwnsBundle = %s", has(marketplace, "PlayerOwnsBundle"))
		local okBundle, resBundle = pcall(function()
			return (marketplace :: any):PlayerOwnsBundle(player, 239) -- bundle "Woman" (#28 no. 4)
		end)
		say("PlayerOwnsBundle(239) ok=%s hasil=%s", tostring(okBundle), tostring(resBundle))
		return
	end

	-- (c) seberapa jujur paging inventory.
	local types = {}
	for _, name in INVENTORY_TYPES do
		local okType, value = pcall(function()
			return (Enum.AvatarAssetType :: any)[name]
		end)
		if okType and value ~= nil then
			table.insert(types, value)
		end
	end
	local okInv, pages = pcall(function()
		return (AvatarEditorService :: any):GetInventoryAsync(types)
	end)
	if not okInv then
		say("GetInventoryAsync GAGAL: %s (jalankan perm() dulu)", tostring(pages))
		return
	end
	local total, pageNo = 0, 0
	while pageNo < 30 do
		pageNo += 1
		local okPage, page = pcall(function()
			return pages:GetCurrentPage()
		end)
		if not okPage or typeof(page) ~= "table" then
			say("halaman %d tidak terbaca: %s", pageNo, tostring(page))
			break
		end
		total += #(page :: any)
		say("halaman %d: %d entri, IsFinished=%s", pageNo, #(page :: any), tostring(pages.IsFinished))
		-- SENGAJA memaksa maju walau IsFinished mengaku true: putaran 1 berhenti di 20 entri, dan
		-- dugaan pertama saya adalah IsFinished-nya yang bohong. Kalau memang habis, ini melempar.
		local okNext, errNext = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not okNext then
			say("AdvanceToNextPageAsync berhenti di halaman %d: %s", pageNo, tostring(errNext))
			break
		end
	end
	say("PAGING: %d entri dalam %d halaman -- bandingkan dengan jumlah item di inventory web-mu", total, pageNo)
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

-- (c) SPIKE PRATINJAU ITEM REMOVAL (#30 Langkah 5). Dialog tong sampah harus menampilkan avatar
-- yang BERGERAK dengan animasi yang dipakai pemain, sekaligus menunjukkan hasil pencentangan
-- (item yang dicopot). Dua hal itu selama ini saling meniadakan di kode kita:
--   * `OutfitPreview.mount` membangun model dari HumanoidDescription -> bisa memakai look apa pun,
--     TAPI modelnya tidak bersendi (temuan #28: tanpa Motor6D) -> tidak bisa dianimasikan.
--   * `OutfitPreview.mountAnimated` menyalin KARAKTER pemain -> bersendi dan bisa menari, TAPI ia
--     memakai look yang sedang dipakai, bukan look hasil pencentangan.
-- Jalan ketiga yang belum pernah diuji: salin karakter (bersendi), lalu PAKAIKAN description baru
-- lewat Humanoid:ApplyDescription di dalam ViewportFrame.
-- Yang harus dijawab SEBELUM kode produksi:
--   A1. ApplyDescription jalan dari CLIENT untuk clone di dalam ViewportFrame? Berapa ms, error apa?
--   A2. Sesudahnya rig masih bersendi (Motor6D) -- atau ApplyDescription membangun ulang badan dan
--       mematikan animasinya?
--   A3. Animasi benar-benar MENGGERAKKAN part di ViewportFrame (bukan cuma track.IsPlaying = true)?
-- clipId boleh diisi id klip animasi milikmu; bawaannya idle R15 klasik.
function M.anim(clipId: string?)
	local desc, player = appliedDescription()
	if desc == nil or player == nil then
		return
	end
	local character = player.Character
	if character == nil then
		return say("[anim] karakter belum ada (%s)", where())
	end

	local gui = player:FindFirstChild("PlayerGui")
	if gui == nil then
		return say("[anim] PlayerGui tidak ada -- jalankan dari tab CLIENT")
	end
	local old = gui:FindFirstChild("AnimSpike")
	if old then
		old:Destroy()
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "AnimSpike"
	screen.ResetOnSpawn = false
	screen.Parent = gui
	local viewport = Instance.new("ViewportFrame")
	viewport.Size = UDim2.fromOffset(260, 340)
	viewport.Position = UDim2.fromOffset(24, 120)
	viewport.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	viewport.Parent = screen
	local world = Instance.new("WorldModel")
	world.Parent = viewport
	local camera = Instance.new("Camera")
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	character.Archivable = true
	local clone = character:Clone()
	-- Skrip Animate bawaan ikut tersalin dan MEMUTAR idle pemain di dalam viewport (temuan #28
	-- no. 6); kalau dibiarkan, tidak ketahuan mana gerakan dari klip kita.
	for _, d in clone:GetDescendants() do
		if d:IsA("BaseScript") then
			d:Destroy()
		end
	end
	local function motors(): number
		local n = 0
		for _, d in clone:GetDescendants() do
			if d:IsA("Motor6D") then
				n += 1
			end
		end
		return n
	end
	local before = motors()
	clone.Parent = world
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return say("[anim] clone tanpa Humanoid")
	end
	local root = clone:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		root.Anchored = true -- hanya root: part lain WAJIB bebas supaya animasi bisa menggerakkannya
		camera.CFrame = CFrame.lookAt(root.Position + Vector3.new(0, 1, 9), root.Position + Vector3.new(0, 1, 0))
	end

	-- A1 & A2: pakaikan look yang BERBEDA dari avatar asli (rambut dicopot) -- kalau viewport-nya
	-- berubah, berarti jalur ini cukup untuk pratinjau Item Removal.
	local wanted = desc:Clone()
	pcall(function()
		wanted.HairAccessory = ""
	end)
	local t0 = os.clock()
	local okApply, applyErr = pcall(function()
		(humanoid :: Humanoid):ApplyDescription(wanted)
	end)
	say("[anim] A1 ApplyDescription ok=%s %d ms err=%s", tostring(okApply), ms(t0), tostring(applyErr))
	say("[anim] A2 Motor6D sebelum=%d sesudah=%d", before, motors())

	-- A3: animasi harus benar-benar menggerakkan part, bukan sekadar mengaku Playing.
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	for _, t in (animator :: Animator):GetPlayingAnimationTracks() do
		t:Stop(0)
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = clipId or "rbxassetid://507766388"
	local okLoad, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	say("[anim] A3 LoadAnimation ok=%s err=%s", tostring(okLoad), if okLoad then "-" else tostring(track))
	if okLoad and track ~= nil then
		local playing: AnimationTrack = track
		playing.Looped = true
		playing:Play()
		local hand = clone:FindFirstChild("RightHand") or clone:FindFirstChild("Right Arm")
		local p0 = if hand ~= nil and hand:IsA("BasePart") then hand.Position else Vector3.zero
		task.wait(1.5)
		local p1 = if hand ~= nil and hand:IsA("BasePart") then hand.Position else Vector3.zero
		say(
			"[anim] A3 IsPlaying=%s tangan bergeser %.3f stud (0.000 = rig tidak bergerak)",
			tostring(playing.IsPlaying),
			(p1 - p0).Magnitude
		)
	end
	say("[anim] viewport ada di kiri layar. Hapus: game.Players.LocalPlayer.PlayerGui.AnimSpike:Destroy()")
end

return M
