--!strict
-- DOMAIN MURNI: tidak memanggil service Roblox apa pun, tidak membuat Instance.
-- Makeup TIDAK bisa dipakai lewat HumanoidDescription (spike #17c). Jalurnya: tekstur yang
-- ditempel ke Head sebagai Decal (spike #18). Modul ini hanya mengurus ATURAN & BENTUK DATA-nya:
--   - satu item per slot (face / eye / lip),
--   - urutan pasang tetap face -> eye -> lip (ZIndex Decal tidak terbukti berpengaruh),
--   - texture id WAJIB hasil InsertService:LoadAsset di server (id item != id texture).
-- Penempelan Decal-nya sendiri ada di AvatarService (server) dan preview (client).

local M = {}

-- Nama Enum.AvatarAssetType -> slot.
local SLOT_OF_ASSET_TYPE: { [string]: string } = {
	FaceMakeup = "face",
	EyeMakeup = "eye",
	LipMakeup = "lip",
}
M.SlotOfAssetType = SLOT_OF_ASSET_TYPE

-- Urutan pasang; yang terakhir ditempel dianggap paling atas.
local SLOTS: { string } = { "face", "eye", "lip" }
M.Slots = SLOTS

M.MaxPerSlot = 1

export type Entry = {
	assetId: number,
	slot: string,
	textureId: string,
}

-- Kunci tabel = nama slot.
export type State = { [string]: Entry }

local TEXTURE_PATTERN = "^rbxassetid://%d+$"

local isSlot: { [string]: boolean } = {}
for _, slot in SLOTS do
	isSlot[slot] = true
end

-- Slot untuk satu nama asset type; nil kalau bukan makeup.
function M.slotOf(assetTypeName: string?): string?
	if type(assetTypeName) ~= "string" then
		return nil
	end
	return SLOT_OF_ASSET_TYPE[assetTypeName]
end

function M.isMakeup(assetTypeName: string?): boolean
	return M.slotOf(assetTypeName) ~= nil
end

function M.isValidSlot(slot: any): boolean
	return type(slot) == "string" and isSlot[slot] == true
end

-- "rbxassetid://98880692903650" — bentuk yang dikembalikan Decal.Texture.
function M.isValidTexture(textureId: any): boolean
	return type(textureId) == "string" and string.match(textureId, TEXTURE_PATTERN) ~= nil
end

function M.empty(): State
	return {}
end

-- Salinan dangkal; semua operasi mengembalikan State BARU (state lama tidak diubah).
local function copy(state: State): State
	return table.clone(state)
end

-- Pasang satu makeup. Mengembalikan (state baru, nil) atau (nil, kode galat).
function M.set(state: State, entry: Entry): (State?, string?)
	if type(entry) ~= "table" then
		return nil, "BAD_ENTRY"
	end
	if type(entry.assetId) ~= "number" or entry.assetId <= 0 then
		return nil, "BAD_ASSET_ID"
	end
	if not M.isValidSlot(entry.slot) then
		return nil, "BAD_SLOT"
	end
	if not M.isValidTexture(entry.textureId) then
		return nil, "BAD_TEXTURE"
	end

	local out = copy(state)
	-- Satu item per slot: yang lama otomatis tergeser.
	out[entry.slot] = {
		assetId = entry.assetId,
		slot = entry.slot,
		textureId = entry.textureId,
	}
	return out, nil
end

function M.remove(state: State, slot: string): State
	local out = copy(state)
	out[slot] = nil
	return out
end

-- Lepas berdasarkan id item (UI hanya tahu id item, bukan slotnya).
function M.removeAsset(state: State, assetId: number): State
	local out = copy(state)
	for slot, entry in state do
		if entry.assetId == assetId then
			out[slot] = nil
		end
	end
	return out
end

function M.get(state: State, slot: string): Entry?
	return state[slot]
end

function M.hasAsset(state: State, assetId: number): boolean
	for _, entry in state do
		if entry.assetId == assetId then
			return true
		end
	end
	return false
end

-- Daftar makeup URUT sesuai M.Slots — inilah urutan penempelan Decal.
function M.list(state: State): { Entry }
	local out: { Entry } = {}
	for _, slot in SLOTS do
		local entry = state[slot]
		if entry then
			table.insert(out, entry)
		end
	end
	return out
end

function M.count(state: State): number
	return #M.list(state)
end

function M.isEmpty(state: State): boolean
	return M.count(state) == 0
end

function M.equals(a: State, b: State): boolean
	for _, slot in SLOTS do
		local x, y = a[slot], b[slot]
		if (x == nil) ~= (y == nil) then
			return false
		end
		if x and y and (x.assetId ~= y.assetId or x.textureId ~= y.textureId) then
			return false
		end
	end
	return true
end

-- Bentuk ringkas untuk dikirim lewat remote / disimpan.
function M.toDto(state: State): { { assetId: number, slot: string, textureId: string } }
	local out = {}
	for _, entry in M.list(state) do
		table.insert(out, { assetId = entry.assetId, slot = entry.slot, textureId = entry.textureId })
	end
	return out
end

-- Kebalikannya; baris yang cacat DILEWATI (data lama boleh saja tidak utuh).
function M.fromDto(rows: any): State
	local out: State = {}
	if type(rows) ~= "table" then
		return out
	end
	for _, row in rows do
		if type(row) == "table" then
			local next_, err = M.set(out, row :: Entry)
			if next_ and not err then
				out = next_
			end
		end
	end
	return out
end

return M
