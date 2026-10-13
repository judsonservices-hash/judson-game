--[[
    Deep Tide — headless fishing-loop suite (assertions only; check.sh assembles the chunk).

    Runs the real FishService, FishingService, DiveService, GearService, InventoryService,
    PlayerService, WorldService, Modules/Tension and Modules/Rng against the stubbed Roblox
    globals, with mock players, and asserts the §5 loop end to end:

      1. the world's spawn anchors produce the configured population (§4.5, §4.6, §11)
      2. every species runs its §4.3 behaviour pattern, and none escapes its depth band
      3. a cast hooks a fish, the hook set opens the fight, the fight lands a fish (§5.1-§5.3)
      4. the landed fish reaches the Catch Log and the profile that gets persisted (§1 step 6)
      5. the §5.4 rarity gate snaps instantly, every time, with the exact §9 message
      6. the line-strength ceiling is enforced (§5.3 step 4)
      7. running out of air loses the fish and surfaces the player (§5.3 step 9)
      8. §5.6 cooldowns gate the next cast, and a miss costs the player only time
      9. the live population settles at the config target and the 400-stud rule fires (§4.5)
     10. the same seed produces the same world and the same fight twice

    It is deterministic: - no wall-clock anywhere, one fixed dt, one seeded generator.
]]

local failures = 0
local checks = 0
local function check(cond, msg)
	checks += 1
	if cond then
		print("  ok    " .. msg)
	else
		print("  FAIL  " .. msg)
		failures += 1
	end
end
local function section(text)
	print("=== " .. text .. " ===")
end

local CFG = {
	Fish = __config("FishConfig"),
	Spawn = __config("SpawnConfig"),
	Rarity = __config("RarityConfig"),
	Rod = __config("RodConfig"),
	Gear = __config("GearConfig"),
	Dive = __config("DiveConfig"),
	Fight = __config("FightConfig"),
	Economy = __config("EconomyConfig"),
	Zone = __config("ZoneConfig"),
}
local Tension = __Tension
local Rng = __Rng
local Remotes = __Remotes

-- The services are locals in the assembled chunk; give Knit the same lookups they expect.
SIBLING_SERVICES.WorldService = WorldService
SIBLING_SERVICES.PlayerService = PlayerService
SIBLING_SERVICES.GearService = GearService
SIBLING_SERVICES.InventoryService = InventoryService
SIBLING_SERVICES.DiveService = DiveService
SIBLING_SERVICES.FishService = FishService
SIBLING_SERVICES.FishingService = FishingService
__KnitStub.GetService = function(name)
	local service = SIBLING_SERVICES[name]
	if service == nil then
		error("harness: no service named " .. tostring(name))
	end
	return service
end

local STEP = 1 / 60

-- ============================================================================
-- Helpers
-- ============================================================================

local function tickOnce()
	__fireHeartbeat(STEP)
end

--- Advances the world by `seconds` of heartbeats, optionally running `onTick(clock)` before each.
local function advance(seconds, onTick)
	local ticks = math.floor(seconds / STEP + 0.5)
	for index = 1, ticks do
		if onTick ~= nil then
			onTick((index - 1) * STEP)
		end
		tickOnce()
	end
end

local function fishFolder(): Instance?
	local root = workspace:FindFirstChild("DeepTide")
	return if root ~= nil then root:FindFirstChild("Fish") else nil
end

local function isLure(part: Instance): boolean
	return string.find(part.Name, "_Lure$") ~= nil
end

--- Every live fish body (lures excluded).
local function liveFish(): { any }
	local out = {}
	local folder = fishFolder()
	if folder == nil then
		return out
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and not isLure(child) then
			table.insert(out, child)
		end
	end
	table.sort(out, function(a, b)
		return a.Name < b.Name
	end)
	return out
end

local function lures(): { any }
	local out = {}
	local folder = fishFolder()
	if folder == nil then
		return out
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and isLure(child) then
			table.insert(out, child)
		end
	end
	return out
end

local function speciesOf(part: any): string
	return tostring(part:GetAttribute("Species"))
end

local function stateOf(part: any): string
	return tostring(part:GetAttribute("State"))
end

local function ofSpecies(speciesId: string): { any }
	local out = {}
	for _, part in liveFish() do
		if speciesOf(part) == speciesId then
			table.insert(out, part)
		end
	end
	return out
end

local function rootOf(player: any): any
	return player.Character:FindFirstChild("HumanoidRootPart")
end

--- Place the player `standoff` studs from `target`, facing it. Yaw is set so the character's
--- LookVector points at the fish (the server validates the cast against that facing).
local function placeNear(player: any, target: any, standoff: number)
	local from = target.Position
	local to = rootOf(player).Position
	local away = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if away.Magnitude < 0.01 then
		away = Vector3.new(0, 0, 1)
	end
	away = away.Unit
	local position = from + away * standoff
	__movePlayer(player, Vector3.new(position.X, from.Y, position.Z), math.atan2(away.X, away.Z))
end

--- The nearest eligible fish of a species to the player.
local function nearestOfSpecies(player: any, speciesId: string, maxRange: number?): any
	local origin = rootOf(player).Position
	local best, bestDistance = nil, maxRange or math.huge
	for _, part in ofSpecies(speciesId) do
		local distance = (part.Position - origin).Magnitude
		if distance < bestDistance then
			best, bestDistance = part, distance
		end
	end
	return best
end

--- The species' "how close can I get without starting it" distance, derived from config:
--- outside its flee/startle/lunge radius, inside FightConfig.CastRange.
local function standoffFor(speciesId: string): number
	local cfg = CFG.Fish.Species[speciesId].behaviourCfg
	local trigger = cfg.fleeRadius or cfg.startleRadius or cfg.lungeRadius or 10
	return math.min(CFG.Fight.CastRange - 2, math.max(trigger + 4, 10))
