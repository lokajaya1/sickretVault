--!strict
-- DOMAIN MURNI: slot outfit tersimpan (Wardrobe) di dalam data pemain (PlayerData v2).
--   local entry, err = Wardrobe.add(data, name, PlayerData.encodeOutfit(state), os.time())
--   Wardrobe.rename(data, id, name, now)   Wardrobe.overwrite(data, id, encoded, now)
--   Wardrobe.setFavorite(data, id, true)   Wardrobe.remove(data, id)   Wardrobe.find(data, id)
--   local rows = Wardrobe.list(data)  -- ringkasan untuk client (urut simpan terbaru dulu; client mengurutkan ulang)
-- Bentuk di DataStore (key pendek supaya hemat ukuran):
--   data.outfits = { { id = 3, n = "Nama", t = 1789000000, u = 1789000500, f = true, g = { 1, 2 }, o = <encodeOutfit> }, ... }
--   (o.mk = makeup di look itu; tidak ada mk = look tanpa makeup)
--   (urut simpan; t = dibuat, u = terakhir diubah (isi/nama), f = favorit (nil = tidak),
--    g = id folder (lihat Domain/OutfitFolders; nil = tidak di folder mana pun))
--   data.nextOutfitId = 4  -- id tidak pernah dipakai ulang (UI yang telat tidak salah sasaran)
-- Nama dari pemain WAJIB lolos filter teks Roblox di server SEBELUM masuk ke sini (lihat WardrobeService).
-- Ukuran: 1 outfit ringkas ~1-2 KB -> 30 slot jauh di bawah batas DataStore 4 MB per key.

local Wardrobe = {}

Wardrobe.MAX_SLOTS = 30
Wardrobe.MAX_NAME = 32 -- karakter (utf8)
Wardrobe.MAX_THUMBS = 4

local MAX_ID = 2 ^ 53

export type Entry = {
	id: number,
	n: string, -- nama (sudah difilter)
	t: number, -- dibuat (os.time)
	u: number?, -- terakhir diubah: simpan / timpa / ganti nama (nil = sama dengan t, data lama)
	f: boolean?, -- favorit
	g: { number }?, -- id folder (OutfitFolders; nil = tidak di folder mana pun)
	o: any, -- PlayerData.encodeOutfit
}

export type Summary = {
	id: number,
	name: string,
	createdAt: number,
	updatedAt: number,
	favorite: boolean,
	folders: { number }, -- id folder tempat outfit ini berada (kosong = "Not In Any Folders")
	count: number, -- jumlah item non-default (aksesori + baju + part tubuh + animasi + makeup)
	makeup: number, -- berapa makeup di look ini (0 = tidak ada); UI memberi label sendiri
	thumbs: { number }, -- assetId untuk thumbnail (maks MAX_THUMBS), cadangan bila render 3D gagal
	outfit: any, -- outfit ringkas (client: PlayerData.decodeOutfit -> render avatar di kartu)
}

type Data = { outfits: { Entry }, nextOutfitId: number }

local function isId(x: any): boolean
	return type(x) == "number" and x > 0 and x % 1 == 0 and x <= MAX_ID
end

local function isTime(x: any): boolean
	return type(x) == "number" and x == x and x >= 0 and x < math.huge
end

-- ===== Nama =====

-- Bersihkan nama dari client: string, tanpa karakter kontrol, spasi dirapikan, 1..max karakter.
-- `max` bawaan MAX_NAME (nama folder memakai batas sendiri, lihat OutfitFolders).
-- Return (nama, nil) | (nil, "BAD_NAME" | "EMPTY" | "TOO_LONG"). Belum difilter Roblox!
function Wardrobe.cleanName(raw: any, max: number?): (string?, string?)
	local limit = if type(max) == "number" then max else Wardrobe.MAX_NAME
	if type(raw) ~= "string" or #raw > limit * 4 or utf8.len(raw) == nil then
		return nil, "BAD_NAME"
	end
	local s = string.gsub(raw, "%c", " ")
	s = string.gsub(s, "%s+", " ")
	s = string.match(s, "^%s*(.-)%s*$") or ""
	local len = utf8.len(s) or 0
	if len == 0 then
		return nil, "EMPTY"
	end
	if len > limit then
		return nil, "TOO_LONG"
	end
	return s, nil
end

-- Nama bawaan buatan server (tidak perlu filter).
function Wardrobe.defaultName(data: Data): string
	return "Outfit " .. tostring(data.nextOutfitId)
end

-- ===== Skema =====

local function validEntry(e: any): boolean
	return type(e) == "table" and isId(e.id) and type(e.n) == "string" and isTime(e.t) and type(e.o) == "table"
end

-- Lengkapi data.outfits & data.nextOutfitId (dipanggil dari PlayerData.migrate). Mengubah di tempat.
-- Entri rusak / id ganda dibuang. Slot di atas MAX_SLOTS TIDAK dihapus (batas bisa diturunkan nanti).
function Wardrobe.sanitize(data: any)
	local clean: { Entry } = {}
	local seen: { [number]: boolean } = {}
	local maxId = 0
	if type(data.outfits) == "table" then
		for _, e in ipairs(data.outfits) do
			if validEntry(e) and not seen[e.id] then
				seen[e.id] = true
				if not isTime(e.u) then
					e.u = nil
				end
				if e.f ~= true then
					e.f = nil -- hanya simpan true (hemat ukuran)
				end
				maxId = math.max(maxId, e.id)
				table.insert(clean, e)
			end
		end
	end
	data.outfits = clean
	local nextId = data.nextOutfitId
	if not isId(nextId) or nextId <= maxId then
		data.nextOutfitId = maxId + 1
	end
