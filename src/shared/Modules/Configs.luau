--!strict
--[[
	Deep Tide — Configs (single entry point for every config table)
	Source: GDD Appendix A (Config/ layout) and Appendix B (config tables).

	Gameplay code should require this one module and never build require paths itself:

		local Config = require(game:GetService("ReplicatedStorage").DeepTide.Modules.Configs)
		local fish = Config.Fish.Species[speciesId]

	These are references, not copies — every requirer sees the same tables.
]]

local Modules = script.Parent
local DeepTide = Modules.Parent

local Configs = {
	Fish = require(DeepTide.Config.FishConfig), -- GDD §4, §5.5, §4.5
	Spawn = require(DeepTide.Config.SpawnConfig), -- GDD §4.6
	Landmark = require(DeepTide.Config.LandmarkConfig), -- GDD §3.2-§3.4
	Rarity = require(DeepTide.Config.RarityConfig), -- GDD §4.1
	Rod = require(DeepTide.Config.RodConfig), -- GDD §5.3, §5.4, §6.3
	Gear = require(DeepTide.Config.GearConfig), -- GDD §3.1, §6.3
	Dive = require(DeepTide.Config.DiveConfig), -- GDD §3, §5.4, §8.8
	Fight = require(DeepTide.Config.FightConfig), -- GDD §5.1-§5.6
	Economy = require(DeepTide.Config.EconomyConfig), -- GDD §6
	Zone = require(DeepTide.Config.ZoneConfig), -- GDD §3
}

return Configs
