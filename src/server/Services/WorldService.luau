--!strict
--[[
    WorldService — builds the playable world at server start, from config data only.
    Source: GDD §3.0 (coordinates, water, build zone), §3.1 (volumes + seabed),
            §3.2 (THE SHALLOWS L1-L9), §3.3 (THE RIM R1-R3), §3.4 (THE SHELF S1-S6),
            §3.4/§7 (the abyss drop and the threshold read), §4.6 (spawn coordinates),
            §1 steps 1-3 and 8 (spawn, rod rack, dive marker, Tide Trader), §9 (zone banners),
            Appendix A (naming rule, folder tree, primitives only).

    Rules this file obeys
      * Config is the source of truth. Landmark anchors and part counts come from
        LandmarkConfig, the seabed grids from ZoneConfig.Seabed, the spawn coordinates from
        SpawnConfig. This file holds only the per-piece *build recipe* (sizes, colours, tilts)
        that the GDD prints in prose — no gameplay number lives here.
      * Deterministic. No math.random: every "random" value in the GDD (yaw, tilt, scatter)
        is a pure hash of the part index, so every server and every re-run builds the same world.
      * Idempotent. Build() clears Workspace.DeepTide.World, .Water and .Spawns first, so a
        server restart or a second call rebuilds instead of duplicating. It never touches
        Workspace.DeepTide.Fish — that folder belongs to FishService.
      * Anchored. Every part is anchored; nothing here can fall or be pushed.
      * No fish, no animation, no prompt behaviour: this service creates the spawn *anchors*
        and the ProximityPrompt *instances*; connecting them to verbs is FishingService /
        ShopService work (their TODOs).
      * Nothing is placed outside ZoneConfig.BuildZone (§3.0) except the water volume itself.

    Known GDD deviations, all commented at the point they happen:
      * §3.2 L1's "-12 deg ramp" (see RAMP_DEGREES) — the angle and the Z 8 water entry cannot
        both hold; the water entry wins (the DIVE HERE marker sits there).
      * §3.2 L2's "Cone primitives" and §3.4 S4's cones — Roblox has no cone Part and
        Appendix A forbids SpecialMesh, so tapered cylinder stacks stand in.
      * §3.4 S2's "3-stud Neon speck" — S2's budget is 7 (the dens), so the speck is a
        PointLight on each den instead of an eighth part.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Knit = require(ReplicatedStorage.Packages.Knit)

local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)
local LandmarkConfig = require(ReplicatedStorage.DeepTide.Config.LandmarkConfig)
local SpawnConfig = require(ReplicatedStorage.DeepTide.Config.SpawnConfig)

local WorldService = Knit.CreateService {
    Name = "WorldService",
    Client = {},
}

-- ============================================================================
-- Layout types (see Build() for how a spec becomes an Instance)
-- ============================================================================

type PartSpec = {
    name: string,
    parent: string, -- folder path under Workspace.DeepTide, e.g. "World/Shallows/L1"
    size: Vector3,
    cf: CFrame,
    class: string?,
    shape: Enum.PartType?,
    axis: string?, -- "Y" for a standing cylinder, "X" for one lying on its side
    material: Enum.Material?,
    color: Color3?,
    transparency: number?,
    decor: boolean?, -- decorative: no collide, no query, no shadow
    collide: boolean?,
    query: boolean?,
    outsideBuildZone: boolean?, -- volumes that define space rather than occupy it
    props: { [string]: any }?, -- extra instance properties (Duration, Neutral, ...)
    attributes: { [string]: any }?,
    light: { [string]: any }?, -- PointLight on this part
    prompt: { [string]: any }?, -- ProximityPrompt on this part (Appendix A prompt host)
    billboard: { [string]: any }?, -- text sign, e.g. "DIVE HERE" (§1 step 3)
}

type AnchorSpec = {
    name: string,
    host: string, -- name of the invisible host BasePart the Attachment hangs off
    hostParent: string, -- folder holding that host part
    position: Vector3, -- relative to the host
    attributes: { [string]: any },
}

type Layout = {
    folders: { string },
    parts: { PartSpec },
    anchors: { AnchorSpec },
    water: { size: Vector3 },
}

-- ============================================================================
-- Names and constants (geometry only; every gameplay number lives in Config/)
-- ============================================================================

local ROOT_NAME = "DeepTide"
local WORLD_FOLDER = "World"
local WATER_FOLDER = "Water"
local SPAWNS_FOLDER = "Spawns"

local GOLDEN_ANGLE = 137.508

-- Palette (§3.2-§3.4 name most of these inline; the rest read off the zone descriptions).
local DOCK_WOOD = Color3.fromRGB(122, 88, 62)
local DOCK_WOOD_DARK = Color3.fromRGB(96, 68, 48)
local SAND = Color3.fromRGB(196, 183, 148)
local REEF_ROCK = Color3.fromRGB(96, 104, 116)
local RIM_ROCK = Color3.fromRGB(58, 66, 74) -- §3.3: deliberately desaturated, "not-reef"
local SHELF_ROCK = Color3.fromRGB(70, 76, 84)
local SHELF_ROCK_DARK = Color3.fromRGB(44, 52, 62)
local DEEP_VOID = Color3.fromRGB(8, 10, 14)
local CORAL_PINK = Color3.fromRGB(214, 96, 120)
local CORAL_TEAL = Color3.fromRGB(96, 186, 168)
local KELP_GREEN = Color3.fromRGB(38, 96, 70)
local WARM_NEON = Color3.fromRGB(255, 214, 140)
local GATE_NEON = Color3.fromRGB(120, 190, 210)
local EEL_NEON = Color3.fromRGB(120, 255, 190)
local VENT_NEON = Color3.fromRGB(255, 132, 60)
local MINERAL_NEON = Color3.fromRGB(150, 190, 220)

-- The dock ramp. §3.2 L1 prints "ramp 16 x 1 x 30 rotated -12 deg down to water at Z 8",
-- but the deck's north lip is at Z 5 (deck 30 deep, centred Z -10) and the water is at Y 0,
-- so a -12 deg ramp cannot reach the water at Z 8 — it would need ~33 studs of Z to fall 7.
-- The builder keeps the GDD's Z 8 water entry (the lead's DIVE HERE decision) and takes the
-- only geometry that satisfies it: a steeper dive ramp hanging off the deck lip.
local RAMP_DEGREES = 62
local RAMP_LENGTH = 18
local RAMP_WIDTH = 16
local DECK_TOP_Y = 7
local DECK_LIP_Z = 5

-- Per-build state (module locals, so nothing is bolted onto the Knit service table).
local lastReport: { [string]: any }? = nil
local promptById: { [string]: ProximityPrompt } = {}

-- ============================================================================
-- Small pure helpers
-- ============================================================================

-- Deterministic "random" in [0,1): a build must be reproducible, so the GDD's random yaw /
-- tilt / scatter values are hashed from the part index instead of rolled.
local function noise(index: number, salt: number): number
    local x = math.sin(index * 12.9898 + salt * 78.233) * 43758.5453
    return x - math.floor(x)
end

local function lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

-- A part resting on a surface at `topY`, with `embed` of its height sunk into it.
local function restingY(topY: number, height: number, embed: number?): number
    return topY + height / 2 - height * (embed or 0.35)
end

local function zonePath(zoneId: string, landmarkId: string): string
    return ("%s/%s/%s"):format(WORLD_FOLDER, zoneId, landmarkId)
end

local function basePath(zoneId: string): string
    return ("%s/%s/Base"):format(WORLD_FOLDER, zoneId)
end

local function landmarkById(id: string): { [string]: any }
    for _, landmark in LandmarkConfig.Landmarks do
        if landmark.id == id then
            return landmark
        end
    end
    return { id = id, name = id, zone = "Shallows", parts = 0 }
end

local function promptHostById(id: string): { [string]: any }?
    for _, host in LandmarkConfig.PromptHosts do
        if host.id == id then
            return host
        end
    end
    return nil
end

