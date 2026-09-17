--!strict
-- Test WardrobeValidator (modul server, tapi murni).
-- Studio (dari SERVER): require(game.ReplicatedStorage.Tests["WardrobeValidator.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Server = game:GetService("ServerScriptService"):WaitForChild("Server")
local V = require(Server.Validators.WardrobeValidator)
local Wardrobe = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Domain.Wardrobe)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function rejects(raw: any, code: string, msg: string)
	local req, err = V.validate(raw)
	eq(req, nil, msg .. " (harus ditolak)")
	eq(err, code, msg)
end

return function()
	-- 1. permintaan valid -> tabel BARU yang bersih
	local raw = { op = "rename", id = 3, name = "  Pesta  Malam " }
	local req = V.validate(raw) :: any
	assert(req, "rename valid")
	eq(req ~= raw, true, "tabel baru")
	eq(req.id, 3, "id")
	eq(req.name, "Pesta Malam", "nama dirapikan")
	eq((V.validate({ op = "list" }) :: any).op, "list", "list")
	eq((V.validate({ op = "wear", id = 1 }) :: any).id, 1, "wear")
	eq((V.validate({ op = "overwrite", id = 2 }) :: any).id, 2, "overwrite")
	eq((V.validate({ op = "delete", id = 2 }) :: any).id, 2, "delete")

	-- 2. save: nama opsional; kosong / spasi -> nil (nama bawaan)
	eq((V.validate({ op = "save" }) :: any).name, nil, "save tanpa nama")
	eq((V.validate({ op = "save", name = "   " }) :: any).name, nil, "save nama spasi")
	eq((V.validate({ op = "save", name = "Kasual" }) :: any).name, "Kasual", "save bernama")
	rejects({ op = "save", name = 5 }, "BAD_NAME", "save nama bukan string")
	rejects({ op = "save", name = string.rep("a", Wardrobe.MAX_NAME + 1) }, "TOO_LONG", "save terlalu panjang")

	-- 3. rename: nama wajib
	rejects({ op = "rename", id = 1 }, "BAD_NAME", "rename tanpa nama")
	rejects({ op = "rename", id = 1, name = "  " }, "EMPTY", "rename nama kosong")
	rejects({ op = "rename", id = 1, name = "\255" }, "BAD_NAME", "utf8 rusak")

	-- 4. bentuk salah
	rejects(nil, "BAD_ARG", "nil")
	rejects("list", "BAD_ARG", "string")
	rejects({}, "BAD_ARG", "tanpa op")
	rejects({ op = "hack" }, "BAD_ARG", "op asing")
	rejects({ op = "list", extra = 1 }, "BAD_ARG", "field asing")
	rejects({ op = "list", [1] = 1 }, "BAD_ARG", "key angka")
	rejects({ op = "save", a = 1, b = 2, c = 3, d = 4 }, "BAD_ARG", "terlalu banyak key")

	-- 5. id
	rejects({ op = "wear" }, "BAD_ARG", "tanpa id")
	rejects({ op = "wear", id = 0 }, "BAD_ARG", "id 0")
	rejects({ op = "wear", id = 1.5 }, "BAD_ARG", "id pecahan")
	rejects({ op = "wear", id = 0 / 0 }, "BAD_ARG", "id NaN")
	rejects({ op = "delete", id = "1" }, "BAD_ARG", "id string")
	rejects({ op = "delete", id = 2 ^ 60 }, "BAD_ARG", "id terlalu besar")

	-- 5b. favorite: value wajib boolean
	local fv = V.validate({ op = "favorite", id = 4, value = false }) :: any
	assert(fv, "favorite valid")
	eq(fv.value, false, "value false tetap")
	rejects({ op = "favorite", id = 4 }, "BAD_ARG", "favorite tanpa value")
	rejects({ op = "favorite", id = 4, value = "ya" }, "BAD_ARG", "favorite value bukan bool")
	rejects({ op = "favorite", value = true }, "BAD_ARG", "favorite tanpa id")

	-- 5c. items: hanya id
	local iv = V.validate({ op = "items", id = 7 }) :: any
	assert(iv, "items valid")
	eq(iv.id, 7, "items id")
	rejects({ op = "items" }, "BAD_ARG", "items tanpa id")
	rejects({ op = "items", id = 7, value = true }, "BAD_ARG", "items field asing")

	-- 6. setSetting: key dari TEMPLATE, tipe harus sama
	local s = V.validate({ op = "setSetting", key = "restoreOutfit", value = false }) :: any
	assert(s, "setSetting valid")
	eq(s.key, "restoreOutfit", "key")
	eq(s.value, false, "value false tetap")
	rejects({ op = "setSetting", key = "restoreOutfit", value = "no" }, "BAD_ARG", "tipe salah")
	rejects({ op = "setSetting", key = "restoreOutfit" }, "BAD_ARG", "tanpa value")
	rejects({ op = "setSetting", key = "admin", value = true }, "BAD_ARG", "key asing")
	rejects({ op = "setSetting", key = 1, value = true }, "BAD_ARG", "key bukan string")

	print("PASS WardrobeValidator.spec")
end
