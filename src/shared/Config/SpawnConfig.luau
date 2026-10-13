--!strict
--[[
	Deep Tide — SpawnConfig
	Source: GDD §4.6 "Fixed spawn coordinates (copy these straight into config)".
	PURE DATA. Depths/positions are exact; do not re-roll them.

	Behaviour => container:
	  "School" / "Patrol" / "Flee"  -> per-species spawn node list (FishService spawns count fish across them)
	  "Ambush"                     -> one den per coordinate, opening faces -Z
	The unit of `nodes` is a node/anchor; FishConfig.behaviourCfg.count is how many there are.
]]

local SpawnConfig = {}

SpawnConfig.SilverSardine = {
	kind = "School",
	box = Vector3.new(44, 22, 44), -- box around each anchor
	anchors = {
		Vector3.new(-140, -15, -110),
		Vector3.new(-70, -15, -110),
		Vector3.new(70, -15, -20),
		Vector3.new(140, -15, -20),
		Vector3.new(-140, -15, 70),
		Vector3.new(-40, -15, 70),
		Vector3.new(0, -20, -120),
		Vector3.new(110, -15, 60),
	},
}

SpawnConfig.SunsetGrouper = {
	kind = "Node",
	waypointRadius = 40,
	waypointsPerNode = 3,
	nodes = {
		Vector3.new(-160, -30, -40),
		Vector3.new(-60, -30, -80),
		Vector3.new(20, -30, -40),
		Vector3.new(90, -30, 10),
		Vector3.new(170, -30, -90),
		Vector3.new(-110, -30, 20),
		Vector3.new(60, -30, 110),
		Vector3.new(-30, -30, 120),
		Vector3.new(140, -30, 80),
		Vector3.new(-180, -30, -120),
	},
}

SpawnConfig.ReefBass = {
	kind = "Node",
	driftRadius = 45,
	nodes = {
		Vector3.new(-120, -60, -140),
		Vector3.new(-20, -60, -110),
		Vector3.new(80, -60, -60),
		Vector3.new(160, -60, -30),
		Vector3.new(-90, -60, 90),
		Vector3.new(40, -60, 130),
	},
}

SpawnConfig.LanternEel = {
	kind = "Den",
	openingFacing = "-Z",
	dens = {
		Vector3.new(-170, -140, 260),
		Vector3.new(-100, -150, 300),
		Vector3.new(-35, -135, 275),
		Vector3.new(25, -155, 310),
		Vector3.new(95, -140, 270),
		Vector3.new(150, -150, 320),
		Vector3.new(190, -145, 290),
	},
}

SpawnConfig.GhostRay = {
	kind = "Node",
	loopBox = Vector3.new(180, 30, 120),
	nodes = {
		Vector3.new(-80, -172, 370),
		Vector3.new(0, -170, 395),
		Vector3.new(80, -172, 360),
	},
}

return SpawnConfig
