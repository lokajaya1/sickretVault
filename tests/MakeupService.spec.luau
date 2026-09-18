--!strict
-- Test MakeupService dengan Head & Decal PALSU (tanpa Studio, tanpa Instance).
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["MakeupService.spec"])()  (jalankan dari server)
-- Sejak PR makeup-wardrobe service ini hanya RESOLVER + RENDERER: state look ada di AvatarService.
local ServerScriptService = game:GetService("ServerScriptService")
local MakeupService = require(ServerScriptService:WaitForChild("Server").Services.MakeupService)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Makeup = require(Shared.Domain.Makeup)
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
local ID_ASING = 777 -- tidak pernah di-resolve -> tidak punya template

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
	local calls = { info = 0, texture = 0 }

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

	-- Pengganti folder ReplicatedStorage: cukup catat id apa saja yang direplikasi.
	local shared: { [number]: any } = {}

	local svc = MakeupService.new({
		decals = fakeDecals,
		itemInfo = fakeItemInfo,
		share = function(assetId: number, decalTemplate: any)
			shared[assetId] = decalTemplate
		end,
		getHead = function()
			return head
		end,
		face = "Front", -- pengganti Enum.NormalId.Front
	})

	-- 1. belum attach -> belum siap, apply ditolak
	eq(svc:isReady(player), false, "belum attach")
	eq(svc:apply(player, Makeup.empty()), false, "apply sebelum attach ditolak")

	-- 2. resolve: id item -> slot + texture, template ikut disimpan
	svc:attach(player)
	local ok, face = svc:resolve(ID_FACE)
	eq(ok, true, "resolve makeup berhasil")
	eq(face.slot, "face", "slot dari tipe aset")
	eq(face.assetId, ID_FACE, "assetId ikut")
	eq(face.textureId, TEX_FACE, "texture dari gateway")
	eq(svc:hasTemplate(ID_FACE), true, "template disimpan")
	eq(svc:hasTemplate(ID_ASING), false, "id asing belum punya template")
	eq(shared[ID_FACE] ~= nil, true, "template ikut direplikasi untuk preview client")
	eq(shared[ID_ASING] ~= nil, false, "id asing tidak direplikasi")

	-- 3. bukan makeup -> ditolak SEBELUM menyentuh gateway
	local textureCallsBefore = calls.texture
	local okHat, codeHat = svc:resolve(ID_HAT)
	eq(okHat, false, "topi ditolak")
	eq(codeHat, "UNSUPPORTED_TYPE", "kode UNSUPPORTED_TYPE")
	eq(calls.texture, textureCallsBefore, "gateway tidak dipanggil untuk topi")

	-- 4. item hilang / texture gagal
	eq(select(2, svc:resolve(ID_GONE)), "NOT_FOUND", "item hilang -> NOT_FOUND")
	eq(select(2, svc:resolve(ID_BROKEN)), "FAILED", "texture gagal -> FAILED")

	-- 5. apply satu makeup -> satu decal kita, bawaan tidak disentuh
	local state = Makeup.set(Makeup.empty(), face)
	eq(svc:apply(player, state), true, "apply berhasil")
	local worn = ourDecals(head)
	eq(#worn, 1, "satu decal kita di Head")
	eq(worn[1].Name, "SV_Makeup_face", "nama decal menyebut slot")
	eq(worn[1].Texture, TEX_FACE, "texture dari template")
	eq(worn[1].Face, "Front", "Face dari deps")
	eq(worn[1].Parent, head, "menempel di Head")
	eq(native.destroyed, nil, "decal 'face' bawaan tidak dihapus")
	eq(#head.children, 2, "bawaan + punya kita")
	eq(svc:isWorn(player, ID_FACE), true, "cermin: dipakai")
	eq(#svc:dto(player), 1, "dto satu baris")

	-- 6. tiga slot: urutan tempel face -> eye -> lip
	local eye = select(2, svc:resolve(ID_EYE))
	local lip = select(2, svc:resolve(ID_LIP))
	state = Makeup.set(state, lip)
	state = Makeup.set(state, eye)
	eq(svc:apply(player, state), true, "apply tiga")
	worn = ourDecals(head)
	eq(#worn, 3, "tiga decal")
	eq(worn[1].Name, "SV_Makeup_face", "urutan 1 face")
	eq(worn[2].Name, "SV_Makeup_eye", "urutan 2 eye")
	eq(worn[3].Name, "SV_Makeup_lip", "urutan 3 lip")

	-- 7. item lain di slot yang sama MENGGESER, bukan menambah
	local face2 = select(2, svc:resolve(ID_FACE2))
	state = Makeup.set(state, face2)
	svc:apply(player, state)
	eq(#ourDecals(head), 3, "tetap tiga decal")
	eq(svc:isWorn(player, ID_FACE), false, "face lama tergeser")
	eq(svc:isWorn(player, ID_FACE2), true, "face baru dipakai")

	-- 8. Head DIGANTI (ApplyDescriptionAsync / respawn): reapply memasang ulang
	local oldHead = head
	head = makeHead()
	makeNative(head, "face")
	eq(#ourDecals(head), 0, "Head baru masih polos")
	eq(svc:reapply(player), true, "reapply berhasil")
	eq(#ourDecals(head), 3, "tiga decal dipasang ulang di Head baru")
	eq(#ourDecals(oldHead), 3, "Head lama dibiarkan (Roblox yang menghancurkannya)")

	-- 9. belum ada Head: state tetap dicatat, dipasang saat Head muncul
	local saved = head
	head = nil :: any
	eq(svc:apply(player, state), false, "apply bilang belum bisa")
	eq(#svc:dto(player), 3, "cermin tetap tercatat")
	eq(svc:reapply(player), false, "reapply juga belum bisa")
	head = saved
	eq(svc:reapply(player), true, "setelah Head ada")
	eq(#ourDecals(head), 3, "semua dipasang")

	-- 10. look kosong -> decal kita hilang, bawaan tetap
	eq(svc:apply(player, Makeup.empty()), true, "apply kosong")
	eq(#ourDecals(head), 0, "tidak ada decal kita")
	eq(#head.children, 1, "bawaan tetap ada")
	eq(#svc:dto(player), 0, "dto kosong")
	eq(svc:apply(player, nil), true, "nil = kosong")

	-- 11. entry tanpa template (belum pernah di-resolve) DILEWATI, tidak error
	local asing = Makeup.set(Makeup.empty(), { assetId = ID_ASING, slot = "face", textureId = TEX_FACE })
	eq(svc:apply(player, asing), true, "apply tetap jalan")
	eq(#ourDecals(head), 0, "entry tanpa template dilewati")

	-- 12. resolveRows: baris tersimpan -> state; yang gagal dilewati, slot ikut TIPE ASET
	local rows = svc:resolveRows({ { assetId = ID_FACE, slot = "face" }, { assetId = ID_LIP, slot = "lip" } })
	eq(Makeup.count(rows), 2, "dua baris kembali")
	eq(Makeup.get(rows, "lip").assetId, ID_LIP, "lip di slotnya")
	local salah = svc:resolveRows({ { assetId = ID_EYE, slot = "lip" } }) -- slot tersimpan ngawur
	eq(Makeup.get(salah, "eye") ~= nil, true, "slot dibetulkan dari tipe aset")
	eq(Makeup.get(salah, "lip"), nil, "slot tersimpan yang salah tidak dipakai")
	local sebagian = svc:resolveRows({ { assetId = ID_BROKEN, slot = "face" }, { assetId = ID_LIP, slot = "lip" } })
	eq(Makeup.count(sebagian), 1, "baris gagal dilewati")
	eq(Makeup.count(svc:resolveRows({})), 0, "kosong")
	eq(Makeup.count(svc:resolveRows("rusak")), 0, "bukan tabel aman")
	eq(Makeup.count(svc:resolveRows({ "x", { assetId = "y" } })), 0, "baris cacat aman")

	-- 13. detach: cermin ikut hilang, apply ditolak
	svc:detach(player)
	eq(svc:isReady(player), false, "setelah detach")
	eq(svc:apply(player, rows), false, "apply ditolak")
	eq(#svc:dto(player), 0, "dto kosong")
	eq(svc:reapply(player), false, "reapply ditolak")

	-- 14. template tetap tersimpan lintas sesi -> Undo/Redo tidak perlu yield lagi
	svc:attach(player)
	eq(svc:hasTemplate(ID_FACE), true, "template bertahan setelah detach")
	eq(svc:apply(player, rows), true, "look lama bisa dipasang langsung")
	eq(#ourDecals(head), 2, "dua decal")
	svc:detach(player)

	-- 15. prewarm: id ganda sekali saja, id bertemplate tidak menyentuh gateway lagi
	local textureCallsPrewarm = calls.texture
	eq(svc:prewarm({ ID_FACE, ID_FACE, ID_ASING }), 2, "dua id siap")
	eq(calls.texture, textureCallsPrewarm + 1, "hanya id baru yang menyentuh gateway")
	eq(shared[ID_ASING] ~= nil, true, "template hasil prewarm ikut direplikasi")
	eq(svc:prewarm(nil), 0, "argumen cacat aman")
	eq(svc:prewarm({ "x", ID_GONE }), 0, "id cacat & item hilang dilewati")

	print("PASS MakeupService.spec")
end
