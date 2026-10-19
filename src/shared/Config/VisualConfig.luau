--!strict
--[[
    Deep Tide — VisualConfig
    Source: GDD §8.4 (the underwater movement kit: bubbles, silt, hand-sweep), §8.5 (fish reads,
            the landing burst, the snap flash), §3.3 (R3 Rim Current: 6 strips + an emitter),
            §3.4 (S4 vents: "6 particle emitters (upward, slow)"), §8.6 (bioluminescence is the
            Shelf's only light source), §9 (navigation: a player must be able to read the place by
            eye), §3.2-§3.4 (the landmarks that must have a focal point), Appendix A
            (primitives + Neon + PointLight + ParticleEmitter only: no meshes, no textures).

    PURE DATA — every non-lighting effect the world and the player carry.

    Why this file exists separately from LightingConfig
      LightingConfig answers "what does the water look like". This answers "what is moving in it".
      The two are read by different things: LightingConfig by the depth sampler (Modules/Atmosphere),
      VisualConfig by VisualService (server instances) and the client EffectsController.

    The instance budget for BOTH files lives in LightingConfig.Budget and is asserted against the
    real build by tools/worldtest/visual_harness.luau.

    Honesty note: none of these are named audio. §8.7's sound layers and §8.8's audible air alarm
    are NOT implemented in this pass — they are the one §8 item the visuals do not cover.
]]

local VisualConfig = {}

-- ============================================================================
-- §8.4 — the underwater movement kit (client-side: only one screen can see it)
-- ============================================================================
-- "A constant, low-rate bubble trail from the player's head (2 particles/s idle, 14/s while
-- swimming, 30/s on a fast ascent)". Those three rates are the design's; everything else is the
-- shape of the bubbles.
VisualConfig.Player = {
    Bubbles = {
        idleRate = 2, -- §8.4
        swimRate = 14, -- §8.4
        ascendRate = 30, -- §8.4
        -- What counts as "swimming" and what counts as a "fast ascent": measured from the
        -- character's own velocity, so the numbers read the same at any frame rate.
        swimSpeedStuds = 6,
        ascendSpeedStuds = 8,
        lifetime = 1.4, -- seconds a bubble lives; short, or the screen fills with foam
        speed = 3.2, -- studs/s upward
        spreadAngle = 22, -- a narrow plume, not a cloud
        sizeMin = 0.18,
        sizeMax = 0.42,
        transparencyStart = 0.35,
        transparencyEnd = 1,
        color = Color3.fromRGB(226, 240, 250),
        lightEmission = 0.15, -- bubbles catch a little light without glowing like lamps
        lightInfluence = 0.35,
        maxParticles = 40, -- a hard ceiling so a fast ascent can never become a fog bank
    },
    -- §8.4: "a kick-up silt puff when the player touches the seabed". Shares the burst emitter
    -- (see VisualConfig.Burst) rather than owning one — the budget is 2 client emitters, and a
    -- one-off puff and a one-off splash are the same machine with different numbers.
    SiltKick = {
        burstCount = 10,
        speed = 2.4,
        lifetime = 1.6,
        sizeMin = 0.6,
        sizeMax = 1.8,
        color = Color3.fromRGB(196, 183, 148), -- the §3.1 sand colour
        transparencyStart = 0.55,
        transparencyEnd = 1,
        spreadAngle = 180,
        lightEmission = 0,
        lightInfluence = 1,
        cooldownSeconds = 1.2, -- touching the floor repeatedly must not sandblast the screen
    },
}

