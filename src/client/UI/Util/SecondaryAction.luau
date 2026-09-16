--!strict
-- Aksi sekunder pada tombol: klik kanan (PC) atau tahan/long-press (HP).
--   local conns, suppressed = SecondaryAction.bind(button, function() ... end)
--   button.Activated:Connect(function() if suppressed() then return end ... end)
-- `suppressed()` = true sesaat setelah aksi sekunder, supaya lepas jari sesudah long-press
-- tidak ikut dianggap tap biasa.

local SUPPRESS_SECONDS = 0.6

local SecondaryAction = {}

export type Suppressed = () -> boolean

function SecondaryAction.bind(button: GuiButton, fn: () -> ()): ({ RBXScriptConnection }, Suppressed)
	local last = -math.huge
	local conns = {
		button.MouseButton2Click:Connect(function()
			last = os.clock()
			fn()
		end),
		button.TouchLongPress:Connect(function(_positions, state: Enum.UserInputState)
			last = os.clock() -- Begin / Change / End: tahan tap biasa sampai jari dilepas
			if state == Enum.UserInputState.Begin then
				fn()
			end
		end),
	}
	local function suppressed(): boolean
		return os.clock() - last < SUPPRESS_SECONDS
	end
	return conns, suppressed
end

return SecondaryAction
