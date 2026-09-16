--!strict
-- Studio: require(game.ReplicatedStorage.Tests["CheckoutSummary.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local CheckoutSummary = require(Shared.Domain.CheckoutSummary)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

-- EnumItem palsu
local function E(name: string): any
	return { Name = name }
end

return function()
	-- 1. hasil lengkap (bentuk docs)
	local s = CheckoutSummary.summarize(E("Completed"), {
		RobuxSpent = 150,
		Items = {
			{ type = E("AvatarAsset"), id = "1", status = E("Success") },
			{ type = E("AvatarBundle"), id = "2", status = E("AlreadyOwned") },
			{ type = E("AvatarAsset"), id = "3", status = E("InsufficientRobux") },
			{ type = E("AvatarAsset"), id = "4" }, -- status hilang -> Unknown
			{ type = E("GamePass"), id = "5", status = E("Success") }, -- tipe asing -> dibuang
			{ type = E("AvatarAsset"), id = "abc", status = E("Success") }, -- id rusak -> dibuang
			{ type = E("AvatarAsset"), id = "1.5", status = E("Success") }, -- id pecahan -> dibuang
			"bukan tabel",
		},
	})
	eq(s.status, "Completed", "status")
	eq(s.robuxSpent, 150, "robux")
	eq(#s.purchased, 1, "purchased")
	eq(s.purchased[1].id, 1, "id jadi angka")
	eq(s.purchased[1].itemType, "Asset", "tipe aset")
	eq(#s.owned, 1, "owned")
	eq(s.owned[1].itemType, "Bundle", "tipe bundle")
	eq(#s.failed, 2, "failed")
	eq(s.failed[1].reason, "InsufficientRobux", "alasan")
	eq(s.failed[2].reason, "Unknown", "alasan kosong")

	-- 2. id angka & nama string juga diterima
	local s2 = CheckoutSummary.summarize("Completed", {
		Items = { { type = "AvatarBundle", id = 7, status = "Success" } },
	})
	eq(#s2.purchased, 1, "string enum")
	eq(s2.purchased[1].id, 7, "id angka")
	eq(s2.robuxSpent, 0, "RobuxSpent hilang -> 0")

	-- 3. dibatalkan / rusak
	local s3 = CheckoutSummary.summarize(E("Aborted"), nil)
	eq(s3.status, "Aborted", "aborted")
	eq(#s3.purchased + #s3.owned + #s3.failed, 0, "kosong")
	eq(CheckoutSummary.summarize(nil, {}).status, "Error", "status nil -> Error")
	eq(CheckoutSummary.summarize(E("Completed"), { RobuxSpent = -5, Items = 3 }).robuxSpent, 0, "robux negatif")
	eq(CheckoutSummary.summarize(E("Completed"), { RobuxSpent = 0 / 0 }).robuxSpent, 0, "robux NaN")

	-- 4. enumName
	eq(CheckoutSummary.enumName(E("X")), "X", "enumName tabel")
	eq(CheckoutSummary.enumName("Y"), "Y", "enumName string")
	eq(CheckoutSummary.enumName(nil), "", "enumName nil")
	eq(CheckoutSummary.enumName(5), "", "enumName angka")

	print("PASS CheckoutSummary.spec")
end
