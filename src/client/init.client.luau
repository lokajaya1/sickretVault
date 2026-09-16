--!strict
-- Titik masuk client: pasang UI katalog + hubungkan klik kartu ke try-on.
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage:WaitForChild("Shared").Util.Log)
local App = require(script.UI.App)

local log = Log.new("Client")

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
		app:toggleCatalog()
	end
end)

log.info("siap")