-- One part. `opts.cf` wins over position/yaw/pitch/roll.
local function add(parts: { PartSpec }, parent: string, name: string, position: Vector3, size: Vector3, opts: { [string]: any }?)
    opts = opts or {}
    local cf = opts.cf :: CFrame?
    if cf == nil then
        cf = CFrame.new(position)
            * CFrame.Angles(
                math.rad((opts.pitch :: number?) or 0),
                math.rad((opts.yaw :: number?) or 0),
                math.rad((opts.roll :: number?) or 0)
            )
    end

    table.insert(parts, {
        name = name,
        parent = parent,
        size = size,
        cf = cf :: CFrame,
        class = (opts.class :: string?) or "Part",
        shape = opts.shape :: Enum.PartType?,
        axis = opts.axis :: string?,
        material = (opts.material :: Enum.Material?) or Enum.Material.Concrete,
        color = (opts.color :: Color3?) or REEF_ROCK,
        transparency = (opts.transparency :: number?) or 0,
        decor = (opts.decor :: boolean?) or false,
        collide = opts.collide :: boolean?,
        query = opts.query :: boolean?,
        outsideBuildZone = (opts.outsideBuildZone :: boolean?) or false,
        props = opts.props :: { [string]: any }?,
        attributes = opts.attributes :: { [string]: any }?,
        light = opts.light :: { [string]: any }?,
        prompt = opts.prompt :: { [string]: any }?,
        billboard = opts.billboard :: { [string]: any }?,
    })
end

-- A cylinder. Roblox has no cone Part and Appendix A forbids SpecialMesh, so every cone the
-- GDD asks for is built as a tapered stack of cylinders (see L2 and S4).
local function cyl(
    parts: { PartSpec },
    parent: string,
    name: string,
    position: Vector3,
    height: number,
    diameter: number,
    opts: { [string]: any }?
)
    opts = opts or {}
    opts.size = Vector3.new(height, diameter, diameter)
    opts.shape = Enum.PartType.Cylinder
    if ((opts.axis :: string?) or "Y") == "Y" then
        opts.cf = ((opts.cf :: CFrame?) or CFrame.new(position)) * CFrame.Angles(0, 0, math.rad(90))
    end
    add(parts, parent, name, position, opts.size :: Vector3, opts)
end

-- ============================================================================
-- Base geology (§3.1) — the seabeds the zones stand on
-- ============================================================================

local function buildShallowsSeabed(parts: { PartSpec })
    local spec = ZoneConfig.Seabed.Shallows
    local footprint = ZoneConfig.Zones.Shallows.footprint
    local parent = basePath("Shallows")

    local cell = spec.cellSize
    local originX = (footprint.minX + footprint.maxX) / 2 - (spec.grid.columns * cell.X) / 2
    local originZ = (footprint.minZ + footprint.maxZ) / 2 - (spec.grid.rows * cell.Z) / 2
    local topY = spec.topY

    for column = 1, spec.grid.columns do
        for row = 1, spec.grid.rows do
            local x = originX + (column - 0.5) * cell.X
            local z = originZ + (row - 0.5) * cell.Z

            if column == spec.trenchCell.column and row == spec.trenchCell.row then
                -- The SE corner cell is the trench: descending sand steps whose deepest slab
                -- sits at trenchTopY (-85), so the flats visibly fall away (§3.1).
                local steps = spec.trenchSteps
                local stepDepth = cell.Z / steps
                for step = 1, steps do
                    local stepTop = lerp(topY, spec.trenchTopY, step / steps)
                    local stepZ = z - cell.Z / 2 + (step - 0.5) * stepDepth
                    add(
                        parts,
                        parent,
                        ("Base_Trench_Step_%d"):format(step),
                        Vector3.new(x, stepTop - cell.Y / 2, stepZ),
                        Vector3.new(spec.trenchSize.X, cell.Y, stepDepth),
                        { material = spec.material, color = spec.color }
                    )
                end
            else
                add(
                    parts,
                    parent,
                    ("Base_Seabed_%d_%d"):format(column, row),
                    Vector3.new(x, topY - cell.Y / 2, z),
                    cell,
                    { material = spec.material, color = spec.color }
                )
            end
        end
    end
end

local function buildShelfSeabed(parts: { PartSpec })
    local spec = ZoneConfig.Seabed.Shelf
    local footprint = ZoneConfig.Zones.Shelf.footprint
    local chasm = ZoneConfig.Chasm
    local parent = basePath("Shelf")

    local cell = spec.cellSize
    local originX = (footprint.minX + footprint.maxX) / 2 - (spec.grid.columns * cell.X) / 2
    local originZ = (footprint.minZ + footprint.maxZ) / 2 - (spec.grid.rows * cell.Z) / 2

    for column = 1, spec.grid.columns do
        for row = 1, spec.grid.rows do
            local isChasm = column == spec.chasmSkipColumn
            if isChasm then
                local inSkippedRow = false
                for _, skipRow in spec.chasmSkipRows do
                    if row == skipRow then
                        inSkippedRow = true
                    end
                end
                isChasm = inSkippedRow
            end

            if not isChasm then
                local topY = spec.topYs[row]
                local x = originX + (column - 0.5) * cell.X
                local z = originZ + (row - 0.5) * cell.Z
                add(parts, parent, ("Base_Shelf_%d_%d"):format(column, row), Vector3.new(x, topY - cell.Y / 2, z), cell, {
                    material = spec.material,
                    color = SHELF_ROCK,
                })
            end
        end
    end

    -- The two carved cells leave a gap either side of the chasm (S6 owns the rift itself).
    -- `aprons` slabs close them, so the shelf still reads as 20 rock parts with no hole into
    -- the void: one at the chasm's south mouth, one across its northern end.
    local centreX = (footprint.minX + footprint.maxX) / 2
    add(
        parts,
        parent,
        "Base_Shelf_Apron_South",
        Vector3.new(centreX, spec.topYs[2] - cell.Y / 2 - 1, chasm.minZ - 12),
        Vector3.new(cell.X, cell.Y, 24),
        { material = spec.material, color = SHELF_ROCK }
    )
    add(
        parts,
        parent,
        "Base_Shelf_Apron_North",
        Vector3.new(centreX, spec.topYs[4] - cell.Y / 2 + 9, chasm.maxZ + 40),
        Vector3.new(cell.X, cell.Y, 80),
        { material = spec.material, color = SHELF_ROCK }
    )
end

-- ============================================================================
-- THE SHALLOWS (§3.2)
-- ============================================================================

local function buildL1Dock(parts: { PartSpec })
    local parent = zonePath("Shallows", "L1")

    add(parts, parent, "L1_Deck", Vector3.new(0, 6, -10), Vector3.new(60, 2, 30), {
        material = Enum.Material.Wood,
        color = DOCK_WOOD,
    })

    local pylons = {
        { "L1_Pylon_NE", Vector3.new(28.5, -3, 3.5) },
        { "L1_Pylon_NW", Vector3.new(-28.5, -3, 3.5) },
        { "L1_Pylon_SE", Vector3.new(28.5, -3, -23.5) },
        { "L1_Pylon_SW", Vector3.new(-28.5, -3, -23.5) },
    }
    for _, pylon in pylons do
        add(parts, parent, pylon[1], pylon[2], Vector3.new(3, 20, 3), {
            material = Enum.Material.Wood,
            color = DOCK_WOOD_DARK,
        })
    end

    -- Dive ramp: its top surface starts at the deck's north lip (0, 7, 5) and crosses the
    -- water surface at Z ~= 8.7, continuing ~9 studs below it — a slipway, not a walkway.
    local pitch = math.rad(RAMP_DEGREES)
    local slope = Vector3.new(0, -math.sin(pitch), math.cos(pitch))
    local normal = Vector3.new(0, math.cos(pitch), math.sin(pitch))
    local lip = Vector3.new(0, DECK_TOP_Y, DECK_LIP_Z)
    local rampCentre = lip + slope * (RAMP_LENGTH / 2) - normal * 0.5
    add(parts, parent, "L1_Ramp", rampCentre, Vector3.new(RAMP_WIDTH, 1, RAMP_LENGTH), {
        pitch = RAMP_DEGREES,
        material = Enum.Material.Wood,
        color = DOCK_WOOD,
    })

    add(parts, parent, "L1_LightTower", Vector3.new(0, 20, -22), Vector3.new(4, 24, 4), {
        material = Enum.Material.Wood,
        color = DOCK_WOOD_DARK,
    })
    add(parts, parent, "L1_Beacon", Vector3.new(0, 32, -22), Vector3.new(2, 2, 2), {
        material = Enum.Material.Neon,
        color = WARM_NEON,
        decor = true,
        light = { color = WARM_NEON, brightness = 2, range = 60 },
    })
end

