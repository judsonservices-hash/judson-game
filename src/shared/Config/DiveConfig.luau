--!strict
--[[
Deep Tide — DiveConfig   (GDD Appendix B, "DiveConfig" + §5.4 / §9 threshold values)
Source: GDD §3 (vertical traversal rule), §5.4 (auto-surface), §8.8 (air alarm),
        §9 (HUD air thresholds), §11 (acceptance: auto-surface is unevadable).
PURE DATA.
]]

local DiveConfig = {}

-- Vertical traversal (§3 "Vertical traversal rule").
DiveConfig.DescendSpeed = 20 -- studs/s
DiveConfig.AscendSpeed = 28 -- studs/s — ascending is deliberately faster

-- Air / oxygen.
DiveConfig.SurfaceRefillSeconds = 3 -- refill takes 3 s at the surface
DiveConfig.AirAmberSeconds = 40 -- HUD turns amber at 40 s (§9)
DiveConfig.AirAlarmSeconds = 20 -- audible beep starts at 20 s (§8.8)
DiveConfig.AirFastPulseSeconds = 5 -- pulse accelerates at 5 s (§8.8)

-- Depth maths. Sea level is Y 0; depth is reported as -Y at the player's head (§3.0).
DiveConfig.SeaLevelY = 0
DiveConfig.DepthIsNegativeY = true
DiveConfig.HudDepthSuffix = "m" -- 1 stud is displayed as 1 "m" (GDD header)

-- Auto-surface rule (§5.4, §11): at DepthRating + RatingWarningMargin for
-- RatingWarningHoldTime the player is forced to the surface with the rating warning.
DiveConfig.RatingWarningMargin = 20 -- studs above the gear's DepthRating
DiveConfig.RatingWarningHoldTime = 1.5 -- seconds

-- Underwater lighting blend (§3.0, §8.1) — values are the Technical Artist's; the fade length is fixed.
DiveConfig.UnderwaterFadeSeconds = 1.5

-- Forced surfacing (the §5.4 rating rule and the §5.3 step 9 out-of-air rule). A forced ascent
-- teleports the character to this height above sea level, standing in the air over the water they
-- were in — never onto the seabed, never underground. Nothing is lost by being surfaced: the
-- catch log is already banked (§1 step 7, §11).
DiveConfig.ForceSurfaceHeightStuds = 6
DiveConfig.ForceSurfaceMessages = {
	outOfAir = "AIR EMPTY — SURFACED",
	-- The rating wall names itself (§2: "DEPTH RATING EXCEEDED — 90m") and names the rating the
	-- player is wearing, so the number on the HUD is the number in the line. Being surfaced by
	-- your own gear is NOT a §5.4 rod failure: nothing here may read as "LINE TOO WEAK". The
	-- number is GearConfig.Gear[x].depthRating for whatever the player has equipped.
	rating = "GEAR RATING EXCEEDED — RATING %dm — SURFACED",
	-- The same line with the next step attached (§9), for the case where a deeper tier exists:
	-- parameters are that tier's printed name, rating and cost, read from GearConfig.
	ratingWithUpgradeFormat = "GEAR RATING EXCEEDED — RATING %dm — SURFACED · %s %dm (%d C)",
}

-- How often the server pushes `DiveStateChanged` to a player (§9). Not per frame: the air number
-- is drawn from a payload, and 10 Hz reads as smooth for a whole-second countdown.
DiveConfig.StatePushHz = 10

return DiveConfig
