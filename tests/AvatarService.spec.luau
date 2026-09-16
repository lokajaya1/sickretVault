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
	[5] = "NeckAccessory",
	[6] = "NeckAccessory",
}

-- bundle palsu (bentuk BundleInfo hasil BundleService)
local BUNDLES: { [number]: any } = {
	[700] = {
		bundleId = 700,
		name = "Paket Tes",
		parts = {
			{ assetId = 701, name = "Topi", assetType = "Hat", kind = "accessory", slot = "Hat" },
			{ assetId = 702, name = "Badan", assetType = "Torso", kind = "bodyPart", slot = "Torso" },
			{ assetId = 703, name = "Aneh", assetType = "Unknown", kind = "unknown" },
		},
		outfitScales = { HeightScale = 1.2 },
		unknownItems = {},
	},
	[710] = {
		bundleId = 710,
		name = "Tak Didukung",
		parts = { { assetId = 711, name = "Aneh", assetType = "Unknown", kind = "unknown" } },
		unknownItems = {},
	},
}

local function setup(opts: { baselineFails: boolean?, noBundles: boolean? }?)
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
	local rules = {}
	function rules.maxPerType(_self: any)
		return { NeckAccessory = 1 }
	end
	local bundles = {}
	function bundles.get(_self: any, id: number)
		if id == 720 then
			return false, { code = "FAILED", message = "HTTP 500" }
		end
		local b = BUNDLES[id]
		if b == nil then
			return false, { code = "NOT_FOUND", message = "x" }
		end
		return true, b
	end
	local svc = AvatarService.new({
		api = api,
		itemInfo = itemInfo,
		rules = rules,
		bundles = if o.noBundles then nil else bundles,
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

	-- 4b. batas per tipe (Neck=1): neck kedua mengganti yang pertama
	assert(svc:handle(player, { op = "wear", assetId = 5 }), "wear neck 5")
	assert(svc:handle(player, { op = "wear", assetId = 6 }), "wear neck 6")
	eq((svc:getState(player) :: any).accessories["5"], nil, "neck 5 diganti")
	assert((svc:getState(player) :: any).accessories["6"], "neck 6 terpasang")
	assert(svc:handle(player, { op = "undo" }), "undo neck 6")
	assert((svc:getState(player) :: any).accessories["5"], "undo mengembalikan neck 5")
	assert(svc:handle(player, { op = "remove", assetId = 5 }), "lepas neck 5")

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

	-- 8. bundle: sebagian part, semua part, error, lepas bundle
	assert(svc:handle(player, { op = "wearBundle", bundleId = 700, partIds = { 701 } }), "pakai topi bundle saja")
	local sb = svc:getState(player) :: any
	eq(sb.accessories["701"].source, 700, "topi bundle ber-source")
	eq(sb.bodyParts.Torso.id, 0, "torso belum dipakai")
	assert(svc:handle(player, { op = "wearBundle", bundleId = 700 }), "pakai semua part")
	sb = svc:getState(player) :: any
	eq(sb.bodyParts.Torso.id, 702, "torso bundle")
	eq(sb.bodyParts.Torso.source, 700, "torso ber-source")
	eq(sb.scales.HeightScale == 1.2, false, "skala bundle tidak dipakai tanpa useBundleScales")
	eq(codeOf(svc:handle(player, { op = "wearBundle", bundleId = 700 })), "NOTHING", "bundle sudah dipakai")
	eq(codeOf(svc:handle(player, { op = "wearBundle", bundleId = 710 })), "UNSUPPORTED_TYPE", "tanpa part didukung")
	eq(
		codeOf(svc:handle(player, { op = "wearBundle", bundleId = 700, partIds = { 703 } })),
		"UNSUPPORTED_TYPE",
		"partIds hanya part tak dikenal"
	)
	eq(codeOf(svc:handle(player, { op = "wearBundle", bundleId = 720 })), "FAILED", "api gagal")
	eq(codeOf(svc:handle(player, { op = "wearBundle", bundleId = 999 })), "NOT_FOUND", "bundle tidak ada")
	assert(svc:handle(player, { op = "removeBundle", bundleId = 700 }), "lepas bundle")
	sb = svc:getState(player) :: any
	eq(sb.accessories["701"], nil, "topi bundle dilepas")
	eq(sb.bodyParts.Torso.id, 0, "torso kembali ke baseline")
	eq(sb.bodyParts.Head.id, 777, "part lain tidak tersentuh")
	eq(codeOf(svc:handle(player, { op = "removeBundle", bundleId = 700 })), "NOTHING", "lepas dua kali")
	assert(
		svc:handle(player, { op = "wearBundle", bundleId = 700, useBundleScales = true }),
		"pakai dengan skala bundle"
	)
	eq((svc:getState(player) :: any).scales.HeightScale, 1.2, "skala bundle dipakai")
	assert(svc:handle(player, { op = "undo" }), "undo skala bundle")
	eq((svc:getState(player) :: any).accessories["701"], nil, "undo melepas bundle")
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

	-- 14. tanpa BundleService -> NOT_IMPLEMENTED
	local svc3 = setup({ noBundles = true })
	assert(svc3:load(player), "load tanpa bundle")
	eq(codeOf(svc3:handle(player, { op = "wearBundle", bundleId = 700 })), "NOT_IMPLEMENTED", "bundle mati")

	print("PASS AvatarService.spec")
end
