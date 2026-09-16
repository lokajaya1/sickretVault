--!strict
-- Studio: require(game.ReplicatedStorage.Tests["BundleNormalizer.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local BN = require(Shared.Domain.BundleNormalizer)
local OS = require(Shared.Domain.OutfitState)
local Samples = require(script.Parent.fixtures.BundleSamples)

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

return function()
	-- 1. bundle tubuh: 6 part, outfitId terbaca, kepala dikenali
	local ex, err = BN.extract(Samples.Body.raw)
	eq(err, nil, "body tanpa error")
	assert(ex, "body extracted")
	eq(#ex.assetIds, 6, "6 aset")
	eq(ex.outfitId, 9001, "outfitId")
	local body = BN.build(ex, Samples.Body.assetTypes)
	eq(body.bundleId, 1001, "bundleId")
	eq(body.bundleType, "BodyParts", "bundleType")
	eq(partById(body, 11).slot, "Head", "dynamic head -> slot Head")
	eq(partById(body, 12).kind, "bodyPart", "torso bodyPart")
	eq(partById(body, 11).name, "Test Head", "nama part")
	assert(BN.hasHead(body), "punya kepala")

	-- 2. enrichment: skala disaring, mood ditambah karena ada kepala
	local rich = BN.enrich(body, Samples.Body.enrichment)
	assert(rich.outfitScales, "ada skala")
	eq(rich.outfitScales.HeightScale, 1.05, "height scale")
	eq(rich.outfitScales.Bogus, nil, "kunci asing dibuang")
	eq(#rich.parts, 7, "mood ditambahkan")
	eq(partById(rich, 77).slot, "MoodAnimation", "slot mood")
	eq(#body.parts, 6, "info asli tidak berubah (immutable)")
	eq(#BN.enrich(rich, Samples.Body.enrichment).parts, 7, "mood tidak dobel")

	-- 3. sepatu: kunci huruf kecil, id string, duplikat dibuang, tanpa kepala -> tanpa mood
	local shoesEx = BN.extract(Samples.Shoes.raw)
	assert(shoesEx, "shoes extracted")
	eq(shoesEx.bundleId, 1002, "id string -> angka")
	eq(#shoesEx.assetIds, 2, "duplikat dibuang")
	eq(shoesEx.outfitId, nil, "tanpa outfit")
	local shoes = BN.enrich(BN.build(shoesEx, Samples.Shoes.assetTypes), Samples.Shoes.enrichment)
	eq(#shoes.parts, 2, "mood tidak ditambah tanpa kepala")
	eq(shoes.outfitScales, nil, "tanpa skala")
	eq(partById(shoes, 21).kind, "accessory", "sepatu = accessory")

	-- 4. respons rusak: tetap jalan, hal aneh masuk unknownItems / kind unknown
	local brokenEx = BN.extract(Samples.Broken.raw)
	assert(brokenEx, "broken tetap extracted")
	eq(brokenEx.name, "Bundle 1003", "nama fallback")
	eq(#brokenEx.assetIds, 3, "hanya id valid bertipe Asset")
	eq(#brokenEx.unknownItems, 4, "string, id negatif, Emote, tanpa id")
	local broken = BN.build(brokenEx, Samples.Broken.assetTypes)
	eq(partById(broken, 31).kind, "accessory", "hat dikenali")
	eq(partById(broken, 32).kind, "unknown", "gear tidak didukung")
	eq(partById(broken, 33).assetType, "Unknown", "tipe hilang")
	eq(BN.enrich(broken, nil).outfitScales, nil, "enrich nil aman")

	-- 5. respons tidak valid ditolak dengan kode error
	eq(select(2, BN.extract(Samples.Invalid.notTable)), "BAD_RESPONSE", "bukan tabel")
	eq(select(2, BN.extract(Samples.Invalid.noId)), "BAD_BUNDLE_ID", "tanpa id")
	eq(select(2, BN.extract(Samples.Invalid.noItems)), "NO_ITEMS", "tanpa items")
	eq(select(2, BN.extract(Samples.Invalid.noAssets)), "NO_ASSETS", "tanpa aset")

	-- 6. integrasi dengan OutfitState: part unknown diabaikan, sisanya terpasang
	local s = OS.wearBundle(OS.empty(), broken.bundleId, broken.parts)
	eq(#OS.wornAssetIds(s), 1, "hanya hat yang terpasang")
	local full = OS.wearBundle(OS.empty(), rich.bundleId, rich.parts, nil, rich.outfitScales)
	eq(full.bodyParts.Head.id, 11, "kepala bundle")
	eq(full.animations.MoodAnimation.id, 77, "mood terpasang")
	eq(full.scales.WidthScale, 0.9, "skala bundle dipakai")
	print("PASS BundleNormalizer.spec")
end
