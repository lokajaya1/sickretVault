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

return function(only: string?)
	local api = RobloxApi.new()

	print(TAG .. " CatalogCategoryFilter: " .. enumNames("CatalogCategoryFilter"))
	print(TAG .. " SalesTypeFilter: " .. enumNames("SalesTypeFilter"))
	print(TAG .. " CatalogSortType: " .. enumNames("CatalogSortType"))
	print(TAG .. " CatalogSortAggregation: " .. enumNames("CatalogSortAggregation"))

	local A = Enum.AvatarAssetType
	local B = Enum.BundleType

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
