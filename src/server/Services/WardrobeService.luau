--!strict
-- Wardrobe (server): simpan LOOK sekarang (outfit + makeup) ke slot, daftar, pakai, timpa,
-- ganti nama, favorit, hapus, setting,
-- plus folder outfit (buat/ganti nama/hapus, pindah satu atau banyak) & hapus banyak sekaligus.
--   local wardrobe = WardrobeService.new({ playerData = playerData, avatar = avatar })
--   local res = wardrobe:handle(player, req)  -- req SUDAH lolos WardrobeValidator (YIELD: filter nama)
--   res = { ok = true, outfits?, folders?, outfit?, settings?, max?, maxFolders?, removed?, changed?, skipped? }
--       | { ok = false, code }
-- Kode gagal: NOT_LOADED (data belum/gagal dimuat) | NOT_READY (avatar belum siap) | FULL | NOT_FOUND
--   | INVALID (slot rusak) | BUSY (permintaan lain masih jalan) | FILTER_FAILED (TextService error)
--   | FILTERED (nama kena filter -> minta nama lain) | DUPLICATE (nama folder sudah ada)
--   | TOO_MANY (folder per outfit melebihi batas) | BAD_ARG.
-- Nama dari pemain WAJIB lewat filter teks Roblox di server sebelum disimpan (aturan Roblox).
-- Konteks Broadcast dipakai karena nama bisa tampil ke pemain lain nanti (Community Outfits).
-- Nama yang berubah oleh filter (jadi ###) DITOLAK, bukan disimpan -> pemain memilih nama lain.
-- Permintaan yang mengubah data membalas daftar terbaru (`outfits`) supaya client cukup 1 round trip.
-- `filterName` bisa diganti saat test.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Wardrobe = require(Shared.Domain.Wardrobe)
local OutfitFolders = require(Shared.Domain.OutfitFolders)
local Retry = require(Shared.Util.Retry)
local Log = require(Shared.Util.Log)

local log = Log.new("WardrobeService")

-- (true, teksTerfilter) | (false, pesanError). Boleh yield.
export type FilterName = (player: any, text: string) -> (boolean, string?)

-- Slot menyimpan look UTUH: makeup ikut disimpan, dan memakai slot TANPA makeup membersihkan
-- makeup yang sedang dipakai (slot lama = look tanpa makeup).
export type Deps = {
	playerData: any, -- PlayerDataService
	avatar: any, -- AvatarService (getState, getMakeup, wearOutfit)
	makeup: any?, -- MakeupService (resolveRows); nil = makeup di slot diabaikan
	items: any?, -- OutfitItemsService (nama & harga item); nil = op "items" menjawab DISABLED
	filterName: FilterName?, -- default TextService (Broadcast)
}

local WardrobeService = {}
WardrobeService.__index = WardrobeService

export type WardrobeService = typeof(setmetatable(
	{} :: {
		_data: any,
		_avatar: any,
		_makeup: any,
		_itemsService: any,
		_filter: FilterName,
		_busy: { [any]: boolean },
	},
	WardrobeService
))

local function defaultFilter(player: any, text: string): (boolean, string?)
	local TextService = game:GetService("TextService")
	local ok, result = Retry.run(function()
		local filtered = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end, { attempts = 2, baseDelay = 0.5 })
	if not ok then
		return false, tostring(result)
	end
	return true, result
end

local function fail(code: string): any
	return { ok = false, code = code }
end

-- Makeup yang sedang dipakai (Makeup.State) -- ikut disimpan ke slot.
local function currentMakeup(self: any, player: any): any
	if self._avatar.getMakeup == nil then
		return nil
	end
	return self._avatar:getMakeup(player)
end

function WardrobeService.new(deps: Deps): WardrobeService
	assert(deps and deps.playerData and deps.avatar, "WardrobeService butuh deps.playerData & deps.avatar")
	return setmetatable({
		_data = deps.playerData,
		_avatar = deps.avatar,
		_makeup = deps.makeup,
		_itemsService = deps.items,
		_filter = deps.filterName or defaultFilter,
		_busy = {},
	}, WardrobeService)
end

-- Filter nama (yield). Dipakai untuk nama outfit DAN nama folder.
-- Return (nama, nil) | (nil, "FILTER_FAILED" | "FILTERED").
function WardrobeService._filterName(self: WardrobeService, player: any, name: string): (string?, string?)
	local pOk, ok, result = pcall(self._filter, player, name)
	if not pOk or not ok or type(result) ~= "string" then
		log.warn("filter nama gagal", player.Name, if pOk then result else ok)
		return nil, "FILTER_FAILED"
	end
	if result ~= name then
		return nil, "FILTERED"
	end
	return result, nil
end

function WardrobeService._list(self: WardrobeService, player: any): any
	local outfits, code = self._data:listOutfits(player)
	if outfits == nil then
		return fail(code or "NOT_LOADED")
	end
	return {
		ok = true,
		outfits = outfits,
		folders = self._data:listFolders(player) or {},
		max = Wardrobe.MAX_SLOTS,
		maxFolders = OutfitFolders.MAX_FOLDERS,
		settings = self._data:getSettings(player),
	}
end

-- Sukses mengubah data -> balas daftar terbaru (+ field tambahan).
function WardrobeService._changed(self: WardrobeService, player: any, extra: { [string]: any }?): any
	local res = self:_list(player)
	if res.ok and extra then
		for k, v in extra do
			res[k] = v
		end
	end
	return res
end

function WardrobeService._save(self: WardrobeService, player: any, name: string?): any
	local full = self._data:outfitSlotInfo(player)
	if full == nil then
		return fail("NOT_LOADED")
	elseif full then
		return fail("FULL")
	end
	if self._avatar:getState(player) == nil then
		return fail("NOT_READY")
	end
	local finalName: string? = nil
	if name ~= nil then
		local filtered, code = self:_filterName(player, name) -- yield
		if filtered == nil then
			return fail(code :: string)
		end
		finalName = filtered
	end
	-- ambil look SETELAH yield: yang disimpan = yang sedang dipakai saat ini
	local state = self._avatar:getState(player)
	if state == nil then
		return fail("NOT_READY")
	end
	local summary, code = self._data:addOutfit(player, finalName, state, currentMakeup(self, player))
	if summary == nil then
		return fail(code or "FAILED")
	end
	return self:_changed(player, { outfit = summary })
end

-- Pakai isi slot sebagai LOOK utuh. Makeup di slot di-resolve dulu (YIELD: InsertService lewat
-- gateway; template biasanya sudah di-cache). Slot tanpa makeup -> makeup sekarang dibersihkan.
function WardrobeService._wear(self: WardrobeService, player: any, id: number): any
	local state, rows, code = self._data:getOutfitLook(player, id)
	if state == nil then
		return fail(code or "NOT_FOUND")
	end
	local makeup = nil
	if self._makeup ~= nil and rows ~= nil and #rows > 0 then
		makeup = self._makeup:resolveRows(rows) -- yield
	end
	local ok, wearCode = self._avatar:wearOutfit(player, state, makeup)
	if not ok and wearCode ~= "NOTHING" then
		return fail(wearCode or "FAILED")
	end
	return { ok = true }
end

function WardrobeService._overwrite(self: WardrobeService, player: any, id: number): any
	local state = self._avatar:getState(player)
	if state == nil then
		return fail("NOT_READY")
	end
	local ok, code = self._data:overwriteOutfit(player, id, state, currentMakeup(self, player))
	if not ok then
		return fail(code or "FAILED")
	end
	return self:_changed(player)
end

function WardrobeService._rename(self: WardrobeService, player: any, id: number, name: string): any
	local filtered, filterCode = self:_filterName(player, name) -- yield
	if filtered == nil then
		return fail(filterCode :: string)
	end
	local ok, code = self._data:renameOutfit(player, id, filtered)
	if not ok then
		return fail(code or "FAILED")
	end
	return self:_changed(player)
end

function WardrobeService._delete(self: WardrobeService, player: any, id: number): any
	local ok, code = self._data:deleteOutfit(player, id)
	if not ok then
		return fail(code or "FAILED")
	end
	return self:_changed(player)
end

-- Nama & harga item di dalam outfit (halaman detail). YIELD (API katalog lewat gateway).
function WardrobeService._items(self: WardrobeService, player: any, id: number): any
	if self._itemsService == nil then
		return fail("DISABLED")
	end
	local state, rows, code = self._data:getOutfitLook(player, id)
	if state == nil then
		return fail(code or "NOT_FOUND")
	end
	local ok, res = self._itemsService:list(state, rows)
	if not ok then
		return fail((res and res.code) or "FAILED")
	end
	return { ok = true, id = id, items = res.items, total = res.total, missing = res.missing }
end

function WardrobeService._favorite(self: WardrobeService, player: any, id: number, value: boolean): any
	local ok, code = self._data:favoriteOutfit(player, id, value)
	if not ok then
		return fail(code or "FAILED")
	end
	return self:_changed(player)
end

-- ===== Folder =====

function WardrobeService._folderAdd(self: WardrobeService, player: any, name: string): any
	local full = self._data:folderSlotInfo(player)
	if full == nil then
		return fail("NOT_LOADED")
	elseif full then
		return fail("FULL")
	end
	local filtered, code = self:_filterName(player, name) -- yield
	if filtered == nil then
		return fail(code :: string)
	end
	local id, addCode = self._data:addFolder(player, filtered)
	if id == nil then
		return fail(addCode or "FAILED")
	end
	return self:_changed(player, { folder = id })
end

function WardrobeService._folderRename(self: WardrobeService, player: any, id: number, name: string): any
	local filtered, code = self:_filterName(player, name) -- yield
	if filtered == nil then
		return fail(code :: string)
	end
	local ok, renameCode = self._data:renameFolder(player, id, filtered)
	if not ok then
		return fail(renameCode or "FAILED")
	end
	return self:_changed(player)
end

-- Hapus folder saja: outfit di dalamnya tetap ada.
function WardrobeService._folderDelete(self: WardrobeService, player: any, id: number): any
	local ok, code = self._data:deleteFolder(player, id)
	if not ok then
		return fail(code or "FAILED")
	end
	return self:_changed(player)
end

function WardrobeService._setFolders(self: WardrobeService, player: any, id: number, folders: { number }): any
	local ok, code = self._data:setOutfitFolders(player, id, folders)
	if not ok then
		return fail(code or "FAILED")
	end
	return self:_changed(player)
end

-- ===== Banyak sekaligus ("Select Outfits") =====

function WardrobeService._bulkDelete(self: WardrobeService, player: any, ids: { number }): any
	local removed, code = self._data:deleteOutfits(player, ids)
	if removed == nil then
		return fail(code or "FAILED")
	end
	return self:_changed(player, { removed = removed })
end

function WardrobeService._bulkFolder(
	self: WardrobeService,
	player: any,
	ids: { number },
	folderId: number,
	value: boolean
): any
	local res, code = self._data:applyFolder(player, ids, folderId, value)
	if res == nil then
		return fail(code or "FAILED")
	end
	return self:_changed(player, { changed = res.changed, skipped = res.skipped })
end

function WardrobeService._setSetting(self: WardrobeService, player: any, key: string, value: any): any
	local ok, code = self._data:setSetting(player, key, value)
	if not ok then
		return fail(code or "FAILED")
	end
	return { ok = true, settings = self._data:getSettings(player) }
end

-- `req` harus hasil WardrobeValidator.validate. Satu permintaan per pemain pada satu waktu.
function WardrobeService.handle(self: WardrobeService, player: any, req: any): any
	local op = req.op
	if op == "list" then
		return self:_list(player) -- tanpa yield, tidak perlu kunci
	end
	if self._busy[player] then
		return fail("BUSY")
	end
	self._busy[player] = true
	local pOk, res = pcall(function()
		if op == "save" then
			return self:_save(player, req.name)
		elseif op == "wear" then
			return self:_wear(player, req.id)
		elseif op == "overwrite" then
			return self:_overwrite(player, req.id)
		elseif op == "rename" then
			return self:_rename(player, req.id, req.name)
		elseif op == "delete" then
			return self:_delete(player, req.id)
		elseif op == "items" then
			return self:_items(player, req.id)
		elseif op == "favorite" then
			return self:_favorite(player, req.id, req.value)
		elseif op == "setSetting" then
			return self:_setSetting(player, req.key, req.value)
		elseif op == "folderAdd" then
			return self:_folderAdd(player, req.name)
		elseif op == "folderRename" then
			return self:_folderRename(player, req.id, req.name)
		elseif op == "folderDelete" then
			return self:_folderDelete(player, req.id)
		elseif op == "setFolders" then
			return self:_setFolders(player, req.id, req.folders)
		elseif op == "bulkDelete" then
			return self:_bulkDelete(player, req.ids)
		elseif op == "bulkFolder" then
			return self:_bulkFolder(player, req.ids, req.id, req.value)
		end
		return fail("BAD_ARG")
	end)
	self._busy[player] = nil
	if not pOk then
		log.error("handle error", op, player.Name, res)
		return fail("FAILED")
	end
	return res
end

-- PlayerRemoving: bersihkan kunci.
function WardrobeService.forget(self: WardrobeService, player: any)
	self._busy[player] = nil
end

return WardrobeService
