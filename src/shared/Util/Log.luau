--!strict
-- Logger kecil dengan tag & level.
--   local log = Log.new("AvatarService")
--   log.info("wear", assetId)   log.warn("gagal", err)
-- Level minimum dari GameConfig.LogLevel. `Log.setSink` untuk test.

local GameConfig = require(script.Parent.Parent.Config.GameConfig)

export type Level = "debug" | "info" | "warn" | "error"
export type Logger = {
	debug: (...any) -> (),
	info: (...any) -> (),
	warn: (...any) -> (),
	error: (...any) -> (),
}

local RANK: { [string]: number } = { debug = 1, info = 2, warn = 3, error = 4 }

local Log = {}

local minRank = RANK[GameConfig.LogLevel] or RANK.info

local function defaultSink(level: string, text: string)
	if level == "warn" or level == "error" then
		warn(text)
	else
		print(text)
	end
end

local sink: (string, string) -> () = defaultSink

function Log.setLevel(level: Level)
	minRank = RANK[level] or RANK.info
end

function Log.setSink(fn: ((string, string) -> ())?)
	sink = fn or defaultSink
end

function Log.new(tag: string): Logger
	local function emit(level: string, ...: any)
		if RANK[level] < minRank then
			return
		end
		local parts = table.pack(...)
		local texts = table.create(parts.n)
		for i = 1, parts.n do
			texts[i] = tostring(parts[i])
		end
		sink(level, ("[%s][%s] %s"):format(string.upper(level), tag, table.concat(texts, " ")))
	end
	return {
		debug = function(...: any)
			emit("debug", ...)
		end,
		info = function(...: any)
			emit("info", ...)
		end,
		warn = function(...: any)
			emit("warn", ...)
		end,
		error = function(...: any)
			emit("error", ...)
		end,
	}
end

return Log
