--!strict
--[[
    Deep Tide — FishConfig
    Source: GDD §4.2 (species table), §4.1 (rarity ladder), §4.3 (behaviour specs),
            §4.5 (spawn behaviour), §5.5 (mini-game tuning), Appendix B (canonical field shape).

    PURE DATA. No logic, no derived values, no tuning number anywhere else in the codebase.

    Per species:
      value         Coins paid by SELL ALL (§6.2)
      depthBand     { shallow, deep } in studs — a species never spawns outside its band (§4.5)
      liveAtStart   live population at server start (Appendix C: 48/10/6/7/3 = 79)
      parts         primitives per fish (Appendix C: 1, Eel 2)
      mini          every input to the Tension mini-game (§5.3 / §5.5) — FishingService reads it
      behaviourCfg  every input to the behaviour state machine (§4.3) — FishService reads it
      strainMult by rarity lives in RarityConfig.StrainMult (§4.1) — §5.5's per-species column repeats it.
]]

local FishConfig = {}

-- Species ids in GDD table order (§4.2 rows 1-5).
FishConfig.Order = { "SilverSardine", "SunsetGrouper", "ReefBass", "LanternEel", "GhostRay" }

-- Sum of liveAtStart below (§4.5, Appendix C: 48 + 10 + 6 + 7 + 3 = 74).
-- (Was recorded as 79, which is the arithmetic slip in the GDD's own §4.5 line: 48+10+6+7+3 = 74,
--  and 74 fish + 7 Lantern Eel lures = the 81 fish Parts Appendix A quotes.)
FishConfig.TotalLiveAtServerStart = 74

-- §4.2's silhouette/colour read, as a budget. Every species carries a `visual` block (below) with
-- one `trim` part and an optional `light`; the totals are what the fish code will actually create,
-- because they are the sums of `liveAtStart` (48 + 10 + 6 + 7 + 3).
--   trim parts   = 74 (one per fish, parented to the body so it is destroyed with it)
--   trim lights  = 10 (7 Lantern Eel lures + 3 Ghost Ray edge lights — the two Shelf species only)
-- Counted by tools/worldtest/visual_harness.luau against the real spawn, and by
-- LightingConfig.Budget.Lights for the whole world's light total.
FishConfig.VisualBudget = {
    TrimParts = 74,
    TrimLights = 10,
}

-- Rules that apply to every species (§4.5).
FishConfig.SpawnRules = {
    RespawnSeconds = 15, -- a caught or despawned fish returns to its home node after 15 s
    MaxSpawnsPerBurst = 1, -- a spawner never spawns more than 1 fish per...
    SpawnBurstIntervalSeconds = 3, -- ...3 s (prevents a wall of fish appearing after a wipe)
    DespawnPlayerDistance = 400, -- despawns (without value) if further than 400 studs...
    DespawnAfterSeconds = 20, -- ...from any player for 20 s
    MovementHz = 20, -- server-authoritative repositioning rate; clients interpolate (§4.3)
    NeverShallowerThanStuds = 110, -- no Shelf fish can ever be found above 110 studs (§4.5)
    -- §4.3 is built from "random" values (anchor walks, orbit phases, scatter, jitter). They are
    -- all drawn from one seeded generator so a run is reproducible: the same seed spawns the same
    -- fish, swims the same paths and produces the same fights twice (tools/worldtest/fish_harness).
    RandomSeed = 20261013,
    -- A stalled frame (a server hitch, a Studio breakpoint) must not teleport every fish: the
    -- movement loop clamps a step to this many seconds before advancing anything.
    MaxStepSeconds = 0.25,
}

