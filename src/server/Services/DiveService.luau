--!strict
--[[
    DiveService — Appendix B: "Oxygen depletion, depth tracking, the DepthRating auto-surface
    rule, air refill, underwater light blending".
    Source: GDD §3.0 (depth is -Y at the head, studs printed as "m"), §5.3 step 9 (oxygen keeps
            draining through every fight phase), §5.4 + §11 (at rating + 20 for 1.5 s the player
            is auto-surfaced, and a forced ascent never costs a banked fish), §8.1 (underwater
            lighting blend), §8.8 (the air alarm at 20 s), §9 (air and depth readouts).

    Air is a clock on the reward, not on the player: running out must never lose a banked fish.

    Who loses what when the tank empties:
      * DiveService surfaces the player and tells them (§8.8's alarm is the client's half).
      * DiveService also tells FishingService, because §5.3 step 9 makes the fight part of the
        clock: the fish that is on the line when the air runs out is lost. Nothing else is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local DiveConfig = require(ReplicatedStorage.DeepTide.Config.DiveConfig)
local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)

local DiveService = Knit.CreateService({
	Name = "DiveService",
	Client = {},
})

local airByPlayer: { [Player]: number } = {}
local ratingHold: { [Player]: number } = {}
local pushAccumulator = 0

local function gearService(): any
	return Knit.GetService("GearService")
end

local function headPosition(player: Player): Vector3?
	local character = player.Character
	if character == nil then
		return nil
	end
	local head = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	return if head ~= nil then (head :: BasePart).Position else nil
end

local function airOf(player: Player): number
	local air = airByPlayer[player]
	if air == nil then
		air = gearService():GetAirCapacity(player)
		airByPlayer[player] = air
	end
	return air
end

-- Public server API -----------------------------------------------------------

--- Depth in studs, always positive: -Y at the player's head (§3.0).
function DiveService:GetDepth(player: Player): number
	local position = headPosition(player)
	if position == nil then
		return 0
	end
	return math.max(0, DiveConfig.SeaLevelY - position.Y)
end

--- Seconds of air left (§9: `AIR 100s`).
function DiveService:GetAir(player: Player): number
	return airOf(player)
end

function DiveService:GetAirCapacity(player: Player): number
	return gearService():GetAirCapacity(player)
end

--- Everything the HUD needs in one payload (§9): air, capacity, depth, rating, and whether
--- the rating is currently exceeded (both turn red and print `GEAR RATING EXCEEDED`).
function DiveService:GetState(player: Player): Types.DiveState
	local depth = self:GetDepth(player)
	local rating = gearService():GetDepthRating(player)
	local air = airOf(player)
	return {
		air = air,
		airCapacity = self:GetAirCapacity(player),
		depth = depth,
		depthRating = rating,
		exceeded = depth > rating,
		submerged = depth > DiveConfig.SeaLevelY,
	}
end

function DiveService:IsSubmerged(player: Player): boolean
	return self:GetDepth(player) > DiveConfig.SeaLevelY
end

--- §5.3 step 9: called by FishingService on every fight tick — oxygen drains through all
--- three phases, which is the slice's central tension.
function DiveService:DrainAir(player: Player, seconds: number)
	local air = math.max(0, airOf(player) - seconds)
	airByPlayer[player] = air
	if air <= 0 then
		self:ForceSurface(player, "outOfAir")
	end
end

--- §1 step 7: air refills over SurfaceRefillSeconds at the surface, with a visible refill.
function DiveService:RefillAir(player: Player)
	airByPlayer[player] = self:GetAirCapacity(player)
end

--- §6.3: the Reinforced Tank immediately becomes AIR 300s — a bigger tank arrives full.
function DiveService:ApplyGearCapacity(player: Player)
	airByPlayer[player] = self:GetAirCapacity(player)
	self:_Push(player)
end

--- Losing the tank's air: the player is put back at the surface, the reason is named (§9: never a
--- loss without a reason), and the fish on the line is lost — nothing banked is ever lost (§11).
function DiveService:ForceSurface(player: Player, kind: string)
	local position = headPosition(player)
	if position ~= nil then
		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		if root ~= nil then
			(root :: BasePart).CFrame = CFrame.new(
				Vector3.new(position.X, DiveConfig.SeaLevelY + DiveConfig.ForceSurfaceHeightStuds, position.Z)
			)
		end
	end

	ratingHold[player] = 0
	airByPlayer[player] = self:GetAirCapacity(player)
	self:_Push(player)

	local message = DiveConfig.ForceSurfaceMessages[kind]
	if message ~= nil then
		Remotes.get("Notify"):FireClient(player, { text = message, seconds = DiveConfig.RatingWarningHoldTime })
	end

	if kind == "outOfAir" then
		-- §5.3 step 9: the tank is a clock on the reward, so the fight it interrupted is lost.
		Knit.GetService("FishingService"):LoseToOutOfAir(player)
	end
