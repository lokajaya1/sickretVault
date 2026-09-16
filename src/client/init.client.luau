--!strict
-- Titik masuk client: pasang UI katalog.
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage:WaitForChild("Shared").Util.Log)
local App = require(script.UI.App)

local log = Log.new("Client")

local app = App.mount({
	onItemActivated = function(item)
		-- feature/tryon-layered: kirim AvatarIntent (wear) di sini.
		log.info("pilih", item.itemType, item.id, item.name)
	end,
})

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
