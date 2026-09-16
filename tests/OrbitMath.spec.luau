--!strict
-- Studio: require(game.ReplicatedStorage.Tests["OrbitMath.spec"])()
-- Lokal : lune run tools/run-tests.luau
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local M = require(Shared.Util.OrbitMath)

local function near(a: number, b: number, msg: string)
	assert(math.abs(a - b) < 1e-6, ("%s: expected %s, got %s"):format(msg, tostring(b), tostring(a)))
end

return function()
	local cfg = M.DEFAULTS

	-- 1. clamp
	near(M.clamp(5, 0, 3), 3, "clamp atas")
	near(M.clamp(-1, 0, 3), 0, "clamp bawah")
	near(M.clamp(2, 0, 3), 2, "clamp tengah")

	-- 2. rotate: geser kanan -> yaw berkurang; pitch dibatasi
	local yaw, pitch = M.rotate(0, 0, 100, 0, cfg)
	near(yaw, -100 * cfg.sensitivity, "yaw")
	near(pitch, 0, "pitch tetap")
	local _, p2 = M.rotate(0, 0, 0, -100000, cfg)
	near(p2, cfg.maxPitch, "pitch maks")
	local _, p3 = M.rotate(0, 0, 0, 100000, cfg)
	near(p3, cfg.minPitch, "pitch min")

	-- 3. zoom & pinch dibatasi
	near(M.zoom(10, 1, cfg), 9, "zoom masuk 1 langkah")
	near(M.zoom(10, 100, cfg), cfg.minDistance, "zoom min")
	near(M.zoom(10, -100, cfg), cfg.maxDistance, "zoom maks")
	near(M.pinch(10, 2, cfg), 5, "pinch melebar = mendekat")
	near(M.pinch(10, 0.1, cfg), cfg.maxDistance, "pinch maks")
	near(M.pinch(10, 0, cfg), 10, "pinch skala 0 aman")

	-- 4. facingYaw: karakter menghadap -Z (default) -> kamera di yaw pi (di depan)
	near(math.abs(M.facingYaw(0, -1)), math.pi, "menghadap -Z")
	near(M.facingYaw(1, 0), math.pi / 2, "menghadap +X")

	-- 5. offset layar
	near(M.lateralOffset(0.5, 10, 70, 16 / 9), 0, "tengah = 0")
	assert(M.lateralOffset(0.7, 10, 70, 16 / 9) < 0, "karakter di kanan -> kamera geser kiri")
	assert(M.lateralOffset(0.3, 10, 70, 16 / 9) > 0, "karakter di kiri -> kamera geser kanan")
	-- tepi kanan layar (anchor 1) = setengah lebar pandang pada jarak tsb
	local halfWidth = 10 * math.tan(math.rad(35)) * (16 / 9)
	near(M.lateralOffset(1, 10, 70, 16 / 9), -halfWidth, "tepi kanan")
	near(M.verticalOffset(0.5, 10, 70), 0, "vertikal tengah")
	assert(M.verticalOffset(0.3, 10, 70) < 0, "karakter di atas -> kamera turun")

	-- 6. alpha
	near(M.alpha(0, 12), 0, "dt 0")
	assert(M.alpha(1 / 60, 12) > 0 and M.alpha(1 / 60, 12) < 1, "alpha 0..1")
	assert(M.alpha(1, 12) > 0.99, "dt besar hampir 1")

	print("PASS OrbitMath.spec")
end