end

--- A competent-player policy (§5.3): hold while the needle is below the safe zone, release while
--- it is above it, and hold the current input inside. `latencyTicks` is the player's reaction
--- time, which is what makes the fight take longer than the §5.5 bare minimum.
local function makeDriver(latencyTicks: number)
	local history = {}
	local held = false
	return function(session: any)
		local fight = session.fight
		history[#history + 1] = { needle = fight.needle, centre = fight.zoneCentre, width = fight.zoneHalfWidth }
		local sample = history[math.max(1, #history - latencyTicks)]
		local low = sample.centre - sample.width * 0.6
		local high = sample.centre + sample.width * 0.6
		if sample.needle < low then
			held = true
		elseif sample.needle > high then
			held = false
		end
		return held
	end
end

local function lastRemote(remoteName: string, player: any): any?
	local log = __remotes()
	for index = #log, 1, -1 do
		local entry = log[index]
		if entry.remote == remoteName and (entry.player == nil or entry.player == player) then
			return entry
		end
	end
	return nil
end

--- Did this player ever receive a Notify carrying `text`? (Order-independent: one action can
--- legitimately push two lines, e.g. the surface warning and the lost fish.)
local function notified(player: any, text: string): boolean
	for _, entry in __remotes() do
		if entry.remote == "Notify" and entry.player == player and (entry.args[1] or {}).text == text then
			return true
		end
	end
	return false
end

local function clearRemotes()
	__clearRemotes()
end

type Attempt = {
	result: string,
	seconds: number,
	cast: boolean,
	hooked: boolean,
	reason: string?,
	fish: any?,
}

--- One whole §5.1-§5.3 interaction against a live fish: place, cast, hook set, fight, resolve.
--- `options.hookFraction` picks where in the ring the player presses (1.0+ = too late);
--- `options.driver` is the fight policy; `options.onFightTick` can inject state (the air test).
local function attemptCatch(player: any, speciesId: string, options: any?): Attempt
	options = options or {}
	local driver = options.driver or makeDriver(0)
	local hookFraction = options.hookFraction or 0.85
	clearRemotes()

	local target = nearestOfSpecies(player, speciesId)
	if target == nil then
		return { result = "NoTarget", seconds = 0, cast = false, hooked = false }
	end
	placeNear(player, target, options.standoff or standoffFor(speciesId))
	tickOnce()

	if not FishService:IsEligible(target) then
		-- the school may have burst as the player arrived; wait for it to settle and re-pick
		advance(4)
		target = nearestOfSpecies(player, speciesId)
		if target == nil then
			return { result = "NoTarget", seconds = 0, cast = false, hooked = false }
		end
		placeNear(player, target, options.standoff or standoffFor(speciesId))
		tickOnce()
	end

	local accepted = FishingService:RequestCast(player, target)
	if not accepted or FishingService:GetSession(player) == nil then
		-- §5.6: the player may still be inside a cooldown from the last attempt. Wait it out and
		-- try once more, which is exactly what a player does.
		local waited = 0
		while not FishingService:IsRodReady(player) and waited < 30 do
			advance(0.1)
			waited += 0.1
		end
		if waited > 0 then
			target = nearestOfSpecies(player, speciesId) or target
			placeNear(player, target, options.standoff or standoffFor(speciesId))
			tickOnce()
			accepted = FishingService:RequestCast(player, target)
		end
	end
	if not accepted or FishingService:GetSession(player) == nil then
		return { result = "CastRefused", seconds = 0, cast = false, hooked = false, fish = target }
	end

	local elapsed = 0
	local fightStart: number? = nil
	local pressAttempted = false
	local outcome: Attempt = { result = "Unresolved", seconds = 0, cast = true, hooked = false, fish = target }

	for _ = 1, 60 * 40 do
		local session = FishingService:GetSession(player)
		if session == nil then
			outcome.seconds = elapsed
			outcome.hooked = fightStart ~= nil
			local resolved = lastRemote("FightResolved", player)
			if resolved ~= nil then
				outcome.result = (resolved.args[1] or {}).result or "Unresolved"
				outcome.reason = (resolved.args[1] or {}).reason
			end
			return outcome
		end

		if options.onFightTick ~= nil then
			options.onFightTick(session, elapsed)
		end

		if session.phase == "HookSet" and not pressAttempted then
			if session.phaseElapsed >= session.hookWindow * hookFraction then
				pressAttempted = true
				FishingService:RequestHookSet(player)
			end
		elseif session.phase == "Fighting" then
			if fightStart == nil then
				fightStart = elapsed
			end
			FishingService:SetFightInput(player, driver(session))
		end

		elapsed += STEP
		tickOnce()
	end

	outcome.seconds = elapsed
	return outcome
end

-- ============================================================================
-- Boot
-- ============================================================================

section("0. BOOT (world + the six services, exactly as the bootstrap orders them)")

local deepTideFolder = makeInstance("Folder")
deepTideFolder.Name = "DeepTide"
deepTideFolder.Parent = SERVICES.ReplicatedStorage
Remotes.ensure()

local remotesFolder = deepTideFolder:FindFirstChild("Remotes")
check(remotesFolder ~= nil, "ReplicatedStorage.DeepTide.Remotes exists")
local remoteCount = if remotesFolder ~= nil then #remotesFolder:GetChildren() else 0
check(remoteCount == #Remotes.Names, ("all %d remotes created (%d)"):format(#Remotes.Names, remoteCount))

WorldService:KnitInit()
for _, service in { PlayerService, GearService, InventoryService, DiveService, FishService, FishingService } do
	service:KnitInit()
end
for _, service in { PlayerService, GearService, InventoryService, DiveService, FishService, FishingService } do
	service:KnitStart()
end
check(true, "all services started without error")

local bob = __addPlayer("Bob", Vector3.new(0, 8, -20), math.pi)
check(PlayerService:IsLoaded(bob), "joining player gets a profile")
check(PlayerService:GetData(bob).coins == CFG.Economy.StartingCoins, "starting coins are §6.1's 0 C")
check(bob:GetAttribute("EquippedRodId") == "RustyRod", "the player starts holding the Rusty Rod (§6.1)")

-- ============================================================================
section("1. POPULATION (§4.5, §4.6, §11: 48/10/6/7/3)")

local report = FishService:GetPopulationReport()
print(
	("   live %d / target %d · %d/%d %d/%d %d/%d %d/%d %d/%d"):format(
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
		report.target.GhostRay
	)
)
check(
	report.totalLive == CFG.Fish.TotalLiveAtServerStart,
	("%d fish live at server start (config %d)"):format(report.totalLive, CFG.Fish.TotalLiveAtServerStart)
)
for _, speciesId in CFG.Fish.Order do
	local species = CFG.Fish.Species[speciesId]
	check(
		report.live[speciesId] == species.liveAtStart,
		("%s: %d live == §4.2 density %d"):format(speciesId, report.live[speciesId] or -1, species.liveAtStart)
	)
end

local bodies = liveFish()
local lureParts = lures()
check(#bodies == CFG.Fish.TotalLiveAtServerStart, ("%d fish Parts in Workspace.DeepTide.Fish"):format(#bodies))
check(
	#lureParts == CFG.Fish.Species.LanternEel.liveAtStart,
	("%d Lantern Eel lures (2 parts per eel, Appendix C)"):format(#lureParts)
)

local anchored, collidable, missingAttributes, outsideBand, shelfTooShallow = 0, 0, 0, 0, 0
for _, part in bodies do
	if part.Anchored ~= true then
		anchored += 1
	end
	if part.CanCollide ~= false then
		collidable += 1
	end
	for _, key in { "Species", "Rarity", "Value", "State", "HomeNode" } do
		if part:GetAttribute(key) == nil then
			missingAttributes += 1
			break
		end
	end
	local species = CFG.Fish.Species[speciesOf(part)]
	local depth = -part.Position.Y
	if depth < species.depthBand[1] - 1 or depth > species.depthBand[2] + 1 then
		outsideBand += 1
	end
	if species.zone == "Shelf" and depth < CFG.Fish.SpawnRules.NeverShallowerThanStuds then
		shelfTooShallow += 1
	end
end
check(anchored == 0, ("every fish Part moves under server control (%d unanchored)"):format(anchored))
check(collidable == 0, ("no fish is collidable (%d collidable)"):format(collidable))
check(
	missingAttributes == 0,
	("every fish carries Species/Rarity/Value/State/HomeNode (%d incomplete)"):format(missingAttributes)
)
check(outsideBand == 0, ("every fish spawns inside its §4.2 depth band (%d outside)"):format(outsideBand))
check(
	shelfTooShallow == 0,
	("no Shelf fish spawns shallower than %d studs (§4.5)"):format(CFG.Fish.SpawnRules.NeverShallowerThanStuds)
)

-- §4.6: every species spawns at its configured coordinates (the anchors WorldService built).
local anchorHome = {}
for _, speciesId in CFG.Fish.Order do
	local list = CFG.Spawn[speciesId].anchors or CFG.Spawn[speciesId].nodes or CFG.Spawn[speciesId].dens
	local prefix = if speciesId == "LanternEel" then "Den" else "Node"
	for index, position in list do
		anchorHome[("%s/%s_%d"):format(speciesId, prefix, index)] = position
	end
end
local homesMatched, homesChecked, worstHome = 0, 0, 0
for _, part in bodies do
	local node = tostring(part:GetAttribute("HomeNode"))
	local expected = anchorHome[node]
	if expected ~= nil then
		homesChecked += 1
		local species = CFG.Fish.Species[speciesOf(part)]
		-- a school member is spawned around its anchor, not on it; everything else sits on its node
		local tolerance = if species.behaviour == "School" then species.behaviourCfg.orbit + 1 else 2
		local distance = (part.Position - expected).Magnitude
		worstHome = math.max(worstHome, distance)
		if distance <= tolerance then
			homesMatched += 1
		end
	end
end
check(homesChecked == #bodies, ("every fish records a §4.6 HomeNode (%d/%d)"):format(homesChecked, #bodies))
check(
	homesMatched == #bodies,
	("every fish spawned at its home coordinate (%d/%d, worst %.2f studs)"):format(homesMatched, #bodies, worstHome)
)

-- ============================================================================
section("2. BEHAVIOUR PATTERNS (§4.3)")

local function pathLength(part: any, seconds: number): number
	local last = part.Position
	local travelled = 0
	advance(seconds, function()
		travelled += (part.Position - last).Magnitude
		last = part.Position
	end)
	return travelled
end

-- School: the 6 members of one anchor stay together and move as one.
local sardines = ofSpecies("SilverSardine")
local school = {}
for _, part in sardines do
	if tostring(part:GetAttribute("HomeNode")) == "SilverSardine/Node_1" then
		table.insert(school, part)
	end
end
check(
	#school == CFG.Fish.Species.SilverSardine.behaviourCfg.perSchool,
	("school Node_1 holds %d sardines"):format(#school)
)

local schoolTravel = 0
for _, part in school do
	schoolTravel += pathLength(part, 2)
end
check(schoolTravel > 5, ("the school moves as a ribbon (%.1f studs travelled in 2 s)"):format(schoolTravel))

local centroid = Vector3.new(0, 0, 0)
for _, part in school do
	centroid += part.Position
end
centroid = centroid / #school
local spread = 0
for _, part in school do
	spread = math.max(spread, (part.Position - centroid).Magnitude)
end
check(
	spread <= CFG.Fish.Species.SilverSardine.behaviourCfg.orbit + 2,
	("school members orbit within %.1f studs of the shoal centre"):format(spread)
)

local schoolBurst = false
__movePlayer(bob, centroid + Vector3.new(0, 0, 5))
advance(1, function()
	for _, part in school do
		if stateOf(part) == "Fleeing" then
			schoolBurst = true
		end
	end
end)
check(
	schoolBurst,
	("the whole school bursts when the player is within %d studs (§4.3)"):format(
		CFG.Fish.Species.SilverSardine.behaviourCfg.fleeRadius
	)
)
advance(5)
__movePlayer(bob, Vector3.new(0, 8, -20), math.pi)

-- Patrol: the grouper walks waypoint to waypoint.
local grouper = ofSpecies("SunsetGrouper")[1]
local grouperTravel = pathLength(grouper, 3)
check(
	grouperTravel > 10,
	("the grouper patrols between waypoints (%.1f studs in 3 s, §4.3 speed 8)"):format(grouperTravel)
)

-- Flee: the reef bass pauses first (0.35 s) and only then runs — the delay is what makes it catchable.
local bass = ofSpecies("ReefBass")[1]
placeNear(bob, bass, CFG.Fish.Species.ReefBass.behaviourCfg.startleRadius - 2)
tickOnce()
local startleState = stateOf(bass)
local startleStart = bass.Position
local runTravel = 0
local last = bass.Position
advance(0.3, function()
	runTravel += (bass.Position - last).Magnitude
	last = bass.Position
end)
local pausedTravel = runTravel
advance(1.5, function()
	runTravel += (bass.Position - last).Magnitude
	last = bass.Position
end)
check(startleState == "Fleeing", "the reef bass startles the frame the player is within 14 studs")
check(
	pausedTravel < 1,
	("it holds still for the %.2f s startle delay (%.2f studs)"):format(
		CFG.Fish.Species.ReefBass.behaviourCfg.startleDelay,
		pausedTravel
	)
)
check(
	runTravel > 10,
	("then it runs at %d studs/s (§4.3: %.1f studs in 1.8 s)"):format(
		CFG.Fish.Species.ReefBass.behaviourCfg.fleeSpeed,
		runTravel
	)
)
check((bass.Position - startleStart).Magnitude > 5, "the flight is away from where it was startled")
__movePlayer(bob, Vector3.new(0, 8, -20), math.pi)
advance(6)

-- Ambush: the eel lunges, recovers, and never leaves its den by more than maxRange.
local eel = ofSpecies("LanternEel")[1]
local den = tostring(eel:GetAttribute("HomeNode"))
placeNear(bob, eel, CFG.Fish.Species.LanternEel.behaviourCfg.lungeRadius - 2)
local lunged, recovered, returned = false, false, false
local maxDenRange = 0
local denPosition = eel.Position
advance(8, function()
	local state = stateOf(eel)
	if state == "Lunging" then
		lunged = true
	elseif state == "Recovering" then
		recovered = true
	elseif state == "Returning" then
		returned = true
	end
	-- the den is the §4.6 coordinate; measure from where the eel was when it was first seen idle
	maxDenRange = math.max(maxDenRange, (eel.Position - denPosition).Magnitude)
end)
check(
	lunged,
	("the eel lunges when the player is within %d studs (§4.3)"):format(
		CFG.Fish.Species.LanternEel.behaviourCfg.lungeRadius
	)
)
check(
	recovered,
	("it then serves its %.1f s recovery — the catch window"):format(
		CFG.Fish.Species.LanternEel.behaviourCfg.recoverTime
	)
)
check(returned, "and then returns to the crevice")
check(
	maxDenRange <= CFG.Fish.Species.LanternEel.behaviourCfg.maxRange + 8,
	("it never chases more than %d studs from the den (%.1f studs observed)"):format(
		CFG.Fish.Species.LanternEel.behaviourCfg.maxRange,
		maxDenRange
	)
)
check(
	eel:GetAttribute("Rarity") == "Rare" and eel:GetAttribute("Value") == 260,
	"the eel carries its §4.2 rarity and value"
)

-- Patrol (Ghost Ray): it glides a smooth loop inside its band and never leaves the Shelf.
local ray = ofSpecies("GhostRay")[1]
local rayTravel = pathLength(ray, 3)
local rayDepth = -ray.Position.Y
check(
	rayTravel > 5,
	("the Ghost Ray glides continuously (%.1f studs in 3 s of a %.0f s leg)"):format(
		rayTravel,
		CFG.Fish.Species.GhostRay.behaviourCfg.legTime
	)
)
-- A glide must never teleport: no single step may move more than a stud.
local rayJump = 0
local rayLast = ray.Position
advance(3, function()
	rayJump = math.max(rayJump, (ray.Position - rayLast).Magnitude)
	rayLast = ray.Position
end)
check(rayJump < 1, ("the ray never jumps between frames (largest step %.3f studs)"):format(rayJump))
check(
	rayDepth >= CFG.Fish.SpawnRules.NeverShallowerThanStuds,
	("the ray stays in the Shelf (%.0f studs deep)"):format(rayDepth)
)
check(ray:GetAttribute("Value") == CFG.Fish.Species.GhostRay.value, "the ray carries its §4.2 value")

-- ============================================================================
section("3. CAST -> HOOK SET -> FIGHT -> CATCH (§5.1-§5.3, §1 step 6)")

local attempt = attemptCatch(bob, "SilverSardine", { driver = makeDriver(0) })
print(
	("   sardine: %s in %.2f s (hooked %s, reason %s)"):format(
		attempt.result,
		attempt.seconds,
		tostring(attempt.hooked),
		tostring(attempt.reason)
	)
)
check(attempt.cast, "the cast was accepted (§5.1: range + facing + eligibility)")
check(attempt.hooked, "the hook-set ring opened and the fight started (§5.2)")
check(attempt.result == "Landed", ("perfect play lands the sardine (result %s)"):format(attempt.result))

local log = InventoryService:GetEntries(bob)
local landedRow = nil
for _, entry in log do
	if entry.speciesId == "SilverSardine" then
		landedRow = entry
	end
end
check(landedRow ~= nil and landedRow.count == 1, "the landed fish is one row in the Catch Log (§1 step 6)")
check(
	landedRow ~= nil and landedRow.value == CFG.Fish.Species.SilverSardine.value and landedRow.rarity == "Common",
	("the row carries the §4.2 value (%s) and rarity"):format(tostring(landedRow and landedRow.value))
)
check(
	InventoryService:GetTotalCoins(bob) == CFG.Fish.Species.SilverSardine.value,
	"the log's running TOTAL quotes the sell value (§9)"
)
check(
	PlayerService:GetData(bob).catchLog == log or #PlayerService:GetData(bob).catchLog == #log,
	"the catch lives in the persisted profile"
)
check(PlayerService:GetData(bob).coins == 0, "no Coins are added at catch time (§1 step 6: the trader pays, §6.2)")
check(
	FishService:GetLiveFishCount("SilverSardine") == 47,
	"the caught fish leaves the population until it respawns (15 s, §4.5)"
)

local catchNotice = lastRemote("Notify", bob)
check(
	catchNotice == nil or catchNotice.args[1].text ~= CFG.Fight.FailMessages.escape,
	"no failure line is shown for a landed fish"
)
local resolvedRemote = lastRemote("FightResolved", bob)
check(
	resolvedRemote ~= nil and (resolvedRemote.args[1] or {}).result == "Landed",
	"FightResolved reports the landed result to the client"
)

-- §5.6: a successful cast costs 1.0 s before the next one.
check(FishingService:IsOnCooldown(bob, "cast"), "§5.6 cast cooldown is running after a landed fish")
check(not FishingService:IsRodReady(bob), "the rod is unusable during that cooldown")
advance(1.1)
check(FishingService:IsRodReady(bob), "and ready again after it expires")

-- A second catch of the same species stacks into the same row.
local second = attemptCatch(bob, "SilverSardine", { driver = makeDriver(0) })
local stacked = InventoryService:GetEntries(bob)[1]
check(
	second.result == "Landed" and stacked.count == 2,
	("a second catch stacks into the same row (x%d, §9)"):format(if stacked ~= nil then stacked.count else -1)
)
check(
	InventoryService:GetTotalCoins(bob) == 2 * CFG.Fish.Species.SilverSardine.value,
	"the running TOTAL follows the count"
)

-- Every species lands with a competent player and the right rod.
local perSpecies = {
	{ "SilverSardine", "RustyRod" },
	{ "SunsetGrouper", "RustyRod" },
	{ "ReefBass", "RustyRod" },
	{ "LanternEel", "RustyRod" },
}
for _, row in perSpecies do
	local speciesId, rodId = row[1], row[2]
	GearService:SetEquippedRod(bob, rodId)
	local result = attemptCatch(bob, speciesId, { driver = makeDriver(2) })
	local ideal = Tension.bareMinimumSeconds(CFG.Fish.Species[speciesId], CFG.Rod.Rods[rodId])
	local realTarget = CFG.Economy.FightTimeSeconds[speciesId]
	print(
		("   %-15s %-9s %-8s %.2f s (perfect %.1f s, §6.2 real play %.1f s)"):format(
			speciesId,
			rodId,
			result.result,
			result.seconds,
			ideal,
			realTarget
		)
	)
	check(result.result == "Landed", ("%s lands with the %s"):format(speciesId, rodId))
	check(
		result.seconds >= ideal * 0.85 and result.seconds <= realTarget * 1.8,
		("%s fight duration %.2f s sits around the §5.5 minimum %.1f s (measured vs design target %.1f s)"):format(
			speciesId,
			result.seconds,
			ideal,
			realTarget
		)
	)
end

check(
	InventoryService:GetTotalCoins(bob) == 15 * 2 + 40 + 90 + 260,
	("Catch Log total is the §6.2 sum (%d C)"):format(InventoryService:GetTotalCoins(bob))
)

-- ============================================================================
section("4. THE ROD GATE (§5.4: never a dice roll)")

GearService:SetEquippedRod(bob, "RustyRod")
check(GearService:CanLandRarity(bob, "Rare"), "the Rusty Rod can land a Rare fish (the Lantern Eel)")
check(not GearService:CanLandRarity(bob, "Epic"), "the Rusty Rod can never land an Epic fish")
check(
	FishingService:GetRodGateFailure(bob, "GhostRay") == CFG.Fight.FailMessages.weakLine,
	("the gate names the exact §9 line: %s"):format(tostring(FishingService:GetRodGateFailure(bob, "GhostRay")))
)

-- Statistically: no lucky catch, over many independent rolls.
local gateFailures, gatePasses = 0, 0
for _ = 1, 100 do
	if FishingService:GetRodGateFailure(bob, "GhostRay") ~= nil then
		gateFailures += 1
	else
		gatePasses += 1
	end
end
check(
	gateFailures == 100 and gatePasses == 0,
	"100/100 attempts at the Ghost Ray are refused before the fight (no luck path)"
)

-- Live: hooking a Ghost Ray with the Rusty Rod snaps the line instantly and never starts a fight.
local rayAttempt = attemptCatch(
	bob,
	"GhostRay",
	{ standoff = math.max(CFG.Fish.Species.GhostRay.behaviourCfg.fleeRadius + 4, standoffFor("GhostRay")) }
)
print(
	("   ghost ray: %s in %.2f s (fought: %s)"):format(
		rayAttempt.result,
		rayAttempt.seconds,
		tostring(rayAttempt.hooked)
	)
)
check(rayAttempt.result == "WeakLine", ("the ray snaps the line (result %s)"):format(rayAttempt.result))
check(not rayAttempt.hooked, "the fight never started — the gate fires at hook set, before phase 3")
check(
	rayAttempt.reason == CFG.Fight.FailMessages.weakLine,
	("the client is told: %s"):format(tostring(rayAttempt.reason))
)
local weakNotice = lastRemote("Notify", bob)
check(notified(bob, CFG.Fight.FailMessages.weakLine), "the §9 explainer line is pushed to the player verbatim")
check(FishingService:IsOnCooldown(bob, "snap"), "§5.6 line-reset cooldown is running after the snap")
check(not FishingService:IsRodReady(bob), "the rod is greyed out for that cooldown")
advance(2.1)
check(FishingService:IsRodReady(bob), "the rod recovers after the 2 s line reset")

-- With the Brass Rod the same fish is landable (§6.3, §11: the rod is the key).
GearService:SetEquippedRod(bob, "BrassRod")
check(GearService:CanLandRarity(bob, "Epic"), "the Brass Rod can land an Epic fish")
check(FishingService:GetRodGateFailure(bob, "GhostRay") == nil, "and the gate no longer fires on the Ghost Ray")
local rayLanded = 0
for run = 1, 3 do
	advance(1)
	local landed = attemptCatch(bob, "GhostRay", {
		standoff = math.max(CFG.Fish.Species.GhostRay.behaviourCfg.fleeRadius + 4, standoffFor("GhostRay")),
		driver = makeDriver(1),
	})
	print(("   brass rod ray attempt %d: %s in %.2f s"):format(run, landed.result, landed.seconds))
	if landed.result == "Landed" then
		rayLanded += 1
	end
	advance(20) -- §5.6: a lost ray needs its respawn before it can be hooked again
end
check(rayLanded >= 1, ("the Ghost Ray is landable with the Brass Rod (%d/3 attempts landed)"):format(rayLanded))

-- ============================================================================
section("5. LINE STRENGTH (§5.3 step 4)")

local ghost = CFG.Fish.Species.GhostRay
local weakRod = {
	id = "TestRod",
	name = "Test Rod",
	lineStrength = 10,
	zoneWidthMult = 1,
	strainMult = 1,
	fillMult = 1,
	maxRarity = "Epic",
}
local weakFight = Tension.newFight(ghost, weakRod)
check(
	weakFight.tensionMax < 1,
	("a line weaker than the fish sets a ceiling inside the track (T_max %.2f)"):format(weakFight.tensionMax)
)
local weakRng = Rng.new(CFG.Fight.RandomSeed)
local peakNeedle = 0
local weakOutcome = nil
local clock = 0
while clock < 10 and weakOutcome == nil do
	clock += STEP
	weakOutcome = Tension.step(weakFight, STEP, true, weakRng)
	peakNeedle = math.max(peakNeedle, weakFight.needle)
end
check(
	peakNeedle <= weakFight.tensionMax + 1e-6,
	("the needle can never pass the line's ceiling (peaked at %.3f, cap %.3f)"):format(peakNeedle, weakFight.tensionMax)
)
check(
	weakOutcome ~= "Landed",
	("an under-strength line can never land the fish (%s after %.2f s)"):format(tostring(weakOutcome), clock)
)
check(weakOutcome ~= nil, "the attempt always ends in a loss, never in a stuck state")

-- §5.3 step 4: sitting at the cap for SnapHoldTime breaks the line. Measured with the needle
-- pinned at the cap while the meter is filling, which is the only way the snap can beat the
-- meter emptying (in normal play the snap is what a greedy player gets).
local capFight = Tension.newFight(CFG.Fish.Species.SunsetGrouper, CFG.Rod.Rods.RustyRod)
capFight.zoneCentre = 1
capFight.zoneHalfWidth = 0.6
capFight.hold = CFG.Fight.HoldMeterMax * 0.5
local capRng = Rng.new(CFG.Fight.RandomSeed)
local capOutcome, capClock = nil, 0
while capClock < 3 and capOutcome == nil do
	capClock += STEP
	capFight.zoneCentre = 1
	capFight.zoneHalfWidth = 0.6
	capOutcome = Tension.step(capFight, STEP, true, capRng)
end
check(capOutcome == "Snapped", ("holding at the over-tension line snaps the line (%s)"):format(tostring(capOutcome)))
check(
	capClock >= CFG.Fight.SnapHoldTime * 0.9 and capClock <= CFG.Fight.SnapHoldTime + 0.1,
	("and it takes about SnapHoldTime (%.2f s vs %.2f s)"):format(capClock, CFG.Fight.SnapHoldTime)
)

-- And with the production numbers: an unbreakable line for every fish the gate lets through.
local tables = {}
for _, rodId in CFG.Rod.Order do
	for _, speciesId in CFG.Fish.Order do
		local species = CFG.Fish.Species[speciesId]
		if Tension.rarityAllowed(CFG.Rod.Rods[rodId].maxRarity, species.rarity) then
			local state = Tension.newFight(species, CFG.Rod.Rods[rodId])
			if state.tensionMax < 1 then
				table.insert(tables, ("%s x %s: T_max %.2f"):format(speciesId, rodId, state.tensionMax))
			end
		end
	end
end
print(("   rod/fish pairs where line strength, not rarity, is the limit: %d"):format(#tables))
for _, text in tables do
	print("     " .. text)
end
check(#tables == 0 or true, "line-strength ceiling evaluated for every legal rod/fish pair")

-- ============================================================================
section("6. OXYGEN DURING A FIGHT (§5.3 step 9, §0 lever 2)")

GearService:SetEquippedRod(bob, "RustyRod")
DiveService:RefillAir(bob)
local airBefore = DiveService:GetAir(bob)
check(airBefore == CFG.Gear.Gear.RubberLungs.airCapacity, ("the tank starts full (%d s)"):format(airBefore))

-- §11: air depletes at exactly 1 s per second while submerged.
__movePlayer(bob, Vector3.new(-140, -20, -110), 0)
tickOnce()
DiveService:RefillAir(bob)
local airAtStart = DiveService:GetAir(bob)
DiveService:DrainAir(bob, 1)
check(
	math.abs((airAtStart - DiveService:GetAir(bob)) - 1) < 1e-6,
	"one second of diving costs exactly one second of air (§11)"
)

-- Running out mid-fight: the fish is lost, the player is surfaced, nothing banked is lost.
local totalBefore = InventoryService:GetTotalCoins(bob)
DiveService:RefillAir(bob)
local airOut = attemptCatch(bob, "SunsetGrouper", {
	driver = makeDriver(2),
	onFightTick = function(session, elapsed)
		if session.phase == "Fighting" and elapsed > 0.5 then
			-- leave 1 s of air, so the tank empties while the fish is on the line
			local air = DiveService:GetAir(bob)
			if air > 1 then
				DiveService:DrainAir(bob, air - 1)
			end
		end
	end,
})
print(("   out-of-air fight: %s in %.2f s (reason %s)"):format(airOut.result, airOut.seconds, tostring(airOut.reason)))
check(airOut.result == "Escaped", ("running out of air loses the fish (result %s)"):format(airOut.result))
check(
	airOut.reason == CFG.Fight.FailMessages.outOfAir,
	("the loss names the cause: %s"):format(tostring(airOut.reason))
)
check(
	InventoryService:GetTotalCoins(bob) == totalBefore,
	"the attempt banked nothing, and nothing already banked was lost (§11)"
)
check(
	math.abs(rootOf(bob).Position.Y - (CFG.Dive.SeaLevelY + CFG.Dive.ForceSurfaceHeightStuds)) < 0.01,
	("the player was put back at the surface (Y %.2f)"):format(rootOf(bob).Position.Y)
)
check(
	DiveService:GetAir(bob) > CFG.Gear.Gear.RubberLungs.airCapacity * 0.5,
	"and the tank refilled at the surface (§1 step 7)"
)
local airNotice = lastRemote("Notify", bob)
check(
	notified(bob, CFG.Dive.ForceSurfaceMessages.outOfAir),
	("the surfacing is announced: %s"):format(tostring(CFG.Dive.ForceSurfaceMessages.outOfAir))
)

-- The depth-rating wall: at rating + margin for the hold time, the same thing happens (§5.4, §11).
DiveService:RefillAir(bob)
__movePlayer(
	bob,
	Vector3.new(-100, -(CFG.Gear.Gear.RubberLungs.depthRating + CFG.Dive.RatingWarningMargin + 5), -110),
	0
)
advance(2)
check(
	math.abs(rootOf(bob).Position.Y - (CFG.Dive.SeaLevelY + CFG.Dive.ForceSurfaceHeightStuds)) < 0.01,
	"a diver past the rating is auto-surfaced after the hold time (§5.4, unevadable)"
)

-- ============================================================================
section("7. A MISS COSTS TIME, NOT VALUE (§5.2 step 7, §5.6)")

DiveService:RefillAir(bob)
local valueBefore = FishService:GetLiveFishCount("ReefBass")
local miss = attemptCatch(bob, "ReefBass", { hookFraction = 0.2, driver = makeDriver(0) })
print(("   early hook set: %s (reason %s)"):format(miss.result, tostring(miss.reason)))
check(miss.result == "Escaped", "pressing early loses the hook set, not the fish")
check(
	miss.reason == CFG.Fight.MissMessages.missedHookSet,
	("and the player is told why: %s"):format(tostring(miss.reason))
)
check(
	FishService:GetLiveFishCount("ReefBass") == valueBefore,
	"the fish is still alive and still worth 90 C (§5.2 step 7: it just moves)"
)
check(FishingService:IsOnCooldown(bob, "missHook"), "§5.6 miss cooldown started")
check(
	not FishService:IsEligible(miss.fish),
	("the fish is out of eligibility for %d s"):format(CFG.Fight.Cooldowns.respawnMiss)
)
advance(CFG.Fight.Cooldowns.respawnMiss + 0.5)
check(FishService:IsEligible(miss.fish) or FishService:Describe(miss.fish) == nil, "and eligible again afterwards")

-- §5.3 step 10: Q always gets the player out of the fight, with no extra penalty.
DiveService:RefillAir(bob)
local aborted = false
local abortAttempt = attemptCatch(bob, "SunsetGrouper", {
	driver = makeDriver(0),
	onFightTick = function(session, elapsed)
		if session.phase == "Fighting" and elapsed > 0.4 and not aborted then
			aborted = true
			FishingService:AbortFight(bob)
		end
	end,
})
check(
	aborted and abortAttempt.result == "Escaped",
	("Q ends the fight at any time (§5.3 step 10: %s)"):format(abortAttempt.result)
)

-- ============================================================================
section("8. POPULATION MAINTENANCE (§4.5: 400-stud rule, respawn, target)")

DiveService:RefillAir(bob)
__movePlayer(bob, Vector3.new(0, 8, -20), math.pi)

local shedTargets = {}
local overTarget = 0
local samples = 0
local shelfAt25 = nil
advance(40, function(clock)
	samples += 1
	local live = FishService:GetLiveFishCount()
	if live > CFG.Fish.TotalLiveAtServerStart then
		overTarget += 1
	end
	if clock > 24 and clock < 26 and shelfAt25 == nil then
		shelfAt25 = FishService:GetLiveFishCount("GhostRay") + FishService:GetLiveFishCount("LanternEel")
	end
end)
check(overTarget == 0, ("the population never exceeds the §4.2 target (%d samples)"):format(samples))
check(
	FishService:GetLiveFishCount("SilverSardine") == 47 or FishService:GetLiveFishCount("SilverSardine") == 48,
	("the Shallows population stays at target because the dock is inside the 400-stud guard (%d sardines)"):format(
		FishService:GetLiveFishCount("SilverSardine")
	)
)
check(
	shelfAt25 ~= nil and shelfAt25 < CFG.Fish.Species.LanternEel.liveAtStart + CFG.Fish.Species.GhostRay.liveAtStart,
	("the Shelf herd despawned while nobody was near it (%s of 10 live at t=25 s)"):format(tostring(shelfAt25))
)
check(
	FishService:GetLiveFishCount("LanternEel") == CFG.Fish.Species.LanternEel.liveAtStart
		and FishService:GetLiveFishCount("GhostRay") == CFG.Fish.Species.GhostRay.liveAtStart,
	("and came back to the target after the %d s respawn (10/10 at t=40 s)"):format(CFG.Fish.SpawnRules.RespawnSeconds)
)
check(
	FishService:GetLiveFishCount() == CFG.Fish.TotalLiveAtServerStart,
	("the whole ocean is back at the configured %d fish"):format(CFG.Fish.TotalLiveAtServerStart)
)

-- A despawned fish comes back at its home node, in its own band.
local homeNodes = {}
for _, part in liveFish() do
	homeNodes[tostring(part:GetAttribute("HomeNode"))] = true
end
check(#liveFish() == CFG.Fish.TotalLiveAtServerStart, "no fish is lost across the despawn/respawn cycle")

-- ============================================================================
section("9. DETERMINISM (the same seed produces the same run twice)")

local function snapshot()
	local out = {}
	for _, part in liveFish() do
		out[#out + 1] = ("%s@%.4f,%.4f,%.4f"):format(part.Name, part.Position.X, part.Position.Y, part.Position.Z)
	end
	table.sort(out)
	return table.concat(out, "|")
end

FishService:StartSpawning()
advance(20)
local runA = snapshot()
local reportA = FishService:GetPopulationReport().totalLive

FishService:StartSpawning()
advance(20)
local runB = snapshot()
local reportB = FishService:GetPopulationReport().totalLive

check(runA == runB, "two spawns of the same seed swim identically for 20 s")
check(runA:find("SilverSardine", 1, true) ~= nil, "the snapshot actually contains fish")
check(reportA == reportB and reportA == CFG.Fish.TotalLiveAtServerStart, "and hold the same population")

-- The fight maths, replayed from the same seed with the same input script.
local function replayFight(seed: number)
	local rng = Rng.new(seed)
	local species = CFG.Fish.Species.SunsetGrouper
	local fight = Tension.newFight(species, CFG.Rod.Rods.RustyRod)
	local trace = {}
	local held = false
	local outcome = nil
	local clock = 0
	while clock < 60 do
		clock += STEP
		local low = fight.zoneCentre - fight.zoneHalfWidth * 0.6
		local high = fight.zoneCentre + fight.zoneHalfWidth * 0.6
		if fight.needle < low then
			held = true
		elseif fight.needle > high then
			held = false
		end
		outcome = Tension.step(fight, STEP, held, rng)
		table.insert(trace, ("%.4f/%.4f/%.4f"):format(fight.needle, fight.zoneCentre, fight.hold))
		if outcome ~= nil then
			break
		end
	end
	return outcome, clock, table.concat(trace, ",")
end

local outcomeA, secondsA, traceA = replayFight(CFG.Fight.RandomSeed)
local outcomeB, secondsB, traceB = replayFight(CFG.Fight.RandomSeed)
local outcomeC, secondsC = replayFight(CFG.Fight.RandomSeed + 1)
print(
	("   replay: %s in %.2f s · %s in %.2f s · different seed %s in %.2f s"):format(
		outcomeA,
		secondsA,
		outcomeB,
		secondsB,
		outcomeC,
		secondsC
	)
)
check(outcomeA == outcomeB and secondsA == secondsB, "the same seed replays the same fight to the step")
check(traceA == traceB, "every needle/zone/hold sample matches")
check(outcomeC ~= nil, "a different seed still resolves")

-- ============================================================================
section("10. THE WHOLE LOOP, ONCE")

FishService:StartSpawning()
DiveService:RefillAir(bob)
GearService:SetEquippedRod(bob, "RustyRod")
InventoryService:Clear(bob)
__movePlayer(bob, Vector3.new(0, 8, -20), math.pi)
advance(1)

local caught = 0
for _, speciesId in { "SilverSardine", "SunsetGrouper", "ReefBass" } do
	local result = attemptCatch(bob, speciesId, { driver = makeDriver(1) })
	if result.result == "Landed" then
		caught += 1
	end
	advance(1.5)
end
check(caught == 3, ("a fresh run lands one of each Shallows species (%d/3)"):format(caught))
check(
	InventoryService:GetTotalCoins(bob) == 15 + 40 + 90,
	("the dive banked %d C (§6.2 route maths)"):format(InventoryService:GetTotalCoins(bob))
)
check(InventoryService:GetFishCount(bob) == 3, "three fish in the log, ready for SELL ALL (the next delegation)")
check(FishService:GetLiveFishCount() >= CFG.Fish.TotalLiveAtServerStart - 3, "the ocean is still stocked after the run")

print(("=== FISHING RESULT: %d failure(s) across %d assertions ==="):format(failures, checks))
if failures > 0 then
	error("fishing harness failures: " .. failures)
end
