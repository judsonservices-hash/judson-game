--!strict
--[[
    Deep Tide — Atmosphere (the depth sampler)
    Source: GDD §3.0 (depth is -Y at the head; the 1.5 s blend on crossing Y 0),
            §8.1 (two-world lighting, one interpolation), §8.2 (fog is the depth gauge),
            §8.3 (sun rays die by 60 studs), §8.8 (the air alarm's screen effect),
            Appendix C (the fog formula).

    WHAT THIS IS: a pure function of one number. Give it a depth in studs and it returns every
    value the water's light should have at that depth — fog distance and colour, ambient, brightness,
    the Atmosphere instance's numbers, the colour grade and the bloom — by interpolating between the
    depth anchors in LightingConfig.Bands. Nothing here touches an Instance, so it runs (and is
    asserted) headlessly, and so the exact curve the client applies is the exact curve the test rig
    checks. The three places the player must be able to name are in that curve as anchors, not as
    branches: descending through the Shallows into the Rim into the Shelf is one continuous fade.

    TWO RULES THIS FILE EXISTS TO ENFORCE
      1. Fog is a gauge, not decoration (§8.2): the numbers come from ZoneConfig.Fog and nowhere
         else, so FogEnd = clamp(320 - 1.35 x depth, 45, 320) is literally the formula the GDD
         prints, and the colour ramp ends where the distance ramp stops moving.
      2. Nothing steps (§8.1: "never a snap"). The sampler is continuous at every band boundary;
         tools/worldtest/visual_harness.luau asserts that by walking depth 0 -> 230 in 1-stud steps
         and failing on any jump larger than the stated tolerance.

    The clock-domain pieces (the 1.5 s underwater cross-fade, the air-alarm pulse) are functions of
    time here too, but they are still pure: the caller supplies the fade factor / the clock, so the
    controller stays a writer and the maths stays testable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)
local LightingConfig = require(ReplicatedStorage.DeepTide.Config.LightingConfig)
local DiveConfig = require(ReplicatedStorage.DeepTide.Config.DiveConfig)

local Atmosphere = {}

-- ============================================================================
-- Small colour maths (Color3:Lerp is not stubbed in the headless rig, and this is 6 lines)
-- ============================================================================

function Atmosphere.Lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

function Atmosphere.Clamp01(t: number): number
    if t < 0 then
        return 0
    elseif t > 1 then
        return 1
    end
    return t
end

--- Linear interpolation between two colours, on their RGB channels (Roblox has no HSV lerp and
--- the GDD only ever names RGB endpoints).
function Atmosphere.LerpColor(a: Color3, b: Color3, t: number): Color3
    local u = Atmosphere.Clamp01(t)
    return Color3.fromRGB(a.R * 255 + (b.R * 255 - a.R * 255) * u, a.G * 255 + (b.G * 255 - a.G * 255) * u, a.B * 255 + (b.B * 255 - a.B * 255) * u)
end

-- ============================================================================
-- §8.2 — the fog curve (ZoneConfig.Fog is the only place these numbers live)
-- ============================================================================

--- How far the player can see at `depthStuds`: §8.2 `FogEnd = clamp(320 - 1.35 x depth, 45, 320)`.
--- 320 studs at the surface, 50 at 200 studs, 45 from 204 studs down. The player's *sense* of
--- depth equals the number on the HUD — which is the whole point of §8.2.
function Atmosphere.FogEnd(depthStuds: number): number
    local fog = ZoneConfig.Fog
    local distance = fog.BaseDistance - fog.DepthCoefficient * math.max(depthStuds, 0)
    if distance < fog.MinDistance then
        return fog.MinDistance
    elseif distance > fog.BaseDistance then
        return fog.BaseDistance
    end
    return distance
end

--- §8.2: `FogStart = FogEnd x 0.25`. The near plane of the haze follows the far plane, so the
--- transition band stays proportional as the world closes in.
function Atmosphere.FogStart(depthStuds: number): number
    return Atmosphere.FogEnd(depthStuds) * ZoneConfig.Fog.StartFraction
end

--- §8.2: FogColor lerps `RGB(90, 150, 170)` -> `RGB(6, 12, 20)` (ZoneConfig.Fog's two ends).
--- The ramp length is ZoneConfig.Fog.ColorRampStuds — the depth at which the distance curve stops
--- moving, so colour and distance finish together.
function Atmosphere.FogColor(depthStuds: number): Color3
    local fog = ZoneConfig.Fog
    return Atmosphere.LerpColor(fog.ShallowColor, fog.DeepColor, Atmosphere.Clamp01(depthStuds / fog.ColorRampStuds))
end

-- ============================================================================
-- §8.3 — sun shafts, per-client, continuous
-- ============================================================================

--- How visibly the §3.2 L8 sun shafts are drawn from `depthStuds` of camera depth.
--- 0.35 seen from the dock (above water), up to 1.0 by LightingConfig.SunShafts.peakStuds, then
--- down to 0 at fadeEndStuds (60) and gone below it (§8.3 "further down their absence is the
--- Shelf's best asset"). Continuous at every breakpoint, including at 0.
function Atmosphere.SunShaftAlpha(depthStuds: number): number
    local cfg = LightingConfig.SunShafts
    local above = cfg.aboveWaterAlpha
    if depthStuds <= cfg.fadeStartStuds then
        return above
    end
    if depthStuds >= cfg.fadeEndStuds then
        return 0
    end
    if depthStuds <= cfg.peakStuds then
        local t = (depthStuds - cfg.fadeStartStuds) / math.max(cfg.peakStuds - cfg.fadeStartStuds, 1e-6)
        return Atmosphere.Lerp(above, 1, t)
    end
    local t = (depthStuds - cfg.peakStuds) / math.max(cfg.fadeEndStuds - cfg.peakStuds, 1e-6)
    return Atmosphere.Lerp(1, 0, t)
end

-- ============================================================================
-- The band curve (§8.1): the three places, as anchors
-- ============================================================================

--- The two anchors a depth sits between: `{ shallow, deep, t }`, where `t` is how far along the
--- pair the depth is (0 at the shallow anchor, 1 at the deep one). Above the first anchor and
--- below the last, `shallow == deep` and `t == 0`, so the ends are held rather than extrapolated.
function Atmosphere.Span(depthStuds: number): { shallow: any, deep: any, t: number }
    local bands = LightingConfig.Bands
    local depth = depthStuds
    if depth <= bands[1].depthStuds then
        return { shallow = bands[1], deep = bands[1], t = 0 }
    end
    for index = 1, #bands - 1 do
        local shallow, deep = bands[index], bands[index + 1]
        if depth < deep.depthStuds then
            local span = deep.depthStuds - shallow.depthStuds
            return { shallow = shallow, deep = deep, t = Atmosphere.Clamp01((depth - shallow.depthStuds) / span) }
        end
    end
    local last = bands[#bands]
    return { shallow = last, deep = last, t = 0 }
end

--- The band a depth *belongs* to (§3.1's three places, plus the chasm floor). A boundary depth
--- belongs to the deeper band: at 40 studs the water is already Shallows water.
function Atmosphere.BandAt(depthStuds: number): string
    local bands = LightingConfig.Bands
    local name = bands[1].id
    for _, band in bands do
        if depthStuds >= band.depthStuds then
            name = band.id
        end
    end
    return name
end

--- Interpolate a fixed set of number fields and a fixed set of colour fields from one band to the
--- next. The two lists are given by the caller rather than sniffed, so a field that is added to a
--- band and forgotten here is a nil the test rig sees, not a silent fallback.
local function lerpFields(
    shallow: any,
    deep: any,
    t: number,
    numberKeys: { string },
    colorKeys: { string }
): { [string]: any }
    local out: { [string]: any } = {}
    for _, key in numberKeys do
        out[key] = Atmosphere.Lerp(shallow[key], deep[key], t)
    end
    for _, key in colorKeys do
        out[key] = Atmosphere.LerpColor(shallow[key], deep[key], t)
    end
    return out
end

local BAND_SCALARS = { "brightness", "exposureCompensation", "environmentDiffuseScale", "environmentSpecularScale" }
local BAND_COLORS = { "ambient", "outdoorAmbient" }
local ATMOSPHERE_SCALARS = { "density", "haze", "glare", "offset" }
local ATMOSPHERE_COLORS = { "color", "decay" }
local GRADE_SCALARS = { "saturation", "contrast", "brightness" }
local GRADE_COLORS = { "tint" }
local BLOOM_SCALARS = { "intensity", "size", "threshold" }

--- Everything the water's light is at `depthStuds` (studs below sea level, §3.0).
--- One table, no Instances: the client controller writes exactly this, and the test rig asserts
--- exactly this is sane.
function Atmosphere.Plan(depthStuds: number): { [string]: any }
    local span = Atmosphere.Span(depthStuds)
    local shallow, deep, t = span.shallow, span.deep, span.t

    local plan = lerpFields(shallow, deep, t, BAND_SCALARS, BAND_COLORS)
    plan.atmosphere = lerpFields(shallow.atmosphere, deep.atmosphere, t, ATMOSPHERE_SCALARS, ATMOSPHERE_COLORS)
    plan.grade = lerpFields(shallow.grade, deep.grade, t, GRADE_SCALARS, GRADE_COLORS)
    plan.bloom = lerpFields(shallow.bloom, deep.bloom, t, BLOOM_SCALARS, {})

    -- §8.2: fog is not a band value, it is the depth gauge. The bands say how the water *feels*;
    -- the curve says how far you can see, and it is the same curve at every depth.
    plan.fogEnd = Atmosphere.FogEnd(depthStuds)
    plan.fogStart = Atmosphere.FogStart(depthStuds)
    plan.fogColor = Atmosphere.FogColor(depthStuds)
    plan.sunShaftAlpha = Atmosphere.SunShaftAlpha(depthStuds)

    plan.depthStuds = depthStuds
    plan.band = Atmosphere.BandAt(depthStuds)
    plan.zone = deep.zone
    plan.span = { from = shallow.id, to = deep.id, t = t }
    return plan
end

--- §8.1's cross-fade, as a pure step: given the current blend (0 = above water, 1 = underwater),
--- the target and `dt` seconds, advance by the blend rate. The controller calls this once per
--- sample; the fade length itself is ZoneConfig.UnderwaterFadeSeconds, read by the controller.
function Atmosphere.AdvanceBlend(current: number, target: number, dt: number, fadeSeconds: number): number
    if fadeSeconds <= 0 then
        return target
    end
    local step = dt / fadeSeconds
    if current < target then
        return math.min(target, current + step)
    end
    return math.max(target, current - step)
end

-- ============================================================================
-- §8.8 — the air alarm, as a screen effect (never as HUD chrome)
-- ============================================================================

--- The alarm's strength: 0 at DiveConfig.AirAlarmSeconds, 1 at DiveConfig.AirFastPulseSeconds,
--- linear between, and 1 below the fast threshold. Above the alarm it is exactly 0 — no warning
--- before the warning, or the number stops meaning anything.
function Atmosphere.AirAlarmStrength(airSeconds: number): number
    local alarm = DiveConfig.AirAlarmSeconds
    local fast = DiveConfig.AirFastPulseSeconds
    if airSeconds >= alarm then
        return 0
    end
    if airSeconds <= fast then
        return 1
    end
    return Atmosphere.Clamp01((alarm - airSeconds) / (alarm - fast))
end

--- The pulse period under the alarm: §8.8 "accelerating to a fast pulse" at the fast threshold.
function Atmosphere.AirAlarmPeriod(airSeconds: number): number
    local oxygen = LightingConfig.Oxygen
    if airSeconds <= DiveConfig.AirFastPulseSeconds then
        return oxygen.pulseFastSeconds
    end
    return oxygen.pulseSlowSeconds
end

--- What the oxygen screen effect should be at this instant: a red wash, the colour draining out,
--- the picture closing in, all of it breathing. Returns a table of property values (never
--- Instances) so the curve can be asserted: this is the "impossible to miss" half of §8.8, and the
--- only part of the alarm that is not audio (the beep is not implemented — see VisualConfig).
function Atmosphere.OxygenPlan(airSeconds: number, clock: number): { [string]: any }
    local oxygen = LightingConfig.Oxygen
    local strength = Atmosphere.AirAlarmStrength(airSeconds)
    if strength <= 0 then
        return {
            enabled = false,
            strength = 0,
            tint = Color3.fromRGB(255, 255, 255),
            saturation = 0,
            brightness = 0,
            blur = 0,
        }
    end

    local period = Atmosphere.AirAlarmPeriod(airSeconds)
    local phase = if period > 0 then math.sin(2 * math.pi * clock / period) else 0
    -- The pulse rides on top of the ramp but never takes it negative: 1 -> 2 at the peak.
    local pulsed = strength * (1 + oxygen.pulseAmplitude * phase)

    return {
        enabled = true,
        strength = strength,
        tint = Atmosphere.LerpColor(Color3.fromRGB(255, 255, 255), oxygen.tint, strength),
        saturation = oxygen.maxSaturation * strength,
        brightness = oxygen.minBrightness * strength,
        blur = oxygen.maxBlur * pulsed,
        pulse = phase,
    }
end

return Atmosphere
