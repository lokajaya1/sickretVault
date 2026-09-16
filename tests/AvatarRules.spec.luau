--!strict
-- Test AvatarRules dengan API palsu.
-- Lokal : lune run tools/run-tests.luau
-- Studio: require(game.ReplicatedStorage.Tests["AvatarRules.spec"])()  (jalankan dari server saat Play)
local ServerScriptService = game:GetService("ServerScriptService")
local AvatarRules = require(ServerScriptService:WaitForChild("Server").Services.AvatarRules)
local Log = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Util.Log)

local function eq(a: any, b: any, msg: string)
	assert(a == b, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

-- Enum.AssetType palsu (Lune tidak punya Enum)
local NAMES: { [number]: string } = { [8] = "Hat", [41] = "HairAccessory", [88] = "FaceMakeup" }
local function toName(id: number): string?
	return NAMES[id]
end

local RAW = {
	WearableAssetTypes = {
		{ Id = 8, Name = "Hat", MaxNumber = 3 },
		{ Id = 41, Name = "Hair Accessory", MaxNumber = 1 },
		{ Id = 88, Name = "Face Makeup", MaxNumber = 6 },
		{ Id = 999, Name = "Tidak dikenal", MaxNumber = 2 },
		{ Name = "rusak" },
	},
}

return function()
	Log.setSink(function() end)

	-- 1. parse
	local p = AvatarRules.parse(RAW, toName) :: any
	eq(p.Hat, 3, "Hat=3")
	eq(p.HairAccessory, 1, "Hair=1 (nama dari Id, bukan 'Hair Accessory')")
	eq(p.FaceMakeup, 6, "makeup=6")
	eq(AvatarRules.parse({}, toName), nil, "tanpa WearableAssetTypes -> nil")
	eq(AvatarRules.parse(nil, toName), nil, "nil -> nil")

	-- 2. maxPerType: sukses, di-cache, tipe hilang diisi fallback
	local now = 0
	local api = { calls = 0, fail = false }
	function api.getAvatarRules(self: any)
		self.calls += 1
		if self.fail then
			return false, { code = "FAILED", message = "HTTP 500" }
		end
		return true, RAW
	end
	local rules = AvatarRules.new({
		api = api,
		toName = toName,
		clock = function()
			return now
		end,
	})
	local m = rules:maxPerType()
	eq(m.Hat, 3, "dari API")
	eq(m.JacketAccessory, 1, "fallback untuk tipe yang tidak disebut")
	rules:maxPerType()
	eq(api.calls, 1, "hasil di-cache")

	-- 3. gagal -> fallback, tidak spam API, coba lagi setelah 60 dtk
	local api2 = { calls = 0, fail = true }
	api2.getAvatarRules = api.getAvatarRules
	local r2 = AvatarRules.new({
		api = api2,
		toName = toName,
		clock = function()
			return now
		end,
	})
	eq(r2:maxPerType(), AvatarRules.FALLBACK, "fallback saat gagal")
	r2:maxPerType()
	eq(api2.calls, 1, "tidak mencoba lagi sebelum 60 dtk")
	now = 61
	api2.fail = false
	eq(r2:maxPerType().FaceMakeup, 6, "berhasil setelah dicoba lagi")
	eq(api2.calls, 2, "dicoba lagi sekali")

	print("PASS AvatarRules.spec")
end
