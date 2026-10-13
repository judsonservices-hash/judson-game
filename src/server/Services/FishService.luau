--!strict
--[[
	FishService — Appendix B: "Owns fish spawning, the 20 Hz movement loop, behaviour state
	machines (§4.3), despawn/respawn timers".
	Source: GDD §4 (fish are single primitives with Attributes), §4.3 (the five behaviour
	        rules), §4.5 (spawn/despawn/respawn rules), §4.6 (fixed coordinates),
	        §11 (48/10/6/7/3 = 79 live at server start; no Shelf fish visible from the dock).

	Every fish is a non-collidable, unanchored Part parented to Workspace.DeepTide.Fish and
	moved by the server at FishConfig.SpawnRules.MovementHz; clients interpolate.
	Coordinates come from SpawnConfig; timings from FishConfig — never from this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local FishConfig = require(ReplicatedStorage.DeepTide.Config.FishConfig)
local SpawnConfig = require(ReplicatedStorage.DeepTide.Config.SpawnConfig)

local FishService = Knit.CreateService {
	Name = "FishService",
}

-- Attributes every fish Part carries (§4): Species, Rarity, Value, State, HomeNode.

-- Public server API -----------------------------------------------------------

--- Spawns every species at its §4.6 coordinates: 79 fish at server start (§11).
function FishService:StartSpawning()
	-- TODO(§4.5/§4.6): walk FishConfig.Order, and for each species build from SpawnConfig:
	--   School -> one anchor per entry, perSchool members around it
	--   Node   -> one fish per node
	--   Den    -> one eel per den, opening facing -Z
	-- Parent to Workspace.DeepTide.Fish and stamp the five attributes.
end

function FishService:StopSpawning()
	-- TODO: stop the loop and clear Workspace.DeepTide.Fish.
end

--- Every live fish Part.
function FishService:GetAllFish(): { BasePart }
	-- TODO: return the tracked fish, not Workspace children.
	return {}
end

--- Live count, optionally for one species (§11 verifies 48/10/6/7/3).
function FishService:GetLiveFishCount(speciesId: string?): number
	return 0
end

--- §5.1: the fish the player is allowed to cast at — within FightConfig.CastRange and
--- FightConfig.CastFacingDot of the camera, not fleeing, and eligible (§5.2 step 7 / §5.6).
function FishService:GetNearestEligibleFish(player: Player, maxRange: number, requireFacing: boolean): BasePart?
	-- TODO(§5.1 steps 1-2): nearest eligible fish to the player.
	return nil
end

--- §5.2 step 7, §5.6: a fish that was missed, escaped or snapped is ineligible for a while.
function FishService:IsEligible(fish: BasePart): boolean
	return true
end

--- Drives the behaviour state machine for one fish (§4.3). Called from the 20 Hz loop.
function FishService:SetState(fish: BasePart, state: string) end

--- A landed fish: remove it and respawn its home node after FishConfig.SpawnRules.RespawnSeconds.
function FishService:MarkCaught(fish: BasePart) end

--- §4.3: the shared flight helper — `speed` and `seconds` come from the species'
--- behaviourCfg (fleeSpeed / fleeTime, or lungeSpeed / lungeTime for the eel).
function FishService:StartFlee(fish: BasePart, speed: number, seconds: number) end

--- §4.5 respawn timers: 15 s after a catch or despawn, and the per-outcome waits in
--- FightConfig.Cooldowns (respawnMiss / respawnSnap / respawnEscape) after a lost fight.
function FishService:RespawnAfter(fish: BasePart, delaySeconds: number) end

-- Knit lifecycle --------------------------------------------------------------

function FishService:KnitInit() end

function FishService:KnitStart()
	-- TODO(§4.3): start the movement loop at FishConfig.SpawnRules.MovementHz and the
	-- despawn guard from FishConfig.SpawnRules (400 studs / 20 s from any player).
	-- FishConfig.SpawnRules.NeverShallowerThanStuds keeps Shelf fish out of the Shallows (§4.5).
end

return FishService
