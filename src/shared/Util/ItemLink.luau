--!strict
-- Kenali link / ID item katalog yang ditempel pemain.
--   ItemLink.parse("https://www.roblox.com/catalog/123456/Cool-Hat") --> 123456, "Asset"
--   ItemLink.parse("roblox.com/bundles/789/Some-Bundle")            --> 789, "Bundle"
--   ItemLink.parse("  123456 ")                                      --> 123456, "Asset"
--   ItemLink.parse("red hat")                                        --> nil
-- Server tetap memvalidasi ID (IntentValidator + ItemInfoService); ini hanya pengenal di client.

export type Kind = "Asset" | "Bundle"

local ItemLink = {}

ItemLink.MAX_DIGITS = 16
ItemLink.MAX_ID = 2 ^ 53 -- sama dengan GameConfig MaxId (server menolak di atas ini)

local function toId(digits: string?): number?
	if digits == nil or #digits == 0 or #digits > ItemLink.MAX_DIGITS then
		return nil
	end
	local n = tonumber(digits)
	if n == nil or n <= 0 or n > ItemLink.MAX_ID then
		return nil
	end
	return n
end

function ItemLink.parse(text: string): (number?, Kind?)
	local s = text:match("^%s*(.-)%s*$") or ""
	if s == "" then
		return nil, nil
	end

	-- ID polos
	if s:match("^%d+$") then
		local id = toId(s)
		return id, if id then "Asset" else nil
	end

	-- Link: hanya domain roblox.com (boleh www. / web. / tanpa https)
	local lower = s:lower():gsub("^%a+://", "")
	local host, path = lower:match("^([%w%.%-]+)(/.*)$")
	if host == nil or path == nil then
		return nil, nil
	end
	if host ~= "roblox.com" and not host:match("%.roblox%.com$") then
		return nil, nil
	end

	local bundle = path:match("^/bundles/(%d+)")
	if bundle then
		local id = toId(bundle)
		return id, if id then "Bundle" else nil
	end
	local asset = path:match("^/catalog/(%d+)") or path:match("^/library/(%d+)")
	if asset then
		local id = toId(asset)
		return id, if id then "Asset" else nil
	end
	return nil, nil
end

-- Teks terlihat seperti percobaan link/ID (dipakai untuk TIDAK mencari saat mengetik).
function ItemLink.looksLikeLink(text: string): boolean
	local s = (text:match("^%s*(.-)%s*$") or ""):lower()
	return s:match("^%d+$") ~= nil or s:find("roblox%.com") ~= nil or s:match("^https?:") ~= nil
end

return ItemLink
