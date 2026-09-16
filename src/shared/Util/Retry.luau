--!strict
-- Jalankan fungsi yang bisa gagal (API Roblox) dengan pcall + backoff eksponensial.
--   local ok, result = Retry.run(function() return AES:GetItemDetailsAsync(id, t) end)
-- Return: (true, hasil...) atau (false, pesanErrorTerakhir)
-- Opsi `sleep` & `shouldRetry` bisa diganti saat test.

export type Options = {
	attempts: number?, -- total percobaan (default 3)
	baseDelay: number?, -- detik, jeda setelah gagal pertama (default 1)
	maxDelay: number?, -- detik (default 8)
	sleep: ((number) -> ())?, -- default task.wait
	shouldRetry: ((err: any) -> boolean)?, -- false = berhenti langsung (mis. id tidak valid)
}

local Retry = {}

function Retry.delayFor(attempt: number, baseDelay: number, maxDelay: number): number
	return math.min(maxDelay, baseDelay * 2 ^ (attempt - 1))
end

function Retry.run(fn: (...any) -> ...any, opts: Options?, ...: any): (boolean, ...any)
	local o = opts or {}
	local attempts = math.max(1, o.attempts or 3)
	local baseDelay = o.baseDelay or 1
	local maxDelay = o.maxDelay or 8
	local sleep = o.sleep or function(t: number)
		task.wait(t)
	end
	local lastErr: any = nil
	for attempt = 1, attempts do
		local result = table.pack(pcall(fn, ...))
		if result[1] then
			return table.unpack(result, 1, result.n)
		end
		lastErr = result[2]
		if o.shouldRetry and not o.shouldRetry(lastErr) then
			break
		end
		if attempt < attempts then
			sleep(Retry.delayFor(attempt, baseDelay, maxDelay))
		end
	end
	return false, lastErr
end

return Retry
