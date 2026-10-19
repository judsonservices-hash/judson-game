--!strict
--[[
    EffectsController — the player's own effects: §8.4's movement kit and §8.5's win/lose reads.
    Source: GDD §8.4 ("a constant, low-rate bubble trail from the player's head — 2 particles/s
            idle, 14/s while swimming, 30/s on a fast ascent; a kick-up silt puff when the player
            touches the seabed"), §8.5 ("a landing pops a Coin-yellow burst at the rod tip ... a
            0.15 s white flash [on a snap] ... an escape is a small grey ripple. The player must be
            able to tell win from loss from across the room"), §1 step 3 (the surface entry splash).

    WHAT IS CLIENT-SIDE AND WHY
      Bubbles follow one head and flashes happen at one player's rod tip, so they are built and
      driven locally: two ParticleEmitters and one invisible anchor part per player, no replication
      per particle. The tradeoff, stated plainly: *other* players do not see your bubble trail.
      That is the right trade for the slice (the loop is single-player in practice) and it is the
      cheapest possible version of §8.4 — but it is a trade, not a free lunch, so it is written down
      here rather than discovered later.

    NOT MUTED BY THE MINI-GAME (§8.5, §8.8): every effect here is 3D and lives in the world. Nothing
    it draws can cover the tension track, and nothing the HUD draws can suppress it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local VisualConfig = require(ReplicatedStorage.DeepTide.Config.VisualConfig)

local EffectsController = Knit.CreateController({
	Name = "EffectsController",
})

local player = Players.LocalPlayer

local state: Types.DiveState = {
	air = 0,
	airCapacity = 0,
	depth = 0,
	depthRating = 0,
	exceeded = false,
	submerged = false,
}

local bubbleEmitter: any = nil
local burstAnchor: any = nil
local burstEmitter: any = nil
local flashLight: any = nil
local lastBubbleRate: number? = nil
local flashEndsAt = 0
local flashPeak = 0
local lastSiltAt = -math.huge
local clock = 0

-- ============================================================================
-- Instances (one invisible anchor carries the burst emitter and the flash light)
-- ============================================================================

local function configure(emitter: any, spec: { [string]: any })
	emitter.Rate = spec.rate or 0
	emitter.Speed = spec.speed
	emitter.Lifetime = spec.lifetime
	emitter.Size = NumberSequence.new(spec.sizeMin, spec.sizeMax)
	emitter.Transparency = NumberSequence.new(spec.transparencyStart, spec.transparencyEnd)
	emitter.Color = ColorSequence.new(spec.color, spec.color)
	emitter.LightEmission = spec.lightEmission or 0
	emitter.LightInfluence = if spec.lightInfluence ~= nil then spec.lightInfluence else 1
	emitter.SpreadAngle = Vector2.new(spec.spreadAngle, spec.spreadAngle)
	emitter.Acceleration = spec.acceleration or Vector3.new(0, 0, 0)
	emitter.MaxParticles = spec.maxParticles or 40
	emitter.EmissionDirection = Enum.NormalId[spec.emissionDirection or "Top"]
	emitter.Enabled = true
end

--- The one anchor every world-space burst is fired from: moved to the point, fired, left alone.
--- Client-only (never replicated), invisible, and non-queryable so it cannot be caught by a
--- raycast or a cast range check.
local function ensureAnchor(): any
	if burstAnchor ~= nil and burstAnchor.Parent ~= nil then
		return burstAnchor
	end
	local anchor: any = Instance.new("Part")
	anchor.Name = "DeepTideFX"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Parent = game:GetService("Workspace")

	burstEmitter = Instance.new("ParticleEmitter")
	burstEmitter.Name = VisualConfig.Burst.name
	configure(burstEmitter, VisualConfig.Burst)
	burstEmitter.Parent = anchor

	flashLight = Instance.new("PointLight")
	flashLight.Name = "DeepTideFlash"
	flashLight.Shadows = false
	flashLight.Enabled = false
	flashLight.Parent = anchor

	burstAnchor = anchor
	return anchor
end

local function ensureBubbles()
	local character = player.Character
	if character == nil then
		return
	end
	local head = character:FindFirstChild("Head")
	if head == nil or head:IsA("BasePart") == false then
		return
	end
	local existing = head:FindFirstChild("DeepTideBubbles")
	if existing ~= nil then
		bubbleEmitter = existing
		return
	end
	local emitter: any = Instance.new("ParticleEmitter")
	emitter.Name = "DeepTideBubbles"
	configure(emitter, VisualConfig.Player.Bubbles)
	emitter.Shape = Enum.ParticleEmitterShape.Sphere -- a plume around the head, not a slab
	emitter.Rate = 0 -- nothing until the first update says the player is underwater
	emitter.Parent = head
	bubbleEmitter = emitter
end

-- ============================================================================
-- Firing bursts
-- ============================================================================

--- One world-space burst. `spec` is one of VisualConfig.Splash / .Flash.* / .Player.SiltKick.
function EffectsController:Burst(position: Vector3, spec: { [string]: any })
	local anchor = ensureAnchor()
	anchor.CFrame = CFrame.new(position)
	configure(burstEmitter, spec)
	burstEmitter:Emit(spec.burstCount or 8)

	if spec.lightRange ~= nil then
		-- §8.5: the loss and the win both carry light, because "tell win from loss from across the
		-- room" is a lighting problem before it is a particle problem.
		flashLight.Enabled = true
		flashLight.Color = spec.lightColor
		flashLight.Range = spec.lightRange
		flashPeak = spec.lightBrightness
		flashLight.Brightness = flashPeak
		flashEndsAt = clock + (spec.lightSeconds or 0.2)
	end
end

--- Where the rod tip is: the player's head plus the config offset. Deliberately independent of the
--- rod's own geometry (RodController's model may be restyled) so the flash cannot drift away from
--- the tip without a config change.
function EffectsController:RodTip(): Vector3
	local character = player.Character
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	if head == nil then
		return Vector3.zero
	end
	return (head :: BasePart).Position + VisualConfig.Flash.rodTipOffset
end

--- §8.5, one entry point per outcome. The result strings are FishingService's.
function EffectsController:OnFightResolved(payload: any)
	local result = if payload ~= nil then payload.result else nil
	local at = self:RodTip()
	if result == "Landed" then
		self:Burst(at, VisualConfig.Flash.Landing)
	elseif result == "Snapped" or result == "WeakLine" then
		self:Burst(at, VisualConfig.Flash.Snap)
	elseif result == "Escaped" then
		self:Burst(at, VisualConfig.Flash.Escape)
	end
end

-- ============================================================================
-- The per-frame drive (§8.4)
-- ============================================================================

function EffectsController:UpdateBubbles()
	if bubbleEmitter == nil then
		return
	end
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	local bubbles = VisualConfig.Player.Bubbles
	local rate = 0
	if state.submerged and root ~= nil then
		local velocity = (root :: BasePart).AssemblyLinearVelocity
		local vertical = velocity.Y
		local speed = velocity.Magnitude
		if vertical >= bubbles.ascendSpeedStuds then
			rate = bubbles.ascendRate -- §8.4: 30/s on a fast ascent
		elseif speed >= bubbles.swimSpeedStuds then
			rate = bubbles.swimRate -- §8.4: 14/s while swimming
		else
			rate = bubbles.idleRate -- §8.4: 2/s idle
		end
	end
	if rate ~= lastBubbleRate then
		bubbleEmitter.Rate = rate
		lastBubbleRate = rate
	end
end

--- §8.4: "a kick-up silt puff when the player touches the seabed". FloorMaterial is the engine's own
--- answer to "am I standing on something", so this costs no raycast and no per-frame work.
function EffectsController:UpdateSilt()
	if not state.submerged then
		return
	end
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid == nil or root == nil then
		return
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return
	end
	local spec = VisualConfig.Player.SiltKick
	if clock - lastSiltAt < spec.cooldownSeconds then
		return
	end
	lastSiltAt = clock
	self:Burst((root :: BasePart).Position - Vector3.new(0, 2, 0), spec)
end

--- §1 step 3: the entry splash. Fires on the false -> true edge of `submerged`, which is the
--- server's own reading of the crossing (§3.0: the camera crossing Y 0).
function EffectsController:OnSubmergedChanged(submerged: boolean, previous: boolean)
	if not submerged or previous then
		return
	end
	local character = player.Character
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	local at = if head ~= nil then (head :: BasePart).Position + Vector3.new(0, 0.5, 0) else Vector3.zero
	self:Burst(at, VisualConfig.Splash)
end

-- Knit lifecycle --------------------------------------------------------------

function EffectsController:KnitStart()
	ensureAnchor()
	ensureBubbles()
	player.CharacterAdded:Connect(function()
		bubbleEmitter = nil
		lastBubbleRate = nil
		ensureBubbles()
	end)

	Remotes.get("DiveStateChanged").OnClientEvent:Connect(function(next: Types.DiveState)
		local wasSubmerged = state.submerged
		state = next
		self:OnSubmergedChanged(next.submerged, wasSubmerged)
	end)

	Remotes.get("FightResolved").OnClientEvent:Connect(function(payload: any)
		self:OnFightResolved(payload)
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		if flashLight ~= nil and flashLight.Enabled then
			-- The flash decays over its config lifetime rather than switching off: a hard cut reads
			-- as a bug, a fade reads as an event.
			local remaining = flashEndsAt - clock
			if remaining <= 0 then
				flashLight.Enabled = false
			else
				flashLight.Brightness = flashPeak * math.clamp(remaining / 0.3, 0, 1)
			end
		end
		self:UpdateBubbles()
		self:UpdateSilt()
	end)
end

return EffectsController
