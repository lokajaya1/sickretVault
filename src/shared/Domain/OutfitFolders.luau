--!strict
-- DOMAIN MURNI: folder outfit (PlayerData v3). Satu outfit boleh ada di BEBERAPA folder
-- (pola CAC: tombol "Modify Folders" + filter "Not In Any Folders").
--   local folder, err = OutfitFolders.add(data, "Pesta", os.time())
--   OutfitFolders.rename(data, id, name)      OutfitFolders.remove(data, id)
--   OutfitFolders.setFolders(data, outfitId, { 1, 3 })       -- ganti total folder satu outfit
--   local res = OutfitFolders.apply(data, { 4, 5 }, 1, true) -- tambah/lepas 1 folder untuk banyak outfit
--   local rows = OutfitFolders.list(data)     -- { { id, name, createdAt, count } } urut dibuat
-- Bentuk di DataStore (key pendek):
--   data.folders = { { id = 1, n = "Pesta", t = 1789000000 }, ... }
--   data.nextFolderId = 2   -- id tidak pernah dipakai ulang
--   outfit: e.g = { 1, 3 }  -- id folder, urut naik (nil = tidak di folder mana pun)
-- Nama folder dari pemain WAJIB lolos filter teks Roblox di server SEBELUM masuk ke sini.
-- Nama ganda (beda huruf besar/kecil pun) DITOLAK supaya tab folder tidak membingungkan.

local Wardrobe = require(script.Parent.Wardrobe)

local OutfitFolders = {}

OutfitFolders.MAX_FOLDERS = 12
OutfitFolders.MAX_NAME = 24 -- karakter (utf8)
OutfitFolders.MAX_PER_OUTFIT = 8

local MAX_ID = 2 ^ 53

export type Entry = {
	id: number,
	n: string, -- nama (sudah difilter)
	t: number, -- dibuat (os.time)
}

export type Summary = {
	id: number,
	name: string,
	createdAt: number,
	count: number, -- jumlah outfit di folder ini
}

export type BulkResult = {
	changed: number, -- outfit yang benar-benar berubah
	skipped: number, -- outfit hilang / sudah penuh folder
}

type Data = { outfits: { Wardrobe.Entry }, folders: { Entry }, nextFolderId: number }

local function isId(x: any): boolean
	return type(x) == "number" and x > 0 and x % 1 == 0 and x <= MAX_ID
end

local function isTime(x: any): boolean
	return type(x) == "number" and x == x and x >= 0 and x < math.huge
end

-- Id folder sebuah outfit: buang yang rusak / ganda / tidak ada di `valid`, urut naik, maks MAX_PER_OUTFIT.
local function cleanIds(raw: any, valid: { [number]: boolean }?): { number }
	local out: { number } = {}
	if type(raw) ~= "table" then
		return out
	end
	local seen: { [number]: boolean } = {}
	for _, id in ipairs(raw) do
		if isId(id) and not seen[id] and (valid == nil or valid[id] == true) then
			seen[id] = true
			table.insert(out, id)
		end
	end
	table.sort(out)
	while #out > OutfitFolders.MAX_PER_OUTFIT do
		table.remove(out)
	end
	return out
end

-- Tulis ke entry outfit: kosong disimpan sebagai nil (hemat ukuran DataStore).
local function store(entry: Wardrobe.Entry, ids: { number })
	entry.g = if #ids > 0 then ids else nil
end

local function validSet(data: Data): { [number]: boolean }
	local set: { [number]: boolean } = {}
	for _, f in data.folders do
		set[f.id] = true
	end
	return set
end

-- ===== Nama =====

-- Sama dengan Wardrobe.cleanName, batas panjang sendiri. Belum difilter Roblox!
function OutfitFolders.cleanName(raw: any): (string?, string?)
	return Wardrobe.cleanName(raw, OutfitFolders.MAX_NAME)
end

-- Nama sudah dipakai folder lain? (huruf besar/kecil diabaikan; `exceptId` untuk ganti nama)
function OutfitFolders.nameTaken(data: Data, name: string, exceptId: number?): boolean
	local target = string.lower(name)
	for _, f in data.folders do
		if f.id ~= exceptId and string.lower(f.n) == target then
			return true
		end
	end
	return false
end

-- ===== Skema =====

-- Lengkapi data.folders & data.nextFolderId, lalu buang id folder mati dari setiap outfit.
-- Dipanggil dari PlayerData.migrate SETELAH Wardrobe.sanitize. Mengubah di tempat.
function OutfitFolders.sanitize(data: any)
	local clean: { Entry } = {}
	local seen: { [number]: boolean } = {}
	local maxId = 0
	if type(data.folders) == "table" then
		for _, f in ipairs(data.folders) do
			if type(f) == "table" and isId(f.id) and type(f.n) == "string" and not seen[f.id] then
				seen[f.id] = true
				if not isTime(f.t) then
					f.t = 0
				end
				maxId = math.max(maxId, f.id)
				table.insert(clean, f)
			end
		end
	end
	data.folders = clean
	local nextId = data.nextFolderId
	if not isId(nextId) or nextId <= maxId then
		data.nextFolderId = maxId + 1
	end
	if type(data.outfits) == "table" then
		for _, e in ipairs(data.outfits) do
			if type(e) == "table" then
				store(e, cleanIds(e.g, seen))
			end
		end
	end
