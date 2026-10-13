--!strict
--[[
Deep Tide — RodConfig   (GDD Appendix B, "RodConfig")
Source: GDD §5.3 (zone width / strain / fill modifiers), §5.4 (the unbreakable rod gate),
        §6.3 (shop SKUs 1 and 3, costs).
PURE DATA.
]]

local RodConfig = {}

RodConfig.Order = { "RustyRod", "BrassRod" }

-- §1 step 2: the Rod Rack hands the starter rod over with a line saying so, in the same voice as
-- §9's explainers. Format: the rod's printed name.
RodConfig.EquippedMessageFormat = "%s EQUIPPED — DIVE WHEN READY"
RodConfig.EquippedMessageSeconds = 2

RodConfig.Rods = {
	RustyRod = {
		id = "RustyRod",
		name = "Rusty Rod",
		tier = 1,
		cost = 0, -- starting gear, taken free from the Rod Rack (§6.1)
		maxRarity = "Rare", -- §5.4: an Epic fish can NEVER be landed with this rod
		lineStrength = 130, -- pounds; sets the over-tension ceiling T_max (§5.3 step 4)
		zoneWidthMult = 1.00, -- safe-zone half-width multiplier (§5.3 step 3)
		strainMult = 1.00, -- hold-meter drain multiplier (§5.3 step 5)
		fillMult = 1.00, -- hold-meter fill multiplier (§5.3 step 5)
	},
	BrassRod = {
		id = "BrassRod",
		name = "Brass Rod",
		tier = 2,
		cost = 750,
		maxRarity = "Epic",
		lineStrength = 260,
		zoneWidthMult = 1.35,
		strainMult = 0.70,
		fillMult = 1.15,
	},
}

return RodConfig
