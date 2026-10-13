--!strict
--[[
    Deep Tide — ZoneConfig
    Source: GDD §3.0 (coordinates, water region, build zone), §3.1 (volume summary),
            §3.3 (The Rim / Rim Gate), §3.4 (zone footprints), §8.2 (fog formula),
            §9 (zone entry banner), Appendix C (depth bands).
    PURE DATA — the world's rules of space, shared by WorldService, DiveService and the blockout.

    Depth is reported as -Y at the player's head (§3.0), in studs, printed as "m" (GDD header).
]]

local ZoneConfig = {}

ZoneConfig.SeaLevelY = 0

-- Water fill region for Roblox Terrain (§3.0). Terrain holds water and nothing else.
ZoneConfig.WaterRegion = {
    minX = -240,
    maxX = 240,
    minZ = -180,
    maxZ = 620,
    topY = 0,
    bottomY = -230,
}

-- Nothing is placed outside this box (§3.0).
ZoneConfig.BuildZone = {
    minX = -220,
    maxX = 220,
    minZ = -160,
    maxZ = 560,
}

-- Vertical depth bands in studs, top -> bottom (Appendix C).
ZoneConfig.DepthBand = {
    Shallows = { top = 0, bottom = -85 },
    Rim = { top = -40, bottom = -175 },
    Shelf = { top = -100, bottom = -215 },
}

-- The two playable areas (§3.1).
ZoneConfig.Zones = {
    Shallows = {
        id = "Shallows",
        displayName = "THE SHALLOWS",
        footprint = { minX = -200, maxX = 200, minZ = -150, maxZ = 150 },
        depthBand = ZoneConfig.DepthBand.Shallows,
        requiredDepthRating = 90, -- Rubber Lungs
        species = { "SilverSardine", "SunsetGrouper", "ReefBass" },
        playtimeShare = 0.85,
    },
    Shelf = {
        id = "Shelf",
        displayName = "THE SHELF",
        footprint = { minX = -200, maxX = 200, minZ = 200, maxZ = 500 },
        depthBand = ZoneConfig.DepthBand.Shelf,
        requiredDepthRating = 240, -- Reinforced Tank
        species = { "LanternEel", "GhostRay" },
        playtimeShare = 0.15,
    },
}

-- The Rim: the gate between the two areas (§3.3).
ZoneConfig.Rim = {
    wall = {
        minX = -200,
        maxX = 200,
        minZ = 150,
        maxZ = 200,
        steps = 8,
        topY = -40,
        bottomY = -175,
    },
    gate = {
        id = "RimGate",
        minX = -25,
        maxX = 25,
        minZ = 150,
        maxZ = 200,
        width = 50,
        rampTopY = -50,
        rampBottomY = -120,
        pillarSize = Vector3.new(26, 90, 26),
    },
    current = {
        topY = -90,
        bottomY = -140,
        pushNorthStudsPerSecond = 30,
        visualOnly = true, -- §3.3: the hard gate is the DepthRating check (§5.4), never this
    },
    -- The rule this geometry exists to express:
    crossingRule = "DepthRating >= 240 (ZoneConfig.Zones.Shelf.requiredDepthRating); "
        .. "the notch is at X in [-25, 25], Z 150 -> 200 (GDD §3.3, §5.4).",
}

-- The Chasm: the deepest playable point of the slice and where the next update's
-- content sits (§3.4 S6, §7). Referenced by LandmarkConfig.
ZoneConfig.Chasm = {
    minX = -40,
    maxX = 40,
    minZ = 300,
    maxZ = 460,
    floorY = -215,
}

-- Fog is the depth gauge (§8.2): FogEnd = clamp(320 - 1.35 x depth, 45, 320).
ZoneConfig.Fog = {
    BaseDistance = 320,
    DepthCoefficient = 1.35,
    MinDistance = 45,
    StartFraction = 0.25,
    ShallowColor = Color3.fromRGB(90, 150, 170),
    DeepColor = Color3.fromRGB(6, 12, 20),
}

-- Presentation timings owned by the world (§3.0, §9).
ZoneConfig.ZoneEntryBannerSeconds = 3
ZoneConfig.UnderwaterFadeSeconds = 1.5

-- Where the world's interactive props stand (§3.2 L1). ProximityPrompts are wired by WorldService.
ZoneConfig.InteractionPoints = {
    PlayerSpawn = Vector3.new(0, 8, -20), -- standing on the dock, facing +Z (§1 step 1)
    RodRack = Vector3.new(12, 9, -10), -- "E — Take Rusty Rod"
    TideTrader = Vector3.new(-14, 9, -10), -- "E — Trade"
    -- DiveMarker: GDD §1 step 3 references a "DIVE HERE" marker but §3.2 gives no coordinate.
    -- The dock ramp meets the water at Z 8 (§3.2 L1); the blockout places the marker there.
}

return ZoneConfig
