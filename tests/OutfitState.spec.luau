--!strict
-- Studio: require(game.ReplicatedStorage.Tests["OutfitState.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local OS = require(Shared.Domain.OutfitState)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	local base = OS.empty()
	base.bodyParts.Head = { id = 111 }

	-- 1. layered order: kaos di bawah jaket
	local s = OS.wear(base, 1, "JacketAccessory")
	s = OS.wear(s, 2, "TShirtAccessory")
	assert(s.accessories["1"].order > s.accessories["2"].order, "jacket harus di luar kaos")

	-- 2. sepatu kiri diganti, bukan ditumpuk
	s = OS.wear(s, 10, "LeftShoeAccessory")
	s = OS.wear(s, 11, "LeftShoeAccessory")
	eq(s.accessories["10"], nil, "sepatu lama dilepas")
	assert(s.accessories["11"], "sepatu baru terpasang")

	-- 3. tipe tak dikenal ditolak tanpa mengubah state
	local same, err = OS.wear(s, 99, "Gear")
	eq(same, s, "state sama")
	eq(err, "UNSUPPORTED_TYPE", "kode error")

	-- 4. coba sebagian bundle: hanya kepala + animasi lari
	local parts = {
		{ assetId = 500, name = "Head", assetType = "DynamicHead", kind = "bodyPart", slot = "Head" },
		{ assetId = 501, name = "Torso", assetType = "Torso", kind = "bodyPart", slot = "Torso" },
		{
			assetId = 502,
			name = "Run",
			assetType = "RunAnimation",
			kind = "animation",
			slot = "RunAnimation",
		},
	}
	local b = OS.wearBundle(base, 9000, parts, { 500, 502 })
	eq(b.bodyParts.Head.id, 500, "head dari bundle")
	eq(b.bodyParts.Torso.id, 0, "torso tidak ikut")
	eq(b.animations.RunAnimation.source, 9000, "sumber bundle dicatat")

	-- 5. part yang tidak ada di bundle diabaikan (client tidak bisa menyelundupkan id)
	local sneaky = OS.wearBundle(base, 9000, parts, { 424242 })
	eq(#OS.wornAssetIds(sneaky), 1, "hanya head baseline yang terpakai")

	-- 6. lepas bundle -> kembali ke baseline
	local r = OS.removeBundle(b, 9000, base)
	eq(r.bodyParts.Head.id, 111, "head kembali ke avatar asli")
	eq(r.animations.RunAnimation.id, 0, "animasi kembali default")

	-- 7. lepas satu part bundle tidak menyentuh part lain
	local r2 = OS.remove(b, 502, base)
	eq(r2.bodyParts.Head.id, 500, "head bundle tetap")
	eq(r2.animations.RunAnimation.id, 0, "run dilepas")

	-- 7b. classic: lepas baju coba -> baseline; lepas baju baseline -> kosong (id 0)
	local cb = OS.empty()
	cb.classic.Shirt = { id = 888 }
	local tryOn = OS.clone(cb)
	tryOn.classic.Shirt = { id = 3 }
	eq(OS.remove(tryOn, 3, cb).classic.Shirt.id, 888, "baju coba -> baju asal")
	eq(OS.remove(cb, 888, cb).classic.Shirt.id, 0, "baju asal -> kosong")
	-- body part baseline tetap tidak bisa dikosongkan
	eq(OS.remove(base, 111, base).bodyParts.Head.id, 111, "kepala asal tetap")

	-- 8. immutability
	eq(base.bodyParts.Head.id, 111, "baseline tidak berubah")
	eq(b.bodyParts.Head.id, 500, "state lama tidak berubah setelah remove")

	-- 9. batas per tipe: Hat=3 -> topi ke-4 mengganti yang TERTUA; Neck=1 -> diganti
	local limits = { Hat = 3, NeckAccessory = 1, FaceAccessory = 0 }
	local h = OS.empty()
	h.accessories["70"] = { assetId = 70, assetType = "Hat", isLayered = false } -- avatar asli (tanpa seq)
	h = OS.wear(h, 71, "Hat", nil, limits)
	h = OS.wear(h, 72, "Hat", nil, limits)
	eq(h.accessories["70"] ~= nil, true, "3 topi masih muat")
	h = OS.wear(h, 73, "Hat", nil, limits)
	eq(h.accessories["70"], nil, "topi avatar asli (tertua) diganti")
	assert(h.accessories["71"] and h.accessories["72"] and h.accessories["73"], "3 topi terbaru")
	h = OS.wear(h, 74, "Hat", nil, limits)
	eq(h.accessories["71"], nil, "topi 71 (tertua berikutnya) diganti")
	h = OS.wear(h, 80, "NeckAccessory", nil, limits)
	h = OS.wear(h, 81, "NeckAccessory", nil, limits)
	eq(h.accessories["80"], nil, "neck lama diganti")
	assert(h.accessories["81"], "neck baru terpasang")
	local unchanged, e9 = OS.wear(h, 90, "FaceAccessory", nil, limits)
	eq(unchanged, h, "tipe batas 0 tidak mengubah state")
	eq(e9, "LIMIT_TYPE", "kode LIMIT_TYPE")
	local free = OS.wear(h, 91, "BackAccessory", nil, limits)
	assert(free.accessories["91"], "tipe tanpa batas tetap bisa dipakai")

	-- 10. bundle meneruskan batas per tipe: 2 topi dari bundle, Hat=1 -> hanya topi terakhir
	local hats = {
		{ assetId = 95, name = "Topi A", assetType = "Hat", kind = "accessory", slot = "Hat" },
		{ assetId = 96, name = "Topi B", assetType = "Hat", kind = "accessory", slot = "Hat" },
	}
	local hb = OS.wearBundle(OS.empty(), 9100, hats, nil, nil, { Hat = 1 })
	eq(hb.accessories["95"], nil, "topi bundle pertama diganti")
	eq(hb.accessories["96"].source, 9100, "topi bundle kedua terpasang dengan source")
	local hb2 = OS.wearBundle(OS.empty(), 9100, hats)
	assert(hb2.accessories["95"] and hb2.accessories["96"], "tanpa batas -> dua topi")

	-- makeup punya kind sendiri sejak PR #18, tapi TIDAK boleh masuk OutfitState
	-- (dipasang sebagai Decal oleh MakeupService, bukan lewat HumanoidDescription)
	for _, ty in { "FaceMakeup", "EyeMakeup", "LipMakeup" } do
		local ms, merr = OS.wear(OS.empty(), 123, ty)
		eq(merr, "UNSUPPORTED_TYPE", ty .. " ditolak OutfitState")
		eq(ms.accessories["123"], nil, ty .. " tidak tersimpan")
	end

	-- removeKind: kategori dibuang sekaligus, dan jumlahnya dilaporkan
	do
		local rk = OS.empty()
		rk.accessories["1"] = { assetId = 1, assetType = "HairAccessory", isLayered = false }
		rk.accessories["2"] = { assetId = 2, assetType = "Hat", isLayered = false }
		rk.accessories["3"] = { assetId = 3, assetType = "JacketAccessory", isLayered = true, order = 7 }
		rk.accessories["4"] = { assetId = 4, assetType = "EyebrowAccessory", isLayered = false }
		rk.classic.Shirt = { id = 10 }
		rk.bodyParts.Torso = { id = 11 }
		rk.animations.IdleAnimation = { id = 12 }

		local hair, nHair = OS.removeKind(rk, "hair")
		assert(nHair == 1 and hair.accessories["1"] == nil, "hair harus terbuang")
		assert(hair.accessories["2"] ~= nil, "topi tidak boleh ikut terbuang oleh kategori hair")

		local acc, nAcc = OS.removeKind(rk, "accessories")
		assert(nAcc == 1 and acc.accessories["2"] == nil, "accessories = rigid selain rambut/wajah")
		assert(acc.accessories["1"] ~= nil and acc.accessories["4"] ~= nil, "rambut & alis terpisah")

		local lay, nLay = OS.removeKind(rk, "layered")
		assert(nLay == 1 and lay.accessories["3"] == nil, "layered harus terbuang")

		local face, nFace = OS.removeKind(rk, "face")
		assert(nFace == 1 and face.accessories["4"] == nil, "alis termasuk kategori face")

		local cls, nCls = OS.removeKind(rk, "classic")
		assert(nCls == 1 and cls.classic.Shirt.id == 0, "classic harus dikosongkan")

		local body, nBody = OS.removeKind(rk, "bodyParts")
		assert(nBody == 1 and body.bodyParts.Torso.id == 0, "bodyParts harus dikosongkan")

		local anim, nAnim = OS.removeKind(rk, "animations")
		assert(nAnim == 1 and anim.animations.IdleAnimation.id == 0, "animations harus dikosongkan")

		local all, nAll = OS.removeKind(rk, "all")
		assert(nAll == 7, "all harus membuang semuanya, dapat " .. tostring(nAll))
		assert(next(all.accessories) == nil, "semua aksesori harus hilang")
		assert(all.classic.Shirt.id == 0 and all.bodyParts.Torso.id == 0, "slot harus kosong")

		-- Makeup BUKAN kategori tersendiri: ia ikut "face", dan yang membuangnya AvatarService
		-- (makeup hidup di luar OutfitState). Kalau suatu saat "makeup" muncul di KINDS, UI akan
		-- mengirim kategori yang tidak pernah membuang apa pun -> tombolnya diam tanpa sebab.
		for _, k in OS.KINDS do
			assert(k ~= "makeup", "makeup tidak boleh jadi kategori sendiri -- ia ikut face")
		end

		local _, nEmpty = OS.removeKind(OS.empty(), "all")
		assert(nEmpty == 0, "state kosong tidak membuang apa pun")

		-- state asal TIDAK boleh ikut berubah (semua fungsi domain immutable)
		assert(rk.accessories["1"] ~= nil and rk.classic.Shirt.id == 10, "state asal tidak disentuh")
	end

	-- 8. Badan: warna kulit & skala (halaman Body)
	do
		local skin = OS.empty()

		assert(OS.cleanHex("#a3a2a5") == "A3A2A5", "hex dinormalkan: '#' dibuang, huruf dibesarkan")
		assert(OS.cleanHex("A3A2A") == nil, "hex kependekan ditolak")
		assert(OS.cleanHex("GGGGGG") == nil, "bukan heksadesimal ditolak")
		assert(OS.cleanHex(123456) == nil, "bukan string ditolak")

		local all, nAll = OS.setColor(skin, "all", "ff0000")
		assert(nAll == 6, "palet kulit mewarnai ENAM bagian, dapat " .. tostring(nAll))
		assert(all.colors.HeadColor == "FF0000" and all.colors.LeftLegColor == "FF0000", "semua slot ikut")
		assert(skin.colors.HeadColor == "A3A2A5", "state asal tidak disentuh")

		local one, nOne = OS.setColor(all, "HeadColor", "00FF00")
		assert(nOne == 1 and one.colors.HeadColor == "00FF00", "Advanced Colors mewarnai satu bagian")
		assert(one.colors.TorsoColor == "FF0000", "bagian lain tidak ikut berubah")

		local _, nSame = OS.setColor(all, "all", "FF0000")
		assert(nSame == 0, "warna yang sama tidak menghitung perubahan")
		local _, nBad = OS.setColor(all, "NoseColor", "FF0000")
		assert(nBad == 0, "slot ngawur ditolak")

		local tall, okTall = OS.setScale(skin, "HeightScale", 1.02)
		assert(okTall and tall.scales.HeightScale == 1.02, "skala sah tersimpan")
		local capped, okCap = OS.setScale(skin, "HeightScale", 9)
		-- DIJEPIT, bukan ditolak: engine pun menjepit, dan slider yang menolak terasa macet.
		assert(okCap and capped.scales.HeightScale == OS.SCALE_LIMITS.HeightScale.max, "skala dijepit ke batas")
		local _, okBadSlot = OS.setScale(skin, "NoseScale", 1)
		assert(not okBadSlot, "slot skala ngawur ditolak")
		local _, okSame = OS.setScale(skin, "HeightScale", 1)
		assert(not okSame, "nilai yang sama bukan perubahan")
	end

	print("PASS OutfitState.spec")
end
