--!strict
-- Inspeksi API Roblox ASLI (khusus developer). Hanya jalan di Studio saat Play
-- dan jika Features.DevInspect = true. Dipanggil otomatis dari init.server.
-- Mencetak respons mentah + ringkasan ✅/❌ untuk docs/API_VERIFICATION.md.
-- Id contoh TIDAK ditulis tangan: diambil dari hasil SearchCatalogAsync.
--
--   Inspect.run(api)   -- api = RobloxApi.new()

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Features = require(ReplicatedStorage:WaitForChild("Shared").Config.Features)

local TAG = "[INSPECT]"
local MAX_DEPTH = 4
local MAX_LIST = 12 -- elemen array yang dicetak per tabel

local Inspect = {}

type Row = { api: string, ok: boolean, note: string }

-- Ubah nilai jadi teks mirip tabel Luau (supaya bisa ditempel ke fixture).
function Inspect.dump(value: any, depth: number?, indent: string?): string
	local d = depth or 0
	local pad = indent or ""
	local t = typeof(value)
	if t == "string" then
		return string.format("%q", value)
	elseif t == "EnumItem" then
		return tostring(value)
	elseif t == "Instance" then
		return ("<%s %s>"):format(value.ClassName, value.Name)
	elseif t ~= "table" then
		return tostring(value)
	end
	if d >= MAX_DEPTH then
		return "{ ... }"
	end
	local keys = {}
	for k in value do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		return a < b
	end)
	if #keys == 0 then
		return "{}"
	end
	local inner = pad .. "\t"
	local lines = {}
	local arrayLen = #value
	local shown = 0
	for _, k in keys do
		-- kunci 1..n = array (tanpa kunci); angka lain (mis. id aset) ditulis [id] =
		local isArrayKey = type(k) == "number" and k >= 1 and k <= arrayLen and k % 1 == 0
		if isArrayKey then
			shown += 1
			if shown > MAX_LIST then
				table.insert(lines, inner .. ("-- ... %d elemen lagi"):format(arrayLen - MAX_LIST))
				break
			end
		end
		local keyText = if isArrayKey
			then ""
			elseif type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then k .. " = "
			elseif type(k) == "number" then ("[%d] = "):format(k)
			else "[" .. Inspect.dump(k, MAX_DEPTH) .. "] = "
		table.insert(lines, inner .. keyText .. Inspect.dump(value[k], d + 1, inner) .. ",")
	end
	return "{\n" .. table.concat(lines, "\n") .. "\n" .. pad .. "}"
end

local function section(title: string, value: any)
	print(("%s ===== %s =====\n%s"):format(TAG, title, Inspect.dump(value)))
end

local function keysOf(value: any): string
	if type(value) ~= "table" then
		return typeof(value)
	end
	local keys = {}
	for k in value do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	return table.concat(keys, ", ")
end

local function firstId(items: { any }, itemType: string): number?
	for _, it in items do
		if type(it) == "table" and it.ItemType == itemType and type(it.Id) == "number" then
			return it.Id
		end
	end
	return nil
end

