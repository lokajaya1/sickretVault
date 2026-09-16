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

-- Enum palsu: tabel dengan Name (mirip EnumItem), identitas tetap per nama.
local enums: { [string]: any } = {}
local function fakeEnum(enumName: string, itemName: string): any
	local k = enumName .. "." .. itemName
	enums[k] = enums[k] or { Name = itemName }
	return enums[k]
end

local function setup(opts: { throw: boolean?, max: number? }?)
	local o = opts or {}
	local st = { calls = {} :: { any }, results = {} :: { any } }
	local handler: any = nil
	local market = {
		PromptBulkPurchaseFinished = {
			Connect = function(_self: any, fn: any)
				handler = fn
				return {
					Disconnect = function()
						handler = nil
					end,
				}
			end,
		},
	}
	function market.PromptBulkPurchase(_self: any, player: any, lineItems: any, options: any)
		if o.throw then
			error("HTTP 500")
		end
		table.insert(st.calls, { player = player, lineItems = lineItems, options = options })
	end
	local now = 0
	local svc = CheckoutService.new({
		marketplace = market,
		toEnum = fakeEnum,
		maxItems = o.max,
		clock = function()
			return now
		end,
		onResult = function(player: any, summary: any)
			table.insert(st.results, { player = player, summary = summary })
		end,
	})
	local function fire(player: any, status: string, results: any)
		assert(handler, "handler tersambung")
		handler(player, fakeEnum("MarketplaceBulkPurchasePromptStatus", status), results)
	end
	return svc, st, fire, function(dt: number)
		now += dt
	end, function()
		return handler
	end
end

local ASSET = fakeEnum("MarketplaceProductType", "AvatarAsset")
local BUNDLE = fakeEnum("MarketplaceProductType", "AvatarBundle")
local function status(name: string): any
	return fakeEnum("MarketplaceItemPurchaseStatus", name)
end

return function()
	Log.setSink(function() end)
	local p1, p2 = { Name = "P1" }, { Name = "P2" }

	-- 1. validasi payload
	do
		local svc, st = setup({ max = 3 })
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
		eq(#st.calls, 0, "tidak ada prompt")
	end

	-- 2. prompt: lineItems benar, duplikat dibuang, Id string, options {}
	do
		local svc, st = setup()
		local ok = svc:prompt(p1, {
			{ id = 10, itemType = "Asset", price = 1 },
			{ id = 10, itemType = "Asset" },
			{ id = 10, itemType = "Bundle" },
		})
		eq(ok, true, "prompt ok")
		eq(#st.calls, 1, "satu panggilan")
		local li = st.calls[1].lineItems
		eq(st.calls[1].player, p1, "player")
		eq(#li, 2, "duplikat dibuang")
		eq(li[1].Type, ASSET, "tipe aset")
		eq(li[1].Id, "10", "Id string")
		eq(li[2].Type, BUNDLE, "tipe bundle")
		eq(li[1].price, nil, "tanpa field asing")
		eq(type(st.calls[1].options), "table", "options tabel")
	end

	-- 3. BUSY sampai Finished; pemain lain tidak terpengaruh; timeout membuka lagi
	do
		local svc, st, fire, advance = setup()
		local one = { { id = 1, itemType = "Asset" } }
		eq(svc:prompt(p1, one), true, "prompt pertama")
		eq(select(2, svc:prompt(p1, one)).code, "BUSY", "sedang prompt")
		eq(svc:prompt(p2, one), true, "pemain lain boleh")
		fire(p1, "Aborted", { RobuxSpent = 0, Items = {} })
		eq(svc:isBusy(p1), false, "selesai -> tidak busy")
		eq(svc:prompt(p1, one), true, "prompt lagi")
		advance(301)
		eq(svc:isBusy(p2), false, "timeout")
		eq(#st.calls, 3, "tiga prompt")
	end

	-- 4. error PromptBulkPurchase -> FAILED & tidak busy
	do
		local svc = setup({ throw = true })
		eq(select(2, svc:prompt(p1, { { id = 1, itemType = "Asset" } })).code, "FAILED", "gagal")
		eq(svc:isBusy(p1), false, "tidak busy setelah gagal")
	end

	-- 5. Finished -> summary per item
	do
		local svc, st, fire = setup()
		svc:prompt(p1, { { id = 1, itemType = "Asset" } })
		fire(p1, "Completed", {
			RobuxSpent = 150,
			Items = {
				{ type = ASSET, id = "1", status = status("Success") },
				{ type = BUNDLE, id = "2", status = status("AlreadyOwned") },
				{ type = ASSET, id = "3", status = status("InsufficientRobux") },
				{ type = "aneh", id = "4", status = status("Success") }, -- tipe tak dikenal -> dibuang
				{ type = ASSET, id = "abc", status = status("Success") }, -- id rusak -> dibuang
				"bukan tabel",
			},
		})
		eq(#st.results, 1, "onResult sekali")
		local s = st.results[1].summary
		eq(st.results[1].player, p1, "player hasil")
		eq(s.status, "Completed", "status")
		eq(s.robuxSpent, 150, "robux")
		eq(#s.purchased, 1, "purchased")
		eq(s.purchased[1].id, 1, "id angka")
		eq(s.purchased[1].itemType, "Asset", "tipe aset")
		eq(#s.owned, 1, "owned")
		eq(s.owned[1].itemType, "Bundle", "tipe bundle")
		eq(#s.failed, 1, "failed")
		eq(s.failed[1].reason, "InsufficientRobux", "alasan")
	end

	-- 6. Finished tanpa prompt dari service / results rusak / onResult error
	do
		local svc, st, fire = setup()
		fire(p2, "Completed", { Items = {} })
		eq(#st.results, 0, "prompt asing diabaikan")
		svc:prompt(p1, { { id = 1, itemType = "Asset" } })
		fire(p1, "Error", nil)
		local s = st.results[1].summary
		eq(s.status, "Error", "status error")
		eq(s.robuxSpent, 0, "robux 0")
		eq(#s.purchased + #s.owned + #s.failed, 0, "kosong")
		eq(svc:summarize("Completed", { RobuxSpent = -5, Items = 3 }).robuxSpent, 0, "robux negatif diabaikan")
	end

	-- 6b. onResult melempar error -> service tetap aman
	do
		local captured: any = nil
		local market = {
			PromptBulkPurchaseFinished = {
				Connect = function(_self: any, fn: any)
					captured = fn
					return { Disconnect = function() end }
				end,
			},
			PromptBulkPurchase = function() end,
		}
		local svc = CheckoutService.new({
			marketplace = market,
			toEnum = fakeEnum,
			onResult = function()
				error("boom")
			end,
		})
		svc:prompt(p1, { { id = 1, itemType = "Asset" } })
		captured(p1, "Completed", { Items = {} }) -- tidak boleh melempar error
		eq(svc:isBusy(p1), false, "tetap dibersihkan")
	end

	-- 7. release & destroy
	do
		local svc, _, _, _, getHandler = setup()
		svc:prompt(p1, { { id = 1, itemType = "Asset" } })
		svc:release(p1)
		eq(svc:isBusy(p1), false, "release")
		svc:destroy()
		eq(getHandler(), nil, "disconnect")
	end

	print("PASS CheckoutService.spec")
end
