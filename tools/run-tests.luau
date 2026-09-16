--!nocheck
-- Jalankan test DOMAIN MURNI di luar Studio (CI/lokal) dengan Lune:
--   lune run tools/run-tests.luau
-- Hanya untuk modul tanpa service Roblox (Domain/*, Config/*, Util/*, Validators/*). Test engine tetap di Studio.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local cache = {}

-- Enum shim minimal (hanya yang dipakai domain)
local Enum = {
	AssetType = {
		GetEnumItems = function()
			return {} -- normalize(number) tidak diuji di sini
		end,
	},
}

local Node = {}
local function node(path, name)
	return setmetatable({ __path = path, Name = name }, Node)
end
Node.__index = function(self, key)
	if key == "Parent" then
		local parent = string.match(self.__path, "^(.*)/[^/]+$")
		return node(parent, string.match(parent or "", "([^/]+)$"))
	elseif key == "WaitForChild" or key == "FindFirstChild" then
		return function(me, child)
			return me[child]
		end
	end
	return node(self.__path .. "/" .. key, key)
end

local function serviceRoot(children)
	return setmetatable({}, {
		__index = function(_, k)
			if k == "WaitForChild" or k == "FindFirstChild" then
				return function(me, c)
					return me[c]
				end
			end
			local path = children[k]
			if path then
				return node(path, k)
			end
			return nil
		end,
	})
end

local services = {
	ReplicatedStorage = serviceRoot({ Shared = "src/shared", Tests = "tests" }),
	-- modul server yang MURNI (mis. Validators) boleh dites juga
	ServerScriptService = serviceRoot({ Server = "src/server" }),
}
local game = {
	GetService = function(_, name)
		local svc = services[name]
		if svc then
			return svc
		end
		error("service tidak tersedia di test domain: " .. name)
	end,
}

local function customRequire(target)
	local p = target.__path
	if cache[p] ~= nil then
		return cache[p]
	end
	local file = if fs.isFile(p .. ".luau") then p .. ".luau" else p .. "/init.luau"
	local env = setmetatable({ script = target, require = customRequire, game = game, Enum = Enum }, { __index = _G })
	local fn = luau.load(fs.readFile(file), { debugName = file, environment = env })
	local result = fn()
	cache[p] = if result == nil then false else result
	return result
end

local failed = 0
for _, f in fs.readDir("tests") do
	local name = string.match(f, "^(.-)%.luau$")
	if name and string.find(name, "%.spec$") then
		local ok, err = pcall(function()
			customRequire(node("tests/" .. name, name))()
		end)
		if not ok then
			failed += 1
			print("FAIL " .. name .. ": " .. tostring(err))
		end
	end
end
process.exit(if failed > 0 then 1 else 0)
