--!strict
-- Test ENGINE Remotes — HANYA di Studio, dijalankan dari SERVER.
-- Play -> pindah ke Server -> Command Bar:
--   require(game.ReplicatedStorage.Tests["Net.studio"])()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local RemoteNames = require(Shared.Net.RemoteNames)
local GameConfig = require(Shared.Config.GameConfig)

return function()
	Remotes.init() -- aman dipanggil ulang (tidak membuat duplikat)
	local folder = ReplicatedStorage:FindFirstChild(GameConfig.RemoteFolderName)
	assert(folder, "folder Remotes ada")

	local expected = 0
	for _, name in RemoteNames.Events do
		expected += 1
		assert(Remotes.event(name):IsA("RemoteEvent"), name .. " adalah RemoteEvent")
	end
	for _, name in RemoteNames.Functions do
		expected += 1
		assert(Remotes.func(name):IsA("RemoteFunction"), name .. " adalah RemoteFunction")
	end
	assert(#folder:GetChildren() == expected, ("jumlah remote %d, harus %d"):format(#folder:GetChildren(), expected))

	local ok = pcall(Remotes.event, "TidakAda")
	assert(not ok, "remote tak terdaftar harus error")

	print("[Net.studio] LULUS (" .. expected .. " remote)")
end
