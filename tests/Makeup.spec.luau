--!strict
-- Studio: require(game.ReplicatedStorage.Tests["Makeup.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Makeup = require(Shared.Domain.Makeup)

local TEX_A = "rbxassetid://98880692903650" -- Shy Kawaii Face V2
local TEX_B = "rbxassetid://123518465016531" -- Bear Claw Scar
local TEX_C = "rbxassetid://77903406032400" -- Korean Lipgloss

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

local function ok(v: any, msg: string)
	assert(v, msg)
end

-- Pasang satu makeup dan pastikan berhasil (gagal = spec berhenti dengan pesan jelas).
local function put(state: any, assetId: number, slot: string, textureId: string): any
	local next_, err = Makeup.set(state, { assetId = assetId, slot = slot, textureId = textureId })
	assert(next_ ~= nil, ("set %s gagal: %s"):format(slot, tostring(err)))
	return next_
end

return function()
	-- 1. peta asset type -> slot
	eq(Makeup.slotOf("FaceMakeup"), "face", "FaceMakeup -> face")
	eq(Makeup.slotOf("EyeMakeup"), "eye", "EyeMakeup -> eye")
	eq(Makeup.slotOf("LipMakeup"), "lip", "LipMakeup -> lip")
	eq(Makeup.slotOf("Hat"), nil, "topi bukan makeup")
	eq(Makeup.slotOf(nil), nil, "nil bukan makeup")
	eq(Makeup.isMakeup("EyeMakeup"), true, "isMakeup eye")
	eq(Makeup.isMakeup("EyelashAccessory"), false, "eyelash bukan makeup (dipakai lewat description)")

	-- 2. texture id harus bentuk rbxassetid://<angka> (id item TIDAK sama dengan id texture)
	eq(Makeup.isValidTexture(TEX_A), true, "texture sah")
	eq(Makeup.isValidTexture("rbxassetid://"), false, "tanpa angka ditolak")
	eq(Makeup.isValidTexture("98880692903650"), false, "angka telanjang ditolak")
	eq(Makeup.isValidTexture("http://x/98880692903650"), false, "url lain ditolak")
	eq(Makeup.isValidTexture(nil), false, "nil ditolak")

	-- 3. state kosong
	local empty = Makeup.empty()
	eq(Makeup.count(empty), 0, "state kosong")
	eq(Makeup.isEmpty(empty), true, "isEmpty")
	eq(#Makeup.list(empty), 0, "list kosong")

	-- 4. pasang satu per slot
	local s = put(empty, 133520807586498, "face", TEX_A)
	s = put(s, 128012015026356, "eye", TEX_B)
	s = put(s, 106390919006817, "lip", TEX_C)
	eq(Makeup.count(s), 3, "tiga slot terisi")
	eq(Makeup.isEmpty(empty), true, "state lama TIDAK ikut berubah")
	eq(Makeup.count(empty), 0, "state lama tetap kosong")

	-- 5. urutan list = urutan tempel face -> eye -> lip
	local order = Makeup.list(s)
	eq(order[1].slot, "face", "urutan 1 face")
	eq(order[2].slot, "eye", "urutan 2 eye")
	eq(order[3].slot, "lip", "urutan 3 lip")

	-- 6. satu item per slot: yang baru menggeser yang lama
	local s2 = put(s, 999, "eye", TEX_A)
	eq(Makeup.count(s2), 3, "tetap tiga, tidak bertambah")
	eq((Makeup.get(s2, "eye") :: any).assetId, 999, "eye tergantikan")
	eq((Makeup.get(s, "eye") :: any).assetId, 128012015026356, "state lama tetap item lama")

	-- 7. penolakan
	local bad, err = Makeup.set(s, { assetId = 1, slot = "hidung", textureId = TEX_A })
	eq(bad, nil, "slot ngawur ditolak")
	eq(err, "BAD_SLOT", "kode BAD_SLOT")
	bad, err = Makeup.set(s, { assetId = 0, slot = "face", textureId = TEX_A })
	eq(bad, nil, "assetId 0 ditolak")
	eq(err, "BAD_ASSET_ID", "kode BAD_ASSET_ID")
	bad, err = Makeup.set(s, { assetId = 5, slot = "face", textureId = "rbxassetid://" })
	eq(bad, nil, "texture cacat ditolak")
	eq(err, "BAD_TEXTURE", "kode BAD_TEXTURE")

	-- 8. lepas per slot dan per id item
	local s3 = Makeup.remove(s, "eye")
	eq(Makeup.count(s3), 2, "eye dilepas")
	eq(Makeup.get(s3, "eye"), nil, "slot eye kosong")
	eq(Makeup.count(s), 3, "state lama utuh")

	local s4 = Makeup.removeAsset(s, 106390919006817)
	eq(Makeup.count(s4), 2, "lip dilepas lewat id item")
	eq(Makeup.hasAsset(s4, 106390919006817), false, "id itu sudah tidak ada")
	eq(Makeup.hasAsset(s4, 133520807586498), true, "face masih ada")
	eq(Makeup.count(Makeup.removeAsset(s, 424242)), 3, "id asing tidak mengubah apa pun")

	-- 9. equals
	local sameAgain = put(
		put(put(Makeup.empty(), 133520807586498, "face", TEX_A), 128012015026356, "eye", TEX_B),
		106390919006817,
		"lip",
		TEX_C
	)
	eq(Makeup.equals(s, sameAgain), true, "isi sama -> equals")
	eq(Makeup.equals(s, s3), false, "isi beda -> tidak equals")
	eq(Makeup.equals(Makeup.empty(), Makeup.empty()), true, "dua state kosong sama")

	-- 10. dto bolak-balik
	local dto = Makeup.toDto(s)
	eq(#dto, 3, "dto tiga baris")
	eq(dto[1].slot, "face", "dto ikut urutan")
	eq(Makeup.equals(Makeup.fromDto(dto), s), true, "fromDto(toDto) kembali utuh")

	-- 11. dto cacat: baris rusak dilewati, sisanya tetap masuk
	local messy = Makeup.fromDto({
		{ assetId = 133520807586498, slot = "face", textureId = TEX_A },
		{ assetId = 1, slot = "hidung", textureId = TEX_A },
		{ assetId = 2, slot = "lip", textureId = "bukan-texture" },
		"bukan tabel",
	} :: any)
	eq(Makeup.count(messy), 1, "hanya baris sah yang masuk")
	eq((Makeup.get(messy, "face") :: any).assetId, 133520807586498, "baris sah utuh")
	eq(Makeup.count(Makeup.fromDto(nil)), 0, "fromDto(nil) aman")
	eq(Makeup.count(Makeup.fromDto("x")), 0, "fromDto(string) aman")

	ok(Makeup.MaxPerSlot == 1, "satu item per slot")
	print("PASS Makeup.spec")
end
