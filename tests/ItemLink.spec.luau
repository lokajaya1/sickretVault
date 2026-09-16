--!strict
-- Studio: require(game.ReplicatedStorage.Tests["ItemLink.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ItemLink = require(Shared.Util.ItemLink)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function check(text: string, id: number?, kind: string?, msg: string)
	local gotId, gotKind = ItemLink.parse(text)
	eq(gotId, id, msg .. " (id)")
	eq(gotKind, kind, msg .. " (kind)")
end

return function()
	-- 1. ID polos
	check("123456", 123456, "Asset", "angka")
	check("  74292642310866 \n", 74292642310866, "Asset", "angka + spasi")
	check("0", nil, nil, "nol ditolak")
	check("1234567890123456789", nil, nil, "terlalu panjang")
	check("9999999999999999", nil, nil, "di atas 2^53")

	-- 2. link katalog
	check("https://www.roblox.com/catalog/140396507416761/Hoodie-and-Black-Cap", 140396507416761, "Asset", "https www")
	check("roblox.com/catalog/123/x", 123, "Asset", "tanpa https")
	check("http://web.roblox.com/catalog/55?ref=abc", 55, "Asset", "subdomain + query")
	check("https://www.roblox.com/library/77/Some", 77, "Asset", "library lama")
	check("HTTPS://WWW.ROBLOX.COM/CATALOG/9/X", 9, "Asset", "huruf besar")

	-- 3. link bundle
	check("https://www.roblox.com/bundles/104915988289001/Tall", 104915988289001, "Bundle", "bundle")

	-- 4. bukan link / domain lain
	check("", nil, nil, "kosong")
	check("red hat", nil, nil, "kata biasa")
	check("https://evil.com/catalog/123", nil, nil, "domain lain")
	check("https://roblox.com.evil.com/catalog/123", nil, nil, "domain menyamar")
	check("https://www.roblox.com/games/7041939546/x", nil, nil, "link game")
	check("https://www.roblox.com/catalog/abc", nil, nil, "id bukan angka")

	-- 5. looksLikeLink: jangan mencari saat mengetik link/ID
	eq(ItemLink.looksLikeLink("12345"), true, "angka mirip link")
	eq(ItemLink.looksLikeLink("https://www.rob"), true, "link setengah")
	eq(ItemLink.looksLikeLink("roblox.com/cat"), true, "domain")
	eq(ItemLink.looksLikeLink("black hoodie"), false, "pencarian biasa")

	print("PASS ItemLink.spec")
end
