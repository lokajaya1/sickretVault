--!strict
-- Hitungan murni untuk kamera try-on (orbit mengelilingi karakter). Tanpa Instance/CFrame -> bisa dites di Lune.
--   local cfg = OrbitMath.DEFAULTS
--   yaw, pitch = OrbitMath.rotate(yaw, pitch, dx, dy, cfg)
--   distance = OrbitMath.zoom(distance, wheelSteps, cfg)
--   local side = OrbitMath.lateralOffset(0.7, distance, 70, 16 / 9)
-- Sudut dalam radian. anchorX/anchorY = posisi karakter di layar (0..1, 0 = kiri/atas).

export type Config = {
	distance: number, -- jarak awal kamera ke karakter (stud)
	minDistance: number,
	maxDistance: number,
	pitch: number, -- sudut awal (negatif = kamera sedikit di atas, melihat ke bawah)
	minPitch: number,
	maxPitch: number,
	height: number, -- titik fokus di atas HumanoidRootPart (stud)
	sensitivity: number, -- radian per piksel geser
	zoomStep: number, -- faktor jarak per langkah scroll (0.9 = 10% lebih dekat)
	smoothing: number, -- kecepatan kamera mengejar target (makin besar makin cepat)
}

local OrbitMath = {}

OrbitMath.DEFAULTS = table.freeze({
	distance = 9,
	minDistance = 4,
	maxDistance = 16,
	pitch = math.rad(-8),
	minPitch = math.rad(-35),
	maxPitch = math.rad(35),
	height = 1.5,
	sensitivity = 0.008,
	zoomStep = 0.9,
	smoothing = 12,
} :: Config)

function OrbitMath.clamp(value: number, min: number, max: number): number
	if value < min then
		return min
	elseif value > max then
		return max
	end
	return value
end

-- Geser layar (piksel) -> sudut baru. Geser ke kanan memutar kamera ke kiri (avatar ikut "berputar" ke kanan).
function OrbitMath.rotate(yaw: number, pitch: number, dx: number, dy: number, cfg: Config): (number, number)
	local newYaw = yaw - dx * cfg.sensitivity
	local newPitch = OrbitMath.clamp(pitch - dy * cfg.sensitivity, cfg.minPitch, cfg.maxPitch)
	return newYaw, newPitch
end

-- steps > 0 = mendekat, < 0 = menjauh. Boleh pecahan (pinch).
function OrbitMath.zoom(distance: number, steps: number, cfg: Config): number
	return OrbitMath.clamp(distance * cfg.zoomStep ^ steps, cfg.minDistance, cfg.maxDistance)
end

-- Pinch: skala jari (1 = awal, >1 = melebar) -> jarak baru dari jarak saat pinch dimulai.
function OrbitMath.pinch(startDistance: number, scale: number, cfg: Config): number
	if scale <= 0 then
		return OrbitMath.clamp(startDistance, cfg.minDistance, cfg.maxDistance)
	end
	return OrbitMath.clamp(startDistance / scale, cfg.minDistance, cfg.maxDistance)
end

-- Yaw awal agar kamera berada DI DEPAN karakter (lookX/lookZ = LookVector karakter).
function OrbitMath.facingYaw(lookX: number, lookZ: number): number
	return math.atan2(lookX, lookZ)
end

-- Geser kamera ke samping (stud, arah kanan kamera) agar karakter tampil di anchorX layar.
-- anchorX 0.5 = tengah (0). anchorX > 0.5 -> nilai negatif (kamera bergeser ke kiri).
function OrbitMath.lateralOffset(anchorX: number, distance: number, verticalFovDeg: number, aspect: number): number
	local halfV = math.rad(verticalFovDeg) / 2
	return (0.5 - anchorX) * 2 * distance * math.tan(halfV) * aspect
end

-- Geser kamera ke atas/bawah (stud) agar karakter tampil di anchorY layar (0 = atas).
-- anchorY < 0.5 -> nilai negatif (kamera turun, karakter terlihat lebih ke atas).
function OrbitMath.verticalOffset(anchorY: number, distance: number, verticalFovDeg: number): number
	local halfV = math.rad(verticalFovDeg) / 2
	return (anchorY - 0.5) * 2 * distance * math.tan(halfV)
end

-- Faktor lerp per frame yang tidak bergantung FPS (0..1).
function OrbitMath.alpha(dt: number, speed: number): number
	if dt <= 0 then
		return 0
	end
	return 1 - math.exp(-speed * dt)
end

return OrbitMath
