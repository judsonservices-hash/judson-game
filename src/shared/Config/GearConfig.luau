--!strict
--[[
Deep Tide — GearConfig   (GDD Appendix B, "GearConfig (dive)")
Source: GDD §3.1 (gear rating required per zone), §5.4 (auto-surface rule thresholds),
        §6.3 (shop SKU 2), §6.5 (the 280 C gate).
PURE DATA. DepthRating is what makes gear "a key, not a stat" (§0 lever 1).
]]

local GearConfig = {}

GearConfig.Order = { "RubberLungs", "ReinforcedTank" }

-- What a player wears is server state, but the HUD has to show it (§9: `ROD: RUSTY / BRASS`)
-- without a remote of its own. GearService stamps these attributes on the Player instance; they
-- replicate to the owning client, which is all the readout needs.
GearConfig.PlayerAttributes = {
	RodId = "EquippedRodId",
	GearId = "EquippedGearId",
}

GearConfig.Gear = {
	RubberLungs = {
		id = "RubberLungs",
		name = "Rubber Lungs",
		tier = 1,
		cost = 0, -- equipped free at spawn (§6.1)
		airCapacity = 100, -- seconds
		depthRating = 90, -- studs
	},
	ReinforcedTank = {
		id = "ReinforcedTank",
		name = "Reinforced Tank",
		tier = 2,
		cost = 280, -- the first upgrade; opens The Shelf (§3.1)
		airCapacity = 300, -- seconds
		depthRating = 240, -- studs
	},
}

return GearConfig
