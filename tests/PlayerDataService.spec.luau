--!strict
-- Test PlayerDataService dengan ProfileStore PALSU.
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["PlayerDataService.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerDataService = require(ServerScriptService:WaitForChild("Server").Services.PlayerDataService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local PlayerData = require(Shared.Domain.PlayerData)
local Wardrobe = require(Shared.Domain.Wardrobe)
local OutfitFolders = require(Shared.Domain.OutfitFolders)
local OS = require(Shared.Domain.OutfitState)
local Log = require(Shared.Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

-- profil palsu: meniru bagian ProfileStore yang dipakai
local function fakeProfile(data: any)
	local p = {
		Data = data,
		released = false,
		userIds = {} :: { number },
		listeners = {} :: { () -> () },
		OnSessionEnd = {} :: any,
	}
	function p.OnSessionEnd.Connect(_self: any, fn: () -> ())
		table.insert(p.listeners, fn)
	end
	function p.AddUserId(self: any, id: number)
		table.insert(self.userIds, id)
	end
	function p.Reconcile(self: any)
		for k, v in PlayerData.TEMPLATE do
			if self.Data[k] == nil then
				self.Data[k] = if type(v) == "table" then table.clone(v) else v
			end
		end
	end
	function p.IsActive(self: any): boolean
		return not self.released
	end
	function p.EndSession(self: any)
		if self.released then
			return
		end
		self.released = true
		for _, fn in self.listeners do
			fn()
		end
	end
	return p
end

local function setup(opts: { data: any?, fail: string?, onLoad: ((any) -> ())? }?)
	local o = opts or {}
	local t = { keys = {} :: { string }, kicks = {} :: { string }, profile = nil :: any, cancel = nil :: any }
	local store = {}
	function store.StartSessionAsync(_self: any, key: string, params: any)
		table.insert(t.keys, key)
		eq(type(params.Cancel), "function", "Cancel diberikan")
		t.cancel = params.Cancel
		if o.fail == "throw" then
			error("DataStore 503")
		elseif o.fail == "nil" then
			return nil
		end
		t.profile = fakeProfile(o.data or {})
		if o.onLoad then
			o.onLoad(t.profile)
		end
		return t.profile
	end
	local svc = PlayerDataService.new({
		store = store,
		kick = function(player: any, msg: string)
			table.insert(t.kicks, player.Name .. ":" .. msg)
		end,
	})
	return svc, t
end

local function player(name: string, userId: number): any
	return { Name = name, UserId = userId, Parent = "Players" }
end

return function()
	Log.setSink(function() end)

	-- 1. profil baru: key benar, reconcile + migrate, GDPR userId
	do
		local svc, t = setup()
		local p = player("A", 42)
		eq(svc:load(p), true, "load ok")
		eq(t.keys[1], "Player_42", "key")
		eq(t.profile.userIds[1], 42, "AddUserId")
		eq(t.profile.Data.v, PlayerData.VERSION, "versi")
		eq(svc:isLoaded(p), true, "loaded")
		eq(svc:getSettings(p).restoreOutfit, true, "setting default")
		eq(svc:getLastOutfit(p), nil, "belum ada outfit")
		eq(svc:load(p), true, "load kedua aman")
		eq(#t.keys, 1, "tidak memuat ulang")
		-- getSettings mengembalikan salinan
		svc:getSettings(p).restoreOutfit = false
		eq(svc:getSettings(p).restoreOutfit, true, "salinan")
	end

	-- 2. simpan & baca outfit, hapus dengan nil
	do
		local svc, t = setup()
		local p = player("B", 7)
		svc:load(p)
		local s = OS.wear(OS.empty(), 20, "Hat")
		eq(svc:setLastOutfit(p, s), true, "tulis")
		eq(type(t.profile.Data.lastOutfit), "table", "tersimpan ringkas")
		local back = svc:getLastOutfit(p)
		assert(back, "baca")
		eq(back.accessories["20"].assetType, "Hat", "isi sama")
		eq(svc:setLastOutfit(p, nil), true, "hapus")
		eq(t.profile.Data.lastOutfit, nil, "terhapus")
	end

	-- 2b. LOOK: makeup ikut di dalam lastOutfit, field lastMakeup lama dibuang
	do
		local svc, t = setup({ data = { v = 4, lastMakeup = { { i = 700, s = "face" } } } })
		local p = player("B2", 71)
		svc:load(p)
		-- data lama (PR #18): makeup masih di lastMakeup -> tetap terbaca
		eq(#svc:getLastMakeup(p), 1, "makeup lama terbaca")
		eq(svc:getLastMakeup(p)[1].assetId, 700, "assetId lama")

		local mk = { face = { assetId = 800, slot = "face", textureId = "rbxassetid://1" } }
		eq(svc:setLastOutfit(p, OS.empty(), mk), true, "tulis look")
		eq(t.profile.Data.lastMakeup, nil, "field lama dibuang")
		eq(#t.profile.Data.lastOutfit.mk, 1, "makeup di dalam lastOutfit")
		local rows = svc:getLastMakeup(p)
		eq(#rows, 1, "satu makeup")
		eq(rows[1].assetId, 800, "makeup baru")
		eq(svc:setLastOutfit(p, nil), true, "hapus look")
		eq(#svc:getLastMakeup(p), 0, "makeup ikut hilang")
	end

	-- 2c. latar area preview: assetId saja, ikut sesi, id cacat = lepas latar
	do
		local svc, t = setup({ data = { v = 4, lastBackground = 121199209890990 } })
		local p = player("B3", 72)
		svc:load(p)
		eq(svc:getBackground(p), 121199209890990, "latar lama ikut naik ke v5")
		eq(svc:setBackground(p, 555), true, "ganti latar")
		eq(t.profile.Data.lastBackground, 555, "tersimpan sebagai angka polos")
		eq(svc:getBackground(p), 555, "baca latar baru")
		eq(svc:setBackground(p, nil), true, "lepas latar")
		eq(t.profile.Data.lastBackground, nil, "terhapus")
		eq(svc:setBackground(p, "rusak"), true, "id cacat diterima tapi tidak disimpan")
		eq(svc:getBackground(p), nil, "id cacat = tanpa latar")
		svc:release(p)
		eq(svc:setBackground(p, 555), false, "setelah release tulis diabaikan")
		eq(svc:getBackground(p), nil, "setelah release tidak ada sesi")
	end

	-- 3. outfit tersimpan rusak -> nil (fallback avatar asli)
	do
		local svc = setup({ data = { v = 1, lastOutfit = { ov = 1, r = "R99" } } })
		local p = player("C", 8)
		svc:load(p)
		eq(svc:getLastOutfit(p), nil, "rusak diabaikan")
	end

	-- 3b. keluar saat memuat & ProfileStore membatalkan (nil) -> LEFT, bukan LOAD_FAILED
	do
		local p = player("E2", 15)
		local svc = setup({
			fail = "nil",
		})
		p.Parent = nil
		eq(select(2, svc:load(p)), "LEFT", "batal karena keluar")
	end

	-- 4. gagal muat (error / nil) -> false, tidak di-kick, tulis diabaikan
	for _, mode in { "throw", "nil" } do
		local svc, t = setup({ fail = mode })
		local p = player("D", 9)
		local ok, code = svc:load(p)
		eq(ok, false, mode .. " gagal")
		eq(code, "LOAD_FAILED", mode .. " kode")
		eq(#t.kicks, 0, mode .. " tidak kick")
		eq(svc:setLastOutfit(p, OS.empty()), false, mode .. " tulis diabaikan")
		eq(svc:getSettings(p), nil, mode .. " settings nil")
		-- boleh dicoba lagi (flag loading dibersihkan)
		eq(select(2, svc:load(p)), "LOAD_FAILED", mode .. " coba lagi")
	end

	-- 5. pemain keluar saat memuat -> profil langsung dilepas, tanpa kick
	do
		local p = player("E", 10)
		local svc, t = setup({
			onLoad = function()
				p.Parent = nil
			end,
		})
		local ok, code = svc:load(p)
		eq(ok, false, "left")
		eq(code, "LEFT", "kode left")
		eq(t.cancel(), true, "Cancel = true setelah keluar")
		eq(t.profile.released, true, "dilepas")
		eq(#t.kicks, 0, "tanpa kick")
		eq(svc:isLoaded(p), false, "tidak ada sesi")
	end

	-- 6. release normal: profil dilepas, tanpa kick, tulis setelahnya diabaikan
	do
		local svc, t = setup()
		local p = player("F", 11)
		svc:load(p)
		svc:release(p)
		eq(t.profile.released, true, "released")
		eq(#t.kicks, 0, "release sendiri tidak kick")
		eq(svc:setLastOutfit(p, OS.empty()), false, "setelah release")
		svc:release(p) -- aman dua kali
	end

	-- 7. profil diambil server lain -> kick + sesi hilang
	do
		local svc, t = setup()
		local p = player("G", 12)
		svc:load(p)
		eq(t.cancel(), false, "Cancel = false selama di game")
		t.profile:EndSession() -- diakhiri dari luar (session stolen)
		eq(#t.kicks, 1, "kick")
		eq(string.find(t.kicks[1], "^G:") ~= nil, true, "pemain yang benar")
		eq(svc:isLoaded(p), false, "sesi hilang")
	end

	-- 8. data dari versi lebih baru: dibaca sebagai tidak ada, tidak ditulis
	do
		local future = { v = PlayerData.VERSION + 1, lastOutfit = "format baru", settings = {} }
		local svc, t = setup({ data = future })
		local p = player("H", 13)
		eq(svc:load(p), true, "load ok")
		eq(svc:getLastOutfit(p), nil, "tidak dibaca")
		eq(svc:getSettings(p), nil, "settings tidak dibaca")
		eq(svc:setLastOutfit(p, OS.empty()), false, "tidak ditulis")
		eq(t.profile.Data.lastOutfit, "format baru", "data utuh")
	end

	-- 9. profil tidak aktif lagi -> tulis ditolak
	do
		local svc, t = setup()
		local p = player("I", 14)
		svc:load(p)
		t.profile.released = true -- IsActive() = false tanpa memicu listener
		eq(svc:setLastOutfit(p, OS.empty()), false, "tidak aktif")
	end

	-- 10. setSetting: hanya key dikenal & tipe sama
	do
		local svc, t = setup()
		local p = player("J", 16)
		eq(select(2, svc:setSetting(p, "restoreOutfit", false)), "NOT_LOADED", "belum dimuat")
		svc:load(p)
		eq(svc:setSetting(p, "restoreOutfit", false), true, "setting diubah")
		eq(svc:getSettings(p).restoreOutfit, false, "tersimpan")
		eq(select(2, svc:setSetting(p, "restoreOutfit", "no")), "BAD_ARG", "tipe salah")
		eq(select(2, svc:setSetting(p, "admin", true)), "BAD_ARG", "key asing")
		eq(select(2, svc:setSetting(p, 5, true)), "BAD_ARG", "key bukan string")
		eq(t.profile.Data.settings.admin, nil, "key asing tidak ditulis")
	end

	-- 11. wardrobe: add / list / get / rename / overwrite / delete
	do
		local svc, t = setup()
		local p = player("K", 17)
		eq(select(2, svc:listOutfits(p)), "NOT_LOADED", "list sebelum load")
		eq(svc:outfitSlotInfo(p), nil, "info sebelum load")
		svc:load(p)
		local full, name = svc:outfitSlotInfo(p)
		eq(full, false, "belum penuh")
		eq(name, "Outfit 1", "nama bawaan")
		local a = svc:addOutfit(p, nil, OS.wear(OS.empty(), 20, "Hat"))
		assert(a, "add bawaan")
		eq(a.name, "Outfit 1", "nama bawaan dipakai")
		eq(a.count, 1, "ringkasan")
		local b = svc:addOutfit(p, "Pesta", OS.wear(OS.empty(), 30, "Shirt"))
		assert(b, "add bernama")
		eq(#t.profile.Data.outfits, 2, "tersimpan di profil")
		local rows = svc:listOutfits(p)
		assert(rows, "list")
		eq(rows[1].name, "Pesta", "terbaru dulu")
		local got = svc:getOutfit(p, a.id)
		assert(got, "get")
		eq(got.accessories["20"].assetType, "Hat", "isi slot")
		eq(select(2, svc:getOutfit(p, 99)), "NOT_FOUND", "get tidak ada")
		eq(svc:renameOutfit(p, b.id, "Malam"), true, "rename")
		eq(t.profile.Data.outfits[2].n, "Malam", "nama berubah")
		eq(svc:overwriteOutfit(p, a.id, OS.empty()), true, "overwrite")
		eq(svc:listOutfits(p)[2].count, 0, "isi ditimpa")
		eq(svc:deleteOutfit(p, a.id), true, "delete")
		eq(select(2, svc:deleteOutfit(p, a.id)), "NOT_FOUND", "delete dua kali")
		eq(#t.profile.Data.outfits, 1, "sisa 1")
		-- slot rusak -> INVALID (bukan error)
		t.profile.Data.outfits[1].o = { ov = 99 }
		eq(select(2, svc:getOutfit(p, b.id)), "INVALID", "slot rusak")
	end

	-- 11b. slot menyimpan LOOK: makeup ikut masuk & keluar lagi
	do
		local svc, t = setup()
		local p = player("K2", 172)
		svc:load(p)
		local mk = {
			face = { assetId = 800, slot = "face", textureId = "rbxassetid://1" },
			lip = { assetId = 801, slot = "lip", textureId = "rbxassetid://2" },
		}
		local a = svc:addOutfit(p, "Look", OS.wear(OS.empty(), 20, "Hat"), mk)
		assert(a, "add look")
		eq(a.makeup, 2, "ringkasan menghitung makeup")
		eq(a.count, 3, "1 item + 2 makeup")
		local state, rows = svc:getOutfitLook(p, a.id)
		assert(state, "look kembali")
		eq(#(rows :: any), 2, "dua baris makeup")
		eq((rows :: any)[1].slot, "face", "urutan slot")
		eq(state.accessories["20"] ~= nil, true, "outfit ikut")

		-- slot tanpa makeup (slot lama / disimpan tanpa makeup) -> baris kosong
		local b = svc:addOutfit(p, "Polos", OS.empty())
		assert(b, "add polos")
		eq(#(select(2, svc:getOutfitLook(p, b.id)) :: any), 0, "tanpa makeup")
		eq(svc:overwriteOutfit(p, b.id, OS.empty(), mk), true, "overwrite dengan makeup")
		eq(#(select(2, svc:getOutfitLook(p, b.id)) :: any), 2, "makeup masuk saat overwrite")
		eq(svc:overwriteOutfit(p, b.id, OS.empty()), true, "overwrite tanpa makeup")
		eq(#(select(2, svc:getOutfitLook(p, b.id)) :: any), 0, "makeup ikut hilang")
		eq(select(3, svc:getOutfitLook(p, 999)), "NOT_FOUND", "slot tidak ada")
		eq(#t.profile.Data.outfits, 2, "dua slot")
	end

	-- 12. wardrobe penuh
	do
		local svc = setup()
		local p = player("L", 18)
		svc:load(p)
		for _ = 1, Wardrobe.MAX_SLOTS do
			assert(svc:addOutfit(p, nil, OS.empty()), "isi")
		end
		eq(svc:outfitSlotInfo(p), true, "penuh")
		eq(select(2, svc:addOutfit(p, "x", OS.empty())), "FULL", "FULL")
	end

	-- 13. data versi lebih baru / profil tidak aktif: wardrobe tidak dibaca/ditulis
	do
		local future = { v = PlayerData.VERSION + 1, settings = {}, outfits = "format baru" }
		local svc, t = setup({ data = future })
		local p = player("M", 19)
		svc:load(p)
		eq(select(2, svc:listOutfits(p)), "NOT_LOADED", "newer: list")
		eq(select(2, svc:addOutfit(p, nil, OS.empty())), "NOT_LOADED", "newer: add")
		eq(select(2, svc:setSetting(p, "restoreOutfit", false)), "NOT_LOADED", "newer: setting")
		eq(t.profile.Data.outfits, "format baru", "data utuh")

		local svc2, t2 = setup()
		local p2 = player("N", 20)
		svc2:load(p2)
		t2.profile.released = true
		eq(select(2, svc2:addOutfit(p2, nil, OS.empty())), "NOT_LOADED", "tidak aktif: add")
		eq(select(2, svc2:deleteOutfit(p2, 1)), "NOT_LOADED", "tidak aktif: delete")
		eq(svc2:listOutfits(p2) ~= nil, true, "tidak aktif: masih bisa dibaca")
	end

	-- 14. favorit & "terakhir diubah" lewat service
	do
		local svc, t = setup()
		local p = player("O", 21)
		eq(select(2, svc:favoriteOutfit(p, 1, true)), "NOT_LOADED", "favorit sebelum load")
		svc:load(p)
		local a = svc:addOutfit(p, "A", OS.empty())
		assert(a, "add")
		eq(svc:favoriteOutfit(p, a.id, true), true, "favorit")
		eq(svc:listOutfits(p)[1].favorite, true, "summary favorit")
		eq(select(2, svc:favoriteOutfit(p, 99, true)), "NOT_FOUND", "favorit tidak ada")
		local entry = t.profile.Data.outfits[1]
		entry.u = 1 -- paksa lama
		svc:renameOutfit(p, a.id, "B")
		eq(entry.u > 1, true, "rename memperbarui u")
		entry.u = 1
		svc:overwriteOutfit(p, a.id, OS.empty())
		eq(entry.u > 1, true, "overwrite memperbarui u")
		entry.u = 1
		svc:favoriteOutfit(p, a.id, false)
		eq(entry.u, 1, "favorit tidak memperbarui u")
		eq(entry.f, nil, "favorit dihapus")
	end

	-- 15. folder: buat, ganti nama, isi, hapus
	do
		local svc, t = setup()
		local p = player("P", 22)
		eq(select(2, svc:listFolders(p)), "NOT_LOADED", "folder sebelum load")
		eq(svc:folderSlotInfo(p), nil, "slot info sebelum load")
		svc:load(p)
		eq(#svc:listFolders(p), 0, "belum ada folder")
		eq(svc:folderSlotInfo(p), false, "belum penuh")
		local fid = svc:addFolder(p, "Pesta")
		eq(fid, 1, "id folder pertama")
		eq(select(2, svc:addFolder(p, "pesta")), "DUPLICATE", "nama ganda")
		eq(svc:renameFolder(p, fid, "Pesta Malam"), true, "ganti nama")
		eq(select(2, svc:renameFolder(p, 99, "X")), "NOT_FOUND", "folder tidak ada")

		local a = svc:addOutfit(p, "A", OS.empty())
		local b = svc:addOutfit(p, "B", OS.empty())
		assert(a and b, "add outfit")
		eq(svc:setOutfitFolders(p, a.id, { fid }), true, "set folder outfit")
		eq(select(2, svc:setOutfitFolders(p, a.id, { 99 })), "BAD_ARG", "folder tidak ada")
		eq(svc:listOutfits(p)[2].folders[1], fid, "summary membawa folder")
		eq(svc:listFolders(p)[1].count, 1, "jumlah outfit di folder")

		local res = svc:applyFolder(p, { a.id, b.id }, fid, true)
		assert(res, "applyFolder")
		eq(res.changed, 1, "hanya B yang berubah")
		eq(svc:listFolders(p)[1].count, 2, "dua outfit di folder")
		eq(select(2, svc:applyFolder(p, { a.id }, 99, true)), "NOT_FOUND", "folder tidak ada")

		eq(svc:deleteFolder(p, fid), true, "hapus folder")
		eq(#svc:listFolders(p), 0, "folder hilang")
		eq(#t.profile.Data.outfits, 2, "outfit tetap ada")
		eq(t.profile.Data.outfits[1].g, nil, "outfit dilepas dari folder")
	end

	-- 16. hapus banyak outfit sekaligus & batas folder
	do
		local svc = setup()
		local p = player("Q", 23)
		eq(select(2, svc:deleteOutfits(p, { 1 })), "NOT_LOADED", "bulk sebelum load")
		svc:load(p)
		local ids = {}
		for i = 1, 4 do
			local o = svc:addOutfit(p, "O" .. i, OS.empty())
			assert(o, "add")
			ids[i] = o.id
		end
		eq(svc:deleteOutfits(p, { ids[1], ids[2], ids[2], 999 }), 2, "id ganda & hilang dilewati")
		eq(#svc:listOutfits(p), 2, "sisa 2")

		for i = 1, OutfitFolders.MAX_FOLDERS do
			assert(svc:addFolder(p, "F" .. i), "folder " .. i)
		end
		eq(svc:folderSlotInfo(p), true, "folder penuh")
		eq(select(2, svc:addFolder(p, "Lagi")), "FULL", "FULL")
	end

	print("PASS PlayerDataService.spec")
end
