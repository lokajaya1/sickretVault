--!strict
-- SPIKE harga item (PR #17c) — HANYA di Studio, dijalankan dari SERVER.
-- Play -> tab Server -> Command Bar:
--   require(game.ReplicatedStorage.Tests["ItemPrice.studio"])()
-- Menjawab sebelum kode harga ditulis:
--   1. Field harga apa yang DIISI oleh SearchCatalogAsync (Price / LowestPrice / LowestResalePrice)?
--   2. Apakah GetItemDetailsAsync memberi angka yang BERBEDA (lebih baru) dari hasil pencarian?
--   3. Item limited: adakah LowestResalePrice / HasResellers / ItemRestrictions yang bisa dipercaya?
--   4. Item gratis & Premium: bagaimana bentuk datanya (Price 0? PriceStatus? IsPurchasable?)
--   5. GetBatchItemDetailsAsync: field yang sama dengan GetItemDetailsAsync?

local ServerScriptService = game:GetService("ServerScriptService")
local RobloxApi = require(ServerScriptService:WaitForChild("Server").Gateways.RobloxApi)

local TAG = "[SPIKE17c]"
local FIELDS = {
	"Price",
	"LowestPrice",
	"LowestResalePrice",
	"HasResellers",
	"ItemRestrictions",
	"ItemStatus",
	"IsPurchasable",
	"Owned",
	"SaleLocationType",
	"TotalQuantity",
	"UnitsAvailableForConsumption",
	"PriceStatus",
	"PremiumPricing",
	"CollectibleItemId",
}

-- Ringkas satu item jadi satu baris: hanya field yang ADA (nil dilewati).
local function line(raw: any): string
	local out = {}
	for _, f in FIELDS do
		local v = (raw :: any)[f]
		if v ~= nil then
			if type(v) == "table" then
				local parts = {}
				for k, x in pairs(v) do
					table.insert(parts, ("%s=%s"):format(tostring(k), tostring(x)))
				end
				table.insert(out, ("%s={%s}"):format(f, table.concat(parts, ",")))
			else
				table.insert(out, ("%s=%s"):format(f, tostring(v)))
			end
		end
	end
	return table.concat(out, " ")
end

local function dump(label: string, raw: any)
	print(("%s %s | %s | %s"):format(TAG, label, tostring((raw :: any).Name), line(raw)))
end

-- Ambil beberapa item dari satu pencarian.
local function sample(api: any, label: string, opts: any, count: number): { any }
	local ok, page = api:searchCatalog(opts)
	if not ok then
		print(("%s %s -> GAGAL %s"):format(TAG, label, tostring(page.code)))
		return {}
	end
	local out = {}
	for i, item in page.items do
		if i > count then
			break
		end
		table.insert(out, item)
		dump(label .. " search#" .. i, item)
	end
	return out
end

return function()
	local api = RobloxApi.new()
	local A = Enum.AvatarAssetType

	-- 1. item biasa berbayar
	local normal = sample(api, "1 topi", { assetTypes = { A.Hat }, limit = 10 }, 3)

	-- 2. item limited (kandidat pita LIMITED + harga resale)
	local limited = sample(api, "2 limited", {
		salesTypeFilter = Enum.SalesTypeFilter.Collectibles,
		assetTypes = { A.Hat },
		limit = 10,
	}, 4)

	-- 3. item gratis
	sample(api, "3 gratis", { assetTypes = { A.Hat }, maxPrice = 0, limit = 10 }, 2)

	-- 4. detail satuan: apakah angkanya berbeda dari hasil pencarian?
	local probe = {}
	for _, it in normal do
		table.insert(probe, it)
	end
	for _, it in limited do
		table.insert(probe, it)
	end
	local ids: { number } = {}
	for i, it in probe do
		if i <= 6 and type(it.Id) == "number" then
			table.insert(ids, it.Id)
			local ok, detail = api:getItemDetails(it.Id, Enum.AvatarItemType.Asset)
			if ok then
				dump("4 detail " .. tostring(it.Id), detail)
			else
				print(("%s 4 detail %d -> GAGAL %s"):format(TAG, it.Id, tostring(detail.code)))
			end
			task.wait(0.2)
		end
	end

	-- 5. batch: bentuk datanya sama?
	if #ids > 0 then
		local ok, map = api:getBatchItemDetails(ids, Enum.AvatarItemType.Asset)
		if ok then
			local n = 0
			for id, detail in pairs(map) do
				n += 1
				if n <= 3 then
					dump("5 batch " .. tostring(id), detail)
				end
			end
			print(("%s 5 batch -> %d hasil dari %d id"):format(TAG, n, #ids))
		else
			print(TAG .. " 5 batch GAGAL " .. tostring((map :: any).code))
		end
	end

	-- 6. Bisakah AvatarBackground / Makeup DIPAKAI di avatar? (laporan: background gagal Try)
	--    HumanoidDescription = satu-satunya jalan memasang item; kalau tidak ada slotnya, tidak bisa.
	local desc = Instance.new("HumanoidDescription")
	local props = {}
	for _, name in
		{
			"AvatarBackground",
			"Background",
			"BackgroundAccessory",
			"FaceMakeup",
			"LipMakeup",
			"EyeMakeup",
			"Eyebrows",
			"Eyelashes",
			"MoodAnimation",
			"IdleAnimation",
			"Face",
			"Head",
		}
	do
		local ok = pcall(function()
			return (desc :: any)[name]
		end)
		table.insert(props, ("%s=%s"):format(name, if ok then "ADA" else "tidak ada"))
	end
	print(TAG .. " 6 HumanoidDescription: " .. table.concat(props, " "))
	desc:Destroy()

	-- 6b. Apakah aksesori layered menerima tipe Makeup/Background lewat GetAccessories?
	local okAcc, accs = pcall(function()
		return Instance.new("HumanoidDescription"):GetAccessories(true)
	end)
	print(TAG .. " 6b GetAccessories tersedia: " .. tostring(okAcc) .. " (" .. tostring(typeof(accs)) .. ")")

	-- 7. Makeup: tidak punya properti sendiri -> satu-satunya jalan lain adalah ACCESSORY.
	local accTypes = {}
	local okEnum, items = pcall(function()
		return Enum.AccessoryType:GetEnumItems()
	end)
	if okEnum then
		for _, it in items do
			table.insert(accTypes, it.Name)
		end
	end
	print(TAG .. " 7 AccessoryType: " .. table.concat(accTypes, ", "))

	-- 7b. Coba pasang SATU item makeup sungguhan ke HumanoidDescription sebagai accessory.
	local okMake, page = api:searchCatalog({ assetTypes = { A.FaceMakeup }, limit = 10 })
	if okMake and page.items[1] then
		local it = page.items[1]
		print(("%s 7b contoh makeup: %s (%d)"):format(TAG, tostring(it.Name), it.Id))
		for _, typeName in { "FaceMakeup", "Face", "Unknown" } do
			local accType = nil
			pcall(function()
				accType = (Enum.AccessoryType :: any)[typeName]
			end)
			if accType then
				local d = Instance.new("HumanoidDescription")
				local okSet, err = pcall(function()
					d:SetAccessories({ { AssetId = it.Id, AccessoryType = accType, IsLayered = false } }, false)
				end)
				print(("%s 7b SetAccessories %s -> %s %s"):format(TAG, typeName, tostring(okSet), tostring(err)))
				d:Destroy()
			else
				print(("%s 7b AccessoryType.%s tidak ada"):format(TAG, typeName))
			end
		end
	else
		print(TAG .. " 7b tidak dapat contoh item makeup")
	end

	-- 8. UJI SUNGGUHAN: pasang item MAKEUP ke karakter pemain lewat ApplyDescriptionAsync.
	--    SetAccessories(Face) mengembalikan true di tes 7b, tapi itu belum membuktikan item terpasang.
	local Players = game:GetService("Players")
	local player = Players:GetPlayers()[1]
	local char = player and player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local before = humanoid:GetAppliedDescription()
		local okMake2, page2 = api:searchCatalog({ assetTypes = { A.FaceMakeup }, limit = 10 })
		local item = if okMake2 then page2.items[1] else nil
		if item then
			local d = before:Clone()
			-- Roblox: IsLayered hanya boleh true kalau Order diisi -> coba dua bentuk yang sah.
			local variants = {
				{
					label = "rigid",
					entry = { AssetId = item.Id, AccessoryType = Enum.AccessoryType.Face, IsLayered = false },
				},
				{
					label = "layered+order",
					entry = { AssetId = item.Id, AccessoryType = Enum.AccessoryType.Face, IsLayered = true, Order = 1 },
				},
			}
			local okApply, err
			for _, v in variants do
				local wornAccs = before:Clone():GetAccessories(true)
				table.insert(wornAccs, v.entry)
				local okSet = pcall(function()
					d:SetAccessories(wornAccs, true)
				end)
				okApply, err = pcall(function()
					humanoid:ApplyDescriptionAsync(d)
				end)
				print(
					("%s 8 makeup %s (%d) %s SetAccessories=%s Apply=%s %s"):format(
						TAG,
						tostring(item.Name),
						item.Id,
						v.label,
						tostring(okSet),
						tostring(okApply),
						tostring(err)
					)
				)
				task.wait(1)
				local check = humanoid:GetAppliedDescription()
				local hit = false
				for _, a in check:GetAccessories(true) do
					if a.AssetId == item.Id then
						hit = true
					end
				end
				print(("%s 8 %s -> TERPASANG=%s"):format(TAG, v.label, tostring(hit)))
			end
			local worn = 0
			for _, child in char:GetChildren() do
				if child:IsA("Accessory") then
					worn += 1
				end
			end
			print(("%s 8 accessory di karakter: %d"):format(TAG, worn))
			pcall(function()
				humanoid:ApplyDescriptionAsync(before) -- kembalikan avatar semula
			end)
		else
			print(TAG .. " 8 tidak dapat contoh makeup")
		end
	else
		print(TAG .. " 8 tidak ada karakter pemain (jalankan saat Play)")
	end

	print(TAG .. " SELESAI")
end