end

--- §5.4 + §11: at DepthRating + RatingWarningMargin for RatingWarningHoldTime the player is
--- auto-surfaced with the rating warning. Returns true when the ascent was forced.
--- The ascent itself must never cost a banked catch (§11).
function DiveService:EnforceDepthRating(player: Player): boolean
	local depth = self:GetDepth(player)
	local limit = gearService():GetDepthRating(player) + DiveConfig.RatingWarningMargin

	if depth <= limit then
		ratingHold[player] = 0
		return false
	end

	local held = (ratingHold[player] or 0) + 1 / DiveConfig.StatePushHz
	ratingHold[player] = held
	if held >= DiveConfig.RatingWarningHoldTime then
		ratingHold[player] = 0
		self:ForceSurface(player, "rating")
		return true
	end
	return false
end

--- §8.1/§3.0: blend the underwater preset in over UnderwaterFadeSeconds when the camera
--- crosses sea level. The effect values are the Technical Artist's; the fade is not.
function DiveService:SetUnderwaterVisuals(player: Player, underwater: boolean)
	local character = player.Character
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	local effect = if head ~= nil then (head :: Instance):FindFirstChild("DeepTideUnderwater") else nil
	if underwater and effect == nil and head ~= nil then
		local created = Instance.new("ColorCorrectionEffect")
		created.Name = "DeepTideUnderwater"
		created.TintColor = Color3.fromRGB(120, 170, 200)
		created.Contrast = 0.15
		created.Saturation = -0.25
		created.Brightness = -0.05
		created.Parent = head
	elseif not underwater and effect ~= nil then
		(effect :: Instance):Destroy()
	end
end

function DiveService:_Push(player: Player)
	Remotes.get("DiveStateChanged"):FireClient(player, self:GetState(player))
end

--- One step of the air clock. Called from Heartbeat at DiveConfig.StatePushHz; the harness calls
--- it with a fixed dt. `dt` seconds of air per second submerged (§11: exactly 1 s per second).
function DiveService:_Step(dt: number)
	for _, player in game:GetService("Players"):GetPlayers() do
		local submerged = self:IsSubmerged(player)
		local capacity = self:GetAirCapacity(player)

		if submerged then
			airByPlayer[player] = math.max(0, airOf(player) - dt)
			if airOf(player) <= 0 then
				self:ForceSurface(player, "outOfAir")
			end
			self:SetUnderwaterVisuals(player, true)
		else
			local refillRate = capacity / math.max(DiveConfig.SurfaceRefillSeconds, 0.01)
			airByPlayer[player] = math.min(capacity, airOf(player) + refillRate * dt)
			-- §1 step 7: nothing is lost by surfacing, and the tank comes back in ≤3 s.
			self:SetUnderwaterVisuals(player, false)
		end

		self:EnforceDepthRating(player)
	end

	pushAccumulator += dt
	if pushAccumulator >= 1 / DiveConfig.StatePushHz then
		pushAccumulator = 0
		for _, player in game:GetService("Players"):GetPlayers() do
			self:_Push(player)
		end
	end
end

function DiveService:ReleasePlayer(player: Player)
	airByPlayer[player] = nil
	ratingHold[player] = nil
end

-- Client surface -------------------------------------------------------------

function DiveService.Client:GetState(player: Player): Types.DiveState
	return self.Server:GetState(player)
end

-- Knit lifecycle --------------------------------------------------------------

function DiveService:KnitInit()
	game:GetService("Players").PlayerAdded:Connect(function(player)
		airByPlayer[player] = nil -- filled to capacity on first read
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		self:ReleasePlayer(player)
	end)
end

function DiveService:KnitStart()
	local accumulator = 0
	local stepSeconds = 1 / DiveConfig.StatePushHz

	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < stepSeconds then
			return
		end
		local step = accumulator
		accumulator = 0
		local ok, err = pcall(function()
			DiveService:_Step(step)
		end)
		if not ok then
			warn("[Deep Tide] DiveService step failed: " .. tostring(err))
		end
	end)

	-- Boot line: the two readouts §9 pairs, straight from GearConfig (§6.3).
	local GearConfig = require(ReplicatedStorage.DeepTide.Config.GearConfig)
	local lungs = GearConfig.Gear[GearConfig.Order[1]]
	local tank = GearConfig.Gear[GearConfig.Order[#GearConfig.Order]]
	print(
		("[Deep Tide] dive: air %ds -> %ds, rating %dm -> %dm, %.0f Hz"):format(
			lungs.airCapacity,
			tank.airCapacity,
			lungs.depthRating,
			tank.depthRating,
			DiveConfig.StatePushHz
		)
	)
end

return DiveService
