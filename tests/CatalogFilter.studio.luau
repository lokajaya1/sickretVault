--!strict
-- SPIKE filter katalog (PR #17b) — HANYA di Studio, dijalankan dari SERVER.
-- Play -> pindah ke tab Server -> Command Bar:
--   require(game.ReplicatedStorage.Tests["CatalogFilter.studio"])()
-- Menjawab 5 pertanyaan sebelum kode #17b ditulis:
--   1. Enum apa saja yang ADA (CatalogCategoryFilter, SalesTypeFilter, CatalogSortType)?
--   2. AssetTypes + BundleTypes dipakai BERSAMA -> dapat hasil atau 0 (AND)?
--   3. Banyak AssetTypes sekaligus (chip "All" per grup) -> jalan?
--   4. MaxPrice = 0 -> benar-benar cuma item gratis (chip "Free")?
--   5. CategoryFilter Featured & SalesTypeFilter Collectibles -> ada isinya?
-- Putaran 4 (19 Sep 2026, PR #17d halaman detail item) menjawab:
--   6. CatalogSearchParams punya CreatorName / CreatorType? (nama creator bisa diklik)
--   7. Cari dengan CreatorName saja (tanpa tipe) -> ada hasil? nama ngawur -> kosong?
--   8. Stok limited: UnitsAvailableForConsumption & TotalQuantity ada di GetItemDetailsAsync?
--   9. AvatarEditorService:GetRecommendedAssetsAsync / GetRecommendedBundlesAsync -> ada & isinya apa?
-- Putaran 5 (19 Sep 2026, PR #17e panel "Search Options") menjawab — dengan MENGISI propertinya,
-- bukan cuma membaca (pelajaran #26 no. 2):
--  10. MinPrice benar-benar dihormati (bukan cuma MaxPrice seperti yang sudah terbukti di #17b)?
--  11. MinPrice + MaxPrice sekaligus -> hasilnya di dalam rentang?
--  12. Rentang terbalik (min > max) -> error, atau 0 item?
--  13. IncludeOffSale = true -> jumlahnya berubah? Apa PENANDA item off-sale di data mentah?
--  14. PriceLowToHigh / PriceHighToLow -> benar terurut?
--  15. Sort harga + BANYAK tipe aset -> masih kena penyakit item gratis bawaan (#17b), atau aman?
--  16. minPrice/maxPrice digabung creatorName -> dua saringan sekaligus jalan?
-- Putaran 5b (19 Sep 2026) — putaran 5 menjawab 21/22/23 dengan jelas tapi meninggalkan tiga
-- tanda tanya; ini MENGUKURNYA, bukan menebak (pelajaran #25: jangan menebak dua kali):
--  17. IncludeOffSale benar mengubah hasil? Putaran 5 tertipu JUMLAH yang sama -> bandingkan ID.
--  18. minPrice=100 mengembalikan item berharga 90, tapi minPrice=50 patuh. Polanya apa?
--  19. Price = 999999999 = sentinel off-sale, atau memang ada item semahal itu?
--  20. 30 item gratis di sort harga: daftar bawaan Roblox (#17b), atau item wajar?

local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")
local RobloxApi = require(Server.Gateways.RobloxApi)
local CatalogService = require(Server.Services.CatalogService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Categories = require(Shared.Config.Categories)
local CatalogMenu = require(Shared.Config.CatalogMenu)

local TAG = "[SPIKE17b]"

local function enumNames(enumName: string): string
	local ok, items = pcall(function()
		return (Enum :: any)[enumName]:GetEnumItems()
	end)
	if not ok then
		return "TIDAK ADA"
	end
	local out = {}
	for _, item in items do
		table.insert(out, item.Name)
	end
	return table.concat(out, ", ")
end

local function enumItem(enumName: string, itemName: string): any
	local ok, item = pcall(function()
		return (Enum :: any)[enumName][itemName]
	end)
	return if ok then item else nil
end

-- Jalankan satu pencarian dan cetak ringkasannya (jumlah, 3 contoh, harga tertinggi).
local function run(api: any, label: string, opts: any)
	local ok, page = api:searchCatalog(opts)
	if not ok then
		print(("%s %s -> GAGAL %s: %s"):format(TAG, label, tostring(page.code), tostring(page.message)))
		return
	end
	local items = page.items
	local maxPrice, free, examples = 0, 0, {}
	for i, it in items do
		local price = tonumber(it.Price) or 0
		if price > maxPrice then
			maxPrice = price
		end
		if price == 0 then
			free += 1
		end
		if i <= 3 then
			table.insert(
				examples,
				("%s (%s/%s, %d R$)"):format(
					tostring(it.Name),
					tostring(it.ItemType),
					tostring(it.AssetType or it.BundleType),
					price
				)
			)
		end
	end
	print(
		("%s %s -> %d item, gratis %d, harga tertinggi %d | %s"):format(
			TAG,
			label,
			#items,
			free,
			maxPrice,
			table.concat(examples, " ; ")
		)
	)
end

-- ===== Putaran 5 (#17e panel "Search Options") =====
-- Harga yang BENAR-BENAR dikembalikan: terendah, tertinggi, yang gratis, dan yang TIDAK punya harga
-- (kandidat off-sale). `Price` nil dan `Price` 0 DIBEDAKAN di sini — `run` di atas menyamakan
-- keduanya lewat `or 0`, padahal justru bedanya yang dicari putaran ini.
local function pricesOf(items: { any }): (number?, number?, number, number)
	local lo: number? = nil
	local hi: number? = nil
	local free, noPrice = 0, 0
	for _, it in items do
		local price = it.Price
		if type(price) ~= "number" then
			price = if type(it.LowestPrice) == "number" then it.LowestPrice else nil
		end
		if price == nil then
			noPrice += 1
		else
			if price == 0 then
				free += 1
			end
			if lo == nil or price < lo then
				lo = price
			end
			if hi == nil or price > hi then
				hi = price
			end
		end
	end
	return lo, hi, free, noPrice
end

-- Cetak semua field NON-tabel satu item: dipakai untuk mencari penanda off-sale.
local function dumpFlat(label: string, t: any)
	local out = {}
	for k, v in pairs(t) do
		if type(v) ~= "table" then
			table.insert(out, ("%s=%s"):format(tostring(k), tostring(v)))
		end
	end
	table.sort(out)
	print(("%s %s: %s"):format(TAG, label, table.concat(out, " ")))
end

-- Satu pencarian: jumlah, rentang harga nyata, dan 5 harga PERTAMA (untuk memeriksa urutan).
local function shot(api: any, label: string, opts: any): { any }
	local okShot, pageShot = api:searchCatalog(opts)
	if not okShot then
		print(("%s %s -> GAGAL %s: %s"):format(TAG, label, tostring(pageShot.code), tostring(pageShot.message)))
		return {}
	end
	local items = pageShot.items
	local lo, hi, free, noPrice = pricesOf(items)
	local seq = {}
	for i, it in items do
		if i > 5 then
			break
		end
		table.insert(seq, tostring(it.Price))
	end
	print(
		("%s %s -> %d item | termurah=%s termahal=%s gratis=%d tanpa-harga=%d | 5 pertama: %s"):format(
			TAG,
			label,
			#items,
			tostring(lo),
			tostring(hi),
			free,
			noPrice,
			table.concat(seq, ", ")
		)
	)
	task.wait(0.25) -- jangan memberondong API (60+ request beruntun = HTTP 429, #17b)
	return items
end

local function round17e(api: any)
	local AT = Enum.AvatarAssetType
	local lowHigh = enumItem("CatalogSortType", "PriceLowToHigh")
	local highLow = enumItem("CatalogSortType", "PriceHighToLow")
	print(("%s 18 PriceLowToHigh=%s PriceHighToLow=%s"):format(TAG, tostring(lowHigh), tostring(highLow)))

	-- 18. Patokan tanpa saringan harga, diurut termurah: ujung bawah katalog yang wajar.
	shot(api, "18 Hat lowToHigh", { assetTypes = { AT.Hat }, sortType = lowHigh, limit = 30 })

	-- 19. MinPrice: kalau dihormati, TIDAK boleh ada harga di bawah 100.
	shot(api, "19 Hat lowToHigh minPrice=100", {
		assetTypes = { AT.Hat },
		sortType = lowHigh,
		minPrice = 100,
		limit = 30,
	})

	-- 20. Rentang: semua harga harus 100..200.
	shot(api, "20 Hat lowToHigh minPrice=100 maxPrice=200", {
		assetTypes = { AT.Hat },
		sortType = lowHigh,
		minPrice = 100,
		maxPrice = 200,
		limit = 30,
	})

	-- 21. Rentang TERBALIK: error, atau 0 item? Menentukan apakah panel wajib menukar min/max sendiri.
	shot(api, "21 Hat minPrice=200 maxPrice=100 (terbalik)", {
		assetTypes = { AT.Hat },
		sortType = lowHigh,
		minPrice = 200,
		maxPrice = 100,
		limit = 30,
	})

	-- 22. Urutan menurun: harga pertama harus yang paling mahal.
	shot(api, "22 Hat highToLow", { assetTypes = { AT.Hat }, sortType = highLow, limit = 30 })

	-- 23. IncludeOffSale: jumlah & 'tanpa-harga' berubah? Lalu CARI PENANDANYA di data mentah.
	local off = shot(api, "23 Hat lowToHigh includeOffSale=true", {
		assetTypes = { AT.Hat },
		sortType = lowHigh,
		includeOffSale = true,
		limit = 30,
	})
	local marked = false
	for i, it in off do
		local noSale = type(it.Price) ~= "number" or it.IsForSale == false
		if noSale and not marked then
			marked = true
			dumpFlat(("23 off-sale #%d"):format(i), it)
		end
	end
	if not marked and off[1] then
		dumpFlat("23 tidak ada yang off-sale; #1 sebagai pembanding", off[1])
	end

	-- 24. Penyakit #17b: banyak tipe sekaligus. Sort harga aman, atau tetap item gratis bawaan?
	shot(api, "24 3 tipe lowToHigh", {
		assetTypes = { AT.Hat, AT.HairAccessory, AT.FaceAccessory },
		sortType = lowHigh,
		limit = 30,
	})

	-- 25. Apakah minPrice menyelamatkan pencarian multi-tipe?
	shot(api, "25 3 tipe lowToHigh minPrice=100", {
		assetTypes = { AT.Hat, AT.HairAccessory, AT.FaceAccessory },
		sortType = lowHigh,
		minPrice = 100,
		limit = 30,
	})

	-- 26. Dua saringan sekaligus: creator + rentang harga (jalur yang dibuka #17d).
	local seedRow = shot(api, "26 patokan Hat highToLow", {
		assetTypes = { AT.Hat },
		sortType = highLow,
		limit = 30,
	})
	local who: string? = nil
	for _, it in seedRow do
		if type(it.CreatorName) == "string" and it.CreatorName ~= "" and it.CreatorName ~= "Roblox" then
			who = it.CreatorName
			break
		end
	end
	if who then
		shot(api, ("26b creatorName '%s' + minPrice=50"):format(who), {
			creatorName = who,
			sortType = lowHigh,
			minPrice = 50,
			limit = 30,
		})
	else
		print(TAG .. " 26b tidak dapat nama creator dari hasil pencarian")
	end
end

-- ===== Putaran 5b (#17e, mengukur sisa tanda tanya putaran 5) =====
local SENTINEL17E = 999999999

-- Sisi yang belum terukur putaran 5: berapa yang off-sale, berapa yang berharga sentinel, harga
-- termurah yang NYATA (bukan sentinel, bukan off-sale), dan 5 ID pertama untuk membandingkan set.
local function stat17e(items: { any }): (number, number, number?, string)
	local nOff, nSentinel = 0, 0
	local lo: number? = nil
	local ids = {}
	for i, it in items do
		if it.IsOffSale == true then
			nOff += 1
		end
		local price = it.Price
		if type(price) == "number" then
			if price >= SENTINEL17E then
				nSentinel += 1
			elseif it.IsOffSale ~= true then
				if lo == nil or price < lo then
					lo = price
				end
			end
		end
		if i <= 5 then
			table.insert(ids, tostring(it.Id))
		end
	end
	return nOff, nSentinel, lo, table.concat(ids, ",")
end

local function shot2(api: any, label: string, opts: any): { any }
	local okS, pageS = api:searchCatalog(opts)
	if not okS then
		print(("%s %s -> GAGAL %s: %s"):format(TAG, label, tostring(pageS.code), tostring(pageS.message)))
		return {}
	end
	local items = pageS.items
	local nOff, nSentinel, lo, ids = stat17e(items)
	print(
		("%s %s -> %d item | offSale=%d sentinel=%d termurah-nyata=%s | 5 id: %s"):format(
			TAG,
			label,
			#items,
			nOff,
			nSentinel,
			tostring(lo),
			ids
		)
	)
	task.wait(0.25)
	return items
end

local function idSet17e(items: { any }): { [number]: boolean }
	local set = {}
	for _, it in items do
		if type(it.Id) == "number" then
			set[it.Id] = true
		end
	end
	return set
end

-- Berapa ID di `left` yang TIDAK ada di `right`.
local function missing17e(left: { any }, right: { any }): number
	local set = idSet17e(right)
	local n = 0
	for _, it in left do
		if type(it.Id) == "number" and not set[it.Id] then
			n += 1
		end
	end
	return n
end

local function round17e2(api: any)
	local AT2 = Enum.AvatarAssetType
	local lowHigh2 = enumItem("CatalogSortType", "PriceLowToHigh")
	local highLow2 = enumItem("CatalogSortType", "PriceHighToLow")

	-- 27. IncludeOffSale tiga keadaan: tidak diset / true / false. Yang dibandingkan DAFTAR ID.
	local unset = shot2(api, "27a Hat lowToHigh (includeOffSale tidak diset)", {
		assetTypes = { AT2.Hat },
		sortType = lowHigh2,
		limit = 30,
	})
	local yes = shot2(api, "27b Hat lowToHigh includeOffSale=true", {
		assetTypes = { AT2.Hat },
		sortType = lowHigh2,
		includeOffSale = true,
		limit = 30,
	})
	local no = shot2(api, "27c Hat lowToHigh includeOffSale=false", {
		assetTypes = { AT2.Hat },
		sortType = lowHigh2,
		includeOffSale = false,
		limit = 30,
	})
	print(
		("%s 27 ID baru di b(true): %d | hilang dari a: %d | c(false) beda dari a: %d"):format(
			TAG,
			missing17e(yes, unset),
			missing17e(unset, yes),
			missing17e(no, unset)
		)
	)

	-- 28. Tangga minPrice: cetak SELISIH antara yang diminta dan yang benar-benar datang.
	local ladder = { 100, 101, 150, 200, 1000 }
	local at100: { any } = {}
	for _, want in ladder do
		local got = shot2(api, ("28 Hat lowToHigh minPrice=%d"):format(want), {
			assetTypes = { AT2.Hat },
			sortType = lowHigh2,
			minPrice = want,
			limit = 30,
		})
		local _, _, lo = stat17e(got)
		print(
			("%s 28 minta>=%d -> termurah-nyata=%s selisih=%s"):format(
				TAG,
				want,
				tostring(lo),
				if lo ~= nil then tostring(lo - want) else "-"
			)
		)
		if want == 100 then
			at100 = got
		end
	end

	-- 29. Item yang LOLOS padahal di bawah minPrice: adakah field harga lain (diskon/harga asli)?
	local naughty: any = nil
	for _, it in at100 do
		if type(it.Price) == "number" and it.Price < 100 and it.IsOffSale ~= true then
			naughty = it
			break
		end
	end
	if naughty ~= nil then
		dumpFlat("29 lolos minPrice=100 padahal Price=" .. tostring(naughty.Price), naughty)
	else
		print(TAG .. " 29 tidak ada item di bawah 100 -> MinPrice patuh di putaran ini")
	end

	-- 30. MaxPrice sama tepatnya, atau lebih patuh daripada MinPrice?
	shot2(api, "30 Hat lowToHigh maxPrice=100", {
		assetTypes = { AT2.Hat },
		sortType = lowHigh2,
		maxPrice = 100,
		limit = 30,
	})

	-- 31. Sentinel 999999999: selalu item off-sale, atau harga sungguhan?
	local high = shot2(api, "31 Hat highToLow", {
		assetTypes = { AT2.Hat },
		sortType = highLow2,
		limit = 30,
	})
	local sentinelItem: any = nil
	for _, it in high do
		if type(it.Price) == "number" and it.Price >= SENTINEL17E then
			sentinelItem = it
			break
		end
	end
	if sentinelItem ~= nil then
		dumpFlat("31 item sentinel pertama", sentinelItem)
	else
		print(TAG .. " 31 tidak ada item berharga sentinel di halaman ini")
	end

	-- 32. 30 item gratis di sort harga: daftar bawaan Roblox (#17b), atau item wajar?
	local many = shot2(api, "32 3 tipe lowToHigh", {
		assetTypes = { AT2.Hat, AT2.HairAccessory, AT2.FaceAccessory },
		sortType = lowHigh2,
		limit = 30,
	})
	for i, it in many do
		if i > 5 then
			break
		end
		print(
			("%s 32 #%d %s | %s | creator=%s | Price=%s offSale=%s"):format(
				TAG,
				i,
				tostring(it.Name),
				tostring(it.AssetType),
				tostring(it.CreatorName),
				tostring(it.Price),
				tostring(it.IsOffSale)
			)
		)
	end
end

return function(only: string?)
	local api = RobloxApi.new()

	print(TAG .. " CatalogCategoryFilter: " .. enumNames("CatalogCategoryFilter"))
	print(TAG .. " SalesTypeFilter: " .. enumNames("SalesTypeFilter"))
	print(TAG .. " CatalogSortType: " .. enumNames("CatalogSortType"))
	print(TAG .. " CatalogSortAggregation: " .. enumNames("CatalogSortAggregation"))

	local A = Enum.AvatarAssetType
	local B = Enum.BundleType

	-- Putaran 5 dijalankan SENDIRI: require(...)("5")
	if only == "5" then
		round17e(api)
		print(TAG .. " SELESAI (putaran 5 saja)")
		return
	end

	if only == "5b" then
		round17e2(api)
		print(TAG .. " SELESAI (putaran 5b saja)")
		return
	end

	-- ===== Putaran 4 (19 Sep 2026, #17d halaman detail item) =====
	-- Ringkas satu item: persis field yang dibutuhkan halaman detail.
	local function line17d(it: any): string
		local restrictions = "-"
		if type(it.ItemRestrictions) == "table" then
			restrictions = table.concat(it.ItemRestrictions, "+")
		end
		return ("%s | creator=%s/%s | restr=%s units=%s total=%s"):format(
			tostring(it.Name),
			tostring(it.CreatorName),
			tostring(it.CreatorType),
			restrictions,
			tostring(it.UnitsAvailableForConsumption),
			tostring(it.TotalQuantity)
		)
	end

	-- Isi satu entri Recommended: tabelnya bersarang (Creator / Item / Product).
	local function dumpDeep(label: string, t: any)
		for k, v in pairs(t) do
			if type(v) == "table" then
				local inner = {}
				for k2, v2 in pairs(v) do
					table.insert(inner, ("%s=%s"):format(tostring(k2), tostring(v2)))
				end
				print(("%s %s.%s: %s"):format(TAG, label, tostring(k), table.concat(inner, " ")))
			else
				print(("%s %s.%s = %s"):format(TAG, label, tostring(k), tostring(v)))
			end
		end
	end

	local function look(label: string, opts: any, count: number): { any }
		local okLook, pageLook = api:searchCatalog(opts)
		if not okLook then
			print(("%s %s -> GAGAL %s"):format(TAG, label, tostring(pageLook.code)))
			return {}
		end
		local out = {}
		for i, it in pageLook.items do
			if i > count then
				break
			end
			table.insert(out, it)
			print(("%s %s #%d %s"):format(TAG, label, i, line17d(it)))
		end
		print(("%s %s -> %d item"):format(TAG, label, #pageLook.items))
		task.wait(0.15)
		return out
	end

	-- 14. Properti CatalogSearchParams yang ADA (sekalian untuk panel "Search Options" nanti).
	local params = CatalogSearchParams.new()
	local have = {}
	for _, propName in
		{
			"CreatorName",
			"CreatorType",
			"CreatorId",
			"CreatorTargetId",
			"MinPrice",
			"MaxPrice",
			"IncludeOffSale",
			"SortAggregation",
			"SearchKeyword",
		}
	do
		local okProp = pcall(function()
			return (params :: any)[propName]
		end)
		table.insert(have, ("%s=%s"):format(propName, if okProp then "ADA" else "-"))
	end
	print(TAG .. " 14 CatalogSearchParams: " .. table.concat(have, " "))
	print(TAG .. " 14 CreatorType: " .. enumNames("CreatorType"))

	-- 15. Klik nama creator: ambil nama dari hasil pencarian lalu cari balik dengan nama itu.
	local seed = look("15 patokan Hat", { assetTypes = { A.Hat }, limit = 30 }, 3)
	local who: string? = nil
	for _, it in seed do
		if type(it.CreatorName) == "string" and it.CreatorName ~= "" and it.CreatorName ~= "Roblox" then
			who = it.CreatorName
			break
		end
	end
	if who then
		look("15b creatorName '" .. who .. "' TANPA tipe", { creatorName = who, limit = 30 }, 5)
		look("15c creatorName '" .. who .. "' + Hat", { creatorName = who, assetTypes = { A.Hat }, limit = 30 }, 5)
	else
		print(TAG .. " 15 tidak dapat nama creator dari hasil pencarian")
	end
	look("15d creatorName 'Roblox' TANPA tipe", { creatorName = "Roblox", limit = 30 }, 3)
	look("15e creatorName ngawur", { creatorName = "zzq" .. tostring(math.random(100000, 999999)), limit = 30 }, 3)

	-- 16. Stok limited: apakah search & detail satuan memberi angka yang sama?
	local salesCollectibles = enumItem("SalesTypeFilter", "Collectibles")
	if salesCollectibles then
		local lim = look("16 limited Hat", {
			salesTypeFilter = salesCollectibles,
			assetTypes = { A.Hat },
			limit = 30,
		}, 4)
		for i, it in lim do
			if i <= 3 and type(it.Id) == "number" then
				local okD, d = api:getItemDetails(it.Id, Enum.AvatarItemType.Asset)
				if okD then
					print(("%s 16 detail %d %s"):format(TAG, it.Id, line17d(d)))
				else
					print(("%s 16 detail %d GAGAL %s"):format(TAG, it.Id, tostring((d :: any).code)))
				end
				task.wait(0.2)
			end
		end
	end

	-- 17. Baris "Recommended" di halaman detail: adakah API-nya, dan apa isinya?
	local AES = game:GetService("AvatarEditorService")
	local ctx = seed[1]
	if ctx then
		local okRec, rec = pcall(function()
			return (AES :: any):GetRecommendedAssetsAsync(A.Hat, ctx.Id)
		end)
		if okRec and type(rec) == "table" then
			print(("%s 17 GetRecommendedAssetsAsync(Hat, %d) -> %d hasil"):format(TAG, ctx.Id, #rec))
			if rec[1] then
				dumpDeep("17 aset[1]", rec[1])
			end
			if rec[2] then
				dumpDeep("17 aset[2]", rec[2])
			end
		else
			print(TAG .. " 17 GetRecommendedAssetsAsync GAGAL: " .. tostring(rec))
		end
	end
	local okBun, bunPage = api:searchCatalog({ bundleTypes = { B.Shoes }, limit = 10 })
	local firstBundle = if okBun then bunPage.items[1] else nil
	if firstBundle then
		local okRB, recB = pcall(function()
			return (AES :: any):GetRecommendedBundlesAsync(firstBundle.Id)
		end)
		print(
			("%s 17b GetRecommendedBundlesAsync(%d) -> %s | %s"):format(
				TAG,
				firstBundle.Id,
				tostring(okRB),
				if okRB and type(recB) == "table" then tostring(#recB) .. " hasil" else tostring(recB)
			)
		)
		if okRB and type(recB) == "table" and recB[1] then
			dumpDeep("17b bundle[1]", recB[1])
		end
	end

	if only == "4" then
		print(TAG .. " SELESAI (putaran 4 saja)")
		return
	end

	-- 1. patokan: satu tipe aset
	run(api, "1 assetTypes {Hat}", { assetTypes = { A.Hat }, limit = 30 })

	-- 2. patokan: satu tipe bundle
	run(api, "2 bundleTypes {Shoes}", { bundleTypes = { B.Shoes }, limit = 30 })

	-- 3. PENTING: aset + bundle bersamaan (chip "All" grup campuran, mis. ACCESSORIES + Shoes)
	run(api, "3 assetTypes {Hat} + bundleTypes {Shoes}", {
		assetTypes = { A.Hat },
		bundleTypes = { B.Shoes },
		limit = 30,
	})

	-- 4. banyak tipe aset sekaligus (chip "All" grup ACCESSORIES)
	run(api, "4 assetTypes ACCESSORIES (7 tipe)", {
		assetTypes = {
			A.Hat,
			A.NeckAccessory,
			A.ShoulderAccessory,
			A.FrontAccessory,
			A.BackAccessory,
			A.WaistAccessory,
			A.FaceAccessory,
		},
		limit = 30,
	})

	-- 5. chip "Free": MaxPrice 0 (harga tertinggi HARUS 0 kalau filter dihormati)
	run(api, "5 assetTypes {Hat} + maxPrice 0", { assetTypes = { A.Hat }, maxPrice = 0, limit = 30 })
	run(api, "5b CLOTHING (Tops+Bottoms) + maxPrice 0", {
		assetTypes = { A.TShirtAccessory, A.ShirtAccessory, A.JacketAccessory, A.PantsAccessory, A.ShortsAccessory },
		maxPrice = 0,
		limit = 30,
	})

	-- 6. FEATURED: coba tiap nilai CatalogCategoryFilter yang ada
	local okFilter, filters = pcall(function()
		return Enum.CatalogCategoryFilter:GetEnumItems()
	end)
	if okFilter then
		for _, f in filters do
			run(api, "6 categoryFilter " .. f.Name, { categoryFilter = f, limit = 10 })
		end
	else
		print(TAG .. " 6 CatalogCategoryFilter tidak ada di engine ini")
	end

	-- 7. Collectibles (kandidat chip "Limited")
	local collectibles = enumItem("SalesTypeFilter", "Collectibles")
	if collectibles then
		run(api, "7 salesTypeFilter Collectibles", { salesTypeFilter = collectibles, limit = 30 })
		run(api, "7b Collectibles + assetTypes {Hat}", {
			salesTypeFilter = collectibles,
			assetTypes = { A.Hat },
			limit = 30,
		})
	else
		print(TAG .. " 7 SalesTypeFilter.Collectibles tidak ada")
	end

	-- 8. tanpa filter apa pun (apa isi default katalog?)
	run(api, "8 tanpa filter", { limit = 10 })

	-- ===== Putaran 2 (18 Sep 2026) =====
	-- 9. Apakah SortType menyelamatkan hasil multi-tipe? (tes 3 & 4 jatuh ke daftar gratis)
	local acc = {
		A.Hat,
		A.NeckAccessory,
		A.ShoulderAccessory,
		A.FrontAccessory,
		A.BackAccessory,
		A.WaistAccessory,
		A.FaceAccessory,
	}
	for _, sortName in { "Relevance", "Bestselling", "MostFavorited", "RecentlyCreated", "PriceHighToLow" } do
		local sort = enumItem("CatalogSortType", sortName)
		if sort then
			run(api, "9 ACCESSORIES 7 tipe + sort " .. sortName, { assetTypes = acc, sortType = sort, limit = 30 })
		end
	end

	-- 10. Pembanding: SATU tipe + sort yang sama (apakah hasilnya beda jauh?)
	local best = enumItem("CatalogSortType", "Bestselling")
	if best then
		run(api, "10 assetTypes {Hat} + sort Bestselling", { assetTypes = { A.Hat }, sortType = best, limit = 30 })
		run(api, "10b 7 tipe + sort Bestselling + keyword 'cap'", {
			assetTypes = acc,
			sortType = best,
			keyword = "cap",
			limit = 30,
		})
	end

	-- 11. Tipe aset & bundle apa saja yang ADA di engine ini (cari Makeup/Background/dll)
	print(TAG .. " AvatarAssetType: " .. enumNames("AvatarAssetType"))
	print(TAG .. " BundleType: " .. enumNames("BundleType"))

	-- 12. Backgrounds & kandidat "Makeup" (item wajah di CAC: Blush, Red Kisses, ...)
	local bg = enumItem("AvatarAssetType", "AvatarBackground")
	if bg then
		run(api, "12 assetTypes {AvatarBackground}", { assetTypes = { bg }, limit = 30 })
	else
		print(TAG .. " 12 AvatarAssetType.AvatarBackground tidak ada")
	end
	run(api, "12b keyword 'blush' tanpa filter tipe", { keyword = "blush", limit = 10 })
	run(api, "12c keyword 'face tattoo' tanpa filter tipe", { keyword = "face tattoo", limit = 10 })

	-- ===== Putaran 3: cek isi TIAP kategori & chip lewat CatalogService (aturan sort ikut dipakai) =====
	local svc = CatalogService.new({ api = api })
	local empty: { string } = {}

	local function probe(label: string, req: any)
		local res = svc:search(req)
		local n = if res.ok then #(res.items or {}) else -1
		if n <= 0 then
			table.insert(empty, label)
		end
		print(
			("%s 13 %s -> %s"):format(
				TAG,
				label,
				if res.ok then tostring(n) .. " item" else "GAGAL " .. tostring(res.code)
			)
		)
		task.wait(0.15) -- jangan memberondong API
	end

	for _, c in Categories.list do
		probe("kategori " .. c.id, { categoryId = c.id })
	end
	for _, g in CatalogMenu.list do
		if not g.soon then
			for _, f in { "all", "free", "limited" } do
				probe(("chip %s/%s"):format(g.id, f), { groupId = g.id, filter = f })
			end
		end
	end

	if #empty == 0 then
		print(TAG .. " 13 SEMUA kategori & chip ADA ISINYA")
	else
		print(TAG .. " 13 KOSONG (" .. #empty .. "): " .. table.concat(empty, ", "))
	end

	print(TAG .. " SELESAI")
end
