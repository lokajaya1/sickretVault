--!strict
-- Studio: require(game.ReplicatedStorage.Tests["PlayerData.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local PlayerData = require(Shared.Domain.PlayerData)
local Wardrobe = require(Shared.Domain.Wardrobe)
local OS = require(Shared.Domain.OutfitState)
local Limits = require(Shared.Config.Limits)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function sample()
	local s = OS.empty()
	s.bodyParts.Head = { id = 111 } -- milik avatar asli
	s.accessories["5"] = { assetId = 5, assetType = "Hat", isLayered = false } -- avatar asli (tanpa seq)
	s = OS.wear(s, 20, "JacketAccessory")
	s = OS.wear(s, 21, "Hat", 900)
	s = OS.wear(s, 30, "Shirt")
	s = OS.wear(s, 40, "RunAnimation", 900)
	s.colors.HeadColor = "FFCC00"
	s.scales.HeightScale = 1.05
	return s
end

return function()
	-- 1. migrate: data kosong / bukan tabel -> v terbaru + setting default
	local d, newer = PlayerData.migrate({})
	eq(d.v, PlayerData.VERSION, "versi")
	eq(d.settings.restoreOutfit, true, "default restore")
	eq(newer, false, "bukan data baru")
	eq(PlayerData.migrate(nil).v, PlayerData.VERSION, "nil -> tabel")

	-- 2. migrate: nilai yang ada dipertahankan, tipe salah diperbaiki
	d = PlayerData.migrate({ v = 1, settings = { restoreOutfit = false }, lastOutfit = { x = 1 } })
	eq(d.settings.restoreOutfit, false, "setting dipertahankan")
	eq(d.lastOutfit.x, 1, "lastOutfit tidak disentuh")
	eq(PlayerData.migrate({ settings = "rusak" }).settings.restoreOutfit, true, "settings rusak")
	eq(PlayerData.migrate({ settings = { restoreOutfit = "ya" } }).settings.restoreOutfit, true, "bool salah")

	-- 3. migrate: data dari versi lebih baru tidak diubah
	local future = { v = PlayerData.VERSION + 1, settings = "format baru" }
	local same, isNewer = PlayerData.migrate(future)
	eq(isNewer, true, "newer")
	eq(same.settings, "format baru", "tidak diubah")
	eq(same.v, PlayerData.VERSION + 1, "versi tetap")

	-- 4. round trip: encode -> decode = tampilan sama
	local s = sample()
	local enc = PlayerData.encodeOutfit(s)
	eq(enc.bp.Torso, nil, "slot kosong dibuang")
	eq(#enc.ac, 3, "3 aksesori")
	eq(enc.ac[1].i, 5, "avatar asli (tanpa seq) paling awal")
	eq(enc.ac[1].q, nil, "tanpa seq -> q nil")
	local back, err = PlayerData.decodeOutfit(enc)
	assert(back, "decode gagal: " .. tostring(err))
	eq(back.rig, "R15", "rig")
	eq(back.bodyParts.Head.id, 111, "head")
	eq(back.bodyParts.Torso.id, 0, "torso kosong")
	eq(back.classic.Shirt.id, 30, "shirt")
	eq(back.animations.RunAnimation.source, 900, "source animasi")
	eq(back.accessories["21"].source, 900, "source aksesori")
	eq(back.accessories["5"].seq, nil, "seq asli tetap nil")
	eq(back.accessories["20"].seq, 1, "seq dinomori ulang")
	eq(back.accessories["21"].seq, 2, "seq urut")
	eq(back.accessories["20"].isLayered, true, "layered")
	eq(back.accessories["20"].order, s.accessories["20"].order, "order")
	eq(back.accessories["20"].puffiness, 1, "puffiness")
	eq(back.colors.HeadColor, "FFCC00", "warna")
	eq(back.colors.TorsoColor, "A3A2A5", "warna default")
	eq(back.scales.HeightScale, 1.05, "skala")

	-- 5. hasil encode aman untuk DataStore: hanya string/number/boolean/tabel, tanpa NaN
	local function check(v: any, path: string)
		local t = type(v)
		if t == "table" then
			for k, x in v do
				assert(type(k) == "string" or type(k) == "number", "key aneh di " .. path)
				check(x, path .. "." .. tostring(k))
			end
		else
			assert(t == "string" or t == "number" or t == "boolean", "tipe aneh di " .. path)
			assert(v == v, "NaN di " .. path)
		end
	end
	check(enc, "enc")

	-- 6. decode menolak bentuk dasar yang salah
	eq(select(2, PlayerData.decodeOutfit(nil)), "missing", "nil")
	eq(select(2, PlayerData.decodeOutfit({ ov = 99, r = "R15" })), "version", "versi outfit")
	eq(select(2, PlayerData.decodeOutfit({ ov = 1, r = "R99" })), "rig", "rig")
	eq(select(2, PlayerData.decodeOutfit({ ov = 1, r = "R15", ac = "x" })), "shape", "ac bukan tabel")
	eq(select(2, PlayerData.decodeOutfit({ ov = 1, r = "R15", bp = 5 })), "shape", "bp bukan tabel")

	-- 7. decode membuang entri rusak satu per satu
	local dirty = {
		ov = 1,
		r = "R6",
		bp = { Head = { i = -1 }, Torso = { i = 7, s = "x" }, Bogus = { i = 8 } },
		ac = {
			{ i = 1, t = "Gear" }, -- tipe bukan aksesori
			{ i = 2, t = "Shirt" }, -- classic, bukan aksesori
			{ i = 3.5, t = "Hat" }, -- id pecahan
			"rusak",
			{ i = 4, t = "Hat", q = true },
			{ i = 4, t = "Hat" }, -- duplikat
			{ i = 6, t = "ShirtAccessory", o = 0 / 0, p = 9 },
			{ i = 9, t = "PantsAccessory", o = 500, p = -1 },
		},
		co = { HeadColor = "zzzzzz", TorsoColor = "ab12cd" },
		sc = { HeightScale = 0 / 0, WidthScale = 99, DepthScale = 0.9 },
	}
	local c = PlayerData.decodeOutfit(dirty)
	assert(c, "decode dirty")
	eq(c.rig, "R6", "rig R6")
	eq(c.bodyParts.Head.id, 0, "id negatif dibuang")
	eq(c.bodyParts.Torso.id, 7, "torso")
	eq(c.bodyParts.Torso.source, nil, "source rusak dibuang")
	eq((c.bodyParts :: any).Bogus, nil, "slot asing dibuang")
	eq(c.accessories["1"], nil, "gear dibuang")
	eq(c.accessories["2"], nil, "classic dibuang")
	eq(c.accessories["4"].seq, 1, "hat seq")
	eq(c.accessories["4"].order, nil, "rigid tanpa order")
	eq(c.accessories["6"].order, 2, "order NaN -> LayerOrder default") -- ShirtAccessory = 2 di LayerOrder
	eq(c.accessories["6"].puffiness, 1, "puffiness dijepit")
	eq(c.accessories["9"].order, 100, "order dijepit")
	eq(c.accessories["9"].puffiness, 0, "puffiness negatif dijepit")
	eq(c.colors.HeadColor, "A3A2A5", "hex rusak -> default")
	eq(c.colors.TorsoColor, "AB12CD", "hex huruf besar")
	eq(c.scales.HeightScale, 1, "NaN -> default")
	eq(c.scales.WidthScale, 1, "terlalu besar -> default")
	eq(c.scales.DepthScale, 0.9, "skala valid")

	-- 8. batas jumlah aksesori ditegakkan
	local many = { ov = 1, r = "R15", ac = {} }
	for i = 1, Limits.MaxRigidAccessories + 5 do
		table.insert(many.ac, { i = 1000 + i, t = "Hat", q = true })
	end
	local m = PlayerData.decodeOutfit(many)
	assert(m, "decode many")
	local n = 0
	for _ in m.accessories do
		n += 1
	end
	eq(n, Limits.MaxRigidAccessories, "dipotong ke batas")
	eq(m.accessories["1001"] ~= nil, true, "yang awal dipertahankan")

	-- 9. v1 -> v2: slot wardrobe ditambahkan, data lama tetap
	local v1 = { v = 1, settings = { restoreOutfit = false }, lastOutfit = { ov = 1, r = "R15" } }
	local v2 = PlayerData.migrate(v1)
	eq(v2.v, PlayerData.VERSION, "naik ke versi terbaru")
	eq(#v2.outfits, 0, "outfits kosong")
	eq(v2.nextOutfitId, 1, "nextOutfitId")
	eq(v2.settings.restoreOutfit, false, "setting v1 tetap")
	eq(v2.lastOutfit.r, "R15", "lastOutfit v1 tetap")
	eq(#PlayerData.TEMPLATE.outfits, 0, "template outfits")
	eq(PlayerData.TEMPLATE.nextOutfitId, 1, "template nextOutfitId")

	-- 10. slot wardrobe bertahan saat load ulang & isinya bisa di-decode
	assert(Wardrobe.add(v2, "Pesta", PlayerData.encodeOutfit(sample()), 123), "add slot")
	local again = PlayerData.migrate(v2)
	eq(#again.outfits, 1, "slot dipertahankan")
	eq(again.outfits[1].n, "Pesta", "nama slot")
	eq(again.nextOutfitId, 2, "id berikutnya")
	local worn = PlayerData.decodeOutfit(again.outfits[1].o)
	assert(worn, "decode slot")
	eq(worn.classic.Shirt.id, 30, "isi slot utuh")
	eq(PlayerData.migrate({ v = 2, settings = {}, outfits = { "rusak" } }).outfits[1], nil, "slot rusak dibuang")

	-- 11. v2 -> v3: folder outfit ditambahkan, id folder mati dilepas dari slot
	local old = {
		v = 2,
		settings = { restoreOutfit = true },
		outfits = { { id = 1, n = "Pesta", t = 1, o = { ov = 1, r = "R15" }, g = { 4, 99 } } },
		nextOutfitId = 2,
		folders = { { id = 4, n = "Malam", t = 5 } },
	}
	local v3 = PlayerData.migrate(old)
	eq(v3.v, PlayerData.VERSION, "naik ke v3")
	eq(#v3.folders, 1, "folder dipertahankan")
	eq(v3.folders[1].n, "Malam", "nama folder")
	eq(v3.nextFolderId, 5, "nextFolderId > id terbesar")
	eq(#v3.outfits[1].g, 1, "id folder mati dilepas")
	eq(v3.outfits[1].g[1], 4, "id folder yang ada tetap")
	eq(#PlayerData.migrate({ v = 2, settings = {} }).folders, 0, "data v2 tanpa folder -> kosong")
	eq(PlayerData.migrate({ v = 2, settings = {} }).nextFolderId, 1, "nextFolderId bawaan")
	eq(#PlayerData.TEMPLATE.folders, 0, "template folders")
	eq(PlayerData.TEMPLATE.nextFolderId, 1, "template nextFolderId")

	-- ===== v4: makeup (assetId + slot saja; texture di-resolve ulang saat join) =====
	local Makeup = require(Shared.Domain.Makeup)
	eq(PlayerData.VERSION, 4, "skema v4")
	eq(PlayerData.encodeMakeup(Makeup.empty()), nil, "tanpa makeup -> nil (tidak menambah data)")

	local mk = Makeup.set(Makeup.empty(), {
		assetId = 133520807586498,
		slot = "face",
		textureId = "rbxassetid://98880692903650",
	})
	mk = Makeup.set(mk, { assetId = 106390919006817, slot = "lip", textureId = "rbxassetid://77903406032400" })
	local encM = PlayerData.encodeMakeup(mk)
	eq(#encM, 2, "dua baris")
	eq(encM[1].i, 133520807586498, "urut face dulu")
	eq(encM[1].s, "face", "slot ikut")
	eq(encM[1].t, nil, "texture TIDAK disimpan")

	local dec = PlayerData.decodeMakeup(encM)
	eq(#dec, 2, "decode dua baris")
	eq(dec[1].assetId, 133520807586498, "assetId kembali")
	eq(dec[2].slot, "lip", "slot kembali")

	eq(#PlayerData.decodeMakeup(nil), 0, "nil aman")
	eq(#PlayerData.decodeMakeup("x"), 0, "string aman")
	eq(#PlayerData.decodeMakeup({ { i = 0, s = "face" } }), 0, "id cacat dibuang")
	eq(#PlayerData.decodeMakeup({ { i = 5, s = "hidung" } }), 0, "slot ngawur dibuang")
	eq(#PlayerData.decodeMakeup({ { i = 5, s = "face" }, { i = 6, s = "face" } }), 1, "slot ganda -> yang pertama")

	local v4 = PlayerData.migrate({ v = 3, settings = {} })
	eq(v4.v, 4, "v3 -> v4")
	eq(v4.lastMakeup, nil, "data lama tanpa makeup tetap aman")

	print("PASS PlayerData.spec")
end
