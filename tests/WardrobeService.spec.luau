--!strict
-- Test WardrobeService dengan PlayerDataService ASLI (ProfileStore palsu), avatar & filter palsu.
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["WardrobeService.spec"])()  (jalankan dari server saat Play)
local Server = game:GetService("ServerScriptService"):WaitForChild("Server")
local WardrobeService = require(Server.Services.WardrobeService)
local PlayerDataService = require(Server.Services.PlayerDataService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Wardrobe = require(Shared.Domain.Wardrobe)
local OS = require(Shared.Domain.OutfitState)
local Log = require(Shared.Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function fakeStore()
	local store: any = {}
	function store.StartSessionAsync(_self: any, _key: string, _params: any)
		local p = { Data = {}, active = true, OnSessionEnd = {} }
		function p.OnSessionEnd.Connect() end
		function p.AddUserId() end
		function p.Reconcile() end
		function p.IsActive(self: any)
			return self.active
		end
		function p.EndSession(self: any)
			self.active = false
		end
		store.profile = p
		return p
	end
	return store
end

local function setup(opts: { filter: any?, noState: boolean? }?)
	local o = opts or {}
	local t = {
		state = if o.noState then nil else OS.wear(OS.empty(), 20, "Hat"),
		worn = {} :: { any },
		filtered = {} :: { string },
		wearCode = nil :: string?,
	}
	local store = fakeStore()
	local data = PlayerDataService.new({ store = store, kick = function() end })
	local avatar: any = {}
	function avatar.getState(_self: any, _player: any)
		return t.state
	end
	function avatar.wearOutfit(_self: any, _player: any, state: any)
		if t.wearCode then
			return false, t.wearCode
		end
		table.insert(t.worn, state)
		return true, nil
	end
	local itemsService: any = {}
	function itemsService.list(_self: any, state: any)
		t.listed = state
		if t.itemsFail then
			return false, { code = "FAILED" }
		end
		return true, { items = { { id = 20, name = "Topi", price = 50, isForSale = true } }, total = 50, missing = 0 }
	end
	local svc = WardrobeService.new({
		playerData = data,
		avatar = avatar,
		items = itemsService,
		filterName = o.filter or function(_player: any, text: string)
			table.insert(t.filtered, text)
			return true, text
		end,
	})
	local player = { Name = "P", UserId = 1, Parent = "Players" }
	return svc, t, data, player, store
end

return function()
	Log.setSink(function() end)

	-- 1. data belum dimuat -> NOT_LOADED
	do
		local svc, _, _, p = setup()
		eq(svc:handle(p, { op = "list" }).code, "NOT_LOADED", "list")
		eq(svc:handle(p, { op = "save" }).code, "NOT_LOADED", "save")
		eq(svc:handle(p, { op = "wear", id = 1 }).code, "NOT_LOADED", "wear")
	end

	-- 2. list kosong + setting
	local svc, t, data, p, store = setup()
	data:load(p)
	local res = svc:handle(p, { op = "list" })
	eq(res.ok, true, "list ok")
	eq(#res.outfits, 0, "kosong")
	eq(res.max, Wardrobe.MAX_SLOTS, "max")
	eq(res.settings.restoreOutfit, true, "setting")

	-- 3. save tanpa nama: nama bawaan, TIDAK lewat filter; balas daftar terbaru
	res = svc:handle(p, { op = "save" })
	eq(res.ok, true, "save ok")
	eq(res.outfit.name, "Outfit 1", "nama bawaan")
	eq(#res.outfits, 1, "daftar terbaru")
	eq(#t.filtered, 0, "tanpa filter")

	-- 4. save bernama: lewat filter; state diambil SETELAH filter
	local afterFilter = OS.wear(OS.empty(), 30, "Shirt")
	local svc2, t2, data2, p2 = setup({
		filter = function(_player: any, text: string)
			return true, text
		end,
	})
	data2:load(p2)
	local svc2Raw: any = svc2
	local filterOrig = svc2Raw._filter
	svc2Raw._filter = function(player: any, text: string)
		t2.state = afterFilter -- pemain ganti baju selama filter (yield)
		return filterOrig(player, text)
	end
	res = svc2:handle(p2, { op = "save", name = "Pesta" })
	eq(res.ok, true, "save bernama")
	eq(res.outfit.name, "Pesta", "nama")
	eq(res.outfit.thumbs[1], 30, "state terbaru yang disimpan")

	-- 5. filter: error -> FILTER_FAILED, nama berubah -> FILTERED; tidak ada yang disimpan
	local svc3, _, data3, p3, store3 = setup({
		filter = function(_player: any, text: string)
			if text == "boom" then
				error("TextService down")
			elseif text == "gagal" then
				return false, "503"
			end
			return true, string.rep("#", #text)
		end,
	})
	data3:load(p3)
	eq(svc3:handle(p3, { op = "save", name = "boom" }).code, "FILTER_FAILED", "filter error")
	eq(svc3:handle(p3, { op = "save", name = "gagal" }).code, "FILTER_FAILED", "filter false")
	eq(svc3:handle(p3, { op = "save", name = "kasar" }).code, "FILTERED", "kena filter")
	eq(#store3.profile.Data.outfits, 0, "tidak ada yang disimpan")
	eq(svc3:handle(p3, { op = "save" }).ok, true, "tanpa nama tetap bisa")
	eq(svc3:handle(p3, { op = "rename", id = 1, name = "kasar" }).code, "FILTERED", "rename kena filter")
	eq(store3.profile.Data.outfits[1].n, "Outfit 1", "nama tidak berubah")

	-- 6. avatar belum siap -> NOT_READY (sebelum filter)
	do
		local s4, t4, d4, p4 = setup({ noState = true })
		d4:load(p4)
		eq(s4:handle(p4, { op = "save", name = "x" }).code, "NOT_READY", "save tanpa state")
		eq(#t4.filtered, 0, "filter tidak dipanggil")
		eq(s4:handle(p4, { op = "overwrite", id = 1 }).code, "NOT_READY", "overwrite tanpa state")
	end

	-- 7. wear: pakai isi slot; NOTHING tetap ok; slot tidak ada -> NOT_FOUND
	res = svc:handle(p, { op = "wear", id = 1 })
	eq(res.ok, true, "wear ok")
	eq(#t.worn, 1, "wearOutfit dipanggil")
	eq(t.worn[1].accessories["20"].assetType, "Hat", "isi slot")
	t.wearCode = "NOTHING"
	eq(svc:handle(p, { op = "wear", id = 1 }).ok, true, "sudah dipakai = ok")
	t.wearCode = "NOT_READY"
	eq(svc:handle(p, { op = "wear", id = 1 }).code, "NOT_READY", "avatar belum siap")
	t.wearCode = nil
	eq(svc:handle(p, { op = "wear", id = 99 }).code, "NOT_FOUND", "slot tidak ada")

	-- 8. overwrite / rename / delete membalas daftar terbaru
	t.state = OS.wear(OS.empty(), 40, "Pants")
	res = svc:handle(p, { op = "overwrite", id = 1 })
	eq(res.ok, true, "overwrite")
	eq(res.outfits[1].thumbs[1], 40, "isi ditimpa")
	res = svc:handle(p, { op = "rename", id = 1, name = "Kerja" })
	eq(res.ok, true, "rename")
	eq(res.outfits[1].name, "Kerja", "nama baru")
	eq(t.filtered[1], "Kerja", "rename lewat filter")
	eq(svc:handle(p, { op = "rename", id = 99, name = "x" }).code, "NOT_FOUND", "rename tidak ada")
	res = svc:handle(p, { op = "delete", id = 1 })
	eq(res.ok, true, "delete")
	eq(#res.outfits, 0, "terhapus")
	eq(svc:handle(p, { op = "delete", id = 1 }).code, "NOT_FOUND", "delete dua kali")

	-- 8b. favorite membalas daftar terbaru
	res = svc:handle(p, { op = "save" })
	local favId = res.outfit.id
	res = svc:handle(p, { op = "favorite", id = favId, value = true })
	eq(res.ok, true, "favorite")
	eq(res.outfits[1].favorite, true, "favorit di daftar")
	eq(svc:handle(p, { op = "favorite", id = 999, value = true }).code, "NOT_FOUND", "favorite tidak ada")
	svc:handle(p, { op = "delete", id = favId })

	-- 8c. items: nama & harga item di dalam outfit
	res = svc:handle(p, { op = "save" })
	local itemsId = res.outfit.id
	res = svc:handle(p, { op = "items", id = itemsId })
	eq(res.ok, true, "items ok")
	eq(res.total, 50, "total harga")
	eq(res.items[1].name, "Topi", "item pertama")
	eq(t.listed.accessories ~= nil, true, "state dikirim ke OutfitItemsService")
	eq(svc:handle(p, { op = "items", id = 999 }).code, "NOT_FOUND", "items slot tidak ada")
	t.itemsFail = true
	eq(svc:handle(p, { op = "items", id = itemsId }).code, "FAILED", "items gagal")
	t.itemsFail = nil
	svc:handle(p, { op = "delete", id = itemsId })

	-- 9. setSetting
	res = svc:handle(p, { op = "setSetting", key = "restoreOutfit", value = false })
	eq(res.ok, true, "setSetting")
	eq(res.settings.restoreOutfit, false, "setting baru dikirim")
	eq(store.profile.Data.settings.restoreOutfit, false, "tersimpan")

	-- 10. penuh -> FULL sebelum filter
	for _ = 1, Wardrobe.MAX_SLOTS do
		assert(svc:handle(p, { op = "save" }).ok, "isi slot")
	end
	local before = #t.filtered
	eq(svc:handle(p, { op = "save", name = "lebih" }).code, "FULL", "penuh")
	eq(#t.filtered, before, "filter tidak dipanggil saat penuh")

	-- 11. satu permintaan per pemain: yang kedua saat filter berjalan -> BUSY
	do
		local s5, _, d5, p5 = setup()
		d5:load(p5)
		local inner: any = nil
		local s5Raw: any = s5
		s5Raw._filter = function(_player: any, text: string)
			inner = s5:handle(p5, { op = "delete", id = 1 }) -- "bersamaan"
			return true, text
		end
		eq(s5:handle(p5, { op = "save", name = "A" }).ok, true, "save pertama")
		eq(inner.code, "BUSY", "kedua ditolak")
		eq(s5:handle(p5, { op = "list" }).ok, true, "list tidak dikunci")
		eq(s5:handle(p5, { op = "delete", id = 1 }).ok, true, "kunci dilepas")
	end

	-- 12. error tak terduga -> FAILED, kunci dilepas; op asing -> BAD_ARG
	do
		local s6, _, d6, p6 = setup()
		d6:load(p6)
		local s6Raw: any = s6
		s6Raw._data.deleteOutfit = function()
			error("boom")
		end
		eq(s6:handle(p6, { op = "delete", id = 1 }).code, "FAILED", "error")
		eq(s6:handle(p6, { op = "save" }).ok, true, "kunci dilepas setelah error")
		eq(s6:handle(p6, { op = "hack" }).code, "BAD_ARG", "op asing")
		s6:forget(p6)
	end

	print("PASS WardrobeService.spec")
end
