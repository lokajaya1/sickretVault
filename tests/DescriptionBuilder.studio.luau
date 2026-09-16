--!strict
-- Test ENGINE DescriptionBuilder — HANYA di Studio (tidak dijalankan Lune karena nama tidak berakhiran .spec).
-- Cara pakai: tekan Play (Server), lalu di Command Bar:
--   require(game.ReplicatedStorage.Tests["DescriptionBuilder.studio"])(1, true)
-- Argumen: userId (avatar yang diuji), spawnModels (true = taruh 2 rig berdampingan untuk cek visual).
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local DB = require(Shared.Avatar.DescriptionBuilder)

return function(userId: number?, spawnModels: boolean?)
	local id = userId or 1
	local original = Players:GetHumanoidDescriptionFromUserId(id)

	-- avatar asli -> state -> description baru
	local state = DB.fromDescription(original)
	local rebuilt, skipped = DB.toDescription(state)

	local same, diff = DB.sameAppearance(original, rebuilt)
	print(
		("[DescriptionBuilder] userId=%d sama=%s diff=%s skipped=%d"):format(
			id,
			tostring(same),
			tostring(diff),
			#skipped
		)
	)
	assert(same, "tampilan berbeda: " .. tostring(diff))

	if spawnModels then
		for i, desc in { original, rebuilt } do
			local model = Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
			model.Name = if i == 1 then "DB_Original" else "DB_Rebuilt"
			model:PivotTo(CFrame.new((i - 1.5) * 6, 5, -10))
			model.Parent = workspace
		end
		print("[DescriptionBuilder] cek visual: DB_Original (kiri) vs DB_Rebuilt (kanan)")
	end
	print("[DescriptionBuilder] LULUS")
end