-- ============================================================================
-- The one burst emitter (client-side) — splash, silt, landing, snap
-- ============================================================================
-- ParticleEmitter properties are read at the moment `Emit(n)` is called, so one emitter can serve
-- every one-shot burst as long as the values are written immediately before the emission. That is
-- why the budget is 2 client emitters and not 5. The tradeoff, stated plainly: two bursts in the
-- same frame share whichever numbers were written last — at these sizes it is not visible.
VisualConfig.Burst = {
    name = "DeepTideBurst",
    rate = 0, -- never emits on its own; only `Emit(count)` ever fires it
    speed = 10,
    lifetime = 1,
    drag = 0,
    acceleration = Vector3.new(0, -6, 0), -- water drags everything down eventually
    spreadAngle = 45,
    emissionDirection = "Top",
    maxParticles = 60,
}

-- §1 step 3 ("jumps off the edge at the DIVE HERE marker"): the surface-entry splash.
VisualConfig.Splash = {
    burstCount = 16,
    speed = 12,
    lifetime = 1.1,
    sizeMin = 0.5,
    sizeMax = 1.4,
    color = Color3.fromRGB(210, 235, 245),
    transparencyStart = 0.25,
    transparencyEnd = 1,
    spreadAngle = 60,
    lightEmission = 0.2,
    lightInfluence = 0.4,
}

-- ============================================================================
-- §8.5 — "the player must be able to tell win from loss from across the room"
-- ============================================================================
-- A landing pops a Coin-yellow burst at the rod tip; a snap is a hard white flash. Both are the
-- same burst emitter plus a PointLight that lives for the flash and is destroyed with it, so the
-- world's steady light count never grows because someone lost a fish.
VisualConfig.Flash = {
    Landing = { -- §8.5 "a Coin-yellow burst at the rod tip"
        color = Color3.fromRGB(255, 214, 120),
        burstCount = 14,
        speed = 8,
        lifetime = 0.9,
        sizeMin = 0.5,
        sizeMax = 1.6,
        transparencyStart = 0.1,
        transparencyEnd = 1,
        lightColor = Color3.fromRGB(255, 214, 120),
        lightBrightness = 6,
        lightRange = 20,
        lightSeconds = 0.45,
    },
    -- §5.4: a line snap with the Rusty Rod is a *designed* wall, so its feedback is the loudest
    -- thing in the game that is not an explosion. 0.15 s, hard cut, no lingering glow.
    Snap = {
        color = Color3.fromRGB(255, 255, 255),
        burstCount = 8,
        speed = 6,
        lifetime = 0.4,
        sizeMin = 0.3,
        sizeMax = 0.9,
        transparencyStart = 0,
        transparencyEnd = 1,
        lightColor = Color3.fromRGB(255, 255, 255),
        lightBrightness = 8,
        lightRange = 14,
        lightSeconds = 0.15, -- §8.5: "a 0.15 s white flash"
    },
    -- Escape (§8.5 "a small grey ripple") — the quiet one, so a loss reads as a loss and not as a
    -- snap: no light at all, just a few grey motes.
    Escape = {
        color = Color3.fromRGB(150, 158, 168),
        burstCount = 5,
        speed = 2.5,
        lifetime = 0.7,
        sizeMin = 0.3,
        sizeMax = 0.8,
        transparencyStart = 0.5,
        transparencyEnd = 1,
    },
    -- Where "the rod tip" is: the character's Head plus this offset (the rod is a Tool the
    -- RodController holds; nothing here depends on its length, so a restyle of the rod cannot
    -- silently move the flash). Offsets are in studs, camera-space-free and constant.
    rodTipOffset = Vector3.new(1.6, -0.4, -2.2),
}

-- ============================================================================
-- §3.3 R3 — the Rim Current: the one place the water visibly moves
-- ============================================================================
-- "6 thin vertical Neon strips + particle emitter ... telegraphs downward flow". The strips are
-- WorldService's geometry; the flow is here. Attached to the middle strip so the particles start
-- inside the neon band rather than beside it.
VisualConfig.RimCurrent = {
    hostPath = "World/Rim/R3/R3_Strip_3",
    rate = 8,
    speed = 5,
    lifetime = 3.2,
    sizeMin = 0.4,
    sizeMax = 1.2,
    color = Color3.fromRGB(150, 215, 235),
    transparencyStart = 0.6,
    transparencyEnd = 1,
    spreadAngle = 12,
    emissionDirection = "Bottom", -- downward, the way the current pulls (§3.3 pushes north, flows down)
    acceleration = Vector3.new(0, -1.5, 0),
    lightEmission = 0.25,
    lightInfluence = 0.3,
    maxParticles = 30,
}

