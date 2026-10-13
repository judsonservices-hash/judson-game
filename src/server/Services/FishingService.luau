--!strict
--[[
	FishingService — Appendix B: "Cast -> hook set -> tension fight state machine (§5), rod
	gating (§5.4), cooldowns (§5.6)".
	Source: GDD §5.1 (cast), §5.2 (hook set), §5.3 (the Tension mini-game, server-authoritative
	        at 30 Hz), §5.4 (the unbreakable rod wall), §5.5 (per-species tuning), §5.6 (cooldowns),
	        §9 (failure explainer is never optional).

	Every tunable below comes from FishConfig.mini (per species) and FightConfig (frame rules).
	This skeleton owns the signatures and the remote wiring only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local FightConfig = require(ReplicatedStorage.DeepTide.Config.FightConfig)

local FishingService = Knit.CreateService {
	Name = "FishingService",
}

-- One in-flight cast or fight per player (§5).
export type FightSession = {
	player: Player,
	fish: BasePart,
	phase: string, -- "Casting" | "HookSet" | "Fighting" (§5.1-§5.3)
	speciesId: string,
	needle: number, -- T, starts at FightConfig.NeedleStart
	zoneCentre: number, -- S
	zoneHalfWidth: number, -- W, species value x RodConfig zoneWidthMult
	hold: number, -- H in [0, FightConfig.HoldMeterMax]
	tensionMax: number, -- T_max = min(1, rod.lineStrength / species.requiredTension)
	fillRate: number,
	strainMult: number,
	overTensionSeconds: number,
}

-- Public server API -----------------------------------------------------------

--- §5.1: begin a cast at the fish the client chose. Returns false when the request is
--- illegal (out of range, ineligible, on cooldown, already fighting) — never a silent no-op.
function FishingService:RequestCast(player: Player, fish: BasePart): boolean
	-- TODO(§5.1): validate range/facing via FishService:GetNearestEligibleFish, set
	-- FishService state to the pending-hook state, tween the line over CastTweenTime,
	-- abort past CastAbortDistance.
	return false
end

--- §5.2: the second E press, inside the species' hook-set window. Failing it is the
--- `missHook` cooldown plus an 8 s eligibility wait — no other penalty (§5.2 step 7).
function FishingService:RequestHookSet(player: Player): boolean
	-- TODO(§5.2): compare the ring position against FightConfig.HookSetZoneMin with
	-- FightConfig.HookSetGraceSeconds of grace; then apply the §5.4 rod gate BEFORE the fight.
	return false
end

--- §5.4: rarity above the rod's MaxRarity snaps the line instantly with
--- FightConfig.FailMessages.weakLine. Returns nil when the rod is fine.
function FishingService:GetRodGateFailure(player: Player, speciesId: string): string?
	-- TODO(§5.4): GearService:CanLandRarity(player, rarity) -> FightConfig.FailMessages.weakLine.
	return nil
end

--- §5.3: hold/release input during the fight; `Q` (FightConfig.Keys.Abort) aborts.
function FishingService:SetFightInput(player: Player, held: boolean) end

--- §5.3 step 10: aborting always works and carries no extra penalty.
function FishingService:AbortFight(player: Player) end

function FishingService:GetSession(player: Player): FightSession?
	-- TODO: return the in-flight session, or nil.
	return nil
end

function FishingService:IsOnCooldown(player: Player, kind: string): boolean
	-- TODO(§5.6): FightConfig.Cooldowns keys — cast, missHook, escape, snap.
	return false
end

--- Ends the fight and applies the §5.6 consequences. `result` uses Types.FightResult:
--- Landed / Escaped / Snapped / WeakLine.
function FishingService:ResolveFight(player: Player, result: Types.FightResult): Types.FightResult
	-- TODO(§5.3, §5.6): Landed -> InventoryService:AddCatch (§1 step 6);
	-- Escaped/Snapped/WeakLine -> FishService:RespawnAfter with the matching respawn cooldown,
	-- set the player cooldown, and fire Remotes.FightResolved + Remotes.Notify with the
	-- exact FightConfig.FailMessages line (§9: never a loss without a reason).
	return result
end

--- §5.3: one tick of the tension maths, at 30 Hz, replicated to the fighting client.
function FishingService:_TickFight(session: FightSession, dt: number) end

-- Knit lifecycle --------------------------------------------------------------

function FishingService:KnitInit()
	-- TODO(§5.1/§5.2/§5.3): bind the three client remotes —
	-- Remotes.CastRequest -> RequestCast, Remotes.HookSetRequest -> RequestHookSet,
	-- Remotes.FightInput -> SetFightInput / AbortFight.
end

function FishingService:KnitStart()
	-- TODO(§5.3): start the 30 Hz fight loop; push FightStateChanged per tick and
	-- drain air through DiveService:DrainAir (§5.3 step 9).
end

return FishingService