function Inspect.run(api: any)
	if not RunService:IsStudio() or not RunService:IsRunning() or not Features.DevInspect then
		return
	end
	local rows: { Row } = {}
	local function record(name: string, ok: boolean, note: string)
		table.insert(rows, { api = name, ok = ok, note = note })
	end

	-- 1. GetAvatarRulesAsync
	local okRules, rules = api:getAvatarRules()
	record("GetAvatarRulesAsync", okRules, if okRules then "kunci: " .. keysOf(rules) else rules.message)
	if okRules then
		section("GetAvatarRulesAsync (kunci atas)", keysOf(rules))
		-- Ringkas: "Nama=MaxNumber" per tipe (sumber Limits)
		local wear = {}
		for _, w in rules.WearableAssetTypes or {} do
			table.insert(wear, ("%s(%s)=%s"):format(tostring(w.Name), tostring(w.Id), tostring(w.MaxNumber)))
		end
		section("GetAvatarRulesAsync.WearableAssetTypes (Nama(Id)=Max)", table.concat(wear, ", "))
		section("GetAvatarRulesAsync.Scales", rules.Scales)
		section("GetAvatarRulesAsync.AccessoryRefinement*", {
			Types = rules.AccessoryRefinementTypes,
			LowerBounds = rules.AccessoryRefinementLowerBounds,
			UpperBounds = rules.AccessoryRefinementUpperBounds,
		})
	end

	-- 2. SearchCatalogAsync (aset) -> sumber id contoh
	local okSearch, page = api:searchCatalog({
		assetTypes = { Enum.AvatarAssetType.Hat },
		limit = 120,
	})
	local assetIds: { number } = {}
	if okSearch then
		for _, it in page.items do
			if type(it) == "table" and type(it.Id) == "number" then
				table.insert(assetIds, it.Id)
			end
		end
		record("SearchCatalogAsync", true, ("%d item, IsFinished=%s"):format(#page.items, tostring(page.isFinished)))
		section("SearchCatalogAsync item[1]", page.items[1])
		local okNext, page2 = api:nextPage(page)
		if okNext then
			-- id halaman 2 ikut dipakai supaya batch 120/150 bisa diuji
			for _, it in page2.items do
				if type(it) == "table" and type(it.Id) == "number" then
					table.insert(assetIds, it.Id)
				end
			end
		end
		record(
			"CatalogPages:AdvanceToNextPageAsync",
			okNext,
			if okNext then ("%d item"):format(#page2.items) else page2.message
		)
	else
		record("SearchCatalogAsync", false, page.message)
	end

	-- 3. GetItemDetailsAsync
	local assetId = assetIds[1]
	if assetId then
		local okItem, item = api:getItemDetails(assetId, Enum.AvatarItemType.Asset)
		record("GetItemDetailsAsync", okItem, if okItem then "kunci: " .. keysOf(item) else item.message)
		if okItem then
			section("GetItemDetailsAsync " .. assetId, item)
		end
	else
		record("GetItemDetailsAsync", false, "dilewati: tidak ada id dari search")
	end

	-- 4. GetBatchItemDetailsAsync: cari batas batch (panggil langsung tanpa cache/retry)
	local aes = game:GetService("AvatarEditorService")
	local sizes = { 100, 101, 120, 150, 200 }
	local notes = {}
	local anyBatchOk = false
	for _, n in sizes do
		if #assetIds >= n then
			local chunk = table.move(assetIds, 1, n, 1, {})
			local ok, res = pcall(function()
				return aes:GetBatchItemDetailsAsync(chunk, Enum.AvatarItemType.Asset)
			end)
			anyBatchOk = anyBatchOk or ok
			local resText = if ok then ("✅ %d hasil"):format(#res) else "❌ " .. tostring(res)
			table.insert(notes, ("%d id -> %s"):format(n, resText))
			task.wait(1)
		end
	end
	record("GetBatchItemDetailsAsync", anyBatchOk, table.concat(notes, " | "))

	-- 5. Bundle tubuh: GetBundleDetailsAsync + tipe aset + outfit
	local okB, bpage = api:searchCatalog({
		bundleTypes = { Enum.BundleType.BodyParts },
		limit = 10,
	})
	local bundleId = if okB then firstId(bpage.items, "Bundle") else nil
	if bundleId then
		local okBundle, bundle = api:getBundleDetails(bundleId)
		record("GetBundleDetailsAsync", okBundle, if okBundle then "kunci: " .. keysOf(bundle) else bundle.message)
		if okBundle then
			section("GetBundleDetailsAsync " .. bundleId .. " (tempel ke fixtures: raw)", bundle)
			local partIds, outfitIds = {}, {}
			for _, it in bundle.Items or {} do
				if it.Type == "Asset" then
					table.insert(partIds, it.Id)
				elseif it.Type == "UserOutfit" then
					table.insert(outfitIds, it.Id)
				end
			end
			section(
				"Jumlah Items bundle / UserOutfit",
				("%d item, outfit: %s"):format(#(bundle.Items or {}), table.concat(outfitIds, ", "))
			)
			local okTypes, map = api:getBatchItemDetails(partIds, Enum.AvatarItemType.Asset)
			if okTypes then
				local assetTypes = {}
				for id, detail in map do
					assetTypes[id] = detail.AssetType
				end
				section("Tipe aset bagian bundle (tempel ke fixtures: assetTypes)", assetTypes)
			end
			if #outfitIds == 0 then
				record("GetOutfitDetailsAsync", false, "dilewati: bundle tanpa UserOutfit")
			end
			-- Semua UserOutfit dicek (bundle bisa punya >1, mis. outfit penuh + outfit kepala)
			for i, outfitId in outfitIds do
				local okO, outfit = api:getOutfitDetails(outfitId)
				local label = ("GetOutfitDetailsAsync #%d"):format(i)
				record(
					label,
					okO,
					if okO then ("%s OutfitType=%s"):format(outfitId, tostring(outfit.OutfitType)) else outfit.message
				)
				if okO then
					section(label .. " " .. outfitId .. " (sumber enrichment)", outfit)
				end
				local okD, desc = api:getDescriptionFromOutfitId(outfitId)
				record(
					"GetHumanoidDescriptionFromOutfitIdAsync #" .. i,
					okD,
					if okD
						then ("Height=%s Width=%s Depth=%s Head=%s BodyType=%s Proportion=%s"):format(
							desc.HeightScale,
							desc.WidthScale,
							desc.DepthScale,
							desc.HeadScale,
							desc.BodyTypeScale,
							desc.ProportionScale
						)
						else desc.message
				)
			end
		end
	else
		record("GetBundleDetailsAsync", false, "dilewati: tidak ada bundle dari search")
	end

	-- 6. Description dari user + ApplyDescriptionAsync ke karakter pemain pertama
	local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
	local userId = if player.UserId > 0 then player.UserId else 1
	local okU, desc = api:getDescriptionFromUserId(userId)
	record("GetHumanoidDescriptionFromUserIdAsync", okU, if okU then "userId " .. userId else desc.message)
	local character = player.Character or player.CharacterAdded:Wait()
	local humanoid = character:WaitForChild("Humanoid", 10)
	if okU and humanoid then
		local okA, errA = api:applyDescription(humanoid, desc)
		record("Humanoid:ApplyDescriptionAsync", okA, if okA then "diterapkan ke " .. player.Name else errA.message)
	else
		record("Humanoid:ApplyDescriptionAsync", false, "dilewati: tidak ada description/humanoid")
	end

	-- Ringkasan
	print(TAG .. " ===== RINGKASAN (salin ke docs/API_VERIFICATION.md) =====")
	for _, r in rows do
		print(("%s | %s | %s | %s"):format(TAG, r.api, if r.ok then "✅" else "❌", r.note))
	end
	print(TAG .. " selesai")
end

return Inspect
