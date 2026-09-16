--!strict
-- Test PlayerDataService dengan ProfileStore PALSU.
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["PlayerDataService.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerDataService = require(ServerScriptService:WaitForChild("Server").Services.PlayerDataService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local PlayerData = require(Shared.Domain.PlayerData)
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

	print("PASS PlayerDataService.spec")
end
