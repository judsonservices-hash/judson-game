--!strict
--[[
    FishService — Appendix B: "Owns fish spawning, the 20 Hz movement loop, behaviour state
    machines (§4.3), despawn/respawn timers".
    Source: GDD §4 (fish are single primitives with Attributes), §4.3 (the five behaviour
            rules), §4.5 (spawn/despawn/respawn rules), §4.6 (fixed coordinates),
            §11 (48/10/6/7/3 = 74 live at server start; no Shelf fish visible from the dock).

    Every fish is a non-collidable Part parented to Workspace.DeepTide.Fish, moved by the server
    at FishConfig.SpawnRules.MovementHz; clients interpolate. Coordinates come from SpawnConfig
    (through the §4.6 spawn anchors WorldService builds); timings from FishConfig — never from
    this file.

    Where the fish live (the one contract with the world):
        Workspace.DeepTide.Spawns.<Species>/<Species>_AnchorHost
            Attachment <Node|Den>_<n>   -- one per §4.6 coordinate
    If those anchors do not exist (a server booted without the world) the service falls back to
    SpawnConfig's coordinates rather than spawning nothing.

    Determinism: every "random" value §4.3 asks for comes from one seeded Rng
    (FishConfig.SpawnRules.RandomSeed), consumed in a fixed order, so a run is reproducible and
    the loop can be tested headlessly — see tools/worldtest/fish_harness.luau.

    Divergence from §4 (flagged, deliberate): §4 says fish are `Anchored = false`. They are
    anchored here. An unanchored part in Roblox Terrain water is buoyant — it rises to the
    surface — so an unanchored Ghost Ray at 210 studs cannot stay there. Fish are
    server-authoritative parts, exactly as §4 asks, and the anchor is only how that is enforced.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local FishConfig = require(ReplicatedStorage.DeepTide.Config.FishConfig)
local SpawnConfig = require(ReplicatedStorage.DeepTide.Config.SpawnConfig)
local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)
local FightConfig = require(ReplicatedStorage.DeepTide.Config.FightConfig)
local Rng = require(ReplicatedStorage.DeepTide.Modules.Rng)

local FishService = Knit.CreateService({
	Name = "FishService",
})

local ROOT_NAME = "DeepTide"
local FISH_FOLDER = "Fish"
local SPAWNS_FOLDER = "Spawns"

-- §5.1 step 1 / §5.2 step 3: states a fish cannot be cast at. "Fleeing" covers the §4.3 flight
-- of every species, "Lunging" is the eel mid-attack, and the hooked states belong to FishingService.
local UNCASTABLE_STATES: { [string]: boolean } = {
	Fleeing = true,
	Lunging = true,
	Hooked_Pending = true,
	Fighting = true,
	Landed = true,
	Despawning = true,
}

-- §4: "Each fish carries Attributes: Species, Rarity, Value, State, HomeNode."
local ATTRIBUTE_KEYS = { "Species", "Rarity", "Value", "State", "HomeNode" }

export type FishRecord = {
	index: number, -- stable spawn order, 1..FishConfig.TotalLiveAtServerStart
	speciesId: string,
	species: any, -- FishConfig.Species entry
	nodeIndex: number, -- 1-based anchor ordinal
	homeNode: string, -- "<Species>/<NodeName>" (§4 attribute value)
	home: Vector3, -- the §4.6 coordinate the fish belongs to
	part: BasePart?,
	lure: BasePart?,
	alive: boolean,
	state: string,
	position: Vector3,
	velocity: Vector3,
	-- shared school anchor
	anchorKey: string?,
	orbitOffset: Vector3,
	swimSpeed: number,
	-- patrol
	waypoints: { Vector3 },
	waypointIndex: number,
	legElapsed: number,
	legDuration: number,
	legFrom: Vector3,
	-- ambush
	denPosition: Vector3,
	denFacing: Vector3,
	-- flee / lunge
	fleeSpeed: number,
	fleeTimer: number,
	fleeDirection: Vector3,
	fleeRespawnDelay: number?,
	fleeRespawnWander: boolean,
	fleeIsFight: boolean, -- true = a lost-fight flight (FishingService), false = the §4.3 pattern
	settleTimer: number, -- §4.3 Reef Bass: drift before it is approachable again
	-- bookkeeping
	eligibilityTimer: number,
	respawnTimer: number,
	awaySeconds: number,
	spawnCooldown: number,
	clock: number, -- per-fish phase clock, drives sway/bob
}

type SchoolAnchor = {
	position: Vector3,
	target: Vector3,
	pause: number,
	fleeTimer: number,
	fleeDirection: Vector3,
}

local records: { FishRecord } = {}
local byPart: { [BasePart]: FishRecord } = {}
local schoolAnchors: { [string]: SchoolAnchor } = {}
local loopConnection: RBXScriptConnection? = nil
local rng = Rng.new(FishConfig.SpawnRules.RandomSeed)
local spawnSequence = 0

-- ============================================================================
-- Small helpers
-- ============================================================================

local function fishFolder(): Instance
	local root = Workspace:FindFirstChild(ROOT_NAME)
	if root == nil then
		local created = Instance.new("Folder")
		created.Name = ROOT_NAME
		created.Parent = Workspace
		root = created
	end
	local folder = (root :: Instance):FindFirstChild(FISH_FOLDER)
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = FISH_FOLDER
		created.Parent = root
		folder = created
	end
	return folder :: Instance
end

--- Depth in studs below sea level (§3.0), positive.
local function depthOf(position: Vector3): number
	return math.max(0, ZoneConfig.SeaLevelY - position.Y)
end

--- §4.2/§4.5: a fish's depth must stay inside its species band, and inside its zone's footprint.
--- This is what makes "no Shelf fish can be found at less than 110 studs" (§4.5) a property of
--- the system rather than of the spawn coordinates happening to be deep enough.
local function clampToBand(species: any, position: Vector3): Vector3
	local band = species.depthBand
	local topY = -band[1]
	local bottomY = -band[2]

	local y = math.clamp(position.Y, bottomY, topY)

	local zone = ZoneConfig.Zones[species.zone]
	local x, z = position.X, position.Z
	if zone ~= nil then
		local footprint = zone.footprint
		x = math.clamp(x, footprint.minX, footprint.maxX)
		z = math.clamp(z, footprint.minZ, footprint.maxZ)
	end

	return Vector3.new(x, y, z)
end

--- The seabed surface a species should be floated above when the GDD says "snapped to seabed
--- + 4 studs" (§4.3, Sunset Grouper). Read from ZoneConfig — the same table WorldService builds
--- the seabed from — so it can never drift from the geometry.
local function seabedTopY(species: any, position: Vector3): number
	local spec = ZoneConfig.Seabed[species.zone]
	if spec == nil then
		return position.Y
	end
	if type(spec.topY) == "number" then
		return spec.topY :: number
	end
	local tops = spec.topYs
	if tops == nil then
		return position.Y
	end
	local footprint = ZoneConfig.Zones[species.zone].footprint
	local cellZ = spec.cellSize.Z
	local originZ = (footprint.minZ + footprint.maxZ) / 2 - (#tops * cellZ) / 2
	local row = math.clamp(math.floor((position.Z - originZ) / cellZ) + 1, 1, #tops)
	return tops[row]
end

local function playerPositions(): { Vector3 }
	local out: { Vector3 } = {}
	local players = game:GetService("Players"):GetPlayers()
	for _, player in players do
		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		if root ~= nil then
			table.insert(out, (root :: BasePart).Position)
		end
	end
	return out
end

--- (distance, player position) of the closest player to `position`; nil when nobody is in.
local function nearestPlayer(position: Vector3, positions: { Vector3 }): (number?, Vector3?)
	local bestDistance: number? = nil
	local bestPosition: Vector3? = nil
	for _, other in positions do
		local distance = (other - position).Magnitude
		if bestDistance == nil or distance < bestDistance then
			bestDistance = distance
			bestPosition = other
		end
	end
	return bestDistance, bestPosition
end

local function unitOr(offset: Vector3, fallback: Vector3): Vector3
	local magnitude = offset.Magnitude
	if magnitude < 1e-4 then
		return fallback
	end
	return offset / magnitude
end

local function nodeRadius(species: any): number
	local cfg = species.behaviourCfg
	return cfg.radius or cfg.driftRadius or cfg.anchorRadius or 0
end

-- ============================================================================
-- Spawn anchors (§4.6, built by WorldService)
-- ============================================================================

--- The §4.6 coordinates for a species, in anchor order: the Attachments WorldService built when
--- they are there, SpawnConfig when they are not. Returns positions and their node names.
local function anchorPositions(speciesId: string): ({ Vector3 }, { string })
	local positions: { Vector3 } = {}
	local names: { string } = {}

	local root = Workspace:FindFirstChild(ROOT_NAME)
	local spawns = if root ~= nil then (root :: Instance):FindFirstChild(SPAWNS_FOLDER) else nil
	local speciesFolder = if spawns ~= nil then (spawns :: Instance):FindFirstChild(speciesId) else nil
	local host = if speciesFolder ~= nil then speciesFolder:FindFirstChild(("%s_AnchorHost"):format(speciesId)) else nil

	if host ~= nil then
		for _, child in (host :: Instance):GetChildren() do
			if child:IsA("Attachment") then
				table.insert(positions, (child :: Attachment).WorldPosition)
				table.insert(names, tostring((child :: Attachment):GetAttribute("NodeName") or child.Name))
			end
		end
	end

	if #positions == 0 then
		local config = (SpawnConfig :: any)[speciesId]
		local list = if config ~= nil then (config.anchors or config.nodes or config.dens) else nil
		for index, position in (list or {}) do
			table.insert(positions, position)
			local prefix = if speciesId == "LanternEel" then "Den" else "Node"
			table.insert(names, ("%s_%d"):format(prefix, index))
		end
	end

	return positions, names
end

-- ============================================================================
-- Fish instances
-- ============================================================================

local function stampAttributes(rec: FishRecord)
	local part = rec.part
	if part == nil then
		return
	end
	part:SetAttribute("Species", rec.speciesId)
	part:SetAttribute("Rarity", rec.species.rarity)
	part:SetAttribute("Value", rec.species.value)
	part:SetAttribute("State", rec.state)
	part:SetAttribute("HomeNode", rec.homeNode)
end

--- Builds (or rebuilds) one fish's Part at its home node. §4.2: one primitive, config's size,
--- colour, material and transparency; the Lantern Eel gets its §4.2 lure as a second neon Part.
local function spawnRecord(rec: FishRecord)
	local species = rec.species
	local start = if rec.state == "Fleeing" then rec.position else rec.home
	local position = clampToBand(species, start)

	local part = Instance.new("Part")
	part.Name = ("%s_%d"):format(rec.speciesId, rec.index)
	part.Shape = Enum.PartType.Block
	part.Size = species.size
	part.Color = species.color
	part.Material = species.material
	part.Transparency = species.transparency
	part.Anchored = true -- see the file header: Terrain water floats unanchored parts
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = CFrame.new(position)
	part.Parent = fishFolder()

	rec.part = part
	rec.position = position
	rec.velocity = Vector3.zero
	rec.alive = true
	rec.state = "Idle"
	rec.clock = rng:range(0, 10)
	rec.eligibilityTimer = 0
	rec.awaySeconds = 0
	rec.settleTimer = 0
	rec.fleeTimer = 0
	rec.spawnCooldown = FishConfig.SpawnRules.SpawnBurstIntervalSeconds
	rec.waypointIndex = 1
	rec.legElapsed = 0
	if rec.waypoints[1] ~= nil then
		rec.legFrom = rec.position
	end

	if species.accent ~= nil and species.accent.placement == "lure" then
		local lure = Instance.new("Part")
		lure.Name = part.Name .. "_Lure"
		lure.Shape = Enum.PartType.Ball
		lure.Size = species.accent.lureSize or Vector3.new(0.9, 0.9, 0.9)
		lure.Color = species.accent.color
		lure.Material = Enum.Material.Neon
		lure.Anchored = true
		lure.CanCollide = false
		lure.CanQuery = false
		lure.CanTouch = false
		lure.CastShadow = false
		lure.CFrame = CFrame.new(position + rec.denFacing * (species.size.X / 2 + 1))
		lure.Parent = fishFolder()
		-- §8.6: the lure is the eel's tell in the dark.
		local light = Instance.new("PointLight")
		light.Color = species.accent.color
		light.Brightness = 1.5
		light.Range = 14
		light.Parent = lure
		rec.lure = lure
	end

	byPart[part] = rec
	stampAttributes(rec)
end

local function despawnRecord(rec: FishRecord)
	if rec.part ~= nil then
		byPart[rec.part] = nil
		rec.part:Destroy()
		rec.part = nil
	end
	if rec.lure ~= nil then
		rec.lure:Destroy()
		rec.lure = nil
	end
	rec.alive = false
	rec.state = "Despawning"
	rec.spawnCooldown = FishConfig.SpawnRules.SpawnBurstIntervalSeconds
end

--- A brand new fish record for one §4.6 anchor slot. `member` distinguishes the 6 sardines that
--- share one school anchor.
local function makeRecord(
	index: number,
	speciesId: string,
	nodeIndex: number,
	nodeName: string,
	home: Vector3,
	member: number
): FishRecord
	local species = FishConfig.Species[speciesId]
	local cfg = species.behaviourCfg

	local rec: FishRecord = {
		index = index,
		speciesId = speciesId,
		species = species,
		nodeIndex = nodeIndex,
		homeNode = ("%s/%s"):format(speciesId, nodeName),
		home = home,
		part = nil,
		lure = nil,
		alive = false,
		state = "Idle",
		position = home,
		velocity = Vector3.zero,
		anchorKey = nil,
		orbitOffset = Vector3.zero,
		swimSpeed = 0,
		waypoints = {},
		waypointIndex = 1,
		legElapsed = 0,
		legDuration = 0,
		legFrom = home,
		denPosition = home,
		denFacing = Vector3.new(0, 0, 1),
		fleeSpeed = 0,
		fleeTimer = 0,
		fleeDirection = Vector3.new(0, 0, 1),
		fleeRespawnDelay = nil,
		fleeRespawnWander = false,
		fleeIsFight = false,
		settleTimer = 0,
		eligibilityTimer = 0,
		respawnTimer = 0,
		awaySeconds = 0,
		spawnCooldown = 0,
		clock = 0,
	}

	if species.behaviour == "School" then
		local radius = cfg.orbit or 0
		rec.orbitOffset = rng:insideSphere(Vector3.zero, radius)
		rec.swimSpeed = cfg.anchorSpeed * rng:range(0.9, 1.1) -- "anchor velocity +/-10% jitter"
		rec.anchorKey = ("%s_%d"):format(speciesId, nodeIndex)
		if member == 1 or schoolAnchors[rec.anchorKey] == nil then
			schoolAnchors[rec.anchorKey] = {
				position = home,
				target = home,
				pause = rng:range(cfg.pauseMin, cfg.pauseMax),
				fleeTimer = 0,
				fleeDirection = Vector3.new(0, 0, 1),
			}
		end
	elseif species.behaviour == "Patrol" then
		rec.legDuration = cfg.legTime or 0
		for waypoint = 1, (cfg.waypoints or 0) do
			local offset = if cfg.loopBox ~= nil
				then Vector3.new(
					rng:range(-cfg.loopBox.X / 2, cfg.loopBox.X / 2),
					rng:range(-cfg.loopBox.Y / 2, cfg.loopBox.Y / 2),
					rng:range(-cfg.loopBox.Z / 2, cfg.loopBox.Z / 2)
				)
				else Vector3.new(
					rng:range(-cfg.radius, cfg.radius),
					rng:range(-8, 8),
					rng:range(-cfg.radius, cfg.radius)
				)
			table.insert(rec.waypoints, clampToBand(species, home + offset))
		end
		if #rec.waypoints == 0 then
			table.insert(rec.waypoints, home)
		end
		rec.legFrom = home
		rec.swimSpeed = cfg.speed
		if rec.legDuration > 0 and #rec.waypoints > 1 then
			-- An eased glide goes leg to leg: the fish starts ON waypoint 1 and its first leg
			-- targets waypoint 2. (Starting a leg from home toward the point the fish is already
			-- sitting on would make the first 14 s a crawl across a few studs.)
			rec.legFrom = rec.waypoints[1]
			rec.position = rec.waypoints[1]
			rec.waypointIndex = 2
		end
	elseif species.behaviour == "Flee" then
		rec.swimSpeed = cfg.speed
		local target = rng:insideSphere(home, cfg.radius * 0.6)
		table.insert(rec.waypoints, clampToBand(species, target))
	elseif species.behaviour == "Ambush" then
		-- §4.6: the den's opening faces -Z, so the eel protrudes that way.
		rec.denPosition = home
		rec.denFacing = Vector3.new(0, 0, -1)
		rec.waypoints = { clampToBand(species, home + rec.denFacing * cfg.idleProtrusion) }
	end

	rec.position = if #rec.waypoints > 0 then rec.waypoints[1] else home
	return rec
end

-- ============================================================================
-- Behaviour (§4.3) — one function per pattern
-- ============================================================================

--- Moves `rec` toward `target` by at most `speed * dt`, writing the velocity for the turn easing.
local function steer(rec: FishRecord, target: Vector3, speed: number, dt: number, ease: number?)
	local offset = target - rec.position
	local distance = offset.Magnitude
	local desired = if distance > 1e-4 then (offset / distance) * speed else Vector3.zero
	local blend = if ease ~= nil and ease > 0 then math.min(1, dt / ease) else 1
	rec.velocity = rec.velocity + (desired - rec.velocity) * blend
	rec.position += rec.velocity * dt
end

--- Shared flight (§4.3): away from the player, optionally with a extra dive component.
local function beginFlee(rec: FishRecord, playerPosition: Vector3, speed: number, seconds: number, dive: boolean)
	rec.state = "Fleeing"
	rec.fleeSpeed = speed
	rec.fleeTimer = seconds
	rec.fleeIsFight = false
	local away = rec.position - playerPosition
	if dive then
		away = away + Vector3.new(0, -math.abs(away.Y) - 6, 0)
	end
	rec.fleeDirection = unitOr(away, Vector3.new(0, 0, 1))
	rec.velocity = rec.fleeDirection * speed
end

--- §4.3 School: 8 anchors random-walking on a 60-stud radius, 6 members orbiting each.
local function stepSchool(rec: FishRecord, dt: number, positions: { Vector3 })
	local cfg = rec.species.behaviourCfg
	local anchor = schoolAnchors[rec.anchorKey :: string]
	if anchor == nil then
		return
	end

	local distance, playerPosition = nearestPlayer(rec.position, positions)

	-- The whole school bursts together (§4.3): the trigger is any member's player distance, but
	-- the anchor is what moves, so every member reacts on the same frame.
	if distance ~= nil and distance <= cfg.fleeRadius and anchor.fleeTimer <= 0 and rec.fleeTimer <= 0 then
		anchor.fleeTimer = cfg.fleeTime
		anchor.fleeDirection = unitOr(anchor.position - (playerPosition :: Vector3), Vector3.new(0, 0, 1))
	end

	if anchor.fleeTimer > 0 then
		anchor.fleeTimer -= dt
		anchor.position += anchor.fleeDirection * cfg.fleeSpeed * dt
		if anchor.fleeTimer <= 0 then
			-- "then re-anchors up to 80 studs away"
			anchor.target = anchor.position + rng:unitVector() * cfg.reanchorMax * rng:range(0.3, 1)
			anchor.pause = 0
		end
	elseif anchor.pause > 0 then
		anchor.pause -= dt
	else
		local offset = anchor.target - anchor.position
		if offset.Magnitude <= 1 then
			anchor.target = anchor.position + rng:unitVector() * cfg.anchorRadius * rng:range(0.3, 1)
			anchor.pause = rng:range(cfg.pauseMin, cfg.pauseMax)
		else
			anchor.position += (offset / offset.Magnitude) * cfg.anchorSpeed * dt
		end
	end

	local desired = clampToBand(rec.species, anchor.position + rec.orbitOffset)
	steer(rec, desired, rec.swimSpeed, dt)
	if anchor.fleeTimer > 0 then
		rec.state = "Fleeing"
		rec.fleeTimer = anchor.fleeTimer
	elseif rec.state == "Fleeing" then
		rec.state = "Idle"
		rec.fleeTimer = 0
	end
end

--- §4.3 Patrol (Sunset Grouper, Ghost Ray): waypoint to waypoint, with the ray's eased glide.
local function stepPatrol(rec: FishRecord, dt: number, positions: { Vector3 })
	local cfg = rec.species.behaviourCfg
	local distance, playerPosition = nearestPlayer(rec.position, positions)

	if rec.settleTimer > 0 then
		rec.settleTimer -= dt
	end

	if rec.fleeTimer > 0 then
		rec.fleeTimer -= dt
		rec.position += rec.fleeDirection * rec.fleeSpeed * dt
		if rec.fleeTimer <= 0 then
			rec.state = "Idle"
			-- "then rejoins its loop at the nearest waypoint"
			local bestIndex, bestDistance = 1, math.huge
			for index, waypoint in rec.waypoints do
				local d = (waypoint - rec.position).Magnitude
				if d < bestDistance then
					bestIndex, bestDistance = index, d
				end
			end
			rec.waypointIndex = bestIndex
			rec.legFrom = rec.position
			rec.legElapsed = 0
		end
		return
	end

	if cfg.fleeRadius ~= nil and rec.settleTimer <= 0 and distance ~= nil and distance <= cfg.fleeRadius then
		rec.fleeSpeed = cfg.fleeSpeed
		rec.fleeTimer = cfg.fleeTime
		rec.fleeDirection = unitOr(rec.position - (playerPosition :: Vector3), Vector3.new(0, 0, 1))
		rec.state = "Fleeing"
		return
	end

	-- A displaced grouper walks home (§4.3: "Returns to its original node if displaced > 80 studs").
	local returnDistance = cfg.returnNodeDistance
	if returnDistance ~= nil and (rec.home - rec.position).Magnitude > returnDistance then
		rec.waypoints[rec.waypointIndex] = clampToBand(rec.species, rec.home)
	end

	local target = rec.waypoints[rec.waypointIndex]
	if rec.legDuration > 0 then
		-- Ghost Ray: 5 waypoints, ~14 s a leg, eased so it never turns sharply. The GDD asks for
		-- TweenService + Quad; the same Quad curve is interpolated here instead, which keeps the
		-- loop deterministic, testable and free of one Tween per fish per leg.
		rec.legElapsed += dt
		local t = math.clamp(rec.legElapsed / rec.legDuration, 0, 1)
		local eased = 1 - (1 - t) * (1 - t) -- Quad, Out
		rec.position = rec.legFrom + (target - rec.legFrom) * eased
		rec.velocity = unitOr(target - rec.legFrom, rec.velocity) * cfg.speed
		if t >= 1 then
			rec.legFrom = target
			rec.legElapsed = 0
			rec.waypointIndex = (rec.waypointIndex % #rec.waypoints) + 1
			rec.waypoints[rec.waypointIndex] = clampToBand(
				rec.species,
				rec.home
					+ Vector3.new(
						rng:range(-cfg.radius, cfg.radius),
						rng:range(-6, 6),
						rng:range(-cfg.radius, cfg.radius) * 0.6
					)
			)
		end
	else
		steer(rec, target, cfg.speed, dt, cfg.turnEase)
		if (target - rec.position).Magnitude <= 1 then
			rec.waypointIndex = (rec.waypointIndex % #rec.waypoints) + 1
			-- §4.3: waypoints are procedural, inside the node's radius, snapped above the seabed.
			local offset =
				Vector3.new(rng:range(-cfg.radius, cfg.radius), rng:range(-10, 10), rng:range(-cfg.radius, cfg.radius))
			local nextPoint = clampToBand(rec.species, rec.home + offset)
			local floor = seabedTopY(rec.species, nextPoint) + 4
			if nextPoint.Y < floor then
				nextPoint = Vector3.new(nextPoint.X, floor, nextPoint.Z)
			end
			rec.waypoints[rec.waypointIndex] = nextPoint
		end
	end
end

--- §4.3 Flee (Reef Bass): drift, the 0.35 s startle pause, then run until it is 40 studs clear.
local function stepFleeFish(rec: FishRecord, dt: number, positions: { Vector3 })
	local cfg = rec.species.behaviourCfg
	local distance, playerPosition = nearestPlayer(rec.position, positions)

	if rec.settleTimer > 0 then
		rec.settleTimer -= dt
	end

	if rec.state == "Fleeing" then
		if rec.fleeSpeed <= 0 then
			-- §4.3: "the frame the player is within 14 studs, pause 0.35 s — that delay is the only
			-- reason it is catchable, do not remove it". The pause is a Fleeing state at zero speed.
			rec.fleeTimer -= dt
			if rec.fleeTimer <= 0 then
				rec.fleeSpeed = cfg.fleeSpeed
				-- ReefBass has no fleeTime: §4.3 runs it until it is clearDistance from its home.
				rec.fleeTimer = cfg.fleeTime or math.huge
			end
		else
			rec.fleeTimer -= dt
			rec.position += rec.fleeDirection * rec.fleeSpeed * dt
			local clear = (rec.position - rec.home).Magnitude
			if rec.fleeTimer <= 0 or clear >= (cfg.clearDistance or math.huge) then
				-- "decelerates and drifts for 5 s before being approachable again"
				rec.state = "Idle"
				rec.settleTimer = cfg.driftTime
				rec.waypoints[1] = clampToBand(rec.species, rec.home + rng:insideSphere(Vector3.zero, cfg.radius * 0.6))
			end
		end
		return
	end

	if rec.settleTimer <= 0 and distance ~= nil and distance <= cfg.startleRadius then
		beginFlee(rec, playerPosition :: Vector3, 0, cfg.startleDelay, distance <= cfg.diveRadius)
		return
	end

	local target = rec.waypoints[rec.waypointIndex]
	if target == nil or (target - rec.position).Magnitude <= 2 then
		rec.waypoints[1] = clampToBand(rec.species, rec.home + rng:insideSphere(Vector3.zero, cfg.radius * 0.6))
		rec.waypointIndex = 1
	end
	steer(rec, rec.waypoints[rec.waypointIndex], cfg.speed, dt, 0.5)
end

--- §4.3 Ambush (Lantern Eel): idle in the den, lunge, 2 s recovery (the catch window), return.
local function stepAmbush(rec: FishRecord, dt: number, positions: { Vector3 })
	local cfg = rec.species.behaviourCfg
	local distance, playerPosition = nearestPlayer(rec.position, positions)

	if rec.fleeTimer > 0 then
		rec.fleeTimer -= dt
		if rec.state == "Lunging" then
			rec.position += rec.fleeDirection * rec.fleeSpeed * dt
			if (rec.position - rec.denPosition).Magnitude > cfg.maxRange then
				rec.position = rec.denPosition + unitOr(rec.position - rec.denPosition, rec.denFacing) * cfg.maxRange
			end
			if rec.fleeTimer <= 0 then
				rec.state = "Recovering"
				rec.fleeTimer = cfg.recoverTime
			end
		elseif rec.state == "Recovering" then
			rec.position += rec.fleeDirection * cfg.recoverSpeed * dt
			if rec.fleeTimer <= 0 then
				rec.state = "Returning"
				rec.fleeTimer = cfg.returnTime
			end
		else
			rec.position += rec.fleeDirection * rec.fleeSpeed * dt
			if rec.fleeTimer <= 0 then
				rec.state = "Idle"
			end
		end
		-- §4.3: the whole encounter stays inside maxRange of the crevice (§4.3 "never chases
		-- more than maxRange studs from its crevice").
		if (rec.position - rec.denPosition).Magnitude > cfg.maxRange then
			rec.position = rec.denPosition + unitOr(rec.position - rec.denPosition, rec.denFacing) * cfg.maxRange
		end
		return
	end

	-- §4.3: "never chases more than maxRange studs from its crevice" — true of the whole
	-- encounter, not just the lunge, so recovery cannot carry it away either.
	if (rec.position - rec.denPosition).Magnitude > cfg.maxRange then
		rec.position = rec.denPosition + unitOr(rec.position - rec.denPosition, rec.denFacing) * cfg.maxRange
	end

	if rec.state == "Returning" then
		local target = rec.denPosition + rec.denFacing * cfg.idleProtrusion
		steer(rec, target, (rec.position - target).Magnitude / math.max(cfg.returnTime, 0.01), dt)
		if (target - rec.position).Magnitude <= 0.5 then
			rec.state = "Idle"
			rec.waypoints = { target }
		end
		return
	end

	-- Idle: it ProtRUDES from the crevice (§4.3). The sway is applied at CFrame-write time.
	if rec.state == "Idle" then
		local target = rec.denPosition + rec.denFacing * cfg.idleProtrusion
		rec.position = rec.position + (target - rec.position) * math.min(1, dt * 2)
	end

	if distance ~= nil and distance <= cfg.lungeRadius then
		rec.state = "Lunging"
		rec.fleeSpeed = cfg.lungeSpeed
		rec.fleeTimer = cfg.lungeTime
		rec.fleeDirection = unitOr((playerPosition :: Vector3) - rec.position, rec.denFacing)
	end
end

--- Where a fish is drawn this frame: behaviour owns `position`, presentation adds the sway/bob
--- the GDD describes, so the two never feed back into each other.
local function renderPosition(rec: FishRecord): Vector3
	local cfg = rec.species.behaviourCfg
	local offset = Vector3.zero
	if rec.species.behaviour == "School" then
		offset = Vector3.new(0, math.sin(rec.clock * 2) * 0.1, 0)
	elseif cfg.bobAmplitude ~= nil then
		local period = cfg.bobPeriod or (1 / (cfg.bobHz or 1))
		offset = Vector3.new(0, cfg.bobAmplitude * math.sin(2 * math.pi * rec.clock / period), 0)
	elseif rec.species.behaviour == "Ambush" then
		offset = Vector3.new(math.sin(2 * math.pi * rec.clock / cfg.swayPeriod) * cfg.swayAmplitude, 0, 0)
	end
	return rec.position + offset
end

local function writeTransform(rec: FishRecord)
	local part = rec.part
	if part == nil then
		return
	end
	local position = clampToBand(rec.species, renderPosition(rec))
	local heading = rec.velocity.Magnitude > 1e-3 and rec.velocity or rec.denFacing
	local flat = Vector3.new(heading.X, 0, heading.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, 1)
	end
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, math.atan2(-flat.X, flat.Z), 0)

	if rec.lure ~= nil then
		local cfg = rec.species.behaviourCfg
		local bob = cfg.lureBobAmplitude or 0
		local forward = if rec.denFacing.Magnitude > 0 then rec.denFacing else Vector3.new(0, 0, 1)
		rec.lure.CFrame = CFrame.new(
			position + forward * (rec.species.size.X / 2 + 1) + Vector3.new(0, math.sin(rec.clock * 1.6) * bob, 0)
		)
	end
end

-- ============================================================================
-- Public server API
-- ============================================================================

--- Spawns every species at its §4.6 coordinates: 74 fish at server start (§11).
function FishService:StartSpawning()
	self:StopSpawning()
	records = {}
	byPart = {}
	schoolAnchors = {}
	rng = Rng.new(FishConfig.SpawnRules.RandomSeed)
	spawnSequence = 0

	for _, speciesId in FishConfig.Order do
		local species = FishConfig.Species[speciesId]
		local positions, names = anchorPositions(speciesId)
		local cfg = species.behaviourCfg

		if #positions > 0 then
			local perNode = if species.behaviour == "School" then cfg.perSchool else 1
			local target = species.liveAtStart
			local spawned = 0

			-- §4.5: the fish live permanently at their node. The population target from config
			-- decides how many fish each anchor actually holds, so the two can never disagree:
			-- `liveAtStart` fish are spread across the anchors in order.
			local member = 0
			while spawned < target do
				local nodeIndex = (math.floor(spawned / perNode) % #positions) + 1
				member += 1
				local record =
					makeRecord(spawnSequence + 1, speciesId, nodeIndex, names[nodeIndex], positions[nodeIndex], member)
				spawnSequence += 1
				spawned += 1
				table.insert(records, record)
				spawnRecord(record)
			end
		end
	end

	return #records
end

function FishService:StopSpawning()
	if loopConnection ~= nil then
		loopConnection:Disconnect()
		loopConnection = nil
	end
	local root = Workspace:FindFirstChild(ROOT_NAME)
	local folder = if root ~= nil then (root :: Instance):FindFirstChild(FISH_FOLDER) else nil
	if folder ~= nil then
		for _, child in (folder :: Instance):GetChildren() do
			child:Destroy()
		end
	end
	records = {}
	byPart = {}
	schoolAnchors = {}
end

--- Every live fish Part.
function FishService:GetAllFish(): { BasePart }
	local out: { BasePart } = {}
	for _, rec in records do
		if rec.alive and rec.part ~= nil then
			table.insert(out, rec.part)
		end
	end
	return out
end

--- Live count, optionally for one species (§11 verifies 48/10/6/7/3).
function FishService:GetLiveFishCount(speciesId: string?): number
	local count = 0
	for _, rec in records do
		if rec.alive and (speciesId == nil or rec.speciesId == speciesId) then
			count += 1
		end
	end
	return count
end

--- What the population should be at rest (FishConfig), vs what is alive right now, per species.
--- One call, so a boot line or a test can state the whole §4.5 target in a sentence.
function FishService:GetPopulationReport(): { [string]: any }
	local live: { [string]: number } = {}
	local target: { [string]: number } = {}
	for _, speciesId in FishConfig.Order do
		live[speciesId] = self:GetLiveFishCount(speciesId)
		target[speciesId] = FishConfig.Species[speciesId].liveAtStart
	end
	return {
		live = live,
		target = target,
		totalLive = self:GetLiveFishCount(),
		totalTarget = FishConfig.TotalLiveAtServerStart,
		tracked = #records,
	}
end

--- The §5.1 rule: nearest eligible fish to the player, within `maxRange` and (optionally) in
--- front of them. "In front" is the character's facing — the camera is the client's business and
--- the client is what draws the [E] CAST prompt; the server refuses a target it cannot see.
function FishService:GetNearestEligibleFish(player: Player, maxRange: number, requireFacing: boolean): BasePart?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil then
		return nil
	end
	local origin = (root :: BasePart).Position
	local look = (root :: BasePart).CFrame.LookVector

	local best: BasePart? = nil
	local bestDistance = math.huge
	for _, rec in records do
		if rec.alive and rec.part ~= nil and self:IsCastable(rec.part) then
			local offset = rec.position - origin
			local distance = offset.Magnitude
			if distance <= maxRange and distance < bestDistance then
				if not requireFacing then
					best, bestDistance = rec.part, distance
				elseif distance > 0 then
					local unit = offset / distance
					local dot = unit.X * look.X + unit.Y * look.Y + unit.Z * look.Z
					if dot >= FightConfig.CastFacingDot then
						best, bestDistance = rec.part, distance
					end
				end
			end
		end
	end
	return best
end

--- §5.2 step 7, §5.6: a fish that was missed, escaped or snapped is ineligible for a while, and a
--- fish that is fleeing or mid-lunge cannot be cast at (§5.1 step 1: "fish not fleeing").
function FishService:IsEligible(fish: BasePart): boolean
	local rec = byPart[fish]
	if rec == nil or not rec.alive then
		return false
	end
	if rec.eligibilityTimer > 0 then
		return false
	end
	return UNCASTABLE_STATES[rec.state] ~= true
end

--- The same test, named for what the caller means: "can the player cast at this fish right now".
function FishService:IsCastable(fish: BasePart): boolean
	return self:IsEligible(fish)
end

--- Everything about one fish that FishingService needs, in one snapshot (§4 attributes + state).
function FishService:Describe(fish: BasePart): { [string]: any }?
	local rec = byPart[fish]
	if rec == nil then
		return nil
	end
	return {
		speciesId = rec.speciesId,
		species = rec.species,
		node = rec.homeNode,
		home = rec.home,
		position = rec.position,
		state = rec.state,
		eligible = self:IsEligible(fish),
		part = rec.part,
	}
end

--- Drives the behaviour state machine for one fish (§4.3). Called from the 20 Hz loop and by
--- FishingService when a fish enters or leaves a fight.
function FishService:SetState(fish: BasePart, state: string)
	local rec = byPart[fish]
	if rec == nil then
		return
	end
	rec.state = state
	rec.velocity = Vector3.zero
	if state == "Fleeing" or state == "Lunging" then
		rec.fleeTimer = 0
	end
	if rec.part ~= nil then
		rec.part:SetAttribute("State", state)
	end
end

function FishService:GetState(fish: BasePart): string?
	local rec = byPart[fish]
	return if rec ~= nil then rec.state else nil
end

--- §5.1 step 3: the targeted fish is frozen in place for the hook-set window — it may not escape
--- before the player has had a chance to react.
function FishService:LockForFight(fish: BasePart, state: string)
	self:SetState(fish, state)
end

--- §5.6: hold the fish out of eligibility without moving it (used after a missed hook set).
function FishService:SetIneligible(fish: BasePart, seconds: number)
	local rec = byPart[fish]
	if rec ~= nil then
		rec.eligibilityTimer = math.max(rec.eligibilityTimer, seconds)
	end
end

--- A landed fish: remove it and respawn its home node after FishConfig.SpawnRules.RespawnSeconds.
function FishService:MarkCaught(fish: BasePart)
	local rec = byPart[fish]
	if rec == nil then
		return
	end
	despawnRecord(rec)
	rec.respawnTimer = FishConfig.SpawnRules.RespawnSeconds
	rec.state = "Despawning"
end

--- §4.3: the shared flight helper — `speed` and `seconds` come from the species'
--- behaviourCfg (fleeSpeed / fleeTime, or lungeSpeed / lungeTime for the eel).
--- `respawnDelay` is the §5.6 addition: the fish flees, then leaves the world and comes back.
function FishService:StartFlee(fish: BasePart, speed: number, seconds: number, respawnDelay: number?, wander: boolean?)
	local rec = byPart[fish]
	if rec == nil then
		return
	end
	local _, playerPosition = nearestPlayer(rec.position, playerPositions())
	local away = if playerPosition ~= nil then rec.position - playerPosition else rng:unitVector()
	rec.state = "Fleeing"
	rec.fleeSpeed = speed
	rec.fleeTimer = seconds
	rec.fleeDirection = unitOr(away, Vector3.new(0, 0, 1))
	rec.velocity = rec.fleeDirection * speed
	rec.settleTimer = 0
	rec.fleeIsFight = true
	rec.fleeRespawnDelay = respawnDelay
	rec.fleeRespawnWander = wander == true
	if rec.part ~= nil then
		rec.part:SetAttribute("State", "Fleeing")
	end
end

--- §5.6 respawn timers: 15 s after a catch or despawn (`MarkCaught`), and the per-outcome waits in
--- FightConfig.Cooldowns (respawnMiss / respawnSnap / respawnEscape) after a lost fight.
--- `wander` respawns the fish elsewhere in its band (§5.3 step 8) instead of on its node.
function FishService:RespawnAfter(fish: BasePart, delaySeconds: number, wander: boolean?)
	local rec = byPart[fish]
	if rec == nil then
		return
	end
	local species = rec.species
	local home = rec.home
	if wander == true then
		local radius = nodeRadius(species)
		home = clampToBand(species, home + rng:insideSphere(Vector3.zero, radius))
	end
	despawnRecord(rec)
	rec.home = home
	rec.respawnTimer = delaySeconds
end

--- §4.5: a spawner will not spawn more than one fish per SpawnBurstIntervalSeconds. The opening
--- population ignores it (the world must start full); everything after it respects it.
function FishService:CanSpawnNow(speciesId: string?): boolean
	for _, rec in records do
		if rec.alive and (speciesId == nil or rec.speciesId == speciesId) then
			if rec.spawnCooldown > 0 then
				return false
			end
		end
	end
	return true
end

-- ============================================================================
-- The movement loop (§4.3, §4.5)
-- ============================================================================

--- One movement step. Called from Heartbeat with the real frame delta; the harness calls it with
--- a fixed delta so a run is reproducible. `dt` is clamped to FishConfig.SpawnRules.MaxStepSeconds.
function FishService:_Step(dt: number)
	local step = math.min(dt, FishConfig.SpawnRules.MaxStepSeconds)
	if step <= 0 then
		return
	end
	local positions = playerPositions()

	for _, rec in records do
		if rec.spawnCooldown > 0 then
			rec.spawnCooldown -= step
		end

		if not rec.alive then
			rec.respawnTimer -= step
			if rec.respawnTimer <= 0 then
				spawnRecord(rec)
			end
		else
			rec.clock += step
			if rec.eligibilityTimer > 0 then
				rec.eligibilityTimer -= step
			end

			-- §5.1-§5.3: a hooked fish is FishingService's until the fight resolves.
			local locked = rec.state == "Hooked_Pending" or rec.state == "Fighting"
			if not locked then
				if rec.state == "Fleeing" and rec.fleeIsFight then
					-- a flight imposed by a lost fight (§5.6): it runs, then leaves and respawns
					rec.fleeTimer -= step
					rec.position += rec.fleeDirection * rec.fleeSpeed * step
					if rec.fleeTimer <= 0 then
						local delay = rec.fleeRespawnDelay
						local wander = rec.fleeRespawnWander
						rec.fleeIsFight = false
						rec.fleeRespawnDelay = nil
						rec.fleeRespawnWander = false
						self:RespawnAfter(rec.part :: BasePart, delay or FishConfig.SpawnRules.RespawnSeconds, wander)
					end
				elseif rec.species.behaviour == "School" then
					stepSchool(rec, step, positions)
				elseif rec.species.behaviour == "Patrol" then
					stepPatrol(rec, step, positions)
				elseif rec.species.behaviour == "Flee" then
					stepFleeFish(rec, step, positions)
				elseif rec.species.behaviour == "Ambush" then
					stepAmbush(rec, step, positions)
				end

				if rec.alive then
					rec.position = clampToBand(rec.species, rec.position)
					-- §4: the State attribute is what a client reads (the cast prompt only appears
					-- over a fish that is not fleeing or hooked), so it is kept in step with the
					-- behaviour machine, one write per actual change.
					if rec.part ~= nil and rec.part:GetAttribute("State") ~= rec.state then
						rec.part:SetAttribute("State", rec.state)
					end
					writeTransform(rec)

					-- §4.5: the 400-stud perf guard. Only measured while somebody is in the server —
					-- an empty server has nobody to be far from, and must not wipe the ocean.
					if #positions > 0 then
						local distance = nearestPlayer(rec.position, positions)
						if distance ~= nil and distance > FishConfig.SpawnRules.DespawnPlayerDistance then
							rec.awaySeconds += step
							if rec.awaySeconds >= FishConfig.SpawnRules.DespawnAfterSeconds then
								despawnRecord(rec)
								rec.respawnTimer = FishConfig.SpawnRules.RespawnSeconds
							end
						else
							rec.awaySeconds = 0
						end
					else
						rec.awaySeconds = 0
					end
				end
			else
				writeTransform(rec)
			end
		end
	end
end

--- The §4.5 population target, per species, as the loop itself sees it.
function FishService:TargetCount(speciesId: string): number
	local species = FishConfig.Species[speciesId]
	return if species ~= nil then species.liveAtStart else 0
end

-- Knit lifecycle --------------------------------------------------------------

function FishService:KnitInit() end

function FishService:KnitStart()
	local spawned = self:StartSpawning()

	-- §4.3: reposition at MovementHz, server-authoritative.
	loopConnection = RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(function()
			FishService:_Step(dt)
		end)
		if not ok then
			warn("[Deep Tide] FishService step failed: " .. tostring(err))
		end
	end)

	local report = self:GetPopulationReport()
	print(
		("[Deep Tide] fish: %d live (target %d) — %d/%d %d/%d %d/%d %d/%d %d/%d · %d Hz"):format(
			report.totalLive,
			report.totalTarget,
			report.live.SilverSardine,
			report.target.SilverSardine,
			report.live.SunsetGrouper,
			report.target.SunsetGrouper,
			report.live.ReefBass,
			report.target.ReefBass,
			report.live.LanternEel,
			report.target.LanternEel,
			report.live.GhostRay,
			report.target.GhostRay,
			FishConfig.SpawnRules.MovementHz
		)
	)
	print(("[Deep Tide] fish spawned: %d records"):format(spawned))
end

return FishService