-- ============================================================================
-- §3.4 S4 — Thermal Vents: the Shelf's only warm light, and its long-range beacon
-- ============================================================================
-- "6 particle emitters (upward, slow)". One per chimney (S4_Chimney_1..6), very low rate: this is
-- water carrying heat, not smoke from a fire.
VisualConfig.VentPlumes = {
    hostFormat = "World/Shelf/S4/S4_Chimney_%d", -- six hosts, §3.4
    hostCount = 6,
    rate = 4,
    speed = 3,
    lifetime = 5,
    sizeMin = 0.8,
    sizeMax = 2.6,
    color = Color3.fromRGB(120, 92, 74), -- warm silt, lit by the vent rim it came out of
    transparencyStart = 0.55,
    transparencyEnd = 1,
    spreadAngle = 18,
    emissionDirection = "Top",
    acceleration = Vector3.new(0, 2, 0), -- it rises; slowly (§3.4 "upward, slow")
    lightEmission = 0.18,
    lightInfluence = 0.35,
    maxParticles = 24,
}

-- ============================================================================
-- Suspended matter — "the water is a place, not air"
-- ============================================================================
-- Silt drifting off the seabed (2 per band) and motes hanging in the sun shafts. Both are seed
-- effects: a few, at a rate of 2/s, so the eye reads water and the frame rate never notices.
VisualConfig.SeabedDust = {
    rate = 2,
    speed = 1.1,
    lifetime = 6,
    sizeMin = 0.4,
    sizeMax = 0.9,
    transparencyStart = 0.78,
    transparencyEnd = 1,
    spreadAngle = 180,
    emissionDirection = "Top",
    acceleration = Vector3.new(0, 0.25, 0),
    lightEmission = 0,
    lightInfluence = 1,
    maxParticles = 16,
    placements = {
        -- Attached to real seabed geometry by name, so the silt rises off the sand rather than
        -- out of an invisible marker (Appendix A: every world part is findable by name).
        { hostPath = "World/Shallows/Base/Base_Seabed_2_2", color = Color3.fromRGB(196, 183, 148) },
        { hostPath = "World/Shallows/Base/Base_Seabed_4_3", color = Color3.fromRGB(196, 183, 148) },
        { hostPath = "World/Rim/R1/R1_Step_4_Rock_W1", color = Color3.fromRGB(110, 120, 130) },
        { hostPath = "World/Rim/R1/R1_Step_4_Rock_E1", color = Color3.fromRGB(110, 120, 130) },
        { hostPath = "World/Shelf/Base/Base_Shelf_2_4", color = Color3.fromRGB(96, 106, 118) },
        { hostPath = "World/Shelf/Base/Base_Shelf_4_1", color = Color3.fromRGB(96, 106, 118) },
    },
}

VisualConfig.ShaftMotes = {
    rate = 2,
    speed = 0.6,
    lifetime = 8,
    sizeMin = 0.25,
    sizeMax = 0.6,
    color = Color3.fromRGB(224, 240, 236),
    transparencyStart = 0.7,
    transparencyEnd = 1,
    spreadAngle = 25,
    emissionDirection = "Bottom",
    acceleration = Vector3.new(0, -0.4, 0),
    lightEmission = 0.35, -- these are inside a light shaft; they should catch it
    lightInfluence = 0.2,
    maxParticles = 12,
    -- The first two sun shafts (LightingConfig.SunShafts.placements) carry the motes: shafts 1 and 3.
    hostIndices = { 1, 3 },
}

