--!strict
--[[
    FishingService — Appendix B: "Cast -> hook set -> tension fight state machine (§5), rod
    gating (§5.4), cooldowns (§5.6)".
    Source: GDD §5.1 (cast), §5.2 (hook set), §5.3 (the Tension mini-game, server-authoritative
            at 30 Hz), §5.4 (the unbreakable rod wall), §5.5 (per-species tuning), §5.6 (cooldowns),
            §9 (failure explainer is never optional), §1 step 6 (a landed fish is banked instantly).

    Every tunable comes from FishConfig.mini (per species) and FightConfig (frame rules); the
    arithmetic itself is Modules/Tension, which is pure and therefore testable headlessly.

    The three phases, and who owns what:
        Casting   the line goes out for CastTweenTime; the fish is Hooked_Pending and does not flee
                  (§5.1 step 3); walking more than CastAbortDistance away cancels it (§5.1 step 4).
        HookSet   the ring shrinks over the species' hook window; the §5.4 rod gate fires here,
                  before the fight, exactly once and instantly.
        Fighting  Tension.step at FightTickHz. The player holds (E / mouse / R2) or releases; the
                  input is a *state*, so a late or dropped packet costs the player nothing but the
                  time until the next change — the latency tolerance §5.3 asks for. Q aborts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local FightConfig = require(ReplicatedStorage.DeepTide.Config.FightConfig)
local FishConfig = require(ReplicatedStorage.DeepTide.Config.FishConfig)
local Rng = require(ReplicatedStorage.DeepTide.Modules.Rng)
local Tension = require(ReplicatedStorage.DeepTide.Modules.Tension)

local FishingService = Knit.CreateService({
	Name = "FishingService",
})

-- One in-flight cast or fight per player (§5).
export type FightSession = {
	player: Player,
	fish: BasePart,
	phase: string, -- "Casting" | "HookSet" | "Fighting" (§5.1-§5.3)
	speciesId: string,
	species: any,
	rodId: string,
	fight: Tension.FightState?,
	phaseElapsed: number,
	castOrigin: Vector3,
	hookWindow: number,
	held: boolean,
}

-- §5.6: cooldown kinds, in the order they are reported.
local COOLDOWN_KINDS = { "cast", "missHook", "escape", "snap" }

-- A cast is refused while the rod is still recovering from any of these (§5.6: the snap
-- cooldown greys the rod and shows a countdown, so it must block a new cast).
local ROD_BLOCKING = { "cast", "missHook", "escape", "snap" }

local sessions: { [Player]: FightSession } = {}
local cooldowns: { [Player]: { [string]: number } } = {}
local rng = Rng.new(FightConfig.RandomSeed)

local services: { [string]: any } = {}

local function svc(name: string): any
	local found = services[name]
	if found == nil then
		found = Knit.GetService(name)
		services[name] = found
	end
	return found
end

local function fire(remoteName: string, player: Player, ...)
	local remote = Remotes.get(remoteName)
	remote:FireClient(player, ...)
end

--- §4.3's flight speeds, reused so a lost fight makes the fish run at its own species' speed.
local function speciesFleeSpeed(species: any): number
	local cfg = species.behaviourCfg
	return cfg.fleeSpeed or cfg.lungeSpeed or cfg.speed or 10
end

-- Public server API -----------------------------------------------------------

--- §5.1 step 2: the client's chosen target, or nil to let the server pick the nearest eligible
--- fish in front of the player. Returns false when the request is illegal (out of range,
--- ineligible, on cooldown, already fighting, no rod) — never a silent no-op.
function FishingService:RequestCast(player: Player, fish: BasePart?): boolean
	if sessions[player] ~= nil then
		return false
	end
	if not self:IsRodReady(player) then
		return false
	end

	local gear = svc("GearService")
	local fishService = svc("FishService")
	local target = fish
	if target == nil then
		target = fishService:GetNearestEligibleFish(player, FightConfig.CastRange, true)
	end
	if target == nil then
		return false
	end
	if not fishService:IsEligible(target) then
		return false
	end

	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil then
		return false
	end
	local origin = (root :: BasePart).Position

	local info = fishService:Describe(target)
	if info == nil then
		return false
	end

	-- §5.1 steps 1-2: within CastRange and roughly in front of the player.
	local ok = Tension.castTargetCheck(origin, (root :: BasePart).CFrame.LookVector, info.position)
	if not ok then
		return false
	end

	local rod = gear:GetRodStats(player)
	local species = FishConfig.Species[info.speciesId]

	sessions[player] = {
		player = player,
		fish = target,
		phase = "Casting",
		speciesId = info.speciesId,
		species = species,
		rodId = rod.id,
		fight = nil,
		phaseElapsed = 0,
		castOrigin = origin,
		hookWindow = species.mini.hookWindow,
		held = false,
	}

	-- §5.1 step 3: hooked but not yet fought — it may not flee before the player has reacted.
	fishService:LockForFight(target, "Hooked_Pending")
	self:_PushState(player)
	return true
end

--- §5.2 step 6/7: the second E press. A press inside the window wins; an early press and a press
--- inside the +HookSetGraceSeconds tail are both misses (§5.2 step 7: fish flees 3 s and is
--- ineligible for 8 s — no other penalty).
function FishingService:RequestHookSet(player: Player): boolean
	local session = sessions[player]
	if session == nil or session.phase ~= "HookSet" then
		return false
	end

	local result = Tension.hookSetResult(session.phaseElapsed, session.hookWindow)
	if result == "Expired" then
		-- the window is already over; the tick will retire it
		return false
	end

	if result ~= "Hit" then
		self:_MissHookSet(player, session)
		return false
	end

	-- §5.4: the rod gate fires here, before the fight, and it is absolute.
	local gate = self:GetRodGateFailure(player, session.speciesId)
	if gate ~= nil then
		self:ResolveFight(player, "WeakLine", gate)
		return false
	end

	session.phase = "Fighting"
	session.phaseElapsed = 0
	local rod = svc("GearService"):GetRodStats(player)
	session.fight = Tension.newFight(session.species, rod)
	svc("FishService"):SetState(session.fish, "Fighting")
	self:_PushState(player)
	return true
end

--- §5.4: rarity above the rod's MaxRarity snaps the line instantly with
--- FightConfig.FailMessages.weakLine. Returns nil when the rod is fine.
function FishingService:GetRodGateFailure(player: Player, speciesId: string): string?
	local species = FishConfig.Species[speciesId]
	if species == nil then
		return nil
	end
	local rod = svc("GearService"):GetRodStats(player)
	if not Tension.rarityAllowed(rod.maxRarity, species.rarity) then
		return FightConfig.FailMessages.weakLine
	end
	return nil
end

--- §5.3: hold/release input during the fight; the input is a state, not an event.
function FishingService:SetFightInput(player: Player, held: boolean)
	local session = sessions[player]
	if session ~= nil and session.phase == "Fighting" then
		session.held = held
	end
end

--- §5.3 step 9 / §0 lever 2: the tank ran out mid-fight. The fish is lost, the player is put back
--- at the surface by DiveService, and nothing that was already banked is touched (§11).
function FishingService:LoseToOutOfAir(player: Player)
	if sessions[player] ~= nil then
		self:ResolveFight(player, "Escaped", FightConfig.FailMessages.outOfAir)
	end
end

--- §5.3 step 10: aborting always works and carries no extra penalty.
function FishingService:AbortFight(player: Player)
	if sessions[player] ~= nil then
		self:ResolveFight(player, "Escaped")
	end
end

function FishingService:GetSession(player: Player): FightSession?
	return sessions[player]
end

--- §5.6: is this cooldown still running? Kinds are FightConfig.Cooldowns keys.
function FishingService:GetCooldown(player: Player, kind: string): number
	local table_ = cooldowns[player]
	if table_ == nil then
		return 0
	end
	return table_[kind] or 0
end

function FishingService:IsOnCooldown(player: Player, kind: string): boolean
	return self:GetCooldown(player, kind) > 0
end

--- Can a new cast start at all? (§5.6: the rod is unusable for Cooldowns.snap after a snap.)
function FishingService:IsRodReady(player: Player): boolean
	for _, kind in ROD_BLOCKING do
		if self:IsOnCooldown(player, kind) then
			return false
		end
	end
	return true
end

function FishingService:SetCooldown(player: Player, kind: string)
	local total = FightConfig.Cooldowns[kind]
	if total == nil then
		return
	end
	local table_ = cooldowns[player]
	if table_ == nil then
		table_ = {}
		cooldowns[player] = table_
	end
	table_[kind] = total
end

--- Ends the fight and applies the §5.6 consequences. `result` uses Types.FightResult:
--- Landed / Escaped / Snapped / WeakLine.
function FishingService:ResolveFight(player: Player, result: Types.FightResult, reason: string?): Types.FightResult
	local session = sessions[player]
	if session == nil then
		return result
	end
	sessions[player] = nil

	local fishService = svc("FishService")
	local species = session.species
	local note = reason

	if result == "Landed" then
		-- §1 step 6: the fish enters the Catch Log instantly; no Coins are added yet (§6.2).
		svc("InventoryService"):AddCatch(player, session.speciesId)
		fishService:MarkCaught(session.fish)
		self:SetCooldown(player, "cast")
		note = FightConfig.CatchMessageFormat:format(species.name, species.value)
	elseif result == "Escaped" then
		fishService:StartFlee(
			session.fish,
			speciesFleeSpeed(species),
			FightConfig.EscapeFleeSeconds,
			FightConfig.Cooldowns.respawnEscape
		)
		self:SetCooldown(player, "escape")
		note = note or FightConfig.FailMessages.escape
	else
		-- "Snapped" (over-tension) and "WeakLine" (§5.4) are the same physical event: the line
		-- broke, the fish runs, and it comes back somewhere else in its band (§5.3 step 8, §5.6).
		fishService:StartFlee(
			session.fish,
			speciesFleeSpeed(species),
			FightConfig.SnapFleeSeconds,
			FightConfig.Cooldowns.respawnSnap,
			true
		)
		self:SetCooldown(player, "snap")
		note = note or FightConfig.FailMessages.snap
	end

	fire("FightResolved", player, { result = result, speciesId = session.speciesId, reason = note })
	if result ~= "Landed" and note ~= nil then
		-- §9: never a loss without a reason and a next step.
		fire("Notify", player, { text = note, seconds = FightConfig.FailureMessageSeconds })
	end
	return result
end

--- §5.2 step 7: a missed hook set. The fish flees as if startled for 3 s and is out of
--- eligibility for Cooldowns.respawnMiss, but keeps its value and does not respawn.
function FishingService:_MissHookSet(player: Player, session: FightSession)
	sessions[player] = nil
	local fishService = svc("FishService")
	fishService:SetState(session.fish, "Idle")
	fishService:StartFlee(session.fish, speciesFleeSpeed(session.species), FightConfig.MissFleeSeconds)
	fishService:SetIneligible(session.fish, FightConfig.Cooldowns.respawnMiss)
	self:SetCooldown(player, "missHook")
	fire("FightResolved", player, {
		result = "Escaped",
		speciesId = session.speciesId,
		reason = FightConfig.MissMessages.missedHookSet,
	})
	fire(
		"Notify",
		player,
		{ text = FightConfig.MissMessages.missedHookSet, seconds = FightConfig.FailureMessageSeconds }
	)
end

--- The `FightStateChanged` payload (§5.3, §9): everything the track needs, including the
--- species name and value so the fight has a known stake.
function FishingService:_PushState(player: Player)
	local session = sessions[player]
	if session == nil then
		return
	end
	local payload: { [string]: any } = {
		phase = session.phase,
		speciesId = session.speciesId,
		name = session.species.name,
		value = session.species.value,
		rarity = session.species.rarity,
		rodId = session.rodId,
		ring = Tension.hookSetFraction(session.phaseElapsed, session.hookWindow),
	}
	if session.fight ~= nil then
		local view = Tension.viewOf(session.fight, session.speciesId)
		for key, value in view do
			payload[key] = value
		end
		payload.ring = nil
	end
	fire("FightStateChanged", player, payload)
end

--- §5.3: one tick of the tension maths, at FightTickHz, replicated to the fighting client.
--- Also the per-tick oxygen check (§5.3 step 9): the tank drains through all three phases, and
--- running dry loses the fish — the tank is a clock on the reward, never a punishment timer.
function FishingService:_TickFight(session: FightSession, dt: number)
	local player = session.player
	session.phaseElapsed += dt

	if session.phase == "Casting" then
		-- §5.1 step 4: moving more than CastAbortDistance from where the cast started aborts it.
		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		if
			root == nil
			or ((root :: BasePart).Position - session.castOrigin).Magnitude > FightConfig.CastAbortDistance
		then
			sessions[player] = nil
			local fishService = svc("FishService")
			fishService:SetState(session.fish, "Idle")
			fishService:StartFlee(session.fish, speciesFleeSpeed(session.species), FightConfig.MissFleeSeconds)
			self:SetCooldown(player, "missHook")
			fire("FightResolved", player, {
				result = "Escaped",
				speciesId = session.speciesId,
				reason = FightConfig.MissMessages.castAborted,
			})
			return
		end
		if session.phaseElapsed >= FightConfig.CastTweenTime then
			session.phase = "HookSet"
			session.phaseElapsed = 0
		end
		self:_PushState(player)
		return
	end

	if session.phase == "HookSet" then
		if Tension.hookSetResult(session.phaseElapsed, session.hookWindow) == "Expired" then
			self:_MissHookSet(player, session)
			return
		end
		self:_PushState(player)
		return
	end

	-- Fighting
	local dive = svc("DiveService")
	if dive:GetAir(player) <= 0 then
		self:ResolveFight(player, "Escaped", FightConfig.FailMessages.outOfAir)
		return
	end

	local fight = session.fight
	if fight == nil then
		return
	end
	local outcome = Tension.step(fight, dt, session.held, rng)
	if outcome ~= nil then
		self:ResolveFight(player, outcome)
		return
	end
	self:_PushState(player)
end

--- One service step: cooldowns down, then every live session (cast, hook set or fight) forward.
--- Called from Heartbeat at FightTickHz; the harness calls it with a fixed dt.
function FishingService:_Step(dt: number)
	for player, table_ in cooldowns do
		for _, kind in COOLDOWN_KINDS do
			local remaining = table_[kind]
			if remaining ~= nil and remaining > 0 then
				table_[kind] = math.max(0, remaining - dt)
			end
		end
		if sessions[player] == nil then
			-- keep the tables small: a player with nothing running and nothing on cooldown
			-- drops their entry entirely
			local any = false
			for _, kind in COOLDOWN_KINDS do
				if (table_[kind] or 0) > 0 then
					any = true
					break
				end
			end
			if not any then
				cooldowns[player] = nil
			end
		end
	end

	for player, session in sessions do
		local ok, err = pcall(function()
			FishingService:_TickFight(session, dt)
		end)
		if not ok then
			warn(("[Deep Tide] FishingService: fight tick failed for %s: %s"):format(player.Name, tostring(err)))
			sessions[player] = nil
		end
	end
end

--- Per-player teardown (§PlayerService's release sweep): a player who leaves mid-fight releases
--- their fish instead of leaving it Hooked forever.
function FishingService:ReleasePlayer(player: Player)
	local session = sessions[player]
	if session ~= nil then
		sessions[player] = nil
		local fishService = svc("FishService")
		if fishService:Describe(session.fish) ~= nil then
			fishService:SetState(session.fish, "Idle")
		end
	end
	cooldowns[player] = nil
end

-- Knit lifecycle --------------------------------------------------------------

function FishingService:KnitInit()
	Remotes.get("CastRequest").OnServerEvent:Connect(function(player: Player, target: BasePart?)
		self:RequestCast(player, target)
	end)

	Remotes.get("HookSetRequest").OnServerEvent:Connect(function(player: Player)
		self:RequestHookSet(player)
	end)

	Remotes.get("FightInput").OnServerEvent:Connect(function(player: Player, action: string)
		if action == "hold" then
			self:SetFightInput(player, true)
		elseif action == "release" then
			self:SetFightInput(player, false)
		elseif action == "abort" then
			self:AbortFight(player)
		end
	end)
end

function FishingService:KnitStart()
	local accumulator = 0
	local tickSeconds = 1 / FightConfig.FightTickHz

	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		local steps = 0
		while accumulator >= tickSeconds and steps < 5 do
			accumulator -= tickSeconds
			steps += 1
			local ok, err = pcall(function()
				FishingService:_Step(tickSeconds)
			end)
			if not ok then
				warn("[Deep Tide] FishingService step failed: " .. tostring(err))
			end
		end
	end)
end

return FishingService
