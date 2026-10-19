--!strict
--[[
    Deep Tide — LandmarkConfig
    Source: GDD §3.2 (The Shallows, L1-L9), §3.3 (The Rim, R1-R3), §3.4 (The Shelf, S1-S6),
            Appendix A (naming rule: every landmark part is named "<ID>_<Piece>").
    PURE DATA — anchor positions and part counts for the blockout builder and WorldService.

    Deviation note: this file is not named in Appendix A/B. It exists so landmark
    coordinates live as data instead of being re-typed from the GDD by every implementer.

    `position` is only set where the GDD prints an explicit (X, Y, Z). Where the GDD
    defines a landmark as a volume instead, `position` is nil and `regionRef` names the
    table that holds its extents (numbers are never repeated across config files).
    Eel den coordinates live in SpawnConfig (§4.6).

    Part-count note: the counts listed in §3.2/§3.3/§3.4 sum to 226 (Shallows 102, Rim 54,
    Shelf 70). Appendix A's "~280 Parts" is the *world* total, not a landmark total: 226
    landmarks + 44 seabed (§3.1: 24 sand + 20 rock) + 8 world props/anchors = 278.
    The per-landmark counts are authoritative and PartBudget below is the measured build
    target; WorldService asserts its built geometry against it and warns on any mismatch.
]]

local LandmarkConfig = {}

-- Appendix A's original estimate, kept so the GDD's own disagreement stays visible in code.
LandmarkConfig.TotalWorldPartsPerAppendixA = 280
LandmarkConfig.SumOfLandmarkPartCounts = 226

-- What the blockout actually builds (measured from WorldService:GetLayout, 2026-10-13).
-- Landmarks + Seabed + WorldProps + SpawnAnchorHosts must equal World.
LandmarkConfig.PartBudget = {
	Landmarks = 226, -- §3.2-§3.4 per-landmark counts (includes the 4 L1 props that live in Spawns)
	Seabed = 44, -- §3.1: 24 sand + 20 rock (ZoneConfig.Seabed)
	WorldProps = 3, -- SpawnLocation, DiveMarker, WaterRegionMarker
	SpawnAnchorHosts = 5, -- one invisible anchor host per species (Appendix A: spawn volumes)
	World = 278,
	FishLive = 74, -- §4.5: 48 + 10 + 6 + 7 + 3 (the GDD prints that sum as 79; the sum is 74)
	FishParts = 81, -- Appendix C: one Part per fish, two for the Lantern Eel (7 lures)
}
LandmarkConfig.PartBudget.GrandTotal = LandmarkConfig.PartBudget.World + LandmarkConfig.PartBudget.FishParts