-- ============================================================================
-- §8.6 — bioluminescence: the Shelf's ONLY light source
-- ============================================================================
-- "A player should be able to hide in the dark and see lights before fish." Everything here is a
-- point of light with no geometry around it to explain it — that is the whole trick. Small parts
-- (a Neon speck) host the lights so the light has a visible source when you get close.
VisualConfig.Bioluminescence = {
    speck = {
        size = Vector3.new(0.35, 0.35, 0.35),
        material = "Neon",
        transparency = 0.15,
    },
    points = {
        -- Shallows' north edge (§3.2 L5 The Deep Hole): one cold shimmer over the hole, so the
        -- place the player cannot go yet is the place that glows.
        {
            zone = "Shallows",
            position = Vector3.new(-6, -78, 78),
            color = Color3.fromRGB(120, 200, 220),
            brightness = 1.2,
            range = 26,
        },
        -- The Rim Gate's far side — the first light a diver sees through the notch (§3.3 R2).
        {
            zone = "Rim",
            position = Vector3.new(0, -132, 208),
            color = Color3.fromRGB(130, 210, 225),
            brightness = 1.0,
            range = 30,
        },
        -- The Shelf: four points spread across the landmarks, so "deeper" reads as a scatter of
        -- living lights rather than one lamp (§8.6).
        {
            zone = "Shelf",
            position = Vector3.new(-48, -140, 268),
            color = Color3.fromRGB(120, 255, 190), -- the eel-lure green (§4.2)
            brightness = 1.3,
            range = 20,
        },
        {
            zone = "Shelf",
            position = Vector3.new(62, -168, 352),
            color = Color3.fromRGB(150, 225, 255),
            brightness = 1.1,
            range = 22,
        },
        {
            zone = "Shelf",
            position = Vector3.new(-120, -158, 312),
            color = Color3.fromRGB(110, 200, 230),
            brightness = 0.9,
            range = 18,
        },
        {
            zone = "Shelf",
            position = Vector3.new(0, -206, 400),
            color = Color3.fromRGB(255, 132, 60), -- the vent warmth, seen from the chasm lip
            brightness = 0.8,
            range = 18,
        },
    },
}

