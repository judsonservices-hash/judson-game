--!strict
--[[
    Deep Tide — LightingConfig
    Source: GDD §3.0 (sky, atmosphere, water region, the 1.5 s blend), §3.1 (per-zone ambience
            row: "Lit, teal, coral" vs "Near-black, cold blue, bioluminescence only"),
            §8.1 (two-world lighting + the fade), §8.2 (fog is the depth gauge),
            §8.3 (sun rays die by 60 studs), §8.6 (bioluminescence is the Shelf's only light),
            §8.8 (the air alarm must be impossible to miss), §3.4/§7 (the chasm is black),
            Appendix C (fog formula, underwater fade).

    PURE DATA — every number the world's light is made of, and nothing else.

    How this file is meant to be read
      * `Bands` is an ordered list of depth anchors (studs below sea level, §3.0). A depth between
        two anchors is a straight interpolation of both (§8.1: "one interpolation ... the transition
        must be a fade, never a snap"). The sampler that does this is Modules/Atmosphere.luau; it is
        the only reader. Three bands are the three places the player must be able to name without
        being told: Surface (lit), Shallows (teal, sunlit), Rim (cold, hazy), Shelf (black, lit by
        living things), Abyss (the chasm floor, darker still — §7's next update starts here).
      * Fog distance is NOT here: §8.2's curve (FogEnd = clamp(320 - 1.35 x depth, 45, 320),
        FogStart = FogEnd x 0.25, FogColor lerp) already lives in ZoneConfig.Fog, and a number
        never lives in two config files. The sampler reads ZoneConfig for the curve and this file
        for the per-band atmosphere/ambient/grade.
      * `Water` is the Terrain water appearance (§3.0: "Water is Roblox Terrain water"). Terrain
        holds water and nothing else, so these five numbers are the whole of the world's water.
      * Every value below is a look, so every value below is the Technical Artist's to retune.
        Nothing in gameplay reads this file.

    NOT done in this pass (owner/lead should know): no Roblox stock audio is wired, so §8.7's
    sound layers and §8.8's audible beep are still missing. This file only covers what can be
    seen.
]]

local LightingConfig = {}

-- §3.0 / §8.1: the fade length (1.5 s on the camera crossing Y 0) is already recorded as
-- ZoneConfig.UnderwaterFadeSeconds ("Presentation timings owned by the world") and as
-- DiveConfig.UnderwaterFadeSeconds (the service that runs the fade). It is NOT repeated here: the
-- depth sampler (Modules/Atmosphere) is a pure function of depth and owns no clock.

-- §3.0: "Sky: Lighting.ClockTime = 17.5". Late afternoon, so the sun is low over the dock and
-- the shafts at §8.3 read as shafts rather than as a noon glare.
LightingConfig.ClockTime = 17.5
LightingConfig.GlobalShadows = true
LightingConfig.ShadowSoftness = 0.35
-- Lighting.Technology is not scriptable at runtime, so it is set in default.project.json as a
-- place property; recorded here so the intended lighting technology sits next to its numbers.
LightingConfig.Technology = "ShadowMap"

-- §8.1 (above water): "Above: Brightness 2, teal-tinted, saturation +0.05."
-- Every band carries the same field set, so a band is comparable to a band and a missing value
-- is a nil rather than a silent fallback.
LightingConfig.Bands = {
    {
        id = "Surface", -- above the waterline: the dock, §1 steps 1-3
        zone = "Shallows",
        depthStuds = 0, -- anchor depth (§3.0: sea level = Y 0)
        ambient = Color3.fromRGB(80, 96, 104),
        outdoorAmbient = Color3.fromRGB(132, 152, 160),
        brightness = 2.0, -- §8.1
        exposureCompensation = 0.0,
        environmentDiffuseScale = 1.0,
        environmentSpecularScale = 1.0,
        -- §3.0 exact: Atmosphere Density 0.38, Haze 1.8, Color RGB(72, 96, 110).
        atmosphere = {
            density = 0.38,
            haze = 1.8,
            color = Color3.fromRGB(72, 96, 110),
            decay = Color3.fromRGB(110, 116, 128),
            glare = 0.35,
            offset = 0.10,
        },
        grade = { -- ColorCorrectionEffect: teal-tinted, saturation +0.05 (§8.1)
            tint = Color3.fromRGB(198, 224, 232),
            saturation = 0.05,
            contrast = 0.0,
            brightness = 0.0,
        },
        bloom = { intensity = 0.70, size = 24, threshold = 1.10 },
    },
    {
        id = "Shallows", -- §3.1 ambience: "Lit, teal, coral, sun rays from above"
        zone = "Shallows",
        depthStuds = 40, -- mid-band (Appendix C: Shallows 0 -> -85)
        ambient = Color3.fromRGB(46, 78, 92),
        outdoorAmbient = Color3.fromRGB(74, 110, 124),
        brightness = 1.15,
        exposureCompensation = -0.08,
        environmentDiffuseScale = 0.85,
        environmentSpecularScale = 0.90,
        atmosphere = {
            density = 0.44,
            haze = 1.35,
            color = Color3.fromRGB(40, 80, 96),
            decay = Color3.fromRGB(40, 70, 86),
            glare = 0.15,
            offset = 0.15,
        },
        grade = {
            tint = Color3.fromRGB(158, 206, 222),
            saturation = -0.04,
            contrast = 0.04,
            brightness = -0.02,
        },
        bloom = { intensity = 0.90, size = 22, threshold = 1.00 },
    },
    {
        id = "Rim", -- §3.1/§3.3: the transition — colder, hazier, the visibility starts collapsing
        zone = "Rim",
        depthStuds = 110,
        ambient = Color3.fromRGB(26, 46, 60),
        outdoorAmbient = Color3.fromRGB(34, 54, 68),
        brightness = 0.80,
        exposureCompensation = -0.20,
        environmentDiffuseScale = 0.60,
        environmentSpecularScale = 0.70,
        atmosphere = {
            density = 0.52,
            haze = 0.95,
            color = Color3.fromRGB(18, 36, 50),
            decay = Color3.fromRGB(16, 32, 44),
            glare = 0.06,
            offset = 0.20,
        },
        grade = {
            tint = Color3.fromRGB(132, 176, 202),
            saturation = -0.16,
            contrast = 0.06,
            brightness = -0.03,
        },
        bloom = { intensity = 0.85, size = 20, threshold = 0.95 },
    },
    {
        -- §8.1 "at depth" verbatim: Ambient RGB(18,30,42), Brightness 0.6, saturation -0.25,
        -- Atmosphere.Density 0.55, TintColor RGB(120,170,200).
        id = "Shelf", -- §3.1 ambience: "Near-black, cold blue, bioluminescence only"
        zone = "Shelf",
        depthStuds = 175,
        ambient = Color3.fromRGB(18, 30, 42),
        outdoorAmbient = Color3.fromRGB(22, 34, 46),
        brightness = 0.60,
        exposureCompensation = -0.30,
        environmentDiffuseScale = 0.35,
        environmentSpecularScale = 0.50,
        atmosphere = {
            density = 0.55,
            haze = 0.75,
            color = Color3.fromRGB(8, 18, 28),
            decay = Color3.fromRGB(8, 16, 24),
            glare = 0.0,
            offset = 0.25,
        },
        grade = {
            tint = Color3.fromRGB(120, 170, 200),
            saturation = -0.25,
            contrast = 0.08,
            brightness = -0.04,
        },
        -- Bloom is *up* in the dark on purpose: §8.6 says the Shelf is lit by bioluminescence, so
        -- the only bright things on screen must bleed a little. It is the cheapest way to make the
        -- eel lures and the vent rims read as light sources rather than as coloured boxes.
        bloom = { intensity = 1.00, size = 18, threshold = 0.85 },
    },
    {
        id = "Abyss", -- §3.4 S6 (chasm floor, Y -215) / §7 ("the black, unlit water below")
        zone = "Shelf",
        depthStuds = 230,
        ambient = Color3.fromRGB(10, 18, 26),
        outdoorAmbient = Color3.fromRGB(12, 20, 28),
        brightness = 0.48,
        exposureCompensation = -0.42,
        environmentDiffuseScale = 0.25,
        environmentSpecularScale = 0.40,
        atmosphere = {
            density = 0.62,
            haze = 0.60,
            color = Color3.fromRGB(4, 10, 18),
            decay = Color3.fromRGB(4, 8, 14),
            glare = 0.0,
            offset = 0.30,
        },
        grade = {
            tint = Color3.fromRGB(104, 152, 190),
            saturation = -0.34,
            contrast = 0.10,
            brightness = -0.06,
        },
        bloom = { intensity = 1.05, size = 16, threshold = 0.80 },
    },
}

-- §3.0 + §3.1: the water itself. Terrain water only; these five properties are its whole look.
-- Teal and only lightly hazed, because §4.2 sells fish by *silhouette* — water the player cannot
-- see through would hide the very thing the game is about.
--
-- MIRRORED IN default.project.json (Rojo cannot read Luau, and the place file has to look like
-- water in Studio's viewport before a single script has run). Change both together — the runtime
-- value here, the place-file baseline there.
LightingConfig.Water = {
    color = Color3.fromRGB(58, 132, 148), -- surface water colour, reflected straight back at you
    transparency = 0.35, -- 0.35 = clear enough to hold a fish silhouette at 25 studs (CastRange)
    reflectance = 0.18, -- a little sky on the surface, not a mirror
    waveSize = 0.12, -- studs of swell; small, or the surface reads as a storm
    waveSpeed = 12, -- studs/s the swell travels
}

-- §8.3: "Sun rays only 0-60 studs ... fade to zero by 60 studs and are fully gone in the Shelf."
-- Five shafts (§3.2 L8 names five), built as thin translucent Neon parts — no meshes, no textures.
-- The fade is per-client: the shafts hold full strength at the surface, are invisible from 60
-- studs down (LightingConfig.SunShafts.fadeEndStuds), and are gone entirely in the Shelf, whose
-- darkness §8.3 calls "the Shelf's best asset".
LightingConfig.SunShafts = {
    count = 5,
    aboveWaterAlpha = 0.35, -- seen from the dock: present, not solid
    fadeStartStuds = 0, -- full strength at the surface
    fadeEndStuds = 60, -- §8.3: zero by here
    -- The shafts brighten over the first stretch of the descent (you are inside them) and then die.
    -- Without this the shafts would be strongest at the exact moment the camera is clamped to the
    -- surface, which reads as a wall of light rather than as a shaft: 0.35 at Y 0, 1.0 at 20 studs,
    -- 0 at 60. Modules/Atmosphere.SunShaftAlpha is that curve, and it is continuous at every point.
    peakStuds = 20,
    size = Vector3.new(9, 60, 9), -- 60 studs tall = the §8.3 0 -> -60 range
    color = Color3.fromRGB(196, 232, 240),
    material = "Neon",
    -- Above the waterline the shafts would float in the sky, so they are dropped this far below
    -- the camera's own depth before they show at all (they read as water columns, not pillars).
    startY = 0,
    -- Deterministic placement inside the Shallows (§3.0 build zone): hand-placed, never rolled, so
    -- the nth build is the 1st build.
    placements = {
        { x = -96, z = -44, yaw = 14, pitch = 9 },
        { x = -34, z = 96, yaw = -8, pitch = 7 },
        { x = 12, z = -108, yaw = 4, pitch = 11 },
        { x = 74, z = 22, yaw = -17, pitch = 8 },
        { x = 148, z = -66, yaw = 21, pitch = 6 },
    },
    -- Per-client fade rate; the shafts are dimmed through LocalTransparencyModifier (client-only),
    -- so no replication cost is paid per frame for an effect only one screen can see.
    fadeLerpPerSecond = 3.0,
}

-- §8.8: "the air alarm ... a red vignette creeping in from the screen edges ... impossible to
-- miss". The thresholds are DiveConfig's (AirAlarmSeconds / AirFastPulseSeconds) — the shapes and
-- colours are here. Applied as a post-process grade on the client, NOT as HUD chrome: the UI/UX
-- pass owns the HUD layout, this owns the screen.
LightingConfig.Oxygen = {
    -- Strength ramps 0 -> 1 between DiveConfig.AirAlarmSeconds and DiveConfig.AirFastPulseSeconds.
    tint = Color3.fromRGB(255, 108, 96), -- the blood-red wash
    maxSaturation = -0.38, -- colour drains out of the world first...
    minBrightness = -0.10, -- ...then the picture darkens
    maxBlur = 6, -- tunnel vision at the end (BlurEffect.Size, 0 = off)
    -- The pulse: slow breathing at the alarm, fast beating at fastPulse (DiveConfig's numbers).
    pulseAmplitude = 0.35, -- fraction of the strength that breathes
    pulseSlowSeconds = 1.0,
    pulseFastSeconds = 0.25, -- §8.8 "accelerating to a fast pulse"
    -- Nothing here may cover the tension track (§8.8): these are post-process values, so they
    -- tint the whole frame and never occlude the mini-game.
}

-- §8.1: the underwater grade. Owned by DiveService (it is the service that knows when the camera
-- crossed Y 0) and cross-faded over LightingConfig.FadeSeconds. The numbers are §8.1's.
LightingConfig.UnderwaterGrade = {
    name = "DeepTideUnderwater", -- the ColorCorrectionEffect DiveService parents to the Head
    tint = Color3.fromRGB(120, 170, 200), -- §8.1
    saturation = -0.25, -- §8.1
    contrast = 0.15,
    brightness = -0.05,
    above = { -- what the same effect reads above water before it fades out
        tint = Color3.fromRGB(255, 255, 255),
        saturation = 0.0,
        contrast = 0.0,
        brightness = 0.0,
    },
}

-- Names of the instances this system owns, so a restyle can find them and a rebuild can replace
-- them without hunting through the tree.
LightingConfig.InstanceNames = {
    Atmosphere = "DeepTideAtmosphere",
    Bloom = "DeepTideBloom",
    Grade = "DeepTideGrade",
    OxygenGrade = "DeepTideOxygen",
    OxygenBlur = "DeepTideOxygenBlur",
}

-- The stated budget for everything this system adds to the place. Asserted by
-- tools/worldtest/visual_harness.luau against the real build, not eyeballed.
LightingConfig.Budget = {
    Lights = 48, -- PointLights the whole world carries (WorldService 15 + VisualService + fish)
    Emitters = 24, -- ParticleEmitters the world carries, at low rates
    VisualParts = 32, -- parts that exist only to be looked at (sun shafts, bioluminescent specks)
    ClientEmittersPerPlayer = 4, -- bubbles, splash, catch flash, snap flash (client-only)
    PostEffects = 4, -- Atmosphere + Bloom + Grade + the oxygen pair (5 instances, 4 kinds)
}

-- How often the client sampler runs. 10 Hz, not per frame: fog that steps 10 times a second is
-- indistinguishable from fog that steps 60 times a second (each step moves the fog end by well
-- under a stud), and the dive camera is the only thing driving it.
LightingConfig.SampleHz = 10

return LightingConfig