end

-- ===== Operasi =====

function Wardrobe.count(data: Data): number
	return #data.outfits
end

function Wardrobe.isFull(data: Data): boolean
	return #data.outfits >= Wardrobe.MAX_SLOTS
end

function Wardrobe.find(data: Data, id: any): (Entry?, number?)
	if not isId(id) then
		return nil, nil
	end
	for i, e in data.outfits do
		if e.id == id then
			return e, i
		end
	end
	return nil, nil
end

-- Tambah slot baru. `name` harus sudah bersih + difilter. Return (entry, nil) | (nil, "FULL").
function Wardrobe.add(data: Data, name: string, encoded: any, now: number): (Entry?, string?)
	if Wardrobe.isFull(data) then
		return nil, "FULL"
	end
	local entry: Entry = { id = data.nextOutfitId, n = name, t = now, u = now, o = encoded }
	data.nextOutfitId += 1
	table.insert(data.outfits, entry)
	return entry, nil
end

-- Timpa isi outfit di slot yang ada (nama tetap). Return (true) | (false, "NOT_FOUND").
function Wardrobe.overwrite(data: Data, id: any, encoded: any, now: number?): (boolean, string?)
	local entry = Wardrobe.find(data, id)
	if entry == nil then
		return false, "NOT_FOUND"
	end
	entry.o = encoded
	if now then
		entry.u = now
	end
	return true, nil
end

function Wardrobe.rename(data: Data, id: any, name: string, now: number?): (boolean, string?)
	local entry = Wardrobe.find(data, id)
	if entry == nil then
		return false, "NOT_FOUND"
	end
	entry.n = name
	if now then
		entry.u = now
	end
	return true, nil
end

-- Tandai / hapus favorit (tidak mengubah "terakhir diubah").
function Wardrobe.setFavorite(data: Data, id: any, value: boolean): (boolean, string?)
	local entry = Wardrobe.find(data, id)
	if entry == nil then
		return false, "NOT_FOUND"
	end
	entry.f = if value then true else nil
	return true, nil
end

function Wardrobe.remove(data: Data, id: any): (boolean, string?)
	local _, index = Wardrobe.find(data, id)
	if index == nil then
		return false, "NOT_FOUND"
	end
	table.remove(data.outfits, index)
	return true, nil
end

-- ===== Ringkasan untuk client =====

-- Salinan id folder (defensif: data DataStore bisa rusak sebelum OutfitFolders.sanitize jalan).
local function folderIds(entry: Entry): { number }
	local out: { number } = {}
	if type(entry.g) == "table" then
		for _, id in ipairs(entry.g :: any) do
			if isId(id) then
				table.insert(out, id)
			end
		end
	end
	return out
end

-- Hitung item & pilih thumbnail dari outfit ringkas (aksesori dulu, lalu baju, lalu part tubuh,
-- makeup paling akhir supaya urutan thumbnail slot lama tidak berubah).
function Wardrobe.summarize(entry: Entry): Summary
	local o = entry.o
	local count = 0
	local thumbs: { number } = {}
	local function take(id: any)
		if not isId(id) then
			return
		end
		count += 1
		if #thumbs < Wardrobe.MAX_THUMBS then
			table.insert(thumbs, id)
		end
	end
	if type(o.ac) == "table" then
		for _, a in ipairs(o.ac) do
			if type(a) == "table" then
				take(a.i)
			end
		end
	end
	for _, key in { "cl", "bp", "an" } do
		local group = o[key]
		if type(group) == "table" then
			-- urut nama slot supaya thumbnail stabil
			local slots = {}
			for slot in group do
				if type(slot) == "string" then
					table.insert(slots, slot)
				end
			end
			table.sort(slots)
			for _, slot in slots do
				local v = group[slot]
				if type(v) == "table" then
					if key == "an" then
						count += if isId(v.i) then 1 else 0 -- animasi: dihitung, tanpa thumbnail
					else
						take(v.i)
					end
				end
			end
		end
	end
	-- makeup (look utuh): assetId ikut dihitung & boleh mengisi sisa slot thumbnail
	local makeupCount = 0
	if type(o.mk) == "table" then
		for _, row in ipairs(o.mk :: any) do
			if type(row) == "table" and isId(row.i) then
				makeupCount += 1
				take(row.i)
			end
		end
	end

	return {
		id = entry.id,
		name = entry.n,
		createdAt = entry.t,
		updatedAt = entry.u or entry.t,
		favorite = entry.f == true,
		folders = folderIds(entry),
		count = count,
		makeup = makeupCount,
		thumbs = thumbs,
		outfit = o,
	}
end

-- Semua slot, terbaru dulu.
function Wardrobe.list(data: Data): { Summary }
	local out: { Summary } = {}
	for i = #data.outfits, 1, -1 do
		table.insert(out, Wardrobe.summarize(data.outfits[i]))
	end
	return out
end

return Wardrobe
