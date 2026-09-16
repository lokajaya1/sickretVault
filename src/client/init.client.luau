--!strict
-- Titik masuk client: pasang UI katalog + hubungkan klik kartu ke try-on.
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage:WaitForChild("Shared").Util.Log)
local App = require(script.UI.App)

local log = Log.new("Client")

-- Pesan singkat per kode error dari server (toast menyusul; sementara ke Output).
local NOTICE_TEXT: { [string]: string } = {
	NOT_FOUND = "Item tidak ditemukan / tipe belum didukung",
	UNSUPPORTED_TYPE = "Tipe item belum didukung",
	LIMIT_RIGID = "Batas aksesori tercapai",
	LIMIT_LAYERED = "Batas pakaian layered tercapai",
	APPLY_FAILED = "Gagal memasang ke avatar, dikembalikan",
	RATE_LIMITED = "Terlalu cepat, tunggu sebentar",
	NOT_READY = "Avatar belum siap, coba lagi",
	NOT_IMPLEMENTED = "Bundle belum didukung",
	FAILED = "Gagal, coba lagi",
}

local app: App.App
app = App.mount({
	onItemActivated = function(item)
		log.info("pilih", item.itemType, item.id, item.name)
		app.outfit:toggle(item)
	end,
})

app.outfit:onNotify(function(notice)
	log.warn("notify", notice.code, notice.op, NOTICE_TEXT[notice.code] or "")
end)

-- Shortcut PC: C = buka/tutup katalog (abaikan saat mengetik).
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode == Enum.KeyCode.C then
		app:toggleCatalog()
	end
end)

log.info("siap")