LandmarkConfig.Landmarks = {
	-- THE SHALLOWS (§3.2) ----------------------------------------------------
	{ id = "L1", name = "Deep Tide Dock", zone = "Shallows", position = Vector3.new(0, 6, -10), parts = 12 },
	{ id = "L2", name = "Coral Spire", zone = "Shallows", position = Vector3.new(-120, -30, 70), parts = 9 },
	{ id = "L3", name = "The Trawler (wreck)", zone = "Shallows", position = Vector3.new(140, -58, -60), parts = 12 },
	{ id = "L4", name = "Kelp Field", zone = "Shallows", position = Vector3.new(-40, -35, -100), parts = 34 },
	{ id = "L5", name = "The Deep Hole", zone = "Shallows", position = Vector3.new(0, -85, 90), parts = 6 },
	{ id = "L6", name = "Sand Channels", zone = "Shallows", position = nil, parts = 12 }, -- 12 ridges at Y -44, scattered
	{ id = "L7", name = "Fish Rock Cluster", zone = "Shallows", position = Vector3.new(-160, -30, 30), parts = 8 },
	{ id = "L8", name = "Sun Shafts", zone = "Shallows", position = nil, parts = 0 }, -- Y 0 -> -60, Technical Artist
	{
		id = "L9",
		name = "Surface Buoys",
		zone = "Shallows",
		position = Vector3.new(0, 1, 120),
		parts = 9,
		positions = { Vector3.new(0, 1, 120), Vector3.new(-80, 1, 60), Vector3.new(80, 1, 60) },
	},

	-- THE RIM (§3.3) ---------------------------------------------------------
	{ id = "R1", name = "Rim Wall", zone = "Rim", position = nil, parts = 40, regionRef = "ZoneConfig.Rim.wall" },
	{
		id = "R2",
		name = "The Rim Gate (notch)",
		zone = "Rim",
		position = nil,
		parts = 8,
		regionRef = "ZoneConfig.Rim.gate",
	},
	{ id = "R3", name = "Rim Current", zone = "Rim", position = nil, parts = 6, regionRef = "ZoneConfig.Rim.current" },

	-- THE SHELF (§3.4) -------------------------------------------------------
	{ id = "S1", name = "The Lip", zone = "Shelf", position = Vector3.new(0, -108, 240), parts = 10 },
	{ id = "S2", name = "Crevice Row (Eel dens)", zone = "Shelf", position = nil, parts = 7 }, -- SpawnConfig.LanternEel.dens
	{ id = "S3", name = "Ghost Ledge", zone = "Shelf", position = Vector3.new(0, -175, 380), parts = 8 },
	{ id = "S4", name = "Thermal Vents", zone = "Shelf", position = Vector3.new(110, -205, 440), parts = 14 },
	{ id = "S5", name = "Sunken Pillars", zone = "Shelf", position = Vector3.new(-130, -165, 330), parts = 9 },
	{ id = "S6", name = "The Chasm", zone = "Shelf", position = nil, parts = 22, regionRef = "ZoneConfig.Chasm" },
}

-- Interaction props that host ProximityPrompts (§1 steps 2, 3 and 8, §3.2 L1).
-- These four L1 props live in Workspace.DeepTide.Spawns (Appendix A), not in the Shallows
-- folder, and are 4 of L1's 12 parts. `actionText` is what the prompt shows; Roblox prefixes
-- the key itself, so §1's "E — Take Rusty Rod" is actionText = "Take Rusty Rod".
LandmarkConfig.PromptHosts = {
	{
		id = "RodRack",
		zone = "Shallows",
		landmark = "L1",
		position = Vector3.new(12, 9, -10),
		objectText = "Rod Rack",
		actionText = "Take Rusty Rod",
		holdDuration = 0,
	},
	{
		id = "TideTrader",
		zone = "Shallows",
		landmark = "L1",
		position = Vector3.new(-14, 9, -10),
		objectText = "Tide Trader",
		actionText = "Trade",
		holdDuration = 0,
	},
	{
		id = "DiveMarker",
		zone = "Shallows",
		landmark = "L1",
		-- §3.2 gives the marker no coordinate; the ramp meets the water at Z 8, so the marker
		-- hangs just above that point (ZoneConfig.InteractionPoints.DiveMarker).
		position = Vector3.new(0, 2.5, 8),
		objectText = "Dive Point",
		actionText = "Dive",
		holdDuration = 0,
		-- §1 step 3: the marker's verb is the dive itself — the hint is what the prompt says
		-- when the player uses it (WorldService:WirePrompts pushes it as a §9 Notify).
		hint = "DIVE — SWIM DOWN, FISH HOLD IN THE SHALLOWS",
	},
}

-- How long a prompt's hint line stays on the HUD (§9's 2-3 s explainer band).
LandmarkConfig.PromptHintSeconds = 3

-- Prompt hosts that are not landmark parts, so the builder counts them separately
-- (LandmarkConfig.PartBudget.WorldProps). Naming rule Appendix A: "<ID>_<Piece>".
LandmarkConfig.WorldPropNames = {
	SpawnLocation = "SpawnLocation",
	DiveMarker = "DiveMarker",
	WaterRegionMarker = "WaterRegionMarker",
}

return LandmarkConfig
