--!strict
-- Test CheckoutService dengan MarketplaceService PALSU.
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["CheckoutService.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local CheckoutService = require(ServerScriptService:WaitForChild("Server").Services.CheckoutService)
local Log = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function fakeEnum(enumName: string, itemName: string): any
	return enumName .. "." .. itemName
end

local function setup(opts: { throw: boolean?, max: number? }?)
	local o = opts or {}
	local calls: { any } = {}
	local market = {}
	function market.PromptBulkPurchase(_self: any, player: any, lineItems: any, options: any)
		if o.throw then
			error("HTTP 500")
		end
		table.insert(calls, { player = player, lineItems = lineItems, options = options })
	end
	local svc = CheckoutService.new({ marketplace = market, toEnum = fakeEnum, maxItems = o.max })
	return svc, calls
end

return function()
	Log.setSink(function() end)
	local p1 = { Name = "P1" }

	-- 1. validasi payload
	do
		local svc, calls = setup({ max = 3 })
		eq(select(2, svc:prompt(p1, nil)).code, "BAD_ARG", "nil")
		eq(select(2, svc:prompt(p1, {})).code, "EMPTY", "kosong")
		local many = {}
		for i = 1, 4 do
			many[i] = { id = i, itemType = "Asset" }
		end
		eq(select(2, svc:prompt(p1, many)).code, "TOO_MANY", "lebih dari max")
		eq(select(2, svc:prompt(p1, { { id = 0, itemType = "Asset" } })).code, "BAD_ARG", "id 0")
		eq(select(2, svc:prompt(p1, { { id = 1, itemType = "GamePass" } })).code, "BAD_ARG", "tipe salah")
		eq(select(2, svc:prompt(p1, { { id = 1, itemType = "Asset" }, "x" })).code, "BAD_ARG", "elemen bukan tabel")
		eq(#calls, 0, "tidak ada prompt")
	end

	-- 2. prompt: lineItems benar, duplikat dibuang, Id string, options {}
	do
		local svc, calls = setup()
		local ok = svc:prompt(p1, {
			{ id = 10, itemType = "Asset", price = 1 },
			{ id = 10, itemType = "Asset" },
			{ id = 10, itemType = "Bundle" },
		})
		eq(ok, true, "prompt ok")
		eq(#calls, 1, "satu panggilan")
		local li = calls[1].lineItems
		eq(calls[1].player, p1, "player")
		eq(#li, 2, "duplikat dibuang")
		eq(li[1].Type, "MarketplaceProductType.AvatarAsset", "tipe aset")
		eq(li[1].Id, "10", "Id string")
		eq(li[2].Type, "MarketplaceProductType.AvatarBundle", "tipe bundle")
		eq(li[1].price, nil, "tanpa field asing")
		eq(type(calls[1].options), "table", "options tabel")
	end

	-- 3. batas default = 20 (docs)
	do
		local svc, calls = setup()
		local twenty, over = {}, {}
		for i = 1, 21 do
			over[i] = { id = i, itemType = "Asset" }
			if i <= 20 then
				twenty[i] = { id = i, itemType = "Asset" }
			end
		end
		eq(svc:prompt(p1, twenty), true, "20 item boleh")
		eq(#calls[1].lineItems, 20, "20 lineItems")
		eq(select(2, svc:prompt(p1, over)).code, "TOO_MANY", "21 item ditolak")
	end

	-- 4. error PromptBulkPurchase -> FAILED
	do
		local svc = setup({ throw = true })
		eq(select(2, svc:prompt(p1, { { id = 1, itemType = "Asset" } })).code, "FAILED", "gagal")
	end

	-- 5. enum tidak ada -> error jelas saat new
	do
		local ok = pcall(CheckoutService.new, {
			marketplace = {},
			toEnum = function()
				return nil
			end,
		})
		eq(ok, false, "enum hilang -> assert")
	end

	print("PASS CheckoutService.spec")
end
