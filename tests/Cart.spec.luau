--!strict
-- Studio: require(game.ReplicatedStorage.Tests["Cart.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Cart = require(Shared.Domain.Cart)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	-- 1. keranjang baru kosong
	local c = Cart.new()
	eq(c.max, Cart.DEFAULT_MAX, "max default")
	eq(Cart.count(c), 0, "kosong")
	eq(Cart.total(c), 0, "total kosong")
	eq(Cart.new(0).max, Cart.DEFAULT_MAX, "max 0 -> default")
	eq(Cart.new(3.7).max, 3, "max dibulatkan ke bawah")

	-- 2. tambah aset & bundle dengan id sama -> dua item berbeda
	local ok, err = Cart.add(c, { id = 10, itemType = "Asset", name = "Hat", price = 50, assetType = "Hat" })
	eq(ok, true, "add aset")
	eq(err, nil, "tanpa error")
	eq((Cart.add(c, { id = 10, itemType = "Bundle", name = "Pack", price = 200 })), true, "add bundle id sama")
	eq(Cart.count(c), 2, "dua item")
	eq(Cart.total(c), 250, "total")
	eq(Cart.has(c, 10, "Asset"), true, "has aset")
	eq(Cart.has(c, 10, "Bundle"), true, "has bundle")
	eq(Cart.has(c, 11, "Asset"), false, "tidak ada")

	-- 3. duplikat ditolak
	ok, err = Cart.add(c, { id = 10, itemType = "Asset", name = "Hat", price = 50 })
	eq(ok, false, "duplikat")
	eq(err, "duplicate", "alasan duplikat")

	-- 4. input tidak valid / tidak dijual
	eq(select(2, Cart.add(c, nil)), "invalid", "nil")
	eq(select(2, Cart.add(c, { id = 0, itemType = "Asset", price = 1 })), "invalid", "id 0")
	eq(select(2, Cart.add(c, { id = 1.5, itemType = "Asset", price = 1 })), "invalid", "id pecahan")
	eq(select(2, Cart.add(c, { id = 5, itemType = "Gamepass", price = 1 })), "invalid", "tipe salah")
	eq(select(2, Cart.add(c, { id = 5, itemType = "Asset" })), "notForSale", "harga nil")
	eq(select(2, Cart.add(c, { id = 5, itemType = "Asset", price = -1 })), "notForSale", "harga negatif")
	eq(select(2, Cart.add(c, { id = 5, itemType = "Asset", price = 0 / 0 })), "notForSale", "harga NaN")
	eq(Cart.count(c), 2, "tidak bertambah")

	-- 5. gratis boleh; nama kosong -> nama cadangan; field asing dibuang
	ok = Cart.add(c, { id = 7, itemType = "Asset", price = 0, name = "", evil = true })
	eq(ok, true, "gratis boleh")
	local list = Cart.list(c)
	eq(#list, 3, "list 3")
	eq(list[1].id, 10, "urutan 1")
	eq(list[2].itemType, "Bundle", "urutan 2")
	eq(list[3].name, "Item 7", "nama cadangan")
	eq((list[3] :: any).evil, nil, "field asing dibuang")

	-- 6. list adalah salinan
	list[1].price = 999
	eq(Cart.total(c), 250, "salinan tidak mengubah cart")

	-- 7. nama panjang dipotong (UTF-8 tetap valid)
	local long = string.rep("é", 80) -- 160 byte
	local item = Cart.sanitize({ id = 8, itemType = "Asset", price = 1, name = long })
	assert(item, "sanitize nama panjang")
	assert(#item.name <= Cart.MAX_NAME, "nama <= MAX_NAME byte")
	assert(utf8.len(item.name) ~= nil, "UTF-8 valid")

	-- 8. remove
	eq(Cart.remove(c, 10, "Asset"), true, "remove ada")
	eq(Cart.remove(c, 10, "Asset"), false, "remove kedua")
	eq(Cart.count(c), 2, "sisa 2")
	eq(Cart.list(c)[1].itemType, "Bundle", "urutan setelah remove")

	-- 9. toRequest ringkas
	local req = Cart.toRequest(c)
	eq(#req, 2, "request 2")
	eq(req[1].id, 10, "req id")
	eq(req[1].itemType, "Bundle", "req tipe")
	eq((req[1] :: any).name, nil, "req tanpa nama")

	-- 10. batas penuh
	local small = Cart.new(2)
	Cart.add(small, { id = 1, itemType = "Asset", price = 1 })
	Cart.add(small, { id = 2, itemType = "Asset", price = 1 })
	eq(Cart.isFull(small), true, "penuh")
	eq(select(2, Cart.add(small, { id = 3, itemType = "Asset", price = 1 })), "full", "alasan penuh")
	eq(select(2, Cart.add(small, { id = 1, itemType = "Asset", price = 1 })), "duplicate", "duplikat dicek dulu")

	-- 11. clear
	Cart.clear(c)
	eq(Cart.count(c), 0, "clear")
	eq(Cart.has(c, 10, "Bundle"), false, "clear has")

	print("PASS Cart.spec")
end
