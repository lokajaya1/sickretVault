--!strict
-- Membuat (server) / mengambil (client) RemoteEvent & RemoteFunction.
-- Server: panggil Remotes.init() SEKALI saat start, sebelum service lain.
-- Client: Remotes.event(name) / Remotes.func(name) menunggu sampai remote ada.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local RemoteNames = require(script.Parent.RemoteNames)

local WAIT_TIMEOUT = 30

local Remotes = {}

local function folder(): Folder
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(GameConfig.RemoteFolderName)
		if existing then
			return existing :: Folder
		end
		local f = Instance.new("Folder")
		f.Name = GameConfig.RemoteFolderName
		f.Parent = ReplicatedStorage
		return f
	end
	local f = ReplicatedStorage:WaitForChild(GameConfig.RemoteFolderName, WAIT_TIMEOUT)
	assert(f, "folder Remotes tidak ditemukan (server belum memanggil Remotes.init?)")
	return f :: Folder
end

local function ensure(parent: Folder, className: string, name: string): Instance
	local found = parent:FindFirstChild(name)
	if found then
		assert(found.ClassName == className, ("remote %s harus %s"):format(name, className))
		return found
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

-- Server saja: buat semua remote dari RemoteNames.
function Remotes.init()
	assert(RunService:IsServer(), "Remotes.init hanya untuk server")
	local f = folder()
	for _, name in RemoteNames.Events do
		ensure(f, "RemoteEvent", name)
	end
	for _, name in RemoteNames.Functions do
		ensure(f, "RemoteFunction", name)
	end
end

local function get(className: string, name: string): Instance
	local f = folder()
	local inst = if RunService:IsServer() then f:FindFirstChild(name) else f:WaitForChild(name, WAIT_TIMEOUT)
	assert(
		inst and inst.ClassName == className,
		("%s '%s' tidak ada di RemoteNames / belum dibuat"):format(className, name)
	)
	return inst :: Instance
end

function Remotes.event(name: string): RemoteEvent
	return get("RemoteEvent", name) :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	return get("RemoteFunction", name) :: RemoteFunction
end

return Remotes