-- ============================================================================
-- §9 — landmark dressing: every place the player must recognise has a light on it
-- ============================================================================
-- The brief for the art pass, restated as data: dock, rod rack, Tide Trader, Rim Gate and each
-- Shelf landmark get a focal point, so the player navigates by eye and the place has shape. These
-- are the ONLY steady lights this system adds, and they are placed on existing landmark parts
-- (found by name, Appendix A) rather than on new geometry — dressing, not building.
--
-- `hostPath` is relative to Workspace.DeepTide. A host that cannot be found is reported as a
-- problem by VisualService:Build, and asserted to be zero problems by the visual suite, so a
-- renamed part cannot silently leave the dock unlit.
VisualConfig.LandmarkLights = {
    -- The dock, L1 (§3.2): a cold work lamp on the ramp, so the DIVE HERE water entry is legible
    -- from the water. The deck's own beacon (L1_Beacon) is already warm neon — this is the other
    -- half of the pair: warm beacon at the top, cold light at the water.
    {
        id = "DockRamp",
        hostPath = "World/Shallows/L1/L1_Ramp",
        zone = "Shallows",
        color = Color3.fromRGB(150, 200, 225),
        brightness = 1.6,
        range = 32,
    },
    -- The Rod Rack (§1 step 2): the first thing the player is told to walk to, so it gets the
    -- warmest small light on the dock.
    {
        id = "RodRack",
        hostPath = "Spawns/L1_RodRack",
        zone = "Shallows",
        color = Color3.fromRGB(255, 214, 140),
        brightness = 2.0,
        range = 24,
    },
    -- The Tide Trader (§1 step 8): a lamp over the stall's sign board.
    {
        id = "TideTraderSign",
        hostPath = "Spawns/L1_TideTrader_Sign",
        zone = "Shallows",
        color = Color3.fromRGB(255, 190, 120),
        brightness = 2.2,
        range = 28,
    },
    -- The trawler (§3.2 L3): the deep-side silhouette. A dim cold light on the broken mast is a
    -- nav mark over the sand flats — "there is something over there" — not a lamp.
    {
        id = "TrawlerMast",
        hostPath = "World/Shallows/L3/L3_Mast",
        zone = "Shallows",
        color = Color3.fromRGB(120, 170, 190),
        brightness = 0.8,
        range = 40,
    },
    -- The Deep Hole (§3.2 L5 exists "purely to make the player want a deeper rating"): its lip is
    -- lit so the mouth of it reads as a drop rather than as a dark patch of sand.
    {
        id = "DeepHoleLip",
        hostPath = "World/Shallows/L5/L5_Lip_Overhang",
        zone = "Shallows",
        color = Color3.fromRGB(70, 120, 150),
        brightness = 0.7,
        range = 30,
    },
    -- The Rim Gate (§3.3 R2): the notch is the one opening in a 400-stud wall and the single most
    -- important navigational fact in the world, so its keystone carries the coldest, furthest
    -- light in the Shallows' water.
    {
        id = "RimGateKeystone",
        hostPath = "World/Rim/R2/R2_Keystone",
        zone = "Rim",
        color = Color3.fromRGB(120, 190, 210),
        brightness = 1.6,
        range = 45,
    },
    -- The Rim Wall (§3.3 R1): a second, dimmer light further along the wall, so the wall reads as
    -- a wall (a long thing) and not as a doorway with nothing either side of it.
    {
        id = "RimWallWest",
        hostPath = "World/Rim/R1/R1_Step_3_Rock_W1",
        zone = "Rim",
        color = Color3.fromRGB(96, 156, 178),
        brightness = 0.9,
        range = 34,
    },
    -- The Lip (§3.4 S1 "Best-lit point in the Shelf; the player's arrival shot"): the brightest
    -- thing below 100 studs, and the reason the arrival into The Shelf reads as an arrival.
    {
        id = "ShelfLip",
        hostPath = "World/Shelf/S1/S1_Ledge",
        zone = "Shelf",
        color = Color3.fromRGB(150, 205, 230),
        brightness = 2.0,
        range = 55,
    },
    -- The Ghost Ledge (§3.4 S3): the mineral speckle is faint neon in the geometry; this light
    -- gives it something to be seen by, and marks where the ray crosses (§2's whole hook).
    {
        id = "GhostLedgeMineral",
        hostPath = "World/Shelf/S3/S3_MineralVein",
        zone = "Shelf",
        color = Color3.fromRGB(150, 190, 220),
        brightness = 1.4,
        range = 35,
    },
    -- The Sunken Pillars (§3.4 S5): cover the player weaves between, so it needs to be navigable
    -- in near-dark. Dim by design.
    {
        id = "SunkenPillar",
        hostPath = "World/Shelf/S5/S5_Pillar_1",
        zone = "Shelf",
        color = Color3.fromRGB(110, 160, 190),
        brightness = 1.0,
        range = 30,
    },
    -- The Chasm's edge (§3.4 S6 / §7): 25 studs below the tank's rating, the mouth of the next
    -- update. Lit just enough to be visibly a drop and visibly unfinished.
    {
        id = "ChasmLip",
        hostPath = "World/Shelf/S6/S6_LipRock_1",
        zone = "Shelf",
        color = Color3.fromRGB(96, 150, 180),
        brightness = 0.9,
        range = 24,
    },
}

-- Names VisualService gives the instances it owns, so a restyle can find them by name.
VisualConfig.InstanceNames = {
    Root = "Visual", -- Workspace.DeepTide.Visual, the folder for visual-only parts
    EmitterPrefix = "DT_", -- every emitter this system adds (idempotent rebuild looks for this)
    LightPrefix = "DT_",
}

return VisualConfig
