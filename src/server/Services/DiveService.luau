--!strict
--[[
	DiveService — Appendix B: "Oxygen depletion, depth tracking, the DepthRating auto-surface
	rule, air refill, underwater light blending".
	Source: GDD §3.0 (depth is -Y at the head, studs printed as "m"), §5.3 step 9 (oxygen keeps
	        draining through every fight phase), §5.4 + §11 (at rating + 20 for 1.5 s the player
	        is auto-surfaced, and a forced ascent never costs a banked fish), §8.1 (underwater
	        lighting blend), §8.8 (the air alarm at 20 s), §9 (air and depth readouts).

	Air is a clock on the reward, not on the player: running out must never lose a banked fish.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local DiveConfig = require(ReplicatedStorage.DeepTide.Config.DiveConfig)
local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)

local DiveService = Knit.CreateService {
	Name = "DiveService",
	Client = {},
}

-- Public server API -----------------------------------------------------------

--- Depth in studs, always positive: -Y at the player's head (§3.0).
function DiveService:GetDepth(player: Player): number
	-- TODO(§3.0): (DiveConfig.SeaLevelY - head.Y), clamped at 0 above the surface.
	return 0
end

--- Seconds of air left (§9: `AIR 100s`).
function DiveService:GetAir(player: Player): number
	-- TODO(§9): per-player air, refilled at the surface over SurfaceRefillSeconds.
	return self:GetAirCapacity(player)
end

function DiveService:GetAirCapacity(player: Player): number
	-- TODO(§6.3): GearService:GetAirCapacity(player) — 100 s, then 300 s.
	return 0
end

--- Everything the HUD needs in one payload (§9): air, capacity, depth, rating, and whether
--- the rating is currently exceeded (both turn red and print `GEAR RATING EXCEEDED`).
function DiveService:GetState(player: Player): Types.DiveState
	-- TODO(§9): assemble from the values above.
	return {
		air = 0,
		airCapacity = self:GetAirCapacity(player),
		depth = self:GetDepth(player),
		depthRating = 0,
		exceeded = false,
		submerged = false,
	}
end

function DiveService:IsSubmerged(player: Player): boolean
	return self:GetDepth(player) > DiveConfig.SeaLevelY
end

--- §5.3 step 9: called by FishingService on every fight tick — oxygen drains through all
--- three phases, which is the slice's central tension.
function DiveService:DrainAir(player: Player, seconds: number) end

--- §3 step 7: air refills over SurfaceRefillSeconds at the surface, with a visible refill.
function DiveService:RefillAir(player: Player) end

--- §5.4 + §11: at DepthRating + RatingWarningMargin for RatingWarningHoldTime the player is
--- auto-surfaced with the rating warning. Returns true when the ascent was forced.
--- The ascent itself must never cost a banked catch (§11).
function DiveService:EnforceDepthRating(player: Player): boolean
	-- TODO(§5.4): compare GetDepth against GearService:GetDepthRating + RatingWarningMargin,
	-- hold for RatingWarningHoldTime, then force the ascent and fire Notify.
	return false
end

--- §8.1/§3.0: blend the underwater preset in over UnderwaterFadeSeconds when the camera
--- crosses sea level. The effect values are the Technical Artist's; the fade is not.
function DiveService:SetUnderwaterVisuals(player: Player, underwater: boolean) end

-- Client surface -------------------------------------------------------------

function DiveService.Client:GetState(player: Player): Types.DiveState
	return self.Server:GetState(player)
end

-- Knit lifecycle --------------------------------------------------------------

function DiveService:KnitInit()
	-- TODO(§9): nothing to bind — DiveService pushes DiveStateChanged on a fixed interval
	-- rather than per frame per player.
end

function DiveService:KnitStart()
	-- TODO(§3, §5.4, §9): start the depth/air loop:
	--   * drain 1 s of air per second while submerged (§11)
	--   * refill at the surface over SurfaceRefillSeconds
	--   * enforce the depth rating (§5.4)
	--   * fire Remotes.DiveStateChanged with the HUD payload
	-- ZoneConfig.Fog / ZoneConfig.UnderwaterFadeSeconds are the world's half of this job.
end

return DiveService
