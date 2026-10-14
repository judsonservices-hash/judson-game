--!strict
--[[
    Deep Tide — Tension (the pure §5 maths, in one place)

    Source: GDD §5.1 (cast geometry), §5.2 (the hook-set ring), §5.3 (the tension mini-game,
    steps 1-7 verbatim), §5.4 (the unbreakable rod wall), §5.5 (per-species tuning),
    §4.1 (hook-set window and strain multiplier by rarity).

    Nothing here touches Instances, remotes or players: it is the arithmetic the server runs and
    the client mirrors, so a fight can be simulated headlessly (tools/worldtest/fish_harness.luau)
    and the same seed produces the same fight twice. FishingService owns the consequences
    (cooldowns, fish states, catch log); this module owns the numbers.

    Every constant comes from FightConfig / RarityConfig / the species' mini table. Tension
    takes at most a species config entry and a rod stats entry — no magic numbers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FightConfig = require(ReplicatedStorage.DeepTide.Config.FightConfig)
local RarityConfig = require(ReplicatedStorage.DeepTide.Config.RarityConfig)

local Tension = {}

export type SpeciesEntry = {
    id: string,
    name: string,
    rarity: string,
    value: number,
    mini: {
        zoneHalfWidth: number,
        zoneHz: number,
        zoneAmp: number,
        fillRate: number,
        requiredTension: number,
        hookWindow: number,
    },
}

export type RodStats = {
    id: string,
    name: string,
    lineStrength: number,
    zoneWidthMult: number,
    strainMult: number,
    fillMult: number,
    maxRarity: string,
}

--- One fight. Mirrored field-for-field by the client (§5.3 UI: safe zone, needle, hold meter,
--- over-tension line).
export type FightState = {
    needle: number, -- T in [0, 1], starts at FightConfig.NeedleStart
    zoneCentre: number, -- S (§5.3 step 2)
    zoneHalfWidth: number, -- W = species value x rod zoneWidthMult
    hold: number, -- H in [0, FightConfig.HoldMeterMax]
    tensionMax: number, -- T_max = min(1, rod.lineStrength / species.requiredTension)
    fillRate: number, -- %/s, species value x rod fillMult
    strainMult: number, -- RarityConfig.StrainMult[rarity] x rod strainMult
    zoneHz: number,
    zoneAmp: number,
    elapsed: number, -- fight clock, drives the sine
    jitter: number, -- the ±ZoneJitterAmp offset currently in force
    jitterTimer: number, -- seconds until the next re-roll
    overTensionSeconds: number, -- how long T has sat at the over-tension line
    inZone: boolean, -- last step's in-zone test (§5.3 step 5)
}

export type FightOutcome = "Landed" | "Escaped" | "Snapped"
export type HookSetResult = "Hit" | "Early" | "Late" | "Expired"

local function clamp(value: number, low: number, high: number): number
    if value < low then
        return low
    elseif value > high then
        return high
    end
    return value
end

-- Cast (§5.1) -----------------------------------------------------------------

--- §5.1 step 1/2: is `targetPosition` a legal cast from `origin`, given the caster's facing?
--- Returns (ok, distance, facingDot) so a refusal can name which rule failed.
function Tension.castTargetCheck(
    origin: Vector3,
    lookVector: Vector3,
    targetPosition: Vector3,
    maxRange: number?,
    minFacingDot: number?
): (boolean, number, number)
    local range = maxRange or FightConfig.CastRange
    local minDot = minFacingDot or FightConfig.CastFacingDot

    local offset = targetPosition - origin
    local distance = offset.Magnitude
    local dot = 0
    if distance > 0 then
        local unit = offset / distance
        dot = unit.X * lookVector.X + unit.Y * lookVector.Y + unit.Z * lookVector.Z
    end

    return distance <= range and dot >= minDot, distance, dot
end

-- Hook set (§5.2) -------------------------------------------------------------

--- How far through the shrink ring is, as a fraction of the species' window (§5.2 step 5).
function Tension.hookSetFraction(elapsed: number, hookWindow: number): number
    if hookWindow <= 0 then
        return 1
    end
    return elapsed / hookWindow
end

--- §5.2 step 6/7: a press lands if the ring is between HookSetZoneMin and 100%; a press inside
--- the +HookSetGraceSeconds tail is a miss ("Late"), as is an early press. `Expired` is the
--- window closing with no press at all.
function Tension.hookSetResult(elapsed: number, hookWindow: number): HookSetResult
    local fraction = Tension.hookSetFraction(elapsed, hookWindow)
    local graceFraction = if hookWindow > 0 then FightConfig.HookSetGraceSeconds / hookWindow else 0

    if fraction < FightConfig.HookSetZoneMin then
        return "Early"
    elseif fraction <= 1 then
        return "Hit"
    elseif fraction <= 1 + graceFraction then
        return "Late"
    end
    return "Expired"
end

-- Fight (§5.3) ----------------------------------------------------------------

--- §5.5: 100 / fillRate with perfect play, before the rod's fill multiplier. The GDD's
--- "bare-minimum time to land" column, computed instead of copied.
function Tension.bareMinimumSeconds(species: SpeciesEntry, rodStats: RodStats?): number
    local fillMult = if rodStats ~= nil then rodStats.fillMult else 1
    local fillRate = species.mini.fillRate * fillMult
    if fillRate <= 0 then
        return math.huge
    end
    return FightConfig.HoldMeterMax / fillRate
end

--- §5.3 step 4: the tension ceiling the rod can hold against this fish. 1.0 means the rod
--- out-strengths the fish; below 1.0 the over-tension line sits inside the track.
function Tension.tensionCeiling(species: SpeciesEntry, rodStats: RodStats): number
    if species.mini.requiredTension <= 0 then
        return 1
    end
    return math.min(1, rodStats.lineStrength / species.mini.requiredTension)
end

--- §5.4/§4.1: can this rod land this rarity at all? One rank comparison — never a roll.
function Tension.rarityAllowed(rodMaxRarity: string, rarity: string): boolean
    local rodRank = RarityConfig.Rank[rodMaxRarity]
    local fishRank = RarityConfig.Rank[rarity]
    if rodRank == nil or fishRank == nil then
        return false
    end
    return fishRank <= rodRank
end

--- A new fight, with every value derived from config (§5.3 steps 1-4 on entry).
function Tension.newFight(species: SpeciesEntry, rodStats: RodStats): FightState
    local rarityStrain = RarityConfig.StrainMult[species.rarity] or 1
    return {
        needle = FightConfig.NeedleStart,
        zoneCentre = 0.5,
        zoneHalfWidth = species.mini.zoneHalfWidth * rodStats.zoneWidthMult,
        hold = FightConfig.HoldMeterStart,
        tensionMax = Tension.tensionCeiling(species, rodStats),
        fillRate = species.mini.fillRate * rodStats.fillMult,
        strainMult = rarityStrain * rodStats.strainMult,
        -- the species' §5.5 zoneHz, held to the sweep ceiling (see zoneSweepCeiling above)
        zoneHz = Tension.effectiveZoneHz(species.mini.zoneHz, species.mini.zoneAmp),
        zoneAmp = species.mini.zoneAmp,
        elapsed = 0,
        jitter = 0,
        jitterTimer = 0, -- first step rolls the jitter
        overTensionSeconds = 0,
        inZone = false,
    }
end

--- §5.3 step 2: S = 0.5 + zoneAmp * sin(2 pi * zoneHz * t) + jitter.
function Tension.zoneCentreAt(fight: FightState, elapsed: number): number
    return 0.5 + fight.zoneAmp * math.sin(2 * math.pi * fight.zoneHz * elapsed) + fight.jitter
end

--- GAP IN §5.3, resolved here and flagged to the design owner (see the note in Config/FightConfig):
--- §5.3 step 1 gives the needle a fixed 0.55 up / 0.75 down track per second, and §5.3 step 2 /
--- §5.5 give each species a zone that sweeps at 2 pi x zoneHz x zoneAmp — up to 2.38/s for the
--- Ghost Ray, 4.3x faster than the needle can move. A zone that out-runs the needle can never be
--- held: measured against the real §5.3 maths, every input policy (including one that reads the
--- zone's next position out of the air) ends up in the band 17% of the time on the Lantern Eel and
--- 12% on the Ghost Ray, against the 71% the 1.4x real-play column of §5.5/§6.2 assumes, and the
--- hold meter drains far faster than it fills — so those two fish, and the Reef Bass at 1.01/s
--- swept/s, were unlandable by construction, and the §5.4 wall ("only the Brass Rod can land a
--- Ghost Ray") guarded a fish nobody could land with any rod.
---
--- The ceiling: the needle must out-pace the zone's sweep and still have the speed left over to
--- close the +/-ZoneJitterAmp step the zone's centre takes every ZoneJitterInterval, otherwise
--- nowhere in the band is stable. Both operands are §5.3's own numbers, so this is a derived rule
--- rather than a new tunable — and it edits no §5.5 value: FishConfig keeps the printed zoneHz.
function Tension.zoneSweepCeiling(): number
    return FightConfig.NeedleRiseRate - FightConfig.ZoneJitterAmp / FightConfig.ZoneJitterInterval
end

--- The zone frequency a fight actually runs at: the species' §5.5 `zoneHz`, held to the ceiling
--- above. Species already inside the ceiling (Silver Sardine, Sunset Grouper) are untouched.
function Tension.effectiveZoneHz(zoneHz: number, zoneAmp: number): number
    local ceiling = Tension.zoneSweepCeiling()
    if zoneAmp <= 0 or ceiling <= 0 then
        return zoneHz
    end
    return math.min(zoneHz, ceiling / (2 * math.pi * zoneAmp))
end

--- One 1/30 s step of §5.3. `held` is the player's current input (hold = pull, release = slack).
--- Mutates `fight` and returns the outcome, or nil while the fight continues.
function Tension.step(fight: FightState, dt: number, held: boolean, rng: any): FightOutcome?
    fight.elapsed += dt

    -- step 2: the drifting safe zone (jitter re-rolled every ZoneJitterInterval)
    fight.jitterTimer -= dt
    if fight.jitterTimer <= 0 then
        fight.jitter = rng:range(-FightConfig.ZoneJitterAmp, FightConfig.ZoneJitterAmp)
        fight.jitterTimer = FightConfig.ZoneJitterInterval
    end
    fight.zoneCentre = Tension.zoneCentreAt(fight, fight.elapsed)

    -- step 1: the needle follows the button, not the fish
    if held then
        fight.needle += FightConfig.NeedleRiseRate * dt
    else
        fight.needle -= FightConfig.NeedleFallRate * dt
    end

    -- step 4: the rod's LineStrength caps the needle, and sitting on the cap breaks the line
    fight.needle = clamp(fight.needle, 0, fight.tensionMax)
    if fight.needle >= fight.tensionMax - FightConfig.SnapBand then
        fight.overTensionSeconds += dt
        if fight.overTensionSeconds >= FightConfig.SnapHoldTime then
            return "Snapped"
        end
    else
        fight.overTensionSeconds = 0
    end

    -- step 5: in zone the meter fills, out of zone it drains, further out drains faster
    local excess = math.abs(fight.needle - fight.zoneCentre) - fight.zoneHalfWidth
    fight.inZone = excess <= 0
    if fight.inZone then
        fight.hold += fight.fillRate * dt
    else
        local slope = if fight.zoneHalfWidth > 0 then excess / fight.zoneHalfWidth else 0
        fight.hold -= (FightConfig.HoldDrainBase + FightConfig.HoldDrainSlope * slope) * fight.strainMult * dt
    end
    fight.hold = clamp(fight.hold, 0, FightConfig.HoldMeterMax)

    -- steps 6/7: the two endings the fight owns (the §5.4 wall is checked before the fight starts)
    if fight.hold >= FightConfig.HoldMeterMax then
        return "Landed"
    elseif fight.hold <= 0 then
        return "Escaped"
    end
    return nil
end

--- The payload the client draws (§5.3 UI, §9) — a flat copy, never the live table.
function Tension.viewOf(fight: FightState, speciesId: string): { [string]: any }
    return {
        needle = fight.needle,
        zoneCentre = fight.zoneCentre,
        zoneHalfWidth = fight.zoneHalfWidth,
        hold = fight.hold,
        tensionMax = fight.tensionMax,
        speciesId = speciesId,
        overTension = fight.needle >= fight.tensionMax - FightConfig.SnapBand,
        inZone = fight.inZone,
    }
end

return Tension
