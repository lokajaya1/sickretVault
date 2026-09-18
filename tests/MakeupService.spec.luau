--!strict
-- Test MakeupService dengan Head & Decal PALSU (tanpa Studio, tanpa Instance).
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["MakeupService.spec"])()  (jalankan dari server)
local ServerScriptService = game:GetService("ServerScriptService")
local MakeupService = require(ServerScriptService:WaitForChild("Server").Services.MakeupService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Log = require(Shared.Util.Log)

local TEX_FACE = "rbxassetid://98880692903650"
local TEX_EYE = "rbxassetid://123518465016531"
local TEX_LIP = "rbxassetid://77903406032400"

local ID_FACE = 133520807586498
local ID_FACE2 = 133520807586499
local ID_EYE = 128012015026356
local ID_LIP = 106390919006817
local ID_HAT = 555
local ID_GONE = 404
local ID_BROKEN = 500

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

-- Head palsu: hanya GetChildren + daftar anak.
local function makeHead(): any
	local head: any = { children = {} }
	function head.GetChildren(self: any): { any }
		local out = {}
		for _, c in self.children do
			table.insert(out, c)
		end
		return out
	end
	return head
end

-- Anak bawaan (mis. decal 'face' atau SurfaceAppearance) yang TIDAK boleh disentuh.
local function makeNative(head: any, name: string): any
	local native: any = { Name = name }
	function native.Destroy(_self: any)
		native.destroyed = true
	end
	table.insert(head.children, native)
	return native
end

-- Decal palsu: menyetel .Parent ikut mendaftarkan diri ke head (seperti Instance sungguhan).
local function makeDecal(counts: { created: number, destroyed: number }, texture: string?): any
	counts.created += 1
	local raw: any = { Name = "", Texture = texture or "", Face = nil, Parent = nil }
	local proxy: any
	raw.Destroy = function(_self: any)
		local parent = raw.Parent
		if parent then
			local idx = table.find(parent.children, proxy)
			if idx then
				table.remove(parent.children, idx)
			end
		end
		raw.Parent = nil
		counts.destroyed += 1
	end
	proxy = setmetatable({}, {
		__index = raw,
		__newindex = function(_t: any, k: string, v: any)
			raw[k] = v
			if k == "Parent" and v ~= nil then
				table.insert(v.children, proxy)
			end
		end,
	})
	return proxy
end

-- Decal kita saja (nama berawalan SV_Makeup_), urut sesuai urutan tempel.
local function ourDecals(head: any): { any }
	local out = {}
	for _, c in head.children do
		if string.sub(tostring(c.Name), 1, 10) == "SV_Makeup_" then
			table.insert(out, c)
		end
	end
	return out
end

return function()
	Log.setSink(function() end)

	local player = { Name = "uji", UserId = 1 }
	local head = makeHead()
	local native = makeNative(head, "face") -- decal wajah bawaan
	local counts = { created = 0, destroyed = 0 }
	local calls = { info = 0, texture = 0, state = 0 }
	local lastDto: any = nil

	local fakeItemInfo = {}
	function fakeItemInfo.get(_self: any, id: number): (boolean, any)
		calls.info += 1
		if id == ID_GONE then
			return false, { code = "NOT_FOUND" }
		end
		local assetType = "FaceMakeup"
		if id == ID_EYE then
			assetType = "EyeMakeup"
		elseif id == ID_LIP then
			assetType = "LipMakeup"
		elseif id == ID_HAT then
			assetType = "Hat"
		end
		return true, { assetId = id, assetType = assetType }
	end

	-- Template palsu: Clone menghasilkan decal baru yang bisa di-parent ke head palsu.
	local function template(texture: string): any
		local t: any = { Texture = texture, Name = "", Face = nil, Parent = nil }
		function t.Clone(_self: any): any
			return makeDecal(counts, texture)
		end
		return t
	end

	local fakeDecals = {}
	function fakeDecals.getMakeup(_self: any, id: number): (boolean, any)
		calls.texture += 1
		if id == ID_BROKEN then
			return false, { code = "FAILED", message = "HTTP 429" }
		end
		if id == ID_EYE then
			return true, { textureId = TEX_EYE, template = template(TEX_EYE) }
		elseif id == ID_LIP then
			return true, { textureId = TEX_LIP, template = template(TEX_LIP) }
		end
		return true, { textureId = TEX_FACE, template = template(TEX_FACE) }
	end

	local svc = MakeupService.new({
		decals = fakeDecals,
		itemInfo = fakeItemInfo,
		getHead = function()
			return head
		end,
		face = "Front", -- pengganti Enum.NormalId.Front
		onState = function(_p: any, dto: any)
			calls.state += 1
			lastDto = dto
		end,
	})

	-- 1. belum attach -> tidak siap
	local ok, code = svc:wear(player, ID_FACE)
	eq(ok, false, "sebelum attach ditolak")
	eq(code, "NOT_READY", "kode NOT_READY")

	-- 2. pakai satu makeup
	svc:attach(player)
	ok = svc:wear(player, ID_FACE)
	eq(ok, true, "makeup terpasang")
	local worn = ourDecals(head)
	eq(#worn, 1, "satu decal kita di Head")
	eq(worn[1].Name, "SV_Makeup_face", "nama decal menyebut slot")
	eq(worn[1].Texture, TEX_FACE, "texture dari gateway")
	eq(worn[1].Face, "Front", "Face dari deps")
	eq(worn[1].Parent, head, "menempel di Head")
	eq(calls.state, 1, "state dikabarkan sekali")
	eq(#lastDto, 1, "dto satu baris")

	-- 3. decal bawaan TIDAK disentuh
	eq(native.destroyed, nil, "decal 'face' bawaan tidak dihapus")
	eq(#head.children, 2, "bawaan + punya kita")

	-- 4. slot lain menumpuk, urutannya face -> eye -> lip
	svc:wear(player, ID_LIP)
	svc:wear(player, ID_EYE)
	worn = ourDecals(head)
	eq(#worn, 3, "tiga decal")
	eq(worn[1].Name, "SV_Makeup_face", "urutan 1 face")
	eq(worn[2].Name, "SV_Makeup_eye", "urutan 2 eye")
	eq(worn[3].Name, "SV_Makeup_lip", "urutan 3 lip")

	-- 5. item yang sama lagi -> NOTHING, gateway tidak dipanggil ulang
	local textureCallsBefore = calls.texture
	ok, code = svc:wear(player, ID_EYE)
	eq(ok, false, "item yang sama ditolak")
	eq(code, "NOTHING", "kode NOTHING")
	eq(calls.texture, textureCallsBefore, "tidak memanggil gateway lagi")

	-- 6. item lain di slot yang sama MENGGESER, bukan menambah
	ok = svc:wear(player, ID_FACE2)
	eq(ok, true, "makeup face diganti")
	worn = ourDecals(head)
	eq(#worn, 3, "tetap tiga decal")
	eq(#svc:dto(player), 3, "dto tetap tiga")

	-- 7. bukan makeup -> ditolak sebelum menyentuh gateway
	textureCallsBefore = calls.texture
	ok, code = svc:wear(player, ID_HAT)
	eq(ok, false, "topi ditolak")
	eq(code, "UNSUPPORTED_TYPE", "kode UNSUPPORTED_TYPE")
	eq(calls.texture, textureCallsBefore, "gateway tidak dipanggil untuk topi")

	-- 8. item hilang / texture gagal
	ok, code = svc:wear(player, ID_GONE)
	eq(ok, false, "item hilang gagal")
	eq(code, "NOT_FOUND", "kode NOT_FOUND")
	ok, code = svc:wear(player, ID_BROKEN)
	eq(ok, false, "texture gagal")
	eq(code, "FAILED", "kode FAILED")
	eq(#ourDecals(head), 3, "kegagalan tidak mengubah decal terpasang")

	-- 9. lepas satu
	ok = svc:remove(player, ID_EYE)
	eq(ok, true, "eye dilepas")
	worn = ourDecals(head)
	eq(#worn, 2, "sisa dua decal")
	eq(worn[1].Name, "SV_Makeup_face", "urutan tetap")
	eq(worn[2].Name, "SV_Makeup_lip", "urutan tetap")
	eq(svc:isWorn(player, ID_EYE), false, "eye tidak dipakai lagi")
	ok, code = svc:remove(player, 999999)
	eq(ok, false, "id asing")
	eq(code, "NOTHING", "kode NOTHING")

	-- 10. Head DIGANTI (ApplyDescriptionAsync / respawn): decal lama ikut hilang, reapply memasang ulang
	local oldHead = head
	head = makeHead()
	makeNative(head, "face")
	eq(#ourDecals(head), 0, "Head baru masih polos")
	eq(svc:reapply(player), true, "reapply berhasil")
	worn = ourDecals(head)
	eq(#worn, 2, "dua decal dipasang ulang di Head baru")
	eq(worn[1].Texture, TEX_FACE, "texture ikut pindah")
	eq(#ourDecals(oldHead), 2, "Head lama dibiarkan (Roblox yang menghancurkannya)")

	-- 11. belum ada Head: state tetap tersimpan, dipasang saat Head muncul
	local saved = head
	head = nil :: any
	ok = svc:wear(player, ID_EYE)
	eq(ok, true, "wear tetap berhasil tanpa Head")
	eq(#svc:dto(player), 3, "state bertambah")
	eq(svc:reapply(player), false, "reapply bilang belum bisa")
	head = saved
	eq(svc:reapply(player), true, "setelah Head ada")
	eq(#ourDecals(head), 3, "semua dipasang")

	-- 12. clear
	calls.state = 0
	ok = svc:clear(player)
	eq(ok, true, "clear berhasil")
	eq(#ourDecals(head), 0, "tidak ada decal kita")
	eq(#head.children, 1, "bawaan tetap ada")
	eq(calls.state, 1, "state dikabarkan")
	ok, code = svc:clear(player)
	eq(ok, false, "clear kedua tidak mengubah apa-apa")
	eq(code, "NOTHING", "kode NOTHING")

	-- 13. detach
	svc:detach(player)
	ok, code = svc:wear(player, ID_FACE)
	eq(ok, false, "setelah detach ditolak")
	eq(code, "NOT_READY", "kode NOT_READY")
	eq(#svc:dto(player), 0, "dto kosong")

	-- 14. restore dari data tersimpan (assetId + slot; texture diambil ulang dari gateway)
	svc:attach(player)
	local rows = { { assetId = ID_FACE, slot = "face" }, { assetId = ID_LIP, slot = "lip" } }
	ok = svc:restore(player, rows)
	eq(ok, true, "restore berhasil")
	eq(#svc:dto(player), 2, "dua makeup kembali")
	eq(#ourDecals(head), 2, "decal terpasang")
	eq(svc:isWorn(player, ID_FACE), true, "face dipakai lagi")

	-- 15. restore TIDAK menimpa pilihan pemain di sesi ini
	ok, code = svc:restore(player, rows)
	eq(ok, false, "sudah ada makeup -> tidak ditimpa")
	eq(code, "NOTHING", "kode NOTHING")

	-- 16. baris yang gagal dimuat dilewati, sisanya tetap dipasang
	svc:detach(player)
	svc:attach(player)
	ok = svc:restore(player, { { assetId = ID_BROKEN, slot = "face" }, { assetId = ID_LIP, slot = "lip" } })
	eq(ok, true, "sebagian berhasil")
	eq(#svc:dto(player), 1, "hanya yang berhasil")
	eq(svc:isWorn(player, ID_LIP), true, "lip terpasang")
	ok, code = svc:restore(player, { { assetId = ID_GONE, slot = "eye" } })
	eq(ok, false, "state sudah terisi -> ditolak")
	svc:detach(player)
	svc:attach(player)
	ok, code = svc:restore(player, {})
	eq(ok, false, "tidak ada baris")
	eq(code, "NOTHING", "kode NOTHING")
	svc:detach(player)

	print("PASS MakeupService.spec")
end