local function buildL2CoralSpire(parts: { PartSpec })
    local parent = zonePath("Shallows", "L2")
    local foot = Vector3.new(-120, -45, 70) -- seabed top under the spire (§3.2 position)
    local seabedTop = foot.Y

    add(parts, parent, "L2_BaseRock", Vector3.new(foot.X, restingY(seabedTop, 12, 0.55), foot.Z), Vector3.new(40, 12, 40), {
        material = Enum.Material.Slate,
        color = REEF_ROCK,
    })

    -- §3.2: "a stack of 7 Cone primitives, heights 24-60, base diameter 40 -> 12". At the
    -- printed heights the stack would stand above the waterline, so the builder keeps the
    -- printed taper (40 -> 10, alternating colours) and spans the seabed to the surface.
    local segments = {
        { diameter = 40, height = 12 },
        { diameter = 34, height = 9 },
        { diameter = 28, height = 7 },
        { diameter = 23, height = 6 },
        { diameter = 18, height = 5 },
        { diameter = 14, height = 3.5 },
        { diameter = 10, height = 2.5 },
    }
    local y = seabedTop
    for index, segment in segments do
        local color = if index % 2 == 1 then CORAL_PINK else CORAL_TEAL
        cyl(
            parts,
            parent,
            ("L2_Spire_%d"):format(index),
            Vector3.new(foot.X, y + segment.height / 2, foot.Z),
            segment.height,
            segment.diameter,
            { material = Enum.Material.SmoothPlastic, color = color }
        )
        y += segment.height
    end

    -- A torus is not a primitive, so the Neon ring at Y -8 is a thin translucent disc.
    add(parts, parent, "L2_Ring", Vector3.new(foot.X, -8, foot.Z), Vector3.new(1, 24, 24), {
        shape = Enum.PartType.Cylinder,
        axis = "Y",
        material = Enum.Material.Neon,
        color = GATE_NEON,
        transparency = 0.35,
        decor = true,
    })
end

local function buildL3Trawler(parts: { PartSpec })
    local parent = zonePath("Shallows", "L3")
    local hull = Vector3.new(140, -58, -60)

    add(parts, parent, "L3_Hull", hull, Vector3.new(46, 10, 14), {
        roll = 12, -- §3.2: hull rotated 12 deg on Z
        material = Enum.Material.Metal,
        color = Color3.fromRGB(84, 74, 62),
    })
    add(parts, parent, "L3_Bow", Vector3.new(112, -58, -60), Vector3.new(12, 10, 14), {
        class = "WedgePart",
        yaw = 180,
        material = Enum.Material.Metal,
        color = Color3.fromRGB(74, 66, 56),
    })
    add(parts, parent, "L3_Superstructure", Vector3.new(146, -49, -60), Vector3.new(12, 8, 10), {
        material = Enum.Material.Metal,
        color = Color3.fromRGB(70, 62, 52),
    })
    cyl(parts, parent, "L3_Funnel", Vector3.new(152, -42, -60), 12, 6, {
        pitch = 8,
        material = Enum.Material.Metal,
        color = Color3.fromRGB(60, 52, 46),
    })
    cyl(parts, parent, "L3_Mast", Vector3.new(140, -36, -60), 34, 1, {
        pitch = 38, -- §3.2: broken mast tilted 38 deg
        material = Enum.Material.Metal,
        color = Color3.fromRGB(66, 60, 52),
    })

    for index = 1, 7 do
        local size = 2 + 3 * noise(index, 3)
        local angle = index * GOLDEN_ANGLE
        local radius = 12 + 18 * noise(index, 4)
        add(
            parts,
            parent,
            ("L3_Debris_%d"):format(index),
            Vector3.new(
                hull.X + math.cos(math.rad(angle)) * radius,
                hull.Y + 6 * noise(index, 5),
                hull.Z + math.sin(math.rad(angle)) * radius
            ),
            Vector3.new(size, size, size),
            { material = Enum.Material.Metal, color = Color3.fromRGB(78, 70, 60), yaw = angle }
        )
    end
end

local function buildL4Kelp(parts: { PartSpec })
    local parent = zonePath("Shallows", "L4")
    local centre = Vector3.new(-40, -45, -100)
    local seabedTop = centre.Y

    for index = 1, 30 do
        local angle = index * GOLDEN_ANGLE
        local radius = 10 + 45 * math.sqrt(index / 30)
        local height = 20 + 35 * noise(index, 7)
        cyl(
            parts,
            parent,
            ("L4_Frond_%d"):format(index),
            Vector3.new(
                centre.X + math.cos(math.rad(angle)) * radius,
                seabedTop + height / 2,
                centre.Z + math.sin(math.rad(angle)) * radius
            ),
            height,
            1.2,
            {
                pitch = -14 + 28 * noise(index, 8), -- §3.2: tilted randomly +/- 14 deg
                yaw = 360 * noise(index, 9),
                material = Enum.Material.Neon,
                color = KELP_GREEN,
                transparency = 0.35,
                decor = true,
            }
        )
    end

    for index = 1, 4 do
        local angle = index * GOLDEN_ANGLE + 40
        local size = 8 + 8 * noise(index, 11)
        add(
            parts,
            parent,
            ("L4_Rock_%d"):format(index),
            Vector3.new(
                centre.X + math.cos(math.rad(angle)) * 30,
                restingY(seabedTop, size),
                centre.Z + math.sin(math.rad(angle)) * 30
            ),
            Vector3.new(size, size, size),
            { material = Enum.Material.Slate, color = REEF_ROCK, yaw = angle }
        )
    end
end

