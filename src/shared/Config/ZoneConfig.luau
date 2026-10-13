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

-- Seabed / base geology (§3.1 "Seabed" row of the volume summary). Parts are laid on a
-- column x row grid inside the zone footprint; `topY` is the surface the player swims over,
-- so a cell's centre is topY - thickness/2. WorldService builds exactly these cells.
ZoneConfig.Seabed = {
    Shallows = {
        parts = 24, -- §3.1: "24 sand Parts (80 x 4 x 75, grid 5 x 4) ... tops at Y -45"
        grid = { columns = 5, rows = 4 },
        cellSize = Vector3.new(80, 4, 75),
        topY = -45,
        -- §3.1: "sloping to -85 in a trench at the SE corner". The SE cell is replaced by
        -- `trenchSteps` descending sand slabs, so grid + trench still totals 24 parts.
        trenchCell = { column = 5, row = 4 },
        trenchTopY = -85,
        trenchSteps = 5,
        trenchSize = Vector3.new(70, 4, 60),
        material = Enum.Material.SmoothPlastic,
        color = Color3.fromRGB(196, 183, 148),
    },
    Shelf = {
        parts = 20, -- §3.1: "20 rock Parts, sloping from Y -150 at the lip down to -215"
        grid = { columns = 5, rows = 4 },
        cellSize = Vector3.new(80, 4, 75),
        topYs = { -150, -172, -194, -215 }, -- one per row, south (lip) -> north
        -- §3.1: "split by a central chasm" (ZoneConfig.Chasm). Those cells are not built;
        -- `aprons` rock slabs close the chasm's north and south ends instead, keeping 20.
        chasmSkipColumn = 3,
        chasmSkipRows = { 2, 3 },
        aprons = 2,
        material = Enum.Material.Slate,
        color = Color3.fromRGB(58, 66, 74),
    },
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
    -- The dock ramp meets the water at Z 8 (§3.2 L1), so the marker floats just above the
    -- ramp's water entry there (lead decision, 2026-10-13).
    DiveMarker = Vector3.new(0, 2.5, 8),
}

return ZoneConfig
