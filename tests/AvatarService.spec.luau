--!strict
-- Test AvatarService dengan API, ItemInfo, dan engine PALSU (tanpa internet, tanpa Studio).
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["AvatarService.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local AvatarService = require(ServerScriptService:WaitForChild("Server").Services.AvatarService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local OutfitState = require(Shared.Domain.OutfitState)
local Log = require(Shared.Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

-- ambil kode error dari (ok, code)
local function codeOf(_ok: boolean, code: string?): string?
	return code
end

local TYPES: { [number]: string } = {
	[1] = "Hat",
	[2] = "JacketAccessory",
	[3] = "Shirt",
	[4] = "TShirtAccessory",
}

local function setup(opts: { baselineFails: boolean? }?)
	local o = opts or {}
	local t = {
		states = {} :: { any },
		errors = {} :: { string },
		applied = {} :: { any },
		applyFail = false,
		timers = {} :: { () -> () },
		humanoid = {} :: any,
		onApply = nil :: (() -> ())?,
	}
	local api = {}
	function api.getDescriptionFromUserId(_self: any, _userId: number)
		if o.baselineFails then
			return false, { code = "FAILED", message = "HTTP 500" }
		end
		return true, "DESC_ASLI"
	end
	function api.applyDescription(_self: any, humanoid: any, desc: any)
		assert(humanoid == t.humanoid, "humanoid benar")
		if t.applyFail then
			return false, { code = "FAILED", message = "moderasi" }
		end
		table.insert(t.applied, desc)
		if t.onApply then
			t.onApply()
		end
		return true, nil
	end
	local itemInfo = {}
	function itemInfo.get(_self: any, id: number)
		local ty = TYPES[id]
		if ty == nil then
			return false, { code = "NOT_FOUND", message = "x" }
		end
		return true, { assetId = id, assetType = ty }
	end
	local svc = AvatarService.new({
		api = api,
		itemInfo = itemInfo,
		onState = function(_p: any, s: any)
			table.insert(t.states, s)
		end,
		onError = function(_p: any, code: string)
			table.insert(t.errors, code)
		end,
		build = function(s: any)
			return s -- "description" palsu = state itu sendiri
		end,
		fromDescription = function(desc: any)
			assert(desc == "DESC_ASLI", "desc asli diteruskan")
			local s = OutfitState.empty()
			s.bodyParts.Head = { id = 777 }
			s.classic.Shirt = { id = 888 }
			return s
		end,
		getHumanoid = function(_p: any)
			return t.humanoid
		end,
		delay = function(_s: number, fn: () -> ())
			table.insert(t.timers, fn)
		end,
	})
	function t.flushTimers()
		local list = t.timers
		t.timers = {}
		for _, fn in list do
			fn()
		end
	end
	return svc, t
end

return function()
	Log.setSink(function() end)
	local player = { UserId = 1, Name = "Tester" }

	-- 1. belum load -> NOT_READY
	local svc, t = setup()
	local ok, code = svc:handle(player, { op = "wear", assetId = 1 })
	eq(ok, false, "belum siap")
	eq(code, "NOT_READY", "kode NOT_READY")

	-- 2. load: baseline dari avatar asli, state dikirim
	assert(svc:load(player), "load ok")
	eq(#t.states, 1, "state awal dikirim")
	eq((svc:getState(player) :: any).bodyParts.Head.id, 777, "baseline Head")

	-- 3. wear: beberapa intent beruntun -> satu apply (debounce)
	assert(svc:handle(player, { op = "wear", assetId = 1 }), "wear topi")
	assert(svc:handle(player, { op = "wear", assetId = 2 }), "wear jaket")
	eq(#t.timers, 1, "hanya satu timer debounce")
	t.flushTimers()
	eq(#t.applied, 1, "satu apply")
	assert(t.applied[1].accessories["1"] and t.applied[1].accessories["2"], "apply berisi topi+jaket")

	-- 4. wear ulang / id asing
	eq(codeOf(svc:handle(player, { op = "wear", assetId = 1 })), "NOTHING", "sudah dipakai")
	eq(codeOf(svc:handle(player, { op = "wear", assetId = 99 })), "NOT_FOUND", "id asing")

	-- 5. remove classic -> kembali ke baseline, bukan 0
	assert(svc:handle(player, { op = "wear", assetId = 3 }), "wear baju")
	eq((svc:getState(player) :: any).classic.Shirt.id, 3, "baju terpasang")
	assert(svc:handle(player, { op = "remove", assetId = 3 }), "remove baju")
	eq((svc:getState(player) :: any).classic.Shirt.id, 888, "baju kembali ke baseline")
	eq(codeOf(svc:handle(player, { op = "remove", assetId = 3 })), "NOTHING", "remove dua kali")

	-- 6. undo / redo
	assert(svc:handle(player, { op = "undo" }), "undo")
	eq((svc:getState(player) :: any).classic.Shirt.id, 3, "undo -> baju lagi")
	assert(svc:handle(player, { op = "redo" }), "redo")
	eq((svc:getState(player) :: any).classic.Shirt.id, 888, "redo -> baseline")
	eq(codeOf(svc:handle(player, { op = "redo" })), "NOTHING", "redo kosong")

	-- 7. layer order
	assert(svc:handle(player, { op = "setLayerOrder", assetId = 2, order = 50 }), "order jaket")
	eq((svc:getState(player) :: any).accessories["2"].order, 50, "order tersimpan")
	eq(
		codeOf(svc:handle(player, { op = "setLayerOrder", assetId = 1, order = 5 })),
		"NOTHING",
		"topi rigid tak punya order"
	)

	-- 8. bundle belum ada
	eq(codeOf(svc:handle(player, { op = "wearBundle", bundleId = 5 })), "NOT_IMPLEMENTED", "bundle menyusul")
	t.flushTimers()

	-- 9. apply gagal -> rollback + APPLY_FAILED
	local before = svc:getState(player)
	t.applyFail = true
	assert(svc:handle(player, { op = "wear", assetId = 4 }), "wear kaos")
	t.flushTimers()
	eq(t.errors[1], "APPLY_FAILED", "error dikirim")
	eq((svc:getState(player) :: any).accessories["4"], nil, "kaos di-rollback")
	eq(svc:getState(player), before, "state kembali ke yang terakhir berhasil")
	t.applyFail = false

	-- 10. respawn: outfit berbeda dari baseline -> apply ulang
	local count = #t.applied
	svc:onRespawn(player)
	t.flushTimers()
	eq(#t.applied, count + 1, "apply ulang saat respawn")

	-- 10b. respawn SAAT apply berjalan -> hasil lama diabaikan, apply ulang ke karakter baru
	assert(svc:handle(player, { op = "wear", assetId = 3 }), "wear baju (respawn test)")
	local respawned = false
	t.onApply = function()
		if not respawned then
			respawned = true
			svc:onRespawn(player)
		end
	end
	count = #t.applied
	t.flushTimers()
	t.onApply = nil
	eq(#t.applied, count + 2, "apply diulang untuk karakter baru")
	t.flushTimers() -- timer dari onRespawn: tampilan sudah sama -> tidak apply lagi
	eq(#t.applied, count + 2, "tidak ada apply ketiga")

	-- 11. reset -> baseline; respawn berikutnya tidak perlu apply
	assert(svc:handle(player, { op = "reset" }), "reset")
	t.flushTimers()
	eq((svc:getState(player) :: any).accessories["1"], nil, "reset lepas topi")
	eq(codeOf(svc:handle(player, { op = "reset" })), "NOTHING", "reset dua kali")
	count = #t.applied
	svc:onRespawn(player)
	eq(#t.timers, 0, "respawn dengan baseline tidak menjadwalkan apply")

	-- 12. detach: timer lama tidak apa-apa, intent ditolak
	assert(svc:handle(player, { op = "wear", assetId = 1 }), "wear sebelum keluar")
	svc:detach(player)
	t.flushTimers()
	eq(#t.applied, count, "tidak apply setelah keluar")
	eq(codeOf(svc:handle(player, { op = "wear", assetId = 1 })), "NOT_READY", "sesi hilang")

	-- 13. avatar asli gagal diambil -> tetap siap dengan state kosong
	local svc2, t2 = setup({ baselineFails = true })
	assert(svc2:load(player), "load fallback")
	eq((svc2:getState(player) :: any).bodyParts.Head.id, 0, "baseline kosong")
	eq(#t2.states, 1, "state tetap dikirim")

	print("PASS AvatarService.spec")
end
