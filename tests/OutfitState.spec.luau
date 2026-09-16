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

	print("PASS OutfitState.spec")
end
