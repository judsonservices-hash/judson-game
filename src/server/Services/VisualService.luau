--!strict
--[[
    VisualService — builds every light, emitter and look-only part the world carries, from config.
    Source: GDD §3.0 (water is Terrain, sky at 17.5), §3.2 L8 (sun shafts — 0 geometry, the
            Technical Artist's), §3.1 (per-zone ambience), §3.3 R3 (the rim current's emitter),
            §3.4 S4 (six upward, slow emitters), §8.1-§8.3 (the two-world lighting, fog as the
            depth gauge, sun rays dying by 60 studs), §8.6 (bioluminescence is the Shelf's only
            light), §9 (a player must be able to read the place by eye), Appendix A (primitives,
            Neon, PointLight, ParticleEmitter only).

    WHERE THIS SITS
      WorldService builds the geometry (278 parts, measured and asserted separately). This service
      adds the things that are not geometry: the water's appearance, the static lighting baseline,
      the sun shafts, the bioluminescent specks, the landmark lamps and the particle emitters. It
      adds no part to the world's geometry budget and never renames anything WorldService built —
      so the world suite keeps asserting 278 parts and this suite asserts its own, smaller budget.

    LAYERING (why the lighting is set twice on purpose)
      The server sets the *baseline* here (the Surface preset at boot, so the place reads correctly
      before any client does anything, and for anyone watching a replay). The client's
      AtmosphereController then drives the real thing: Lighting's fog, ambient and brightness are
      per-frame functions of the local camera's depth (§8.2 "the player's sense of depth must equal
      the number on the HUD"), which only a client can know. Both read the same config through the
      same sampler (Modules/Atmosphere), so the two cannot disagree about what 40 studs looks like.

    Idempotency: Build() clears Workspace.DeepTide.Visual and every child this service added is
    named with VisualConfig.InstanceNames' prefixes, so a second Build() replaces rather than
    duplicates. Every host it dresses is found by name (Appendix A) and a host that is missing is
    reported as a problem, never silently skipped.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Knit = require(ReplicatedStorage.Packages.Knit)

local LightingConfig = require(ReplicatedStorage.DeepTide.Config.LightingConfig)
local VisualConfig = require(ReplicatedStorage.DeepTide.Config.VisualConfig)
local Atmosphere = require(ReplicatedStorage.DeepTide.Modules.Atmosphere)

local VisualService = Knit.CreateService({
	Name = "VisualService",
	Client = {},
})

local ROOT_NAME = "DeepTide"
local VISUAL_FOLDER = VisualConfig.InstanceNames.Root

-- Per-build state (module locals, so nothing is bolted onto the Knit service table).
local lastReport: { [string]: any }? = nil

-- ============================================================================
-- Tree helpers
-- ============================================================================

local function rootFolder(): Instance
	local existing = Workspace:FindFirstChild(ROOT_NAME)
	if existing ~= nil then
		return existing
	end
	local created: any = Instance.new("Folder")
	created.Name = ROOT_NAME
	created.Parent = Workspace
	return created
end

--- Create (or return) a folder by path under a root, e.g. "Visual/Shallows/Shafts".
local function folderAt(root: Instance, path: string): Instance
	local current = root
	for segment in string.gmatch(path, "[^/]+") do
		local next = current:FindFirstChild(segment)
		if next == nil then
			local created: any = Instance.new("Folder")
			created.Name = segment
			created.Parent = current
			next = created
		end
		current = next :: Instance
	end
	return current
end

--- Find a world instance by the config's path, e.g. "World/Shallows/L1/L1_Ramp".
--- Returns nil (and the caller records a problem) rather than creating anything: dressing a part
--- that does not exist would hide a rename instead of surfacing it.
local function findPath(path: string): Instance?
	local current: Instance? = rootFolder()
	for segment in string.gmatch(path, "[^/]+") do
		if current == nil then
			return nil
		end
		current = (current :: Instance):FindFirstChild(segment)
	end
	return current
end

local function clearChildren(folder: Instance)
	for _, child in folder:GetChildren() do
		child:Destroy()
	end
end

--- Remove every child this service previously added, wherever it was parented (Visual/ for parts,
--- a landmark part for a lamp, a seabed part for a dust emitter). Identifying them by name prefix
--- rather than by remembering addresses is what makes Build() safe to run twice.
local function clearOwnedChildren(root: Instance, prefix: string)
	for _, descendant in root:GetDescendants() do
		if string.sub(descendant.Name, 1, #prefix) == prefix then
			descendant:Destroy()
		end
	end
end

local function replaceChild(parent: Instance, className: string, name: string): any
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		existing:Destroy()
	end
	local created: any = Instance.new(className)
	created.Name = name
	created.Parent = parent
	return created
end

-- ============================================================================
-- Instance builders (all numbers arrive from config; nothing here is a look)
-- ============================================================================

local function applyLight(host: Instance, name: string, spec: { [string]: any }): any
	local light = replaceChild(host, "PointLight", name)
	light.Color = spec.color
	light.Brightness = spec.brightness
	light.Range = spec.range
	-- Nothing in this world casts a shadow from a point light: 30-odd shadows at 60 Hz is the
	-- fastest way to spend a mid-range laptop's frame budget on the one thing nobody looks at.
	light.Shadows = false
	return light
end

local function applyEmitter(host: Instance, name: string, spec: { [string]: any }): any
	local emitter = replaceChild(host, "ParticleEmitter", name)
	emitter.Rate = spec.rate
	emitter.Speed = spec.speed
	emitter.Lifetime = spec.lifetime
	emitter.Size = NumberSequence.new(spec.sizeMin, spec.sizeMax)
	emitter.Transparency = NumberSequence.new(spec.transparencyStart, spec.transparencyEnd)
	emitter.Color = ColorSequence.new(spec.color, spec.color)
	emitter.LightEmission = spec.lightEmission or 0
	emitter.LightInfluence = if spec.lightInfluence ~= nil then spec.lightInfluence else 1
	emitter.SpreadAngle = Vector2.new(spec.spreadAngle, spec.spreadAngle)
	emitter.Acceleration = spec.acceleration or Vector3.zero
	emitter.Drag = spec.drag or 0
	emitter.EmissionDirection = Enum.NormalId[spec.emissionDirection or "Top"]
	emitter.MaxParticles = spec.maxParticles or 20
	-- Never a texture: Appendix A forbids imported assets. A large particle with no texture is a
	-- soft water-fog mote, which is exactly what silt and bubbles should look like.
	emitter.Enabled = true
	return emitter
end

--- A part that exists only to be looked at: anchored, non-collidable, non-queryable, no shadow.
local function addLookPart(
	parent: Instance,
	name: string,
	position: Vector3,
	size: Vector3,
	color: Color3,
	material: any,
	transparency: number
): any
	local part: any = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Block
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = material
	part.Transparency = transparency
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- ============================================================================
-- The water and the static lighting baseline (§3.0, §3.1, §8.1)
-- ============================================================================

--- §3.0: "Water is Roblox Terrain water, one fill region ... Nothing else is Terrain."
--- Terrain's water properties are global, so this is the whole of the world's water look.
function VisualService:ApplyWater(): { [string]: any }
	local water = LightingConfig.Water
	local terrain: any = Workspace.Terrain
	terrain.WaterColor = water.color
	terrain.WaterTransparency = water.transparency
	terrain.WaterReflectance = water.reflectance
	terrain.WaterWaveSize = water.waveSize
	terrain.WaterWaveSpeed = water.waveSpeed
	return water
end

--- The boot-time baseline: the Surface preset, applied to Lighting and the three post-process
--- instances. The client takes it from here (see the file header) — this is what the place looks
--- like with no client script running at all.
function VisualService:ApplyLightingBaseline(): { [string]: any }
	local lighting: any = game:GetService("Lighting")
	local plan = Atmosphere.Plan(0)
	local names = LightingConfig.InstanceNames

	lighting.ClockTime = LightingConfig.ClockTime
	lighting.GlobalShadows = LightingConfig.GlobalShadows
	lighting.ShadowSoftness = LightingConfig.ShadowSoftness
	lighting.Ambient = plan.ambient
	lighting.OutdoorAmbient = plan.outdoorAmbient
	lighting.Brightness = plan.brightness
	lighting.ExposureCompensation = plan.exposureCompensation
	lighting.EnvironmentDiffuseScale = plan.environmentDiffuseScale
	lighting.EnvironmentSpecularScale = plan.environmentSpecularScale
	lighting.FogEnd = plan.fogEnd
	lighting.FogStart = plan.fogStart
	lighting.FogColor = plan.fogColor

	local atmosphere = replaceChild(lighting, "Atmosphere", names.Atmosphere)
	atmosphere.Density = plan.atmosphere.density
	atmosphere.Haze = plan.atmosphere.haze
	atmosphere.Color = plan.atmosphere.color
	atmosphere.Decay = plan.atmosphere.decay
	atmosphere.Glare = plan.atmosphere.glare
	atmosphere.Offset = plan.atmosphere.offset

	local bloom = replaceChild(lighting, "BloomEffect", names.Bloom)
	bloom.Intensity = plan.bloom.intensity
	bloom.Size = plan.bloom.size
	bloom.Threshold = plan.bloom.threshold
	bloom.Enabled = true

	local grade = replaceChild(lighting, "ColorCorrectionEffect", names.Grade)
	grade.TintColor = plan.grade.tint
	grade.Saturation = plan.grade.saturation
	grade.Contrast = plan.grade.contrast
	grade.Brightness = plan.grade.brightness
	grade.Enabled = true

	return plan
end

-- ============================================================================
-- Build
-- ============================================================================

--- Everything this service puts in the place, counted.
--- Returns { lights, emitters, parts, missing, problems, budget, seconds }.
function VisualService:Build(): { [string]: any }
	local startedAt = os.clock()
	local report: { [string]: any } = {
		lights = 0,
		emitters = 0,
		parts = 0,
		hosts = 0,
		missing = {},
		problems = {},
		seconds = 0,
	}

	local root = rootFolder()
	local names = VisualConfig.InstanceNames

	-- Water + the lighting baseline are not instances this service owns (Terrain and Lighting are
	-- services), so they are applied rather than counted.
	self:ApplyWater()
	self:ApplyLightingBaseline()

	-- Idempotency: drop everything this service previously added anywhere in the tree.
	clearOwnedChildren(root, names.EmitterPrefix)
	clearOwnedChildren(root, names.LightPrefix)
	local visual = folderAt(root, VISUAL_FOLDER)
	clearChildren(visual)

	-- ------------------------------------------------------------------
	-- §3.2 L8 / §8.3 — sun shafts (5 parts, 0 in the world's geometry budget by design)
	-- ------------------------------------------------------------------
	local shaftFolder = folderAt(root, VISUAL_FOLDER .. "/Shallows/Shafts")
	local shaftParts: { any } = {}
	local shaftCfg = LightingConfig.SunShafts
	for index, placement in shaftCfg.placements do
		local position = Vector3.new(
			placement.x,
			shaftCfg.startY - shaftCfg.size.Y / 2,
			placement.z
		)
		local part = addLookPart(
			shaftFolder,
			("SunShaft_%d"):format(index),
			position,
			shaftCfg.size,
			shaftCfg.color,
			Enum.Material[shaftCfg.material],
			-- 1 - alpha: the parts are drawn at `aboveWaterAlpha` transparency (0.65 = faint) and the
			-- client's AtmosphereController moves them from there to fully invisible with depth.
			1 - shaftCfg.aboveWaterAlpha
		)
		part.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(placement.pitch), math.rad(placement.yaw), 0)
		part:SetAttribute("SunShaftIndex", index)
		part:SetAttribute("Zone", "Shallows")
		table.insert(shaftParts, part)
		report.parts += 1
	end

	-- Suspended motes inside two of the shafts (§8.4's "hand-sweep"/water density read, cheapest
	-- possible form: something already in the light path that drifts very slowly).
	for _, index in VisualConfig.ShaftMotes.hostIndices do
		local host = shaftParts[index]
		if host ~= nil then
			applyEmitter(host, names.EmitterPrefix .. "ShaftMotes_" .. tostring(index), VisualConfig.ShaftMotes)
			report.emitters += 1
		end
	end

	-- ------------------------------------------------------------------
	-- §8.6 — bioluminescent points: the Shelf's only light source
	-- ------------------------------------------------------------------
	local biolum = VisualConfig.Bioluminescence
	for index, point in biolum.points do
		local zone = point.zone
		local folder = folderAt(root, ("%s/%s/Biolum"):format(VISUAL_FOLDER, zone))
		local speck = addLookPart(
			folder,
			("BioluminescentPoint_%d"):format(index),
			point.position,
			biolum.speck.size,
			point.color,
			Enum.Material[biolum.speck.material],
			biolum.speck.transparency
		)
		speck:SetAttribute("Zone", zone)
		applyLight(speck, names.LightPrefix .. "Biolum_" .. tostring(index), point)
		report.parts += 1
		report.lights += 1
	end

	-- ------------------------------------------------------------------
	-- §9 — landmark dressing: every place the player must recognise, lit
	-- ------------------------------------------------------------------
	for _, dressing in VisualConfig.LandmarkLights do
		local host = findPath(dressing.hostPath)
		if host == nil then
			table.insert(report.missing, dressing.hostPath)
			table.insert(
				report.problems,
				("%s: no such part (%s) — that landmark would be left unlit"):format(dressing.id, dressing.hostPath)
			)
		else
			applyLight(host, names.LightPrefix .. dressing.id, dressing)
			report.lights += 1
			report.hosts += 1
		end
	end

	-- ------------------------------------------------------------------
	-- §3.3 R3 — the Rim Current's particle emitter (its 6 neon strips are WorldService's)
	-- ------------------------------------------------------------------
	local currentHost = findPath(VisualConfig.RimCurrent.hostPath)
	if currentHost == nil then
		table.insert(report.missing, VisualConfig.RimCurrent.hostPath)
		table.insert(
			report.problems,
			("RimCurrent: no such part (%s) — the only moving water in the world would be still"):format(
				VisualConfig.RimCurrent.hostPath
			)
		)
	else
		applyEmitter(currentHost, names.EmitterPrefix .. "RimCurrent", VisualConfig.RimCurrent)
		report.emitters += 1
		report.hosts += 1
	end

	-- ------------------------------------------------------------------
	-- §3.4 S4 — six upward, slow vent plumes
	-- ------------------------------------------------------------------
	local plumeCfg = VisualConfig.VentPlumes
	for index = 1, plumeCfg.hostCount do
		local path = plumeCfg.hostFormat:format(index)
		local host = findPath(path)
		if host == nil then
			table.insert(report.missing, path)
			table.insert(report.problems, ("VentPlume %d: no such part (%s)"):format(index, path))
		else
			applyEmitter(host, ("%sVentPlume_%d"):format(names.EmitterPrefix, index), plumeCfg)
			report.emitters += 1
			report.hosts += 1
		end
	end

	-- ------------------------------------------------------------------
	-- Silt: the water is a place, not air (2 emitters per band, on real seabed geometry)
	-- ------------------------------------------------------------------
	for index, placement in VisualConfig.SeabedDust.placements do
		local host = findPath(placement.hostPath)
		if host == nil then
			table.insert(report.missing, placement.hostPath)
			table.insert(report.problems, ("SeabedDust %d: no such part (%s)"):format(index, placement.hostPath))
		else
			local spec = table.clone(VisualConfig.SeabedDust)
			spec.color = placement.color
			applyEmitter(host, ("%sSeabedDust_%d"):format(names.EmitterPrefix, index), spec)
			report.emitters += 1
			report.hosts += 1
		end
	end

	report.seconds = os.clock() - startedAt
	report.problems = self:_BudgetProblems(report, report.problems)
	lastReport = report
	return report
end

--- The stated budget, checked rather than trusted (LightingConfig.Budget).
function VisualService:_BudgetProblems(report: { [string]: any }, problems: { string }): { string }
	local budget = LightingConfig.Budget
	if report.lights > budget.Lights then
		table.insert(problems, ("%d lights, budget is %d"):format(report.lights, budget.Lights))
	end
	if report.emitters > budget.Emitters then
		table.insert(problems, ("%d emitters, budget is %d"):format(report.emitters, budget.Emitters))
	end
	if report.parts > budget.VisualParts then
		table.insert(problems, ("%d look-only parts, budget is %d"):format(report.parts, budget.VisualParts))
	end
	return problems
end

-- ============================================================================
-- Reporting
-- ============================================================================

function VisualService:GetReport(): { [string]: any }?
	return lastReport
end

function VisualService:GetLightCount(): number
	return if lastReport ~= nil then (lastReport :: any).lights else 0
end

function VisualService:GetEmitterCount(): number
	return if lastReport ~= nil then (lastReport :: any).emitters else 0
end

function VisualService:GetVisualPartCount(): number
	return if lastReport ~= nil then (lastReport :: any).parts else 0
end

--- How many lights WorldService itself built, read off the live tree rather than remembered, so
--- this file never carries a second copy of the world's own numbers.
function VisualService:EngineLightCount(): number
	local total = 0
	for _, descendant in rootFolder():GetDescendants() do
		if descendant:IsA("PointLight") and string.sub(descendant.Name, 1, 2) ~= VisualConfig.InstanceNames.LightPrefix then
			total += 1
		end
	end
	return total
end

function VisualService:SummaryLine(): string
	local report = lastReport
	if report == nil then
		return "visuals: not built"
	end
	local budget = LightingConfig.Budget
	return ("visuals: %d lights (world %d, budget %d) · %d emitters (budget %d) · %d look-only parts (budget %d) · %d/5 bands"):format(
		report.lights,
		self:EngineLightCount(),
		budget.Lights,
		report.emitters,
		budget.Emitters,
		report.parts,
		budget.VisualParts,
		#LightingConfig.Bands
	)
end

-- Client surface -------------------------------------------------------------

--- The client's AtmosphereController reads config directly (it is in ReplicatedStorage), so
--- nothing needs to be shipped here.
function VisualService.Client:GetLightCount(player: Player): number
	return self.Server:GetLightCount()
end

-- Knit lifecycle --------------------------------------------------------------

function VisualService:KnitStart()
	-- KnitStart, not KnitInit: the world is built in WorldService's init and every host this
	-- service dresses is found by name in the tree WorldService produced.
	local report = self:Build()
	for _, problem in report.problems do
		warn("[Deep Tide] visual: " .. problem)
	end
	print("[Deep Tide] " .. self:SummaryLine())
end

return VisualService
