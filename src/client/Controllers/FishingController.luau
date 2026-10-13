--!strict
--[[
	FishingController — GDD §5.1 (cast and its [E] CAST prompt), §5.2 (hook set), §5.3 (hold /
	release / abort input), §5.6 (cooldowns shown to the player), §9 (the in-fight prompt shows
	the same key as the cast prompt, plus the species name and rarity colour).

	Owns: local input and the client half of the Tension mini-game. The maths is
	server-authoritative at 30 Hz — this controller sends input and mirrors the state the
	server pushes. HudController draws the track from GetFightView().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local FightConfig = require(ReplicatedStorage.DeepTide.Config.FightConfig)
local RarityConfig = require(ReplicatedStorage.DeepTide.Config.RarityConfig)
local FishConfig = require(ReplicatedStorage.DeepTide.Config.FishConfig)

local FishingController = Knit.CreateController {
	Name = "FishingController",
}

-- Mirrors the server's FightStateChanged payload (§5.3): needle T, zone centre S, zone
-- half-width W, hold meter H, over-tension ceiling.
export type FightView = {
	needle: number,
	zoneCentre: number,
	zoneHalfWidth: number,
	hold: number,
	tensionMax: number,
	speciesId: string,
}

local remotes: { [string]: RemoteEvent } = {}
local fightView: FightView? = nil

-- Public API ------------------------------------------------------------------

--- §5.1 step 2: ask the server to cast at the fish the player is aiming at.
--- The server validates range, facing and eligibility — this is a request, not a command.
function FishingController:RequestCast(target: BasePart?): boolean
	local remote = remotes.CastRequest
	if remote == nil then
		return false
	end
	-- TODO(§5.1 step 1): pass the target the [E] CAST prompt is anchored to.
	remote:FireServer(target)
	return true
end

--- §5.2 step 6: the second press, inside the species' hook-set window.
function FishingController:RequestHookSet(): boolean
	local remote = remotes.HookSetRequest
	if remote == nil then
		return false
	end
	remote:FireServer()
	return true
end

--- §5.3: hold (E, left mouse or R2) to pull, release to slack. One button, nothing else.
function FishingController:SetFightInput(held: boolean)
	local remote = remotes.FightInput
	if remote == nil then
		return
	end
	remote:FireServer(if held then "hold" else "release")
end

--- §5.3 step 10: abort at any time — a player must never feel trapped in the UI minigame.
function FishingController:AbortFight()
	local remote = remotes.FightInput
	if remote == nil then
		return
	end
	remote:FireServer("abort")
end

--- Is a cast or fight in flight? (§5.6: drives the greyed rod and the countdown.)
function FishingController:IsBusy(): boolean
	return fightView ~= nil
end

--- The live fight view for the HUD track (§5.3), or nil when not fighting.
function FishingController:GetFightView(): FightView?
	return fightView
end

--- §5.6: how long the current cooldown still has to run, for the HUD countdown.
function FishingController:GetCooldownRemaining(kind: string): number
	local total = FightConfig.Cooldowns[kind]
	if total == nil then
		return 0
	end
	-- TODO(§5.6): subtract the elapsed time since the server reported the cooldown started;
	-- the snap cooldown (FightConfig.Cooldowns.snap) greys the rod and shows a countdown.
	return 0
end

--- §9: name + rarity colour for the prompt, so the player knows what they are casting at
--- BEFORE committing air.
function FishingController:GetSpeciesLabel(speciesId: string): { name: string, color: Color3 }
	local species = FishConfig.Species[speciesId]
	return {
		name = species.name,
		color = RarityConfig.Color[species.rarity],
	}
end

--- §5.4 / §9: show the exact failure line — never a loss without a reason and a next step.
function FishingController:ShowFailure(result: Types.FightResult, reason: string?)
	-- TODO(§9): hand FightConfig.FailMessages to HudController:ShowFailureMessage.
end

-- Knit lifecycle --------------------------------------------------------------

function FishingController:KnitStart()
	for _, name in { "CastRequest", "HookSetRequest", "FightInput", "FightStateChanged", "FightResolved" } do
		remotes[name] = Remotes.get(name)
	end

	remotes.FightStateChanged.OnClientEvent:Connect(function(view: FightView)
		fightView = view
	end)

	remotes.FightResolved.OnClientEvent:Connect(function(payload: { result: Types.FightResult, reason: string? })
		fightView = nil
		self:ShowFailure(payload.result, payload.reason)
	end)

	-- TODO(§5.1-§5.3): bind the input set —
	--   ContextActionService holds FightConfig.Keys.Cast / .Fight on hold/release, and
	--   FightConfig.Keys.Abort on press; mouse button 1 and gamepad R2 are the same pull.
	-- TODO(§5.1): show the world-anchored "[E] CAST" prompt (species name + rarity colour via
	-- GetSpeciesLabel) over a fish within FightConfig.CastRange that is in front of the camera.
end

return FishingController