end

-- ===== Operasi folder =====

function OutfitFolders.count(data: Data): number
	return #data.folders
end

function OutfitFolders.isFull(data: Data): boolean
	return #data.folders >= OutfitFolders.MAX_FOLDERS
end

function OutfitFolders.find(data: Data, id: any): (Entry?, number?)
	if not isId(id) then
		return nil, nil
	end
	for i, f in data.folders do
		if f.id == id then
			return f, i
		end
	end
	return nil, nil
end

-- `name` harus sudah bersih + difilter. Return (entry, nil) | (nil, "FULL" | "DUPLICATE").
function OutfitFolders.add(data: Data, name: string, now: number): (Entry?, string?)
	if OutfitFolders.isFull(data) then
		return nil, "FULL"
	end
	if OutfitFolders.nameTaken(data, name) then
		return nil, "DUPLICATE"
	end
	local entry: Entry = { id = data.nextFolderId, n = name, t = now }
	data.nextFolderId += 1
	table.insert(data.folders, entry)
	return entry, nil
end

function OutfitFolders.rename(data: Data, id: any, name: string): (boolean, string?)
	local entry = OutfitFolders.find(data, id)
	if entry == nil then
		return false, "NOT_FOUND"
	end
	if OutfitFolders.nameTaken(data, name, entry.id) then
		return false, "DUPLICATE"
	end
	entry.n = name
	return true, nil
end

-- Hapus folder (outfit di dalamnya TIDAK ikut terhapus, hanya dilepas dari folder ini).
function OutfitFolders.remove(data: Data, id: any): (boolean, string?)
	local _, index = OutfitFolders.find(data, id)
	if index == nil then
		return false, "NOT_FOUND"
	end
	table.remove(data.folders, index)
	for _, e in data.outfits do
		if type(e.g) == "table" then
			local kept: { number } = {}
			for _, fid in e.g :: any do
				if fid ~= id then
					table.insert(kept, fid)
				end
			end
			store(e, kept)
		end
	end
	return true, nil
end

-- ===== Keanggotaan outfit =====

function OutfitFolders.foldersOf(data: Data, outfitId: any): { number }
	local entry = Wardrobe.find(data :: any, outfitId)
	if entry == nil then
		return {}
	end
	return cleanIds(entry.g, nil)
end

-- Ganti TOTAL folder satu outfit (halaman detail -> "Modify Folders").
-- Return (true) | (false, "NOT_FOUND" | "BAD_ARG" | "TOO_MANY").
function OutfitFolders.setFolders(data: Data, outfitId: any, ids: any): (boolean, string?)
	local entry = Wardrobe.find(data :: any, outfitId)
	if entry == nil then
		return false, "NOT_FOUND"
	end
	if type(ids) ~= "table" then
		return false, "BAD_ARG"
	end
	local valid = validSet(data)
	local picked: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, fid in ipairs(ids) do
		if not isId(fid) or not valid[fid] then
			return false, "BAD_ARG"
		end
		if not seen[fid] then
			seen[fid] = true
			table.insert(picked, fid)
		end
	end
	if #picked > OutfitFolders.MAX_PER_OUTFIT then
		return false, "TOO_MANY"
	end
	table.sort(picked)
	store(entry, picked)
	return true, nil
end

-- Tambah (value = true) / lepas (false) SATU folder untuk banyak outfit ("Select Outfits").
-- Outfit yang hilang atau sudah punya MAX_PER_OUTFIT folder dilewati, bukan menggagalkan semuanya.
-- Return (result, nil) | (nil, "NOT_FOUND" | "BAD_ARG").
function OutfitFolders.apply(data: Data, outfitIds: any, folderId: any, value: boolean): (BulkResult?, string?)
	if OutfitFolders.find(data, folderId) == nil then
		return nil, "NOT_FOUND"
	end
	if type(outfitIds) ~= "table" then
		return nil, "BAD_ARG"
	end
	local res: BulkResult = { changed = 0, skipped = 0 }
	local done: { [number]: boolean } = {}
	for _, oid in ipairs(outfitIds) do
		if isId(oid) and not done[oid] then
			done[oid] = true
			local entry = Wardrobe.find(data :: any, oid)
			if entry == nil then
				res.skipped += 1
			else
				local ids = cleanIds(entry.g, nil)
				local at = table.find(ids, folderId)
				if value and at == nil then
					if #ids >= OutfitFolders.MAX_PER_OUTFIT then
						res.skipped += 1
					else
						table.insert(ids, folderId)
						table.sort(ids)
						store(entry, ids)
						res.changed += 1
					end
				elseif not value and at ~= nil then
					table.remove(ids, at)
					store(entry, ids)
					res.changed += 1
				end
			end
		end
	end
	return res, nil
end

-- ===== Ringkasan untuk client =====

-- Semua folder (urut dibuat) + jumlah outfit di dalamnya.
function OutfitFolders.list(data: Data): { Summary }
	local total: { [number]: number } = {}
	for _, e in data.outfits do
		for _, fid in cleanIds(e.g, nil) do
			total[fid] = (total[fid] or 0) + 1
		end
	end
	local out: { Summary } = {}
	for _, f in data.folders do
		table.insert(out, { id = f.id, name = f.n, createdAt = f.t, count = total[f.id] or 0 })
	end
	return out
end

return OutfitFolders
