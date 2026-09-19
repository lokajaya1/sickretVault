--!strict
-- Titik masuk client: pasang UI katalog + hubungkan klik kartu ke try-on.
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage:WaitForChild("Shared").Util.Log)
local App = require(script.UI.App)

local log = Log.new("Client")

-- Mengganti rig R6/R15 hanya bisa dilakukan dengan MENGGANTI seluruh model karakter -- tidak ada
-- cara lain, dan LoadCharacter tidak punya argumen rig
-- (devforum.roblox.com/t/is-it-possible-to-toggle-r15-to-r6-or-r6-to-r15/4696562).
-- Begitu player.Character diganti, Camera.CameraSubject MASIH menunjuk Humanoid lama yang sudah
-- dihancurkan -> kamera membeku. Workspace.CurrentCamera hanya ada di CLIENT, jadi server tidak
-- akan pernah bisa memperbaikinya sendiri
-- (devforum.roblox.com/t/changing-the-players-character-breaks-the-camera/3032512).
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer

local function bindCamera(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil then
		log.warn("karakter baru tanpa Humanoid: kamera tidak diikat ulang")
		return
	end
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	-- HANYA subjeknya yang diperbarui. CameraType TIDAK disentuh: saat panel katalog terbuka,
	-- kamera dipegang TryOnCamera dalam mode Scriptable, dan memaksanya kembali ke Custom berarti
	-- merebut kamera dari pengendali aplikasi -- itulah bug gerak kamera setelah ganti rig.
	camera.CameraSubject = humanoid
end

localPlayer.CharacterAdded:Connect(bindCamera)
if localPlayer.Character then
	bindCamera(localPlayer.Character)
end

-- Teks toast per kode dari server (teks pemain berbahasa Inggris).
local NOTICE_TEXT: { [string]: string } = {
	NOT_FOUND = "Item not found or not supported",
	UNSUPPORTED_TYPE = "This item type isn't supported yet",
	LIMIT_RIGID = "Accessory limit reached",
	LIMIT_LAYERED = "Layered clothing limit reached",
	LIMIT_TYPE = "This item type can't be worn",
	APPLY_FAILED = "Couldn't apply to your avatar, reverted",
	RATE_LIMITED = "Slow down a little",
	NOT_READY = "Avatar is loading, try again",
	NOT_IMPLEMENTED = "Bundles are coming soon",
	BAD_ARG = "Invalid request",
	FAILED = "Something went wrong, try again",
}

local NOTICE_KIND: { [string]: "info" | "warning" | "error" } = {
	NOT_FOUND = "warning",
	UNSUPPORTED_TYPE = "warning",
	LIMIT_RIGID = "warning",
	LIMIT_LAYERED = "warning",
	LIMIT_TYPE = "warning",
	APPLY_FAILED = "error",
	RATE_LIMITED = "info",
	NOT_READY = "info",
	NOT_IMPLEMENTED = "info",
	BAD_ARG = "warning",
	FAILED = "error",
}

local app: App.App
app = App.mount({
	onItemActivated = function(item)
		log.info("pilih", item.itemType, item.id, item.name)
	end,
})

app.outfit:onNotify(function(notice)
	log.warn("notify", notice.code, notice.op)
	local text = NOTICE_TEXT[notice.code] or NOTICE_TEXT.FAILED
	app.toast:show(text, NOTICE_KIND[notice.code] or "error")
end)

-- Shortcut PC: C = buka/tutup katalog (abaikan saat mengetik).
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode == Enum.KeyCode.C then
		-- Bukan sekadar buka/tutup katalog: kalau ada panel simpan di depan, panel itu ditutup
		-- dulu lalu katalog yang muncul. Seluruh urutannya ada di App.catalogShortcut, supaya
		-- jalan masuk lain (tombol, nanti mungkin gamepad) ikut memakai aturan yang sama.
		app:catalogShortcut()
	end
end)

log.info("siap")