local function buildL5DeepHole(parts: { PartSpec })
    local parent = zonePath("Shallows", "L5")
    local hole = Vector3.new(0, -85, 90)
    local mouthTop = -45 -- the sand surface the mouth is cut into
    local mouth = Vector3.new(60, 22, 40)

    -- The mouth is the dark volume the sand opens into (§3.2: "view straight down into
    -- unlit water"). It does not collide or answer queries; the sand around it does.
    add(
        parts,
        parent,
        "L5_Mouth",
        Vector3.new(hole.X, mouthTop - mouth.Y / 2 + 0.02, hole.Z),
        mouth,
        { material = Enum.Material.SmoothPlastic, color = DEEP_VOID, transparency = 0.15, collide = false, query = false }
    )

    local lips = {
        { "L5_Lip_W", Vector3.new(-32, -42, 90), Vector3.new(14, 6, 44) },
        { "L5_Lip_E", Vector3.new(32, -42, 90), Vector3.new(14, 6, 44) },
        { "L5_Lip_N", Vector3.new(0, -42, 66), Vector3.new(44, 6, 14) },
        { "L5_Lip_S", Vector3.new(0, -42, 114), Vector3.new(44, 6, 14) },
        { "L5_Lip_Overhang", Vector3.new(-20, -40, 76), Vector3.new(20, 8, 20) },
    }
    for index, lip in lips do
        add(parts, parent, lip[1], lip[2], lip[3], {
            material = Enum.Material.Slate,
            color = REEF_ROCK,
            yaw = 12 * noise(index, 13),
        })
    end
end

local function buildL6SandChannels(parts: { PartSpec })
    local parent = zonePath("Shallows", "L6")
    local seabedTop = ZoneConfig.Seabed.Shallows.topY

    for index = 1, 12 do
        local x = -172 + (index - 1) * 31 -- 90 wide: keeps every ridge inside §3.0's X +/220
        local z = -140 + 18 * ((index * 7) % 11)
        add(parts, parent, ("L6_Ridge_%d"):format(index), Vector3.new(x, seabedTop + 1.5, z), Vector3.new(90, 3, 16), {
            -- §3.2: "at random yaw" — hashed, so every build is still identical.
            yaw = 180 * noise(index, 17),
            material = Enum.Material.Sand,
            color = SAND,
        })
    end
end

local function buildL7FishRocks(parts: { PartSpec })
    local parent = zonePath("Shallows", "L7")
    local centre = Vector3.new(-160, -45, 30)
    local seabedTop = centre.Y

    for index = 1, 8 do
        local angle = index * GOLDEN_ANGLE
        local radius = 8 + 22 * math.sqrt(index / 8)
        local size = 14 + 16 * noise(index, 19)
        add(
            parts,
            parent,
            ("L7_Rock_%d"):format(index),
            Vector3.new(
                centre.X + math.cos(math.rad(angle)) * radius,
                restingY(seabedTop, size),
                centre.Z + math.sin(math.rad(angle)) * radius
            ),
            Vector3.new(size, size * 0.8, size),
            { material = Enum.Material.Slate, color = REEF_ROCK, yaw = angle, roll = -10 + 20 * noise(index, 21) }
        )
    end
end

local function buildL9Buoys(parts: { PartSpec })
    local parent = zonePath("Shallows", "L9")
    local buoys = landmarkById("L9").positions -- (0, 1, 120), (-80, 1, 60), (80, 1, 60)

    for index, position in buoys do
        local y = position.Y
        add(parts, parent, ("L9_Float_%d"):format(index), Vector3.new(position.X, y - 0.5, position.Z), Vector3.new(4, 4, 4), {
            shape = Enum.PartType.Ball,
            material = Enum.Material.SmoothPlastic,
            color = Color3.fromRGB(220, 120, 90),
        })
        cyl(parts, parent, ("L9_Mast_%d"):format(index), Vector3.new(position.X, y + 4.5, position.Z), 10, 0.6, {
            material = Enum.Material.Metal,
            color = Color3.fromRGB(200, 200, 205),
            roll = 3 * noise(index, 23),
        })
        add(parts, parent, ("L9_Light_%d"):format(index), Vector3.new(position.X, y + 10, position.Z), Vector3.new(1.6, 1.6, 1.6), {
            shape = Enum.PartType.Ball,
            material = Enum.Material.Neon,
            color = WARM_NEON,
            decor = true,
            light = { color = WARM_NEON, brightness = 2, range = 45 },
        })
    end
end

-- ============================================================================
-- THE RIM (§3.3) — the threshold between the two zones
-- ============================================================================

local function buildRimWall(parts: { PartSpec })
    local parent = zonePath("Rim", "R1")
    local wall = ZoneConfig.Rim.wall
    local gate = ZoneConfig.Rim.gate

    local steps = wall.steps
    local stepHeight = (wall.topY - wall.bottomY) / steps
    local stepDepth = (wall.maxZ - wall.minZ) / steps
    local partHeight = 18 -- §3.3: each step is 5 rock Parts ~90 x 18 x 14
    local partWidth = 100
    local partDepth = 14

    -- Four columns per step cover |X| 30..210, leaving the 50-stud gate notch (X -25..25)
    -- and its frame clear. The centre column exists only below the notch floor, so the notch
    -- stays open for R2's ramp. Names carry the column ordinal: §Appendix A's naming rule
    -- means a scripter must be able to find any part by name, so they have to be unique.
    local columns = { { -160, "W1" }, { -80, "W2" }, { 80, "E1" }, { 160, "E2" } }
    local notchFloorY = gate.rampBottomY

    for step = 1, steps do
        local top = wall.topY - (step - 1) * stepHeight
        local centreY = top - partHeight / 2
        local z = wall.minZ + (step - 0.5) * stepDepth

        for _, column in columns do
            local columnX = column[1]
            add(
                parts,
                parent,
                ("R1_Step_%d_Rock_%s"):format(step, column[2]),
                Vector3.new(columnX, centreY, z),
                Vector3.new(partWidth, partHeight, partDepth),
                {
                    yaw = 3 + 6 * noise(step * 10 + columnX, 29), -- §3.3: yaw-rotated 3-9 deg
                    material = Enum.Material.Slate,
                    color = RIM_ROCK,
                }
            )
        end

        if centreY < notchFloorY then
            add(parts, parent, ("R1_Step_%d_Rock_C"):format(step), Vector3.new(0, centreY, z), Vector3.new(partWidth, partHeight, partDepth), {
                yaw = 3 + 6 * noise(step, 31),
                material = Enum.Material.Slate,
                color = RIM_ROCK,
            })
        end
    end

    -- The rest of R1's 40: shoulders at the notch lip and three outcrops so the face reads
    -- as rock rather than as a grid.
    add(parts, parent, "R1_GateShelf_W", Vector3.new(-33, -46, 175), Vector3.new(16, 8, 50), {
        material = Enum.Material.Slate,
        color = RIM_ROCK,
        yaw = 5,
    })
    add(parts, parent, "R1_GateShelf_E", Vector3.new(33, -46, 175), Vector3.new(16, 8, 50), {
        material = Enum.Material.Slate,
        color = RIM_ROCK,
        yaw = -5,
    })
    for index, columnX in { -140, 0, 140 } do
        add(
            parts,
            parent,
            ("R1_Outcrop_%d"):format(index),
            Vector3.new(columnX, wall.topY - 20 - 40 * index, 168 + 6 * index),
            Vector3.new(46, 30, 22),
            { material = Enum.Material.Slate, color = RIM_ROCK, yaw = 8 * noise(index, 37) }
        )
    end
end

local function buildRimGate(parts: { PartSpec })
    local parent = zonePath("Rim", "R2")
    local gate = ZoneConfig.Rim.gate

    local rise = gate.rampTopY - gate.rampBottomY -- 70 studs of Y
    local run = gate.maxZ - gate.minZ -- 50 studs of Z
    local length = math.sqrt(rise * rise + run * run)
    local degrees = math.deg(math.atan(rise / run))
    local centreZ = (gate.minZ + gate.maxZ) / 2

    add(
        parts,
        parent,
        "R2_GateRamp",
        Vector3.new(0, (gate.rampTopY + gate.rampBottomY) / 2, centreZ),
        Vector3.new(gate.width, 4, length),
        { pitch = degrees, material = Enum.Material.Slate, color = SHELF_ROCK }
    )

    add(parts, parent, "R2_Pillar_W", Vector3.new(-38, -75, centreZ), gate.pillarSize, {
        material = Enum.Material.Slate,
        color = RIM_ROCK,
        yaw = 6,
    })
    add(parts, parent, "R2_Pillar_E", Vector3.new(38, -75, centreZ), gate.pillarSize, {
        material = Enum.Material.Slate,
        color = RIM_ROCK,
        yaw = -6,
    })
    add(parts, parent, "R2_Lintel", Vector3.new(0, -32, centreZ), Vector3.new(102, 8, 30), {
        material = Enum.Material.Slate,
        color = RIM_ROCK,
    })
    -- The threshold read: a cold Neon keystone over the opening (R3's palette), so crossing
    -- into The Shelf is legible from both sides.
    add(parts, parent, "R2_Keystone", Vector3.new(0, -24, centreZ), Vector3.new(14, 10, 10), {
        material = Enum.Material.Neon,
        color = GATE_NEON,
        transparency = 0.25,
        decor = true,
        light = { color = GATE_NEON, brightness = 1.2, range = 40 },
    })
    add(parts, parent, "R2_Threshold", Vector3.new(0, gate.rampBottomY - 2, gate.maxZ - 6), Vector3.new(gate.width, 4, 16), {
        material = Enum.Material.Slate,
        color = SHELF_ROCK,
    })
    add(parts, parent, "R2_Buttress_W", Vector3.new(-60, -100, centreZ), Vector3.new(30, 40, 30), {
        material = Enum.Material.Slate,
        color = RIM_ROCK,
        yaw = 10,
    })
    add(parts, parent, "R2_Buttress_E", Vector3.new(60, -100, centreZ), Vector3.new(30, 40, 30), {
        material = Enum.Material.Slate,
        color = RIM_ROCK,
        yaw = -10,
    })
end

local function buildRimCurrent(parts: { PartSpec })
    local parent = zonePath("Rim", "R3")
    local current = ZoneConfig.Rim.current
    local midY = (current.topY + current.bottomY) / 2
    local height = current.topY - current.bottomY

    local index = 0
    for _, z in { 162, 175, 188 } do
        for _, x in { -10, 10 } do
            index += 1
            add(parts, parent, ("R3_Strip_%d"):format(index), Vector3.new(x, midY, z), Vector3.new(1.5, height, 1.5), {
                material = Enum.Material.Neon,
                color = GATE_NEON,
                transparency = 0.75, -- §3.3: 0.75 transparency, visual only
                decor = true,
            })
        end
    end
end

-- ============================================================================
-- THE SHELF (§3.4)
-- ============================================================================

local function buildS1Lip(parts: { PartSpec })
    local parent = zonePath("Shelf", "S1")
    local lip = Vector3.new(0, -108, 240)
    local gate = ZoneConfig.Rim.gate
    local lipTop = lip.Y + 3

    add(parts, parent, "S1_Ledge", lip, Vector3.new(130, 6, 70), {
        material = Enum.Material.Slate,
        color = SHELF_ROCK,
    })

    -- Two ramps bridge the Rim Gate's foot (Z 200, Y -120) up to the Lip's surface so the
    -- arrival is a slope, not a cliff.
    local rise = 15
    local run = 40
    local rampLength = math.sqrt(rise * rise + run * run)
    local degrees = -math.deg(math.atan(rise / run))
    for _, side in { { -35, "W" }, { 35, "E" } } do
        add(
            parts,
            parent,
            ("S1_Ramp_%s"):format(side[2]),
            Vector3.new(side[1], gate.rampBottomY + rise / 2, gate.maxZ + run / 2),
            Vector3.new(40, 6, rampLength),
            { pitch = degrees, material = Enum.Material.Slate, color = SHELF_ROCK }
        )
    end

    for index = 1, 3 do
        local angle = index * GOLDEN_ANGLE
        local size = 20 + 10 * noise(index, 41)
        add(
            parts,
            parent,
            ("S1_Boulder_%d"):format(index),
            Vector3.new(
                lip.X + math.cos(math.rad(angle)) * 55,
                restingY(lipTop, size),
                lip.Z + math.sin(math.rad(angle)) * 28
            ),
            Vector3.new(size, size * 0.8, size),
            { material = Enum.Material.Slate, color = SHELF_ROCK_DARK, yaw = angle }
        )
    end

    for index = 1, 3 do
        add(parts, parent, ("S1_Fin_%d"):format(index), Vector3.new(-45 + 45 * (index - 1), lipTop + 2, 272), Vector3.new(30, 5, 12), {
            material = Enum.Material.Slate,
            color = SHELF_ROCK_DARK,
            yaw = 10 * noise(index, 43),
        })
    end

    add(parts, parent, "S1_BackStep", Vector3.new(0, -101, 292), Vector3.new(120, 8, 40), {
        material = Enum.Material.Slate,
        color = Color3.fromRGB(60, 66, 74),
    })
end

local function buildS2CreviceRow(parts: { PartSpec })
    local parent = zonePath("Shelf", "S2")
    local dens = SpawnConfig.LanternEel.dens -- §4.6: 7 dens, opening faces -Z

    local index = 0
    for _, position in dens do
        index += 1
        add(parts, parent, ("S2_Den_%d"):format(index), position, Vector3.new(10, 6, 14), {
            material = Enum.Material.Slate,
            color = Color3.fromRGB(30, 34, 40),
            attributes = {
                -- The matching spawn anchor lives in Spawns/LanternEel; this links the two.
                SpawnNode = ("LanternEel/Den_%d"):format(index),
                OpeningFacing = SpawnConfig.LanternEel.openingFacing,
            },
            -- §3.4: "a 3-stud Neon speck to be found in the dark". S2's budget is the 7 dens,
            -- so the speck is a light rather than an eighth part.
            light = { color = EEL_NEON, brightness = 1, range = 12 },
        })
    end
end

local function buildS3GhostLedge(parts: { PartSpec })
    local parent = zonePath("Shelf", "S3")
    local ledge = Vector3.new(0, -175, 380)
    local top = ledge.Y + 3

    add(parts, parent, "S3_Ledge", ledge, Vector3.new(200, 6, 80), {
        material = Enum.Material.Slate,
        color = SHELF_ROCK_DARK,
    })

    for index = 1, 6 do
        add(parts, parent, ("S3_Fin_%d"):format(index), Vector3.new(-75 + 30 * (index - 1), top + 2.5, 345), Vector3.new(30, 5, 12), {
            material = Enum.Material.Slate,
            color = Color3.fromRGB(50, 58, 68),
            yaw = -8 + 16 * noise(index, 47),
        })
    end

    add(parts, parent, "S3_MineralVein", Vector3.new(0, top + 1, 405), Vector3.new(60, 3, 8), {
        material = Enum.Material.Neon,
        color = MINERAL_NEON,
        transparency = 0.45,
        decor = true,
    })
end

local function buildS4ThermalVents(parts: { PartSpec })
    local parent = zonePath("Shelf", "S4")
    local field = Vector3.new(110, -205, 440)
    local floorTop = ZoneConfig.Seabed.Shelf.topYs[4] + 4

    for index = 1, 6 do
        local angle = index * GOLDEN_ANGLE
        local radius = 6 + 22 * noise(index, 53)
        local x = field.X + math.cos(math.rad(angle)) * radius
        local z = field.Z + math.sin(math.rad(angle)) * radius
        local height = 10 + 8 * noise(index, 59)
        local diameter = 8 - 2 * noise(index, 61)

        cyl(parts, parent, ("S4_Chimney_%d"):format(index), Vector3.new(x, floorTop + height / 2, z), height, diameter, {
            material = Enum.Material.Slate,
            color = Color3.fromRGB(48, 40, 36),
            yaw = 6 * noise(index, 63),
        })
        cyl(parts, parent, ("S4_Rim_%d"):format(index), Vector3.new(x, floorTop + height + 0.6, z), 1.2, diameter + 2, {
            material = Enum.Material.Neon,
            color = VENT_NEON,
            transparency = 0.15,
            decor = true,
            -- §3.4: 3 PointLights across the field — the Shelf's only warm light.
            light = if index <= 3 then { color = Color3.fromRGB(255, 140, 70), brightness = 2, range = 40 } else nil,
        })
    end

    add(parts, parent, "S4_Mound_1", Vector3.new(field.X - 34, floorTop + 3, field.Z + 18), Vector3.new(24, 8, 24), {
        material = Enum.Material.Slate,
        color = Color3.fromRGB(52, 44, 40),
        yaw = 14,
    })
    add(parts, parent, "S4_Mound_2", Vector3.new(field.X + 30, floorTop + 2.4, field.Z - 16), Vector3.new(20, 7, 20), {
        material = Enum.Material.Slate,
        color = Color3.fromRGB(52, 44, 40),
        yaw = -22,
    })
end

local function buildS5SunkenPillars(parts: { PartSpec })
    local parent = zonePath("Shelf", "S5")
    local field = Vector3.new(-130, -165, 330)
    local floorTop = ZoneConfig.Seabed.Shelf.topYs[2]

    for index = 1, 5 do
        local length = 60 + 30 * noise(index, 67)
        local angle = index * GOLDEN_ANGLE
        add(
            parts,
            parent,
            ("S5_Pillar_%d"):format(index),
            Vector3.new(
                field.X + math.cos(math.rad(angle)) * 40,
                floorTop + 10,
                field.Z + math.sin(math.rad(angle)) * 40
            ),
            Vector3.new(length, 16, 16),
            {
                shape = Enum.PartType.Cylinder, -- axis X: lying on its side
                yaw = 20 + 50 * noise(index, 71), -- §3.4: yaw 20-70 deg
                roll = -12 + 24 * noise(index, 73), -- tilt +/- 12 deg
                material = Enum.Material.Slate,
                color = Color3.fromRGB(70, 76, 84),
            }
        )
    end

    for index = 1, 4 do
        local angle = index * GOLDEN_ANGLE + 25
        local size = 18 + 8 * noise(index, 79)
        add(
            parts,
            parent,
            ("S5_Rubble_%d"):format(index),
            Vector3.new(
                field.X + math.cos(math.rad(angle)) * 60,
                floorTop + size * 0.3,
                field.Z + math.sin(math.rad(angle)) * 55
            ),
            Vector3.new(size, size * 0.6, size * 0.8),
            { material = Enum.Material.Slate, color = Color3.fromRGB(64, 70, 78), yaw = angle }
        )
    end
end

local function buildS6Chasm(parts: { PartSpec })
    local parent = zonePath("Shelf", "S6")
    local chasm = ZoneConfig.Chasm
    local spanX = chasm.maxX - chasm.minX
    local spanZ = chasm.maxZ - chasm.minZ
    local centreZ = (chasm.minZ + chasm.maxZ) / 2

    -- §3.4/§7: the deepest playable point, built dark and unfinished on purpose — this is
    -- where the next update's content goes.
    add(parts, parent, "S6_Floor", Vector3.new(0, chasm.floorY - 2, centreZ), Vector3.new(spanX, 4, spanZ), {
        material = Enum.Material.Slate,
        color = DEEP_VOID,
    })

    -- §3.4: "walls from 12 large Parts 80 x 30 x 20 stepped down on both sides".
    for _, side in { { -1, "W" }, { 1, "E" } } do
        for tier = 1, 2 do
            for step = 1, 3 do
                add(
                    parts,
                    parent,
                    ("S6_Wall_%s_%d_%d"):format(side[2], tier, step),
                    Vector3.new(side[1] * 60, chasm.floorY + 15 + (tier - 1) * 14, chasm.minZ + 30 + (step - 1) * 50),
                    Vector3.new(80, 30, 20),
                    {
                        material = Enum.Material.Slate,
                        color = if tier == 1 then SHELF_ROCK_DARK else Color3.fromRGB(36, 42, 50),
                        yaw = side[1] * (4 + 6 * noise(tier * 10 + step, 83)),
                    }
                )
            end
        end
    end

    for index = 1, 6 do
        local side = if index <= 3 then -1 else 1
        local slot = ((index - 1) % 3) + 1
        add(
            parts,
            parent,
            ("S6_LipRock_%d"):format(index),
            Vector3.new(side * 14 * slot, -192, chasm.minZ + 12 + (slot - 1) * 26),
            Vector3.new(30, 12, 40),
            { material = Enum.Material.Slate, color = Color3.fromRGB(40, 46, 54), yaw = 6 * noise(index, 89) }
        )
    end

    for index = 1, 3 do
        add(
            parts,
            parent,
            ("S6_Rubble_%d"):format(index),
            Vector3.new(-20 + 20 * index, chasm.floorY + 8, centreZ - 60 + 30 * index),
            Vector3.new(20, 14, 20),
            { material = Enum.Material.Slate, color = Color3.fromRGB(34, 40, 48), yaw = 25 * noise(index, 97) }
        )
    end
end

-- ============================================================================
-- World props, water and spawn anchors (§1, §3.0, §4.6, Appendix A)
-- ============================================================================

local function buildSpawns(parts: { PartSpec }, layout: Layout)
    -- §11: the player spawns at (0, 8, -20) on the dock, standing, facing the water (+Z).
    -- This SpawnLocation replaces the stand-in pad the scaffold shipped: it sits on L1_Deck's
    -- top (Y 7) and its LookVector points +Z, which is the way a spawned character faces.
    local spawnPoint = ZoneConfig.InteractionPoints.PlayerSpawn
    add(parts, SPAWNS_FOLDER, "SpawnLocation", spawnPoint - Vector3.new(0, 0.5, 0), Vector3.new(12, 1, 12), {
        class = "SpawnLocation",
        material = Enum.Material.Wood,
        color = DOCK_WOOD,
        cf = CFrame.new(spawnPoint - Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, math.pi, 0),
        props = { Duration = 0, Neutral = true, Enabled = true },
    })

    -- L1's four prompt-host props live here (Appendix A), not in the Shallows folder, but by
    -- the naming rule they are L1 parts and are counted as such. Their ProximityPrompts are
    -- created now; their verbs are the owning service's TODO.
    local rack = promptHostById("RodRack")
    local rackAt = if rack ~= nil then rack.position else Vector3.new(12, 9, -10)
    add(parts, SPAWNS_FOLDER, "L1_RodRack", rackAt, Vector3.new(7, 3, 2), {
        material = Enum.Material.Wood,
        color = DOCK_WOOD_DARK,
        attributes = { PromptId = "RodRack" },
        prompt = rack,
    })
    add(parts, SPAWNS_FOLDER, "L1_RodRack_Top", rackAt + Vector3.new(0, 1.75, 0), Vector3.new(7.4, 0.6, 2.4), {
        material = Enum.Material.Metal,
        color = Color3.fromRGB(180, 180, 190),
    })

    local trader = promptHostById("TideTrader")
    local traderAt = if trader ~= nil then trader.position else Vector3.new(-14, 9, -10)
    add(parts, SPAWNS_FOLDER, "L1_TideTrader", traderAt, Vector3.new(8, 6, 8), {
        material = Enum.Material.Wood,
        color = Color3.fromRGB(92, 70, 54),
        attributes = { PromptId = "TideTrader" },
        prompt = trader,
    })
    add(parts, SPAWNS_FOLDER, "L1_TideTrader_Sign", traderAt + Vector3.new(0, 4.5, 4.2), Vector3.new(7, 2, 0.6), {
        material = Enum.Material.Neon,
        color = WARM_NEON,
        transparency = 0.1,
        decor = true,
    })

    add(parts, SPAWNS_FOLDER, "DiveMarker", ZoneConfig.InteractionPoints.DiveMarker, Vector3.new(12, 0.6, 2.2), {
        material = Enum.Material.Neon,
        color = GATE_NEON,
        transparency = 0.2,
        decor = true,
        attributes = { PromptId = "DiveMarker" },
        prompt = promptHostById("DiveMarker"),
        billboard = { text = "DIVE HERE", color = GATE_NEON },
    })

    -- §4.6 spawn anchors: one invisible host part per species (Appendix A: "spawn volumes
    -- are Attachments rather than Parts, so they cannot be rendered by accident") with an
    -- Attachment per coordinate. FishService spawns into these; WorldService never does.
    local groups = {
        { species = "SilverSardine", config = SpawnConfig.SilverSardine, list = SpawnConfig.SilverSardine.anchors, prefix = "Node" },
        { species = "SunsetGrouper", config = SpawnConfig.SunsetGrouper, list = SpawnConfig.SunsetGrouper.nodes, prefix = "Node" },
        { species = "ReefBass", config = SpawnConfig.ReefBass, list = SpawnConfig.ReefBass.nodes, prefix = "Node" },
        { species = "LanternEel", config = SpawnConfig.LanternEel, list = SpawnConfig.LanternEel.dens, prefix = "Den" },
        { species = "GhostRay", config = SpawnConfig.GhostRay, list = SpawnConfig.GhostRay.nodes, prefix = "Node" },
    }

    for _, group in groups do
        local folder = ("%s/%s"):format(SPAWNS_FOLDER, group.species)
        table.insert(layout.folders, folder)

        local centre = Vector3.new(0, 0, 0)
        for _, position in group.list do
            centre += position
        end
        centre = centre / #group.list

        local hostName = ("%s_AnchorHost"):format(group.species)
        add(parts, folder, hostName, centre, Vector3.new(1, 1, 1), {
            transparency = 1,
            decor = true,
            collide = false,
            query = false,
            outsideBuildZone = true, -- it is a volume anchor, not scenery
            attributes = { Species = group.species, Kind = group.config.kind, AnchorCount = #group.list },
        })

        local index = 0
        for _, position in group.list do
            index += 1
            local attributes: { [string]: any } = {
                Species = group.species,
                Kind = group.config.kind,
                Index = index,
                NodeName = ("%s_%d"):format(group.prefix, index),
            }
            -- Every other scalar field of the species' SpawnConfig entry is a behaviour
            -- parameter (box, waypointRadius, driftRadius, loopBox, openingFacing): copy them
            -- onto the anchor so FishService reads its rules from one place.
            for key, value in group.config do
                if key ~= "kind" and type(value) ~= "table" then
                    attributes[key] = value
                end
            end
            table.insert(layout.anchors, {
                name = ("%s_%d"):format(group.prefix, index),
                host = hostName,
                hostParent = folder,
                position = position - centre,
                attributes = attributes,
            })
        end
    end
end

local function buildWater(parts: { PartSpec }, layout: Layout)
    local region = ZoneConfig.WaterRegion
    local size = Vector3.new(region.maxX - region.minX, region.topY - region.bottomY, region.maxZ - region.minZ)
    local centre = Vector3.new(
        (region.minX + region.maxX) / 2,
        (region.topY + region.bottomY) / 2,
        (region.minZ + region.maxZ) / 2
    )
    layout.water = { size = size }

    -- One invisible marker lets a scripter or the artist see the water volume; the water
    -- itself is Terrain (§3.0: "Terrain holds water and nothing else").
    add(parts, WATER_FOLDER, LandmarkConfig.WorldPropNames.WaterRegionMarker, centre, size, {
        transparency = 1,
        decor = true,
        collide = false,
        query = false,
        outsideBuildZone = true, -- it *is* the water volume (§3.0), which is wider than the build zone
        attributes = { TopY = region.topY, BottomY = region.bottomY },
    })
end

-- ============================================================================
-- Layout
-- ============================================================================

--- The whole world as data: folders, part specs, spawn anchors and the water volume.
--- Pure — no Instances are touched, so it can be asserted before anything is built.
function WorldService:GetLayout(): Layout
    local layout: Layout = { folders = {}, parts = {}, anchors = {}, water = { size = Vector3.new(0, 0, 0) } }

    table.insert(layout.folders, WORLD_FOLDER)
    table.insert(layout.folders, WATER_FOLDER)
    table.insert(layout.folders, SPAWNS_FOLDER)
    for zoneId in ZoneConfig.Zones do
        table.insert(layout.folders, ("%s/%s"):format(WORLD_FOLDER, zoneId))
    end
    for _, landmark in LandmarkConfig.Landmarks do
        table.insert(layout.folders, zonePath(landmark.zone, landmark.id))
    end
    table.insert(layout.folders, basePath("Shallows"))
    table.insert(layout.folders, basePath("Shelf"))

    buildShallowsSeabed(layout.parts)
    buildShelfSeabed(layout.parts)

    buildL1Dock(layout.parts)
    buildL2CoralSpire(layout.parts)
    buildL3Trawler(layout.parts)
    buildL4Kelp(layout.parts)
    buildL5DeepHole(layout.parts)
    buildL6SandChannels(layout.parts)
    buildL7FishRocks(layout.parts)
    -- L8 Sun Shafts is deliberately 0 parts (§3.2): the Technical Artist owns it.
    buildL9Buoys(layout.parts)

    buildRimWall(layout.parts)
    buildRimGate(layout.parts)
    buildRimCurrent(layout.parts)

    buildS1Lip(layout.parts)
    buildS2CreviceRow(layout.parts)
    buildS3GhostLedge(layout.parts)
    buildS4ThermalVents(layout.parts)
    buildS5SunkenPillars(layout.parts)
    buildS6Chasm(layout.parts)

    buildSpawns(layout.parts, layout)
    buildWater(layout.parts, layout)

    return layout
end

--- Everything the built layout must satisfy: each landmark's part count from §3.2-§3.4,
--- the Appendix A world total, the §3.0 build zone, and the §4.6 anchor counts.
--- Returns a list of human-readable problems (empty = clean). Pure, so it can be run before
--- or after Build().
function WorldService:ValidateLayout(layout: Layout?): { string }
    local resolved = if layout ~= nil then layout else self:GetLayout()
    local problems: { string } = {}

    local byLandmark: { [string]: number } = {}
    for _, spec in resolved.parts do
        local id = spec.name:match("^([LRS]%d)_")
        if id ~= nil then
            byLandmark[id] = (byLandmark[id] or 0) + 1
        end
    end
    for _, landmark in LandmarkConfig.Landmarks do
        local actual = byLandmark[landmark.id] or 0
        if actual ~= landmark.parts then
            table.insert(
                problems,
                ("%s %s: built %d parts, LandmarkConfig says %d"):format(landmark.id, landmark.name, actual, landmark.parts)
            )
        end
    end

    if #resolved.parts ~= LandmarkConfig.PartBudget.World then
        table.insert(
            problems,
            ("world total: built %d parts, LandmarkConfig.PartBudget.World says %d"):format(#resolved.parts, LandmarkConfig.PartBudget.World)
        )
    end

    -- §3.0: nothing outside the build zone (the water volume and its marker are the space
    -- itself, so they are exempt by flag rather than by exception).
    for _, spec in resolved.parts do
        if not spec.outsideBuildZone then
            local p = spec.cf.Position
            local size = spec.size
            local box = ZoneConfig.BuildZone
            if
                p.X - size.X / 2 < box.minX
                or p.X + size.X / 2 > box.maxX
                or p.Z - size.Z / 2 < box.minZ
                or p.Z + size.Z / 2 > box.maxZ
            then
                table.insert(problems, ("%s is placed outside ZoneConfig.BuildZone"):format(spec.name))
            end
        end
    end

    -- §Appendix A: a scripter must be able to find any world part by name, so names have to
    -- be unique inside their folder.
    local seen: { [string]: boolean } = {}
    for _, spec in resolved.parts do
        local key = ("%s/%s"):format(spec.parent, spec.name)
        if seen[key] then
            table.insert(problems, ("duplicate part name %s in %s"):format(spec.name, spec.parent))
        end
        seen[key] = true
    end
    for _, anchor in resolved.anchors do
        local key = ("%s/%s"):format(anchor.hostParent, anchor.name)
        if seen[key] then
            table.insert(problems, ("duplicate anchor name %s in %s"):format(anchor.name, anchor.hostParent))
        end
        seen[key] = true
    end

    -- §4.6: one anchor per coordinate, per species.
    local counts: { [string]: number } = {}
    for _, anchor in resolved.anchors do
        counts[anchor.attributes.Species] = (counts[anchor.attributes.Species] or 0) + 1
    end
    local groups = {
        { "SilverSardine", #SpawnConfig.SilverSardine.anchors },
        { "SunsetGrouper", #SpawnConfig.SunsetGrouper.nodes },
        { "ReefBass", #SpawnConfig.ReefBass.nodes },
        { "LanternEel", #SpawnConfig.LanternEel.dens },
        { "GhostRay", #SpawnConfig.GhostRay.nodes },
    }
    for _, group in groups do
        if (counts[group[1]] or 0) ~= group[2] then
            table.insert(
                problems,
                ("%s: %d spawn anchors, SpawnConfig has %d"):format(group[1], counts[group[1]] or 0, group[2])
            )
        end
    end

    return problems
end

-- ============================================================================
-- Build (idempotent)
-- ============================================================================

local function folderAt(root: Instance, path: string): Instance
    local current = root
    for segment in path:gmatch("[^/]+") do
        local nextFolder = current:FindFirstChild(segment)
        if nextFolder == nil then
            local created: any = Instance.new("Folder")
            created.Name = segment
            created.Parent = current
            nextFolder = created
        end
        current = nextFolder
    end
    return current
end

local function clearChildren(folder: Instance)
    for _, child in folder:GetChildren() do
        child:Destroy()
    end
end

local function applyPrompt(part: any, spec: PartSpec)
    if spec.prompt == nil then
        return
    end
    local proximity: any = Instance.new("ProximityPrompt")
    proximity.Name = "Prompt"
    proximity.ActionText = spec.prompt.actionText or "Use"
    proximity.ObjectText = spec.prompt.objectText or ""
    proximity.HoldDuration = spec.prompt.holdDuration or 0
    proximity.MaxActivationDistance = 12
    proximity.RequiresLineOfSight = false
    proximity.KeyboardKeyCode = Enum.KeyCode.E -- §1: "E — Take Rusty Rod"
    proximity.Parent = part
    proximity:SetAttribute("HostId", spec.attributes and spec.attributes.PromptId or spec.name)
    local hostId = spec.attributes and spec.attributes.PromptId
    if hostId ~= nil then
        promptById[hostId] = proximity
    end
end

local function applyBillboard(part: any, spec: PartSpec)
    if spec.billboard == nil then
        return
    end
    local gui: any = Instance.new("BillboardGui")
    gui.Name = "Sign"
    gui.Size = UDim2.fromScale(14, 3.5)
    gui.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
    local label: any = Instance.new("TextLabel")
    label.Name = "Text"
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextScaled = true
    label.TextColor3 = spec.billboard.color or Color3.fromRGB(255, 255, 255)
    label.Text = spec.billboard.text or ""
    label.Parent = gui
    gui.Parent = part
end

--- Creates the world. Safe to call repeatedly: every folder it owns is cleared first, so a
--- server restart or a second call rebuilds rather than duplicating (and the part count is
--- identical every time).
function WorldService:Build(): { [string]: any }
    local startedAt = os.clock()
    local layout = self:GetLayout()

    local rootInstance = Workspace:FindFirstChild(ROOT_NAME)
    if rootInstance == nil then
        local created: any = Instance.new("Folder")
        created.Name = ROOT_NAME
        created.Parent = Workspace
        rootInstance = created
    end
    local root: any = rootInstance

    local world = folderAt(root, WORLD_FOLDER)
    local water = folderAt(root, WATER_FOLDER)
    local spawns = folderAt(root, SPAWNS_FOLDER)

    -- Idempotency: drop everything this service owns, then rebuild it. Fish/ is untouched.
    clearChildren(world)
    clearChildren(water)
    clearChildren(spawns)
    promptById = {}

    for _, path in layout.folders do
        folderAt(root, path)
    end

    local byKey: { [string]: any } = {}
    local counts: { [string]: number } = {}
    for _, spec in layout.parts do
        local part: any = Instance.new(spec.class or "Part")
        part.Name = spec.name

        if spec.shape ~= nil and part:IsA("Part") then
            part.Shape = spec.shape
        end

        local collide = spec.collide
        if collide == nil then
            collide = not spec.decor
        end
        local query = spec.query
        if query == nil then
            query = not spec.decor
        end

        part.Anchored = true
        part.CanCollide = collide
        part.CanQuery = query
        part.CanTouch = false -- nothing in the game watches Touched on world geometry
        part.CastShadow = not spec.decor
        part.Material = spec.material
        part.Color = spec.color
        part.Transparency = spec.transparency
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
        part.Size = spec.size
        part.CFrame = spec.cf

        for key, value in spec.props or {} do
            part[key] = value
        end
        for key, value in spec.attributes or {} do
            part:SetAttribute(key, value)
        end
        if spec.light ~= nil then
            local light: any = Instance.new("PointLight")
            light.Name = "Glow"
            light.Color = spec.light.color
            light.Brightness = spec.light.brightness
            light.Range = spec.light.range
            light.Shadows = false
            light.Parent = part
        end
        applyPrompt(part, spec)
        applyBillboard(part, spec)

        part.Parent = folderAt(root, spec.parent)
        byKey[("%s/%s"):format(spec.parent, spec.name)] = part

        local group = spec.parent:match("^World/([^/]+)") or spec.parent:match("^([^/]+)")
        if group ~= nil then
            counts[group] = (counts[group] or 0) + 1
        end
    end

    -- Spawn anchors: Attachments on their species' host part (§4.6). Attachments cannot be
    -- rendered, which is exactly why Appendix A asks for them instead of Parts.
    local anchorCounts: { [string]: number } = {}
    for _, anchor in layout.anchors do
        local host = byKey[("%s/%s"):format(anchor.hostParent, anchor.host)]
        if host ~= nil then
            local attachment: any = Instance.new("Attachment")
            attachment.Name = anchor.name
            attachment.Position = anchor.position
            for key, value in anchor.attributes do
                attachment:SetAttribute(key, value)
            end
            attachment.Parent = host
            local species = anchor.attributes.Species
            anchorCounts[species] = (anchorCounts[species] or 0) + 1
        end
    end

    -- Water: §3.0 — one Terrain fill and nothing else. Cleared first so re-running cannot
    -- stack two volumes.
    local terrain: any = Workspace.Terrain
    local centre = self:WaterCentre()
    terrain:FillBlock(CFrame.new(centre), layout.water.size, Enum.Material.Air)
    terrain:FillBlock(CFrame.new(centre), layout.water.size, Enum.Material.Water)

    local total = 0
    for _, count in counts do
        total += count
    end

    local report = {
        parts = total,
        counts = counts,
        anchors = anchorCounts,
        seconds = os.clock() - startedAt,
        problems = self:ValidateLayout(layout),
    }
    lastReport = report
    return report
end

--- The centre of the §3.0 water volume.
function WorldService:WaterCentre(): Vector3
    local region = ZoneConfig.WaterRegion
    return Vector3.new(
        (region.minX + region.maxX) / 2,
        (region.topY + region.bottomY) / 2,
        (region.minZ + region.maxZ) / 2
    )
end

-- ============================================================================
-- Public server API
-- ============================================================================

--- Which zone a world position sits in ("Shallows" | "Shelf" | nil between them, §3.1).
function WorldService:GetZoneAt(position: Vector3): string?
    for id, zone in ZoneConfig.Zones do
        local footprint = zone.footprint
        if
            position.X >= footprint.minX
            and position.X <= footprint.maxX
            and position.Z >= footprint.minZ
            and position.Z <= footprint.maxZ
        then
            return id
        end
    end
    return nil
end

--- Which zone a depth belongs to, using ZoneConfig.DepthBand (§3, Appendix C).
--- Depth is positive studs below sea level. The two playable zones have disjoint bands
--- (Shallows 0-85, Shelf 100-215), so they are tested first and the Rim — the transition
--- band that deliberately overlaps both — is only reported when neither zone band matches.
function WorldService:GetZoneForDepth(depthStuds: number): string?
    for id, zone in ZoneConfig.Zones do
        local band = zone.depthBand
        if depthStuds >= -band.top and depthStuds <= -band.bottom then
            return id
        end
    end
    local rim = ZoneConfig.DepthBand.Rim
    if depthStuds >= -rim.top and depthStuds <= -rim.bottom then
        return "Rim"
    end
    return nil
end

--- A named interaction point from ZoneConfig.InteractionPoints ("RodRack", "TideTrader",
--- "DiveMarker", "PlayerSpawn").
function WorldService:GetInteractionPoint(name: string): Vector3?
    return ZoneConfig.InteractionPoints[name]
end

--- §1 step 1: where the player appears, standing on the dock facing the water.
function WorldService:GetSpawnPosition(): Vector3
    return ZoneConfig.InteractionPoints.PlayerSpawn
end

--- Total parts in the built world (World + Water + Spawns; fish excluded).
function WorldService:GetPartCount(): number
    local report = lastReport
    return if report ~= nil then report.parts else 0
end

--- The species' spawn-anchor folder (Workspace.DeepTide.Spawns.<species>, §4.6). FishService
--- reads the Attachments inside; nothing here spawns fish.
function WorldService:GetAnchorFolder(species: string): Instance?
    local root = Workspace:FindFirstChild(ROOT_NAME)
    if root == nil then
        return nil
    end
    local spawns = root:FindFirstChild(SPAWNS_FOLDER)
    if spawns == nil then
        return nil
    end
    return spawns:FindFirstChild(species)
end

--- The ProximityPrompt a service wires its verb to (§1 steps 2, 3, 8). The prompt instance
--- exists from Build() on; connecting `.Triggered` is the owning service's job.
function WorldService:GetPrompt(id: string): ProximityPrompt?
    return promptById[id]
end

--- §9: announce a zone entry — fires ZoneChanged and the 3 s top-centre banner
--- (ZoneConfig.ZoneEntryBannerSeconds), first entry only per player.
function WorldService:AnnounceZone(player: Player, zoneId: string)
    -- TODO(§9): first-entry-per-player bookkeeping + Remotes.ZoneChanged, and the banner
    -- itself is the HUD's. Owned by the gameplay pass.
end

--- §1 steps 2, 3 and 8: the ProximityPrompts on the Rod Rack, the dive marker and the Tide
--- Trader already exist from Build(); this is where their `.Triggered` connections go once
--- the services that own the verbs exist. Returns the prompts it can see.
function WorldService:WirePrompts(): { [string]: ProximityPrompt? }
    local found: { [string]: ProximityPrompt? } = {}
    for _, host in LandmarkConfig.PromptHosts do
        found[host.id] = promptById[host.id]
        -- TODO(§1): RodRack -> "Take Rusty Rod" (FishingService); TideTrader -> "Trade"
        -- (ShopService); DiveMarker -> §1 step 3's dive hint.
    end
    return found
end

--- Human-readable one-liner for the boot output / the lead's status checks.
function WorldService:SummaryLine(): string
    local report = lastReport
    if report == nil then
        return "world: not built"
    end
    local counts = report.counts
    local anchorTotal = 0
    for _, count in report.anchors do
        anchorTotal += count
    end
    return ("world built in %d ms — %d parts (Shallows %d, Rim %d, Shelf %d) + Spawns %d, Water %d · %d spawn anchors · %d layout problems"):format(
        math.floor(report.seconds * 1000 + 0.5),
        report.parts,
        counts.Shallows or 0,
        counts.Rim or 0,
        counts.Shelf or 0,
        counts.Spawns or 0,
        counts.Water or 0,
        anchorTotal,
        #report.problems
    )
end

-- ============================================================================
-- Client surface
-- ============================================================================

function WorldService.Client:GetInteractionPoint(name: string): Vector3?
    return self.Server:GetInteractionPoint(name)
end

-- ============================================================================
-- Knit lifecycle
-- ============================================================================

function WorldService:KnitInit()
    local report = self:Build()
    for _, problem in report.problems do
        warn("[Deep Tide] world: " .. problem)
    end
end

function WorldService:KnitStart()
    self:WirePrompts()
    print("[Deep Tide] " .. self:SummaryLine())
end

return WorldService
