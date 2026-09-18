--!strict
-- Test AssetDecal dengan InsertService PALSU (tanpa internet, tanpa Studio).
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["AssetDecal.spec"])()  (jalankan dari server)
local ServerScriptService = game:GetService("ServerScriptService")
local AssetDecal = require(ServerScriptService:WaitForChild("Server").Gateways.AssetDecal)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Log = require(Shared.Util.Log)

local TEX = "rbxassetid://98880692903650"
local ID_OK = 133520807586498
local ID_MISSING = 404
local ID_FLAKY = 429
local ID_NO_DECAL = 777

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

-- Model palsu: hanya menyediakan dua method yang dipakai gateway.
local function fakeModel(texture: string?, destroyed: { n: number }): any
	local model = {}
	function model.FindFirstChildWhichIsA(_self: any, className: string, _recursive: boolean?): any
		if className == "Decal" and texture ~= nil then
			return { Texture = texture }
		end
		return nil
	end
	function model.Destroy(_self: any)
		destroyed.n += 1
	end
	return model
end

return function()
	Log.setSink(function() end) -- bungkam log warn saat test

	local calls = { load = 0, sleep = 0 }
	local destroyed = { n = 0 }
	local flakyLeft = 0

	local fakeInsert = {}
	function fakeInsert.LoadAsset(_self: any, id: number): any
		calls.load += 1
		if id == ID_MISSING then
			error("Asset not found")
		end
		if id == ID_FLAKY then
			if flakyLeft > 0 then
				flakyLeft -= 1
				error("HTTP 429 (Too Many Requests)")
			end
			return fakeModel(TEX, destroyed)
		end
		if id == ID_NO_DECAL then
			return fakeModel(nil, destroyed)
		end
		return fakeModel(TEX, destroyed)
	end

	local function newApi(): any
		calls.load = 0
		calls.sleep = 0
		destroyed.n = 0
		return AssetDecal.new({
			insertService = fakeInsert,
			retry = {
				baseDelay = 0,
				sleep = function()
					calls.sleep += 1
				end,
			},
			sleep = function()
				calls.sleep += 1
			end,
		})
	end

	-- 1. jalur normal: texture didapat, model hasil LoadAsset dibuang
	local api = newApi()
	local ok, texture = api:getMakeupTexture(ID_OK)
	eq(ok, true, "LoadAsset berhasil")
	eq(texture, TEX, "texture id dikembalikan")
	eq(calls.load, 1, "LoadAsset dipanggil sekali")
	eq(destroyed.n, 1, "model dibuang setelah dibaca")

	-- 2. cache: id yang sama tidak memanggil LoadAsset lagi (~0,5 detik per panggilan)
	local ok2, texture2 = api:getMakeupTexture(ID_OK)
	eq(ok2, true, "hit cache tetap sukses")
	eq(texture2, TEX, "texture sama")
	eq(calls.load, 1, "tidak ada LoadAsset kedua")

	-- 3. id cacat ditolak sebelum menyentuh InsertService
	for _, bad in { 0, -5, 1.5, "133" } :: { any } do
		local okBad, err = api:getMakeupTexture(bad :: any)
		eq(okBad, false, "id cacat ditolak: " .. tostring(bad))
		eq(err.code, "BAD_ARG", "kode BAD_ARG untuk " .. tostring(bad))
	end
	eq(calls.load, 1, "id cacat tidak memanggil LoadAsset")

	-- 4. gagal permanen: tidak diulang, dan diingat supaya tidak dicoba lagi
	api = newApi()
	local okMiss, errMiss = api:getMakeupTexture(ID_MISSING)
	eq(okMiss, false, "aset hilang gagal")
	eq(errMiss.code, "NOT_FOUND", "kode NOT_FOUND")
	eq(errMiss.assetId, ID_MISSING, "error menyebut id")
	eq(calls.load, 1, "gagal permanen tidak diulang")
	local okMiss2, errMiss2 = api:getMakeupTexture(ID_MISSING)
	eq(okMiss2, false, "tetap gagal dari cache")
	eq(errMiss2.code, "NOT_FOUND", "kode dari cache")
	eq(calls.load, 1, "tidak memanggil LoadAsset lagi")

	-- 5. gagal sementara: diulang, lalu berhasil
	api = newApi()
	flakyLeft = 2
	local okFlaky, texFlaky = api:getMakeupTexture(ID_FLAKY)
	eq(okFlaky, true, "berhasil setelah diulang")
	eq(texFlaky, TEX, "texture dari percobaan terakhir")
	eq(calls.load, 3, "tiga kali percobaan")

	-- 6. gagal sementara sampai habis: TIDAK di-cache, boleh dicoba lagi nanti
	api = newApi()
	flakyLeft = 99
	local okOut, errOut = api:getMakeupTexture(ID_FLAKY)
	eq(okOut, false, "habis percobaan")
	eq(errOut.code, "FAILED", "kode FAILED")
	eq(calls.load, 3, "berhenti di 3 percobaan")
	flakyLeft = 0
	local okAgain = api:getMakeupTexture(ID_FLAKY)
	eq(okAgain, true, "boleh dicoba lagi karena tidak di-cache")
	eq(calls.load, 4, "percobaan baru terjadi")

	-- 7. aset tanpa Decal (mis. AvatarBackground) ditolak jelas dan diingat
	api = newApi()
	local okNo, errNo = api:getMakeupTexture(ID_NO_DECAL)
	eq(okNo, false, "aset tanpa Decal gagal")
	eq(errNo.code, "NO_DECAL", "kode NO_DECAL")
	eq(destroyed.n, 1, "model tetap dibuang")
	local okNo2 = api:getMakeupTexture(ID_NO_DECAL)
	eq(okNo2, false, "tetap gagal")
	eq(calls.load, 1, "hasil NO_DECAL diingat")

	-- 8. permintaan yang sedang berjalan: penunggu memakai hasilnya, tanpa LoadAsset kedua
	api = newApi()
	api._inflight[ID_OK] = true
	local released = 0
	api._sleep = function()
		released += 1
		if released >= 2 then
			api._inflight[ID_OK] = nil
			api._textures:set(ID_OK, { texture = TEX })
		end
	end
	local okWait, texWait = api:getMakeupTexture(ID_OK)
	eq(okWait, true, "penunggu dapat hasil")
	eq(texWait, TEX, "texture dari permintaan yang sedang berjalan")
	eq(calls.load, 0, "penunggu tidak memanggil LoadAsset")

	-- 9. clear membuang cache
	api = newApi()
	api:getMakeupTexture(ID_OK)
	api:clear()
	api:getMakeupTexture(ID_OK)
	eq(calls.load, 2, "setelah clear, LoadAsset dipanggil lagi")

	-- 10. penanda error permanen
	eq(AssetDecal.isPermanentError("Asset not found"), true, "not found permanen")
	eq(
		AssetDecal.isPermanentError("InsertService cannot be used to load assets from the client"),
		true,
		"client ditolak permanen"
	)
	eq(AssetDecal.isPermanentError("HTTP 429 (Too Many Requests)"), false, "429 boleh diulang")

	print("PASS AssetDecal.spec")
end
