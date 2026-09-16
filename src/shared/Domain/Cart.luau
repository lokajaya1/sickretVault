--!strict
-- DOMAIN MURNI: isi keranjang belanja (client menyimpan, server memvalidasi ulang saat checkout).
--   local cart = Cart.new()             -- maks Cart.DEFAULT_MAX item
--   local ok, reason = Cart.add(cart, { id = 123, itemType = "Asset", name = "Hat", price = 50 })
--   Cart.remove(cart, 123, "Asset"); Cart.has(cart, 123, "Asset"); Cart.list(cart); Cart.total(cart)
-- Urutan = urutan dimasukkan. Tanpa duplikat (kunci = itemType + id).
-- Item tanpa harga (nil) dianggap TIDAK DIJUAL dan ditolak.

export type ItemType = "Asset" | "Bundle"

export type Item = {
	id: number,
	itemType: ItemType,
	name: string,
	price: number, -- Robux (0 = gratis)
	assetType: string?,
	bundleType: string?,
	creatorName: string?,
}

export type Cart = {
	max: number,
	order: { string }, -- kunci berurutan
	items: { [string]: Item },
}

-- "invalid" | "notForSale" | "duplicate" | "full"
export type AddError = string

local Cart = {}

-- Batas jumlah item PromptBulkPurchase belum tercantum di docs -> fallback aman, verifikasi di Studio.
Cart.DEFAULT_MAX = 20
Cart.MAX_NAME = 100

local function isId(v: any): boolean
	return type(v) == "number" and v > 0 and v % 1 == 0 and v <= 2 ^ 53
end

local function isType(v: any): boolean
	return v == "Asset" or v == "Bundle"
end

local function optStr(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

function Cart.key(id: number, itemType: string): string
	return itemType .. ":" .. tostring(id)
end

function Cart.new(max: number?): Cart
	local m = if type(max) == "number" and max >= 1 then math.floor(max) else Cart.DEFAULT_MAX
	return { max = m, order = {}, items = {} }
end

-- Bersihkan item mentah (dari UI/remote). nil + alasan bila tidak layak.
function Cart.sanitize(raw: any): (Item?, AddError?)
	if type(raw) ~= "table" or not isId(raw.id) or not isType(raw.itemType) then
		return nil, "invalid"
	end
	local price = raw.price
	if type(price) ~= "number" or price ~= price or price < 0 or price >= 2 ^ 53 then
		return nil, "notForSale"
	end
	local name = if type(raw.name) == "string" and raw.name ~= "" then raw.name else "Item " .. tostring(raw.id)
	if #name > Cart.MAX_NAME then
		name = string.sub(name, 1, Cart.MAX_NAME)
		while #name > 0 and utf8.len(name) == nil do
			name = string.sub(name, 1, #name - 1)
		end
	end
	local item: Item = {
		id = raw.id,
		itemType = raw.itemType,
		name = name,
		price = math.floor(price),
		assetType = optStr(raw.assetType),
		bundleType = optStr(raw.bundleType),
		creatorName = optStr(raw.creatorName),
	}
	return item, nil
end

function Cart.add(cart: Cart, raw: any): (boolean, AddError?)
	local item, err = Cart.sanitize(raw)
	if not item then
		return false, err
	end
	local k = Cart.key(item.id, item.itemType)
	if cart.items[k] then
		return false, "duplicate"
	end
	if #cart.order >= cart.max then
		return false, "full"
	end
	cart.items[k] = item
	table.insert(cart.order, k)
	return true, nil
end

function Cart.remove(cart: Cart, id: number, itemType: string): boolean
	local k = Cart.key(id, itemType)
	if not cart.items[k] then
		return false
	end
	cart.items[k] = nil
	local i = table.find(cart.order, k)
	if i then
		table.remove(cart.order, i)
	end
	return true
end

function Cart.has(cart: Cart, id: number, itemType: string): boolean
	return cart.items[Cart.key(id, itemType)] ~= nil
end

function Cart.count(cart: Cart): number
	return #cart.order
end

function Cart.isFull(cart: Cart): boolean
	return #cart.order >= cart.max
end

-- Salinan daftar (aman diubah pemanggil).
function Cart.list(cart: Cart): { Item }
	local out = {}
	for _, k in cart.order do
		table.insert(out, table.clone(cart.items[k]))
	end
	return out
end

function Cart.total(cart: Cart): number
	local sum = 0
	for _, k in cart.order do
		sum += cart.items[k].price
	end
	return sum
end

function Cart.clear(cart: Cart)
	table.clear(cart.order)
	table.clear(cart.items)
end

-- Payload ringkas untuk remote Checkout: { { id, itemType }, ... }
function Cart.toRequest(cart: Cart): { { id: number, itemType: ItemType } }
	local out = {}
	for _, k in cart.order do
		local it = cart.items[k]
		table.insert(out, { id = it.id, itemType = it.itemType })
	end
	return out
end

return Cart
