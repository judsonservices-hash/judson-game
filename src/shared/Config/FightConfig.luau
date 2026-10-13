--!strict
--[[
Deep Tide — FightConfig   (GDD Appendix B, "FightConfig (frameworks for §5.3)" + §5.1-§5.3)
Source: GDD §5.1 (cast), §5.2 (hook set), §5.3 (tension mini-game), §5.6 (cooldowns), §9 (failure lines).
PURE DATA. Every number the Tension mini-game needs; FishingService reads it, never hard-codes.
]]

local FightConfig = {}

-- Needle and safe zone (§5.3 steps 1-2).
FightConfig.NeedleRiseRate = 0.55         -- T += this x dt while holding
FightConfig.NeedleFallRate = 0.75         -- T -= this x dt while released
FightConfig.NeedleStart = 0.35            -- T on entry
FightConfig.ZoneJitterAmp = 0.05          -- random jitter on the zone centre S
FightConfig.ZoneJitterInterval = 0.40     -- re-rolled every 0.4 s

-- Over-tension and the snap (§5.3 step 4).
FightConfig.SnapBand = 0.02               -- within this of T_max...
FightConfig.SnapHoldTime = 0.40           -- ...continuously for this long => line snaps
FightConfig.HoldMeterMax = 100            -- H in [0, 100], starts at 0
FightConfig.HoldDrainBase = 9             -- drain = (base + slope x out-of-zone) x strainMult
FightConfig.HoldDrainSlope = 3

-- Cast and hook set (§5.1, §5.2).
FightConfig.CastRange = 25                -- studs
FightConfig.CastFacingDot = 0.3           -- target must be this "in front" of the camera
FightConfig.CastTweenTime = 0.6           -- seconds for the line to reach the fish
FightConfig.CastAbortDistance = 20        -- abort if the player moves this far from the target
FightConfig.LineRetractSeconds = 0.4      -- retract time on abort / miss
FightConfig.HookSetZoneMin = 0.65         -- press between 65% and 100% of the shrink
FightConfig.HookSetGraceSeconds = 0.30    -- grace after the window closes
FightConfig.LandedTweenSeconds = 0.9      -- win tween: fish to the rod tip (§5.3 step 6)

-- Presentation numbers that the mini-game and HUD share (§5.3 UI, §9).
FightConfig.TrackWidthPixels = 360
FightConfig.TrackScreenHeightFraction = 0.45
FightConfig.FailureMessageSeconds = 2     -- how long a failure line stays on screen (§9)

-- Input keys (§1 step 5, §5.3, §9: one key, never re-learned).
FightConfig.Keys = {
Cast = "E",
Fight = "E",
Abort = "Q",
}

-- Cooldowns in seconds (§5.6).
FightConfig.Cooldowns = {
cast = 1.0,          -- successful cast -> next cast
missHook = 0.4,      -- missed hook set
escape = 1.0,        -- fish escape (H <= 0 or Q)
snap = 2.0,          -- line reset after a snap (rod greyed, countdown shown)
respawnMiss = 8,     -- fish eligible again after a missed hook set
respawnSnap = 15,    -- fish respawns elsewhere in its band after a snap
respawnEscape = 20,  -- fish eligible again after an escape (counted from the respawn)
}

-- The three loss explanations (§5.3, §9). Never a loss without a reason and a next step.
FightConfig.FailMessages = {
weakLine = "LINE TOO WEAK — UPGRADE ROD (750 C)",
snap = "LINE SNAPPED — TOO MUCH TENSION",
escape = "IT GOT AWAY — KEEP THE NEEDLE IN THE GREEN",
}

return FightConfig
