--!strict
-- DOMAIN MURNI: ringkas hasil MarketplaceService.PromptBulkPurchaseFinished (dipakai CLIENT).
--   local summary = CheckoutSummary.summarize(status, results)
-- Docs (Creator Hub, 17 Sep 2026):
--   status  = Enum.MarketplaceBulkPurchasePromptStatus (Completed | Aborted | Error)
--   results = { RobuxSpent = number, Items = { { type = Enum.MarketplaceProductType, id = "<string>",
--               status = Enum.MarketplaceItemPurchaseStatus } } }
-- Enum dibaca lewat .Name, jadi modul ini tidak butuh Enum (bisa dites Lune dengan tabel { Name = ... }).
-- Event ini tidak tepercaya -> hasilnya hanya untuk UI (bersihkan cart, toast).

export type LineRef = { id: number, itemType: string } -- itemType "Asset" | "Bundle"
export type Failed = { id: number, itemType: string, reason: string }
export type Summary = {
	status: string, -- "Completed" | "Aborted" | "Error" | lainnya
	robuxSpent: number,
	purchased: { LineRef }, -- Success
	owned: { LineRef }, -- AlreadyOwned
	failed: { Failed }, -- status lain (InsufficientRobux, NotForSale, ...)
}

local CheckoutSummary = {}

local TYPE_BY_NAME: { [string]: string } = {
	AvatarAsset = "Asset",
	AvatarBundle = "Bundle",
}

-- Nama EnumItem (atau string apa adanya). "" bila tidak bisa dibaca.
function CheckoutSummary.enumName(v: any): string
	if type(v) == "string" then
		return v
	end
	if v == nil then
		return ""
	end
	local ok, name = pcall(function()
		return v.Name
	end)
	return if ok and type(name) == "string" then name else ""
end

local function toRef(line: any): LineRef?
	if type(line) ~= "table" then
		return nil
	end
	local id = tonumber(line.id)
	if id == nil or id <= 0 or id % 1 ~= 0 or id > 2 ^ 53 then
		return nil
	end
	local itemType = TYPE_BY_NAME[CheckoutSummary.enumName(line.type)]
	if itemType == nil then
		return nil
	end
	return { id = id, itemType = itemType }
end

function CheckoutSummary.summarize(status: any, results: any): Summary
	local name = CheckoutSummary.enumName(status)
	local summary: Summary = {
		status = if name ~= "" then name else "Error",
		robuxSpent = 0,
		purchased = {},
		owned = {},
		failed = {},
	}
	if type(results) ~= "table" then
		return summary
	end
	local spent = results.RobuxSpent
	if type(spent) == "number" and spent == spent and spent >= 0 and spent < 2 ^ 53 then
		summary.robuxSpent = spent
	end
	if type(results.Items) ~= "table" then
		return summary
	end
	for _, line in results.Items do
		local ref = toRef(line)
		if ref then
			local s = CheckoutSummary.enumName(line.status)
			if s == "Success" then
				table.insert(summary.purchased, ref)
			elseif s == "AlreadyOwned" then
				table.insert(summary.owned, ref)
			else
				table.insert(summary.failed, {
					id = ref.id,
					itemType = ref.itemType,
					reason = if s ~= "" then s else "Unknown",
				})
			end
		end
	end
	return summary
end

return CheckoutSummary
