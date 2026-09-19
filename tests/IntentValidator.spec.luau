--!strict
-- Test IntentValidator (modul server, tapi murni).
-- Studio (dari SERVER): require(game.ReplicatedStorage.Tests["IntentValidator.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Server = game:GetService("ServerScriptService"):WaitForChild("Server")
local V = require(Server.Validators.IntentValidator)
local E = V.Errors

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function rejects(raw: any, code: string, msg: string)
	local intent, err = V.validate(raw)
	eq(intent, nil, msg .. " (harus ditolak)")
	eq(err, code, msg)
end

return function()
	-- 1. intent valid
	local i, err = V.validate({ op = "wear", assetId = 123 })
	eq(err, nil, "wear valid")
	eq((i :: any).assetId, 123, "assetId disalin")

	for _, op in { "undo", "redo", "reset" } do
		local ok = V.validate({ op = op })
		assert(ok, op .. " valid")
	end

	local wb = V.validate({ op = "wearBundle", bundleId = 9, partIds = { 1, 2 }, useBundleScales = true }) :: any
	assert(wb, "wearBundle valid")
	eq(#wb.partIds, 2, "partIds disalin")
	eq(wb.useBundleScales, true, "flag disalin")

	local wbAll = V.validate({ op = "wearBundle", bundleId = 9 }) :: any
	assert(wbAll and wbAll.partIds == nil, "partIds opsional")

	local lo = V.validate({ op = "setLayerOrder", assetId = 5, order = 100 }) :: any
	eq(lo.order, 100, "order batas atas")

	-- 2. hasil adalah tabel BARU (bukan referensi dari client)
	local rawIds = { 7 }
	local copy = V.validate({ op = "wearBundle", bundleId = 1, partIds = rawIds }) :: any
	assert(copy.partIds ~= rawIds, "partIds disalin, bukan referensi")

	-- 3. bentuk rusak
	rejects(nil, E.NOT_TABLE, "nil")
	rejects("wear", E.NOT_TABLE, "string")
	rejects({}, E.BAD_OP, "tanpa op")
	rejects({ op = "hack" }, E.BAD_OP, "op tak dikenal")
	rejects({ op = 1 }, E.BAD_OP, "op bukan string")
	rejects({ op = "wear", assetId = 1, assetType = "Hat" }, E.UNKNOWN_FIELD, "field asing (tipe dari client)")
	rejects({ op = "undo", [1] = true }, E.UNKNOWN_FIELD, "key angka")
	rejects({ op = "undo", a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }, E.TOO_MANY_KEYS, "terlalu banyak key")

	-- 4. id rusak
	rejects({ op = "wear" }, E.BAD_ID, "id hilang")
	rejects({ op = "wear", assetId = "123" }, E.BAD_ID, "id string")
	rejects({ op = "wear", assetId = 0 }, E.BAD_ID, "id nol")
	rejects({ op = "wear", assetId = -1 }, E.BAD_ID, "id negatif")
	rejects({ op = "wear", assetId = 1.5 }, E.BAD_ID, "id pecahan")
	rejects({ op = "wear", assetId = 0 / 0 }, E.BAD_ID, "id NaN")
	rejects({ op = "wear", assetId = math.huge }, E.BAD_ID, "id inf")
	rejects({ op = "remove", assetId = 2 ^ 60 }, E.BAD_ID, "id terlalu besar")

	-- 5. partIds rusak
	rejects({ op = "wearBundle", bundleId = 1, partIds = {} }, E.BAD_IDS, "partIds kosong")
	rejects({ op = "wearBundle", bundleId = 1, partIds = { 1, 1 } }, E.BAD_IDS, "duplikat")
	rejects({ op = "wearBundle", bundleId = 1, partIds = { 1, "2" } }, E.BAD_IDS, "elemen string")
	-- selene: allow(mixed_table)
	rejects({ op = "wearBundle", bundleId = 1, partIds = { 1, x = 2 } }, E.BAD_IDS, "key non-array")
	rejects({ op = "wearBundle", bundleId = 1, partIds = 5 }, E.BAD_IDS, "bukan tabel")
	local big = {}
	for n = 1, 51 do
		big[n] = n
	end
	rejects({ op = "wearBundle", bundleId = 1, partIds = big }, E.BAD_IDS, "terlalu panjang")
	rejects({ op = "wearBundle", bundleId = 1, useBundleScales = "yes" }, E.BAD_BOOL, "bool rusak")

	-- 6. order rusak
	rejects({ op = "setLayerOrder", assetId = 1, order = 0 }, E.BAD_ORDER, "order 0")
	rejects({ op = "setLayerOrder", assetId = 1, order = 101 }, E.BAD_ORDER, "order > 100")
	rejects({ op = "setLayerOrder", assetId = 1, order = 2.5 }, E.BAD_ORDER, "order pecahan")
	rejects({ op = "setLayerOrder", assetId = 1 }, E.BAD_ORDER, "order hilang")

	-- 7. removeKind: daftar kategori, semuanya wajib ada di OutfitState.KINDS
	do
		local okKind = V.validate({ op = "removeKind", kinds = { "hair", "face" } })
		assert(okKind ~= nil and #okKind.kinds == 2, "daftar kategori sah harus lolos utuh")
		assert(okKind.kinds[1] == "hair" and okKind.kinds[2] == "face", "urutannya dibiarkan apa adanya")
	end
	rejects({ op = "removeKind", kinds = { "rambut" } }, E.BAD_KIND, "kategori ngawur")
	rejects({ op = "removeKind", kinds = { "hair", 5 } }, E.BAD_KIND, "kategori bukan string")
	rejects({ op = "removeKind", kinds = { "hair", "hair" } }, E.BAD_KIND, "kategori kembar")
	rejects({ op = "removeKind", kinds = {} }, E.BAD_KIND, "daftar kosong")
	rejects({ op = "removeKind", kinds = "hair" }, E.BAD_KIND, "bukan daftar")
	rejects({ op = "removeKind", kind = "hair" }, E.UNKNOWN_FIELD, "bentuk lama ditolak")
	rejects({ op = "removeKind" }, E.BAD_KIND, "daftar hilang")

	print("PASS IntentValidator.spec")
end
