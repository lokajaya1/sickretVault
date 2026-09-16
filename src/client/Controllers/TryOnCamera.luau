--!strict
-- TryOnCamera: saat katalog terbuka, kamera membingkai karakter pemain di area layar yang kosong.
--   local cam = TryOnCamera.new({ getAnchor = function() return 0.7, 0.5 end })
--   cam:enable()    -- kamera Scriptable: geser = putar, scroll/pinch = zoom
--   cam:disable()   -- kembali ke kamera biasa
--   cam:destroy()
-- Memakai karakter ASLI (bukan salinan), jadi yang terlihat sama dengan yang dilihat pemain lain.
-- Geser/scroll di atas UI diabaikan (processed), jadi tidak bentrok dengan scroll grid katalog.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local OrbitMath = require(ReplicatedStorage:WaitForChild("Shared").Util.OrbitMath)

local BIND_NAME = "TryOnCamera"

export type Options = {
	-- posisi karakter di layar (0..1); dipanggil tiap frame agar ikut ukuran panel
	getAnchor: (() -> (number, number))?,
	config: OrbitMath.Config?,
}

local TryOnCamera = {}
TryOnCamera.__index = TryOnCamera

export type TryOnCamera = typeof(setmetatable(
	{} :: {
		_cfg: OrbitMath.Config,
		_getAnchor: () -> (number, number),
		_enabled: boolean,
		_yaw: number,
		_pitch: number,
		_distance: number,
		_pinchStart: number?,
		_dragInput: InputObject?,
		_dragMouse: boolean,
		_lastPos: Vector3,
		_prevType: Enum.CameraType,
		_conns: { RBXScriptConnection },
	},
	TryOnCamera
))

local function center(): (number, number)
	return 0.5, 0.5
end

local function getRoot(): BasePart?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getHumanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

function TryOnCamera.new(opts: Options?): TryOnCamera
	local o = opts or {}
	local cfg = o.config or OrbitMath.DEFAULTS
	return setmetatable({
		_cfg = cfg,
		_getAnchor = o.getAnchor or center,
		_enabled = false,
		_yaw = 0,
		_pitch = cfg.pitch,
		_distance = cfg.distance,
		_pinchStart = nil,
		_dragInput = nil,
		_dragMouse = false,
		_lastPos = Vector3.zero,
		_prevType = Enum.CameraType.Custom,
		_conns = {},
	}, TryOnCamera)
end

function TryOnCamera.isEnabled(self: TryOnCamera): boolean
	return self._enabled
end

function TryOnCamera.enable(self: TryOnCamera)
	local cam = Workspace.CurrentCamera
	if self._enabled or cam == nil then
		return
	end
	self._enabled = true
	self._prevType = cam.CameraType

	-- Mulai dari depan karakter, jarak & sudut bawaan.
	local root = getRoot()
	if root then
		local look = root.CFrame.LookVector
		self._yaw = OrbitMath.facingYaw(look.X, look.Z)
	end
	self._pitch = self._cfg.pitch
	self._distance = self._cfg.distance
	cam.CameraType = Enum.CameraType.Scriptable

	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		self:_step(dt)
	end)
	self:_connectInput()
end

function TryOnCamera.disable(self: TryOnCamera)
	if not self._enabled then
		return
	end
	self._enabled = false
	RunService:UnbindFromRenderStep(BIND_NAME)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	self._dragInput = nil
	self._pinchStart = nil

	local cam = Workspace.CurrentCamera
	if cam then
		local prev = self._prevType
		cam.CameraType = if prev == Enum.CameraType.Scriptable then Enum.CameraType.Custom else prev
		local humanoid = getHumanoid()
		if humanoid then
			cam.CameraSubject = humanoid
		end
	end
end

function TryOnCamera.destroy(self: TryOnCamera)
	self:disable()
end

function TryOnCamera._step(self: TryOnCamera, dt: number)
	local cam = Workspace.CurrentCamera
	local root = getRoot()
	if cam == nil or root == nil then
		return -- karakter belum ada / sedang respawn
	end
	local cfg = self._cfg
	local vp = cam.ViewportSize
	local aspect = if vp.Y > 0 then vp.X / vp.Y else 16 / 9
	local ax, ay = self._getAnchor()
	local side = OrbitMath.lateralOffset(ax, self._distance, cam.FieldOfView, aspect)
	local up = OrbitMath.verticalOffset(ay, self._distance, cam.FieldOfView)

	local focus = root.Position + Vector3.new(0, cfg.height, 0)
	local goal = CFrame.new(focus)
		* CFrame.Angles(0, self._yaw, 0)
		* CFrame.Angles(self._pitch, 0, 0)
		* CFrame.new(side, up, self._distance)
	cam.CFrame = cam.CFrame:Lerp(goal, OrbitMath.alpha(dt, cfg.smoothing))
	cam.Focus = CFrame.new(focus)
end

function TryOnCamera._connectInput(self: TryOnCamera)
	local cfg = self._cfg
	local conns = self._conns

	table.insert(
		conns,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed or self._dragInput ~= nil or self._pinchStart ~= nil then
				return
			end
			local t = input.UserInputType
			if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
				self._dragInput = input
				self._dragMouse = t == Enum.UserInputType.MouseButton1
				self._lastPos = input.Position
			end
		end)
	)

	table.insert(
		conns,
		UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
			local t = input.UserInputType
			if t == Enum.UserInputType.MouseWheel then
				if not processed then
					self._distance = OrbitMath.zoom(self._distance, input.Position.Z, cfg)
				end
				return
			end
			local drag = self._dragInput
			if drag == nil then
				return
			end
			local isMine = if self._dragMouse then t == Enum.UserInputType.MouseMovement else input == drag
			if not isMine then
				return
			end
			local delta = input.Position - self._lastPos
			self._lastPos = input.Position
			self._yaw, self._pitch = OrbitMath.rotate(self._yaw, self._pitch, delta.X, delta.Y, cfg)
		end)
	)

	table.insert(
		conns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			local drag = self._dragInput
			if drag == nil then
				return
			end
			local done = if self._dragMouse
				then input.UserInputType == Enum.UserInputType.MouseButton1
				else input == drag
			if done then
				self._dragInput = nil
			end
		end)
	)

	table.insert(
		conns,
		UserInputService.TouchPinch:Connect(
			function(
				_positions: { any },
				scale: number,
				_velocity: number,
				state: Enum.UserInputState,
				processed: boolean
			)
				if state == Enum.UserInputState.Begin then
					if processed then
						return
					end
					self._pinchStart = self._distance
					self._dragInput = nil -- dua jari: berhenti memutar
				elseif state == Enum.UserInputState.Change then
					local start = self._pinchStart
					if start then
						self._distance = OrbitMath.pinch(start, scale, cfg)
					end
				else
					self._pinchStart = nil
				end
			end
		)
	)
end

return TryOnCamera
