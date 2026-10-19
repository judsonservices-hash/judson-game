--!strict
--[[
    AtmosphereController — the client half of §8.1/§8.2/the §8.8 screen effect.
    Source: GDD §3.0 (depth is -Y at the head; Sky at 17.5), §8.1 (two-world lighting, one
            interpolation, cross-fade never a snap), §8.2 (fog IS the depth gauge: the player's
            sense of depth must equal the number on the HUD), §8.3 (sun rays die by 60 studs),
            §8.8 (the air alarm must be impossible to miss and must never be muted by the mini-game).

    WHY THIS RUNS ON THE CLIENT
      Fog distance, ambient and the shafts' strength are functions of *this* camera's depth, and
      the server cannot know ten players' camera depths without ten times the traffic. So the
      server sets the baseline once (VisualService.ApplyLightingBaseline) and this controller owns
      the truth from then on, at LightingConfig.SampleHz (10 Hz — fog that steps 10 times a second
      is indistinguishable from fog that steps 60 times, and it is not a per-frame cost).

    WHAT IT WRITES (one plan, five instances)
      Lighting.FogEnd / FogStart / FogColor / Ambient / OutdoorAmbient / Brightness /
      ExposureCompensation / EnvironmentDiffuseScale / EnvironmentSpecularScale
      Lighting.DeepTideAtmosphere, Lighting.DeepTideBloom, Lighting.DeepTideGrade
      Lighting.DeepTideOxygen + Lighting.DeepTideOxygenBlur (the §8.8 alarm — post-process, so it
      tints the whole frame and can never occlude the tension track)
      LocalTransparencyModifier on the sun-shaft parts (client-only: dimming them costs no
      replication and no other screen can see it)

    IT DOES NOT TOUCH THE HUD. The depth/air labels and the red vignette belong to DepthController
    and the UI/UX pass. This is the water and the screen, not the chrome.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Atmosphere = require(ReplicatedStorage.DeepTide.Modules.Atmosphere)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local LightingConfig = require(ReplicatedStorage.DeepTide.Config.LightingConfig)
local VisualConfig = require(ReplicatedStorage.DeepTide.Config.VisualConfig)
local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)

local AtmosphereController = Knit.CreateController({
	Name = "AtmosphereController",
})

local player = Players.LocalPlayer

-- The last dive state the server sent (nothing here is inferred when the server has said it).
local state: Types.DiveState = {
	air = 0,
	airCapacity = 0,
	depth = 0,
	depthRating = 0,
	exceeded = false,
	submerged = false,
}

local effects: { [string]: any } = {}
local shaftParts: { any } = {}
local shaftAlpha = LightingConfig.SunShafts.aboveWaterAlpha
local clock = 0

-- ============================================================================
-- Instance plumbing
-- ============================================================================

local function lighting(): any
	return game:GetService("Lighting")
end

--- Find (or create) one of the instances this controller drives. VisualService creates them
--- server-side at boot, so on a normal join this is a lookup; `create` only matters if the client
--- ran before the server's visuals replicated, where a missing Atmosphere would otherwise mean an
--- unlit world rather than a slightly later-lit one.
local function effect(name: string, className: string): any
	local existing = effects[name]
	if existing ~= nil then
		return existing
	end
	local lightingService = lighting()
	local found = lightingService:FindFirstChild(name)
	if found == nil then
		found = Instance.new(className)
		found.Name = name
		found.Parent = lightingService
	end
	effects[name] = found
	return found
end

local function collectShafts()
	shaftParts = {}
	local root = game:GetService("Workspace"):FindFirstChild("DeepTide")
	local visual = if root ~= nil then root:FindFirstChild(VisualConfig.InstanceNames.Root) else nil
	local shallows = if visual ~= nil then visual:FindFirstChild("Shallows") else nil
	local folder = if shallows ~= nil then shallows:FindFirstChild("Shafts") else nil
	if folder == nil then
		return
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(shaftParts, child)
		end
	end
end

-- ============================================================================
-- One sample: the whole water, from one number
-- ============================================================================

--- Applies Atmosphere.Plan(depth) to the place. Called at LightingConfig.SampleHz.
function AtmosphereController:Apply(depthStuds: number, dt: number)
	local plan = Atmosphere.Plan(depthStuds)
	local names = LightingConfig.InstanceNames
	local lightingService = lighting()

	-- §8.2: the depth gauge. This is the number the player's eye reads against the HUD's DEPTH.
	lightingService.FogEnd = plan.fogEnd
	lightingService.FogStart = plan.fogStart
	lightingService.FogColor = plan.fogColor
	lightingService.Ambient = plan.ambient
	lightingService.OutdoorAmbient = plan.outdoorAmbient
	lightingService.Brightness = plan.brightness
	lightingService.ExposureCompensation = plan.exposureCompensation
	lightingService.EnvironmentDiffuseScale = plan.environmentDiffuseScale
	lightingService.EnvironmentSpecularScale = plan.environmentSpecularScale

	local atmosphere = effect(names.Atmosphere, "Atmosphere")
	atmosphere.Density = plan.atmosphere.density
	atmosphere.Haze = plan.atmosphere.haze
	atmosphere.Color = plan.atmosphere.color
	atmosphere.Decay = plan.atmosphere.decay
	atmosphere.Glare = plan.atmosphere.glare
	atmosphere.Offset = plan.atmosphere.offset

	local bloom = effect(names.Bloom, "BloomEffect")
	bloom.Intensity = plan.bloom.intensity
	bloom.Size = plan.bloom.size
	bloom.Threshold = plan.bloom.threshold
	bloom.Enabled = true

	local grade = effect(names.Grade, "ColorCorrectionEffect")
	grade.TintColor = plan.grade.tint
	grade.Saturation = plan.grade.saturation
	grade.Contrast = plan.grade.contrast
	grade.Brightness = plan.grade.brightness
	grade.Enabled = true

	-- §8.3: the shafts fade with depth, and the fade is smoothed rather than switched, so a camera
	-- that pops across Y 0 (a forced ascent, §5.4) cannot make them strobe.
	local target = Atmosphere.SunShaftAlpha(depthStuds)
	shaftAlpha = Atmosphere.AdvanceBlend(
		shaftAlpha,
		target,
		dt,
		1 / math.max(LightingConfig.SunShafts.fadeLerpPerSecond, 1e-3)
	)
	for _, part in shaftParts do
		-- LocalTransparencyModifier is the client-only transparency channel: dimming a shaft costs
		-- no replication and changes nothing for any other player's screen.
		part.LocalTransparencyModifier = 1 - shaftAlpha
	end

	return plan
end

--- §8.8: the air alarm as a screen effect. Zero until the alarm threshold, then a red wash, the
--- colour draining, the picture closing in, all of it breathing — and disabled the moment the
--- player is at the surface or has air, so the warning never cries wolf.
function AtmosphereController:ApplyOxygen()
	local names = LightingConfig.InstanceNames
	local plan = Atmosphere.OxygenPlan(state.air, clock)
	local active = plan.enabled and state.submerged

	local grade = effect(names.OxygenGrade, "ColorCorrectionEffect")
	grade.Enabled = active
	if active then
		grade.TintColor = plan.tint
		grade.Saturation = plan.saturation
		grade.Brightness = plan.brightness
	end

	local blur = effect(names.OxygenBlur, "BlurEffect")
	blur.Enabled = active and plan.blur > 0.05
	blur.Size = if active then plan.blur else 0

	return plan
end

--- The depth this client draws from: the server's own number for the local player's head (§3.0),
--- because that is the number the HUD prints (§8.2: the sense of depth must equal the readout).
--- The camera is only a fallback for the first frames of a join, before the first state push.
function AtmosphereController:SampleDepth(): number
	if state.depth > 0 then
		return state.depth
	end
	local camera = game:GetService("Workspace").CurrentCamera
	if camera ~= nil then
		return math.max(-camera.CFrame.Position.Y, 0)
	end
	return 0
end

-- Knit lifecycle --------------------------------------------------------------

function AtmosphereController:KnitStart()
	collectShafts()
	self:Apply(self:SampleDepth(), 0)

	Remotes.get("DiveStateChanged").OnClientEvent:Connect(function(next: Types.DiveState)
		state = next
		self:ApplyOxygen()
	end)

	local accumulated = 0
	local interval = 1 / math.max(LightingConfig.SampleHz, 1)
	RunService.RenderStepped:Connect(function(dt: number)
		accumulated += dt
		if accumulated < interval then
			return
		end
		clock += accumulated
		local step = accumulated
		accumulated = 0
		if #shaftParts == 0 then
			collectShafts() -- the server's visuals may land a frame or two after this controller starts
		end
		self:Apply(self:SampleDepth(), step)
		self:ApplyOxygen()
	end)
end

return AtmosphereController