FishConfig.Species = {
    SilverSardine = {
        id = "SilverSardine",
        name = "Silver Sardine",
        rarity = "Common",
        value = 15,
        depthBand = { 5, 30 },
        zone = "Shallows",
        behaviour = "School",
        liveAtStart = 48, -- 8 schools x 6 fish (§4.5)
        parts = 1,
        size = Vector3.new(1.2, 0.5, 0.35),
        color = Color3.fromRGB(206, 212, 222),
        material = Enum.Material.Metal, -- §4.2 also asks for 0.2 "shininess" (Technical Artist)
        transparency = 0.15,
        visualCue = "Tiny bright dart, moves as a shimmering ribbon — the only fish brighter than the water.",
        -- §4.2's silhouette read, in numbers the fish code can build. `trim` is ONE extra part; it
        -- is parented to the body part, so it follows the fish and is destroyed with it. `offset` is
        -- body-local (+X is the long axis, +Y up), so a strip stays on top of the fish whatever way
        -- it is swimming.
        visual = {
            band = "Shallows",
            trim = {
                placement = "shimmer strip",
                size = Vector3.new(1.05, 0.06, 0.06),
                offset = Vector3.new(0, 0.28, 0),
                color = Color3.fromRGB(236, 242, 255),
                transparency = 0.35,
            },
            -- 48 of these — the most numerous fish in the world — so a per-fish PointLight is the one
            -- thing this species may never have (LightingConfig.Budget.Lights).
            light = nil,
        },
        mini = {
            zoneHalfWidth = 0.20,
            zoneHz = 0.25,
            zoneAmp = 0.18,
            fillRate = 20,
            requiredTension = 20,
            hookWindow = 0.50,
        },
        behaviourCfg = {
            count = 8, -- anchors, not fish
            perSchool = 6,
            anchorSpeed = 6,
            anchorRadius = 60,
            orbit = 6,
            pauseMin = 1,
            pauseMax = 3,
            fleeRadius = 8,
            fleeSpeed = 22,
            fleeTime = 3,
            reanchorMax = 80,
        },
    },

    SunsetGrouper = {
        id = "SunsetGrouper",
        name = "Sunset Grouper",
        rarity = "Common",
        value = 40,
        depthBand = { 15, 55 },
        zone = "Shallows",
        behaviour = "Patrol",
        liveAtStart = 10,
        parts = 1,
        size = Vector3.new(3.0, 1.6, 1.1),
        color = Color3.fromRGB(232, 140, 86),
        material = Enum.Material.SmoothPlastic,
        transparency = 0,
        visualCue = 'Chunky rounded brick, wide and slow, orange — reads as "fat and worth it".',
        visual = {
            band = "Shallows",
            trim = { -- a lateral band around the flanks: turns "orange box" into "that orange fish"
                placement = "flank band",
                size = Vector3.new(2.70, 0.16, 1.16),
                offset = Vector3.new(0, 0, 0),
                color = Color3.fromRGB(255, 190, 120),
                transparency = 0.40,
            },
            light = nil,
        },
        mini = {
            zoneHalfWidth = 0.17,
            zoneHz = 0.35,
            zoneAmp = 0.25,
            fillRate = 18,
            requiredTension = 35,
            hookWindow = 0.50,
        },
        behaviourCfg = {
            count = 10,
            waypoints = 3,
            radius = 40,
            speed = 8,
            turnEase = 0.4,
            bobAmplitude = 0.8,
            bobPeriod = 2,
            fleeRadius = 10,
            fleeSpeed = 18,
            fleeTime = 4,
            returnNodeDistance = 80,
        },
    },

    ReefBass = {
        id = "ReefBass",
        name = "Reef Bass",
        rarity = "Uncommon",
        value = 90,
        depthBand = { 30, 85 },
        zone = "Shallows",
        behaviour = "Flee",
        liveAtStart = 6,
        parts = 1,
        size = Vector3.new(3.5, 1.8, 1.2),
        color = Color3.fromRGB(86, 150, 125),
        material = Enum.Material.SmoothPlastic,
        transparency = 0,
        accent = { -- thin Neon dorsal strip (§4.2)
            color = Color3.fromRGB(150, 240, 200),
            placement = "dorsal strip",
        },
        visualCue = "Sleek olive torpedo with a glowing spine line; the one that runs — the first real chase.",
        -- §4.2's "thin Neon RGB(150,240,200) dorsal strip" — the cue the blockout never built, and
        -- the only thing that tells a Reef Bass from a dark shape at 60 studs in the Shallows.
        visual = {
            band = "Shallows",
            trim = {
                placement = "dorsal strip",
                size = Vector3.new(3.10, 0.10, 0.10),
                offset = Vector3.new(0, 0.95, 0),
                color = Color3.fromRGB(150, 240, 200),
                transparency = 0.20,
            },
            light = nil,
        },
        mini = {
            zoneHalfWidth = 0.13,
            zoneHz = 0.50,
            zoneAmp = 0.32,
            fillRate = 15,
            requiredTension = 60,
            hookWindow = 0.42,
        },
        behaviourCfg = {
            count = 6,
            radius = 45,
            speed = 4,
            startleRadius = 14,
            startleDelay = 0.35, -- the only reason it is catchable — do not remove (§4.3)
            fleeSpeed = 26,
            clearDistance = 40,
            driftTime = 5,
            diveRadius = 8,
        },
    },

    LanternEel = {
        id = "LanternEel",
        name = "Lantern Eel",
        rarity = "Rare",
        value = 260,
        depthBand = { 115, 175 },
        zone = "Shelf",
        behaviour = "Ambush",
        liveAtStart = 7, -- one eel per crevice den (§4.3, dens in SpawnConfig)
        parts = 2, -- body + lure (Appendix C)
        size = Vector3.new(6.0, 0.8, 0.8),
        color = Color3.fromRGB(40, 32, 58),
        material = Enum.Material.SmoothPlastic,
        transparency = 0,
        accent = {
            color = Color3.fromRGB(120, 255, 190),
            placement = "lure",
            lureSize = Vector3.new(0.9, 0.9, 0.9),
            dashColor = Color3.fromRGB(80, 200, 160),
            dashCount = 3,
        },
        visualCue = "A long dark ribbon with one floating green point of light — the light is the tell.",
        -- §4.2 says the body carries "3 Neon RGB(80,200,160) dashes". Three parts per eel is 21 parts
        -- for a read that one continuous back-line gives better at distance, so the dashes are a
        -- single thin back line here (stated as a deviation, not hidden). The lure is the real tell.
        visual = {
            band = "Shelf",
            trim = {
                placement = "back line",
                size = Vector3.new(5.40, 0.10, 0.12),
                offset = Vector3.new(0, 0.45, 0),
                color = Color3.fromRGB(80, 200, 160),
                transparency = 0.25,
            },
            -- §8.6: "Eel lures RGB(120,255,190) with PointLight Brightness 1.5 / Range 14". The lure
            -- itself is §4.2 geometry (the accent above); its light and the flame-like sway are here.
            light = {
                color = Color3.fromRGB(120, 255, 190),
                brightness = 1.5,
                range = 14,
                flickerAmplitude = 0.08, -- the lure breathes rather than glows steady
                flickerHz = 0.45,
            },
        },
        mini = {
            zoneHalfWidth = 0.09,
            zoneHz = 0.70,
            zoneAmp = 0.38,
            fillRate = 12,
            requiredTension = 110,
            hookWindow = 0.34,
        },
        behaviourCfg = {
            count = 7,
            lungeRadius = 9,
            lungeSpeed = 30,
            lungeTime = 1.5,
            recoverTime = 2.0,
            recoverSpeed = 2,
            maxRange = 20,
            idleProtrusion = 3,
            swayAmplitude = 1.2,
            swayPeriod = 1.8,
            lureBobAmplitude = 0.5,
            returnTime = 4,
        },
    },

    GhostRay = {
        id = "GhostRay",
        name = "Ghost Ray",
        rarity = "Epic",
        value = 600,
        depthBand = { 130, 210 },
        zone = "Shelf",
        behaviour = "Patrol",
        liveAtStart = 3,
        parts = 1,
        size = Vector3.new(8.0, 0.6, 7.0),
        color = Color3.fromRGB(212, 236, 255),
        material = Enum.Material.Neon, -- Appendix B; §4.2 describes it as glass-like at 0.55
        transparency = 0.55,
        accent = {
            color = Color3.fromRGB(160, 220, 255),
            placement = "wing-tip edge trim",
            transparency = 0.35,
        },
        visualCue = "A wide flat pale diamond that never flaps, only glides — crosses the vent glow.",
        -- §8.6: "Ghost Ray edge trim Neon RGB(160,220,255) at 0.35 transparency with a very slow
        -- PointLight flicker (10% amplitude, 0.3 Hz)". This is the fish the whole retention plan
        -- hangs on (§2), so it is the one species that is *always* slightly lit: the trim is what a
        -- player sees first, from the dock-side edge of the Shelf, before they can ever catch it.
        visual = {
            band = "Shelf",
            trim = {
                placement = "wing-tip edge trim",
                size = Vector3.new(8.20, 0.12, 0.50),
                offset = Vector3.new(0, 0, 3.50),
                color = Color3.fromRGB(160, 220, 255),
                transparency = 0.35,
            },
            light = {
                color = Color3.fromRGB(160, 220, 255),
                brightness = 0.9,
                range = 18,
                flickerAmplitude = 0.10, -- §8.6
                flickerHz = 0.30, -- §8.6
            },
        },
        mini = {
            zoneHalfWidth = 0.06,
            zoneHz = 0.90,
            zoneAmp = 0.42,
            fillRate = 9,
            requiredTension = 160,
            hookWindow = 0.26,
        },
        behaviourCfg = {
            count = 3,
            waypoints = 5,
            radius = 90, -- half of the 180-stud loop box (§4.3)
            loopBox = Vector3.new(180, 30, 120),
            legTime = 14,
            easing = "Quad",
            bobAmplitude = 2,
            bobHz = 0.15,
            speed = 12,
            fleeRadius = 18,
            fleeSpeed = 22,
            fleeTime = 5,
        },
    },
}

return FishConfig
