--!strict
-- Test BundleService dengan API & ItemInfo PALSU (data asli dari fixtures/BundleSamples.RealBody).
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["BundleService.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local BundleService = require(ServerScriptService:WaitForChild("Server").Services.BundleService)
local Samples = require(script.Parent.fixtures.BundleSamples)
local Log = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function partById(info: any, id: number): any
	for _, p in info.parts do
		if p.assetId == id then
			return p
		end
	end
	return nil
end

local REAL = Samples.RealBody

local function setup(opts: { infoFails: boolean?, outfitFails: boolean?, bundleError: string? }?)
	local o = opts or {}
	local calls = { bundle = 0, outfit = 0, info = 0 }
	local api = {}
	function api.getBundleDetails(_self: any, id: number)
		calls.bundle += 1
		if o.bundleError then
			return false, { code = o.bundleError, message = "x" }
		end
		if id == REAL.raw.Id then
			return true, REAL.raw
		elseif id == Samples.Invalid.noAssets.Id then
			return true, Samples.Invalid.noAssets
		end
		return false, { code = "NOT_FOUND", message = "HTTP 404" }
	end
	function api.getOutfitDetails(_self: any, id: number)
		calls.outfit += 1
		if o.outfitFails then
			return false, { code = "FAILED", message = "HTTP 500" }
		end
		local d = REAL.outfits[string.format("%d", id)]
		if d == nil then
			return false, { code = "NOT_FOUND", message = "x" }
		end
		return true, d
	end
	local itemInfo = {}
	function itemInfo.getMany(_self: any, ids: { number })
		calls.info += 1
		if o.infoFails then
			return false, { code = "FAILED", message = "HTTP 500" }
		end
		local out = {}
		for _, id in ids do
			local ty = REAL.assetTypes[id]
			if ty and id ~= 99377734100872 then -- Torso sengaja "tidak dikembalikan" -> pakai cadangan
				out[id] = { assetId = id, assetType = ty }
			end
		end
		return true, out
	end
	local now = 0
	local svc = BundleService.new({
		api = api,
		itemInfo = itemInfo,
		clock = function()
			return now
		end,
	})
	return svc, calls, function(dt: number)
		now += dt
	end
end

return function()
	Log.setSink(function() end) -- sembunyikan warn yang memang diharapkan

	-- 1. adapter skala
	local sc = BundleService.adaptScales({ Height = 1.05, BodyType = 0.3, Bogus = 9 }) :: any
	eq(sc.HeightScale, 1.05, "Height -> HeightScale")
	eq(sc.BodyTypeScale, 0.3, "BodyType -> BodyTypeScale")
	eq(sc.Bogus, nil, "kunci asing dibuang")
	eq(BundleService.adaptScales({}), nil, "kosong -> nil")
	eq(BundleService.adaptScales("x"), nil, "bukan tabel -> nil")

	-- 2. bundle asli: 7 part, tipe terisi (Torso dari cadangan), outfit Avatar + skala
	local svc, calls, advance = setup()
	local ok, info = svc:get(REAL.raw.Id)
	assert(ok, "get ok")
	eq(#info.parts, 7, "7 part (mood tidak dobel)")
	eq(partById(info, 99377734100872).assetType, "Torso", "tipe cadangan Torso")
	eq(partById(info, 99377734100872).kind, "bodyPart", "Torso bodyPart")
	eq(partById(info, 110446883733723).slot, "Head", "DynamicHead -> Head")
	eq(partById(info, 14618207727).kind, "animation", "mood = animasi")
	eq(info.outfitId, 6016977565474900, "outfit Avatar dipilih")
	assert(info.outfitScales, "skala ada")
	eq(info.outfitScales.BodyTypeScale, 0, "BodyTypeScale 0")
	eq(info.outfitScales.HeightScale, 1, "HeightScale 1")
	eq(calls.outfit, 1, "berhenti di outfit Avatar pertama")

	-- 3. cache: panggilan kedua tidak memanggil API
	local ok2, info2 = svc:get(REAL.raw.Id)
	assert(ok2 and info2 == info, "dari cache")
	eq(calls.bundle, 1, "api bundle sekali")
	advance(4000) -- lewat TTL
	assert(svc:get(REAL.raw.Id), "setelah TTL")
	eq(calls.bundle, 2, "api dipanggil lagi setelah TTL")

	-- 4. id salah / tidak ada / tanpa aset
	local bad, e = svc:get(0)
	eq(bad, false, "id 0")
	eq(e.code, "BAD_ARG", "BAD_ARG")
	local nf, e2 = svc:get(555)
	eq(nf, false, "tidak ada")
	eq(e2.code, "NOT_FOUND", "NOT_FOUND")
	local before = calls.bundle
	svc:get(555)
	eq(calls.bundle, before, "miss di-cache")
	local na, e3 = svc:get(Samples.Invalid.noAssets.Id)
	eq(na, false, "tanpa aset")
	eq(e3.code, "NOT_FOUND", "tanpa aset -> NOT_FOUND")

	-- 5. API gagal sementara -> FAILED, TIDAK di-cache
	local svcF, callsF = setup({ bundleError = "FAILED" })
	local f, e4 = svcF:get(REAL.raw.Id)
	eq(f, false, "gagal")
	eq(e4.code, "FAILED", "FAILED")
	svcF:get(REAL.raw.Id)
	eq(callsF.bundle, 2, "FAILED dicoba lagi")

	-- 6. ItemInfo & outfit gagal -> tetap jalan (tipe cadangan, tanpa skala)
	local svcI = setup({ infoFails = true, outfitFails = true })
	local okI, infoI = svcI:get(REAL.raw.Id)
	assert(okI, "tetap ok")
	eq(partById(infoI, 108248819544910).assetType, "RightArm", "tipe cadangan")
	eq(infoI.outfitScales, nil, "tanpa skala")
	eq(infoI.outfitId, 6016977565474900, "outfitId = UserOutfit pertama")

	Log.setSink(nil)
	print("PASS BundleService.spec")
end
