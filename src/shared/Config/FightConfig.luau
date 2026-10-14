--!strict
--[[
Deep Tide — FightConfig   (GDD Appendix B, "FightConfig (frameworks for §5.3)" + §5.1-§5.3)
Source: GDD §5.1 (cast), §5.2 (hook set), §5.3 (tension mini-game), §5.6 (cooldowns), §9 (failure lines).
PURE DATA. Every number the Tension mini-game needs; FishingService reads it, never hard-codes.
]]

local FightConfig = {}

-- Needle and safe zone (§5.3 steps 1-2).
FightConfig.NeedleRiseRate = 0.55 -- T += this x dt while holding
FightConfig.NeedleFallRate = 0.75 -- T -= this x dt while released
FightConfig.NeedleStart = 0.35 -- T on entry
FightConfig.ZoneJitterAmp = 0.05 -- random jitter on the zone centre S
FightConfig.ZoneJitterInterval = 0.40 -- re-rolled every 0.4 s
-- GAP IN §5.3, flagged to the design owner: §5.3 step 1 fixes the needle's rates and §5.3 step 2 /
-- §5.5 fix each species' zone speed, and for three of the five species the second out-runs the
-- first — the safe zone sweeps faster than the needle can ever move, so the fish is unlandable by
-- any input policy at all (perfect or human). Peak sweep = 2 pi x zoneHz x zoneAmp:
--   Silver Sardine 0.28/s   Sunset Grouper 0.55/s   Reef Bass 1.01/s
--   Lantern Eel 1.67/s      Ghost Ray 2.38/s
-- against a needle that rises at 0.55/s and falls at 0.75/s. A player can only hold the band if
-- the needle out-paces the zone *and* still has the speed left to close the +/-ZoneJitterAmp step
-- the zone takes every ZoneJitterInterval. That gives the ceiling Modules/Tension derives from
-- these three numbers (NeedleRiseRate - ZoneJitterAmp / ZoneJitterInterval = 0.425 track/s) and
-- clamps the offending species' zoneHz to it. No §5.5 number is edited: FishConfig still carries
-- the GDD's printed zoneHz/zoneAmp, and Tension applies the ceiling at fight start.

-- Over-tension and the snap (§5.3 step 4).
FightConfig.SnapBand = 0.02 -- within this of T_max...
FightConfig.SnapHoldTime = 0.40 -- ...continuously for this long => line snaps
FightConfig.HoldMeterMax = 100 -- H in [0, 100]
FightConfig.HoldDrainBase = 9 -- drain = (base + slope x out-of-zone) x strainMult
FightConfig.HoldDrainSlope = 3
-- GAP IN §5.3, resolved here and flagged to the design owner: the GDD says the hold meter starts
-- at 0 and that `H <= 0` loses the fish, which cannot both be true — the first out-of-zone tick
-- would end the fight before the player has pressed anything (the needle starts at 0.35, which is
-- already outside the Ghost Ray's 0.06 half-width). The meter therefore starts with this much of
-- the meter already banked, which is the same fairness rule §5.1 step 3 applies to the hook-set
-- window: the fish may not escape before the player has had a chance to react.
FightConfig.HoldMeterStart = 25

-- Cast and hook set (§5.1, §5.2).
FightConfig.CastRange = 25 -- studs
FightConfig.CastFacingDot = 0.3 -- target must be this "in front" of the camera
FightConfig.CastTweenTime = 0.6 -- seconds for the line to reach the fish
FightConfig.CastAbortDistance = 20 -- abort if the player moves this far from the target
FightConfig.LineRetractSeconds = 0.4 -- retract time on abort / miss
FightConfig.HookSetZoneMin = 0.65 -- press between 65% and 100% of the shrink
FightConfig.HookSetGraceSeconds = 0.30 -- grace after the window closes
FightConfig.LandedTweenSeconds = 0.9 -- win tween: fish to the rod tip (§5.3 step 6)

-- Presentation numbers that the mini-game and HUD share (§5.3 UI, §9).
FightConfig.TrackWidthPixels = 360
FightConfig.TrackScreenHeightFraction = 0.45
FightConfig.FailureMessageSeconds = 2 -- how long a failure line stays on screen (§9)
FightConfig.CatchMessageSeconds = 2 -- how long the landed-fish line stays on screen (§1 step 6)
FightConfig.SnapFlashSeconds = 0.4 -- white flash on a snap, hook-set-time or over-tension (§5.3 step 8, §5.4)
FightConfig.FightTickHz = 30 -- the server ticks the fight at this rate (§5.3)
-- §5.2 step 7 / §5.3 steps 7-8: how long the fish runs after each kind of loss, before it settles
-- back into its behaviour pattern. The eligibility waits it then serves are in Cooldowns below.
FightConfig.MissFleeSeconds = 3 -- miss the hook set -> flees as if startled for 3 s
FightConfig.EscapeFleeSeconds = 3 -- throw the hook -> flees 3 s
FightConfig.SnapFleeSeconds = 5 -- line snap -> flees 5 s, then respawns in its band

-- Input keys (§1 step 5, §5.3, §9: one key, never re-learned).
FightConfig.Keys = {
    Cast = "E",
    Fight = "E",
    Abort = "Q",
}

-- Cooldowns in seconds (§5.6).
FightConfig.Cooldowns = {
    cast = 1.0, -- successful cast -> next cast
    missHook = 0.4, -- missed hook set
    escape = 1.0, -- fish escape (H <= 0 or Q)
    snap = 2.0, -- line reset after a snap (rod greyed, countdown shown)
    respawnMiss = 8, -- fish eligible again after a missed hook set
    respawnSnap = 15, -- fish respawns elsewhere in its band after a snap
    respawnEscape = 20, -- fish eligible again after an escape (counted from the respawn)
}

-- The three loss explanations (§5.3, §9). Never a loss without a reason and a next step.
-- `outOfAir` is the fourth way to lose a fish, added by the GDD's own oxygen rule (§5.3 step 9:
-- "oxygen keeps draining throughout all three phases"; §0 lever 2: the tank is a clock on the
-- reward). §9 names three messages, so this one is written in the same voice and the same shape:
-- what happened, then what to do about it.
FightConfig.FailMessages = {
    weakLine = "LINE TOO WEAK — UPGRADE ROD (750 C)",
    snap = "LINE SNAPPED — TOO MUCH TENSION",
    escape = "IT GOT AWAY — KEEP THE NEEDLE IN THE GREEN",
    outOfAir = "OUT OF AIR — THE FISH GOT AWAY",
}

-- The two losses §9 does not name: the player never hooked the fish (§5.2 step 7) and the cast
-- came apart because they swam off (§5.1 step 4). Same voice, same shape as the three above.
FightConfig.MissMessages = {
    missedHookSet = "IT GOT AWAY — PRESS E AS THE RING CLOSES",
    castAborted = "CAST BROKE — STAY WITH THE FISH",
}

-- The one good message (§1 step 6): the fish is banked, not yet paid. Values only become Coins at
-- the Tide Trader (§6.2), so this line says BANKED and quotes what the trader will pay.
-- Format: species name, then value in Coins.
FightConfig.CatchMessageFormat = "%s BANKED — %d C AT THE TRADER"

-- Fights re-roll the safe zone's jitter every ZoneJitterInterval; a seeded generator keeps a
-- fight reproducible (see Modules/Rng — the same seed produces the same fight twice).
FightConfig.RandomSeed = 20261013

return FightConfig
