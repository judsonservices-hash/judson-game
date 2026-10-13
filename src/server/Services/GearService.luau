--!strict
--[[
	GearService — Appendix B: "Equipped rod + dive gear, DepthRating, LineStrength modifiers,
	applies effects to combat/dive maths".
	Source: GDD §0 lever 1 (gear is a key, not a stat), §5.3 step 3-5 (zone width, strain,
	fill modifiers), §5.4 (MaxRarity wall), §6.3 (the two upgrades).

	The only service that answers "what is this player holding, and what does that allow?".
	FishingService asks it for rod modifiers; DiveService asks it for rating and air.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local RodConfig = require(ReplicatedStorage.DeepTide.Config.RodConfig)
local GearConfig = require(ReplicatedStorage.DeepTide.Config.GearConfig)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)

local GearService = Knit.CreateService {
	Name = "GearService",
	Client = {},
}

-- Rod -------------------------------------------------------------------------

--- "RustyRod" until the Brass Rod is bought.
function GearService:GetEquippedRodId(player: Player): string
	-- TODO(§6.1): read PlayerService profile.equippedRodId.
	return EconomyConfig.StartingRodId
end

function GearService:GetRodStats(player: Player): Types.RodConfigEntry
	return RodConfig.Rods[self:GetEquippedRodId(player)]
end

--- §5.4: can this rod land that rarity at all? One comparison of RarityConfig.Rank —
--- Rusty Rod (Rare) can never land the Ghost Ray (Epic), by design, at any skill level.
function GearService:CanLandRarity(player: Player, rarity: string): boolean
	-- TODO(§5.4): return RarityConfig.Rank[rarity] <= RarityConfig.Rank[GetRodStats(player).maxRarity]
	return false
end

--- Equip a rod the player owns (Rod Rack handout or a shop purchase).
function GearService:SetEquippedRod(player: Player, rodId: string): boolean
	-- TODO: validate rodId against RodConfig.Rods, write the profile, push the HUD readout.
	return false
end

-- Dive gear -------------------------------------------------------------------

--- "RubberLungs" until the Reinforced Tank is bought.
function GearService:GetEquippedGearId(player: Player): string
	-- TODO(§6.1): read PlayerService profile.equippedGearId.
	return EconomyConfig.StartingGearId
end

function GearService:GetGearStats(player: Player): Types.GearConfigEntry
	return GearConfig.Gear[self:GetEquippedGearId(player)]
end

--- §3.1/§6.3: 90 studs, or 240 with the Reinforced Tank.
function GearService:GetDepthRating(player: Player): number
	return self:GetGearStats(player).depthRating
end

--- §6.3: 100 s, or 300 with the Reinforced Tank.
function GearService:GetAirCapacity(player: Player): number
	return self:GetGearStats(player).airCapacity
end

function GearService:SetEquippedGear(player: Player, gearId: string): boolean
	-- TODO: validate against GearConfig.Gear, write the profile, tell DiveService to
	-- re-apply the new capacity (§6.3: the purchase immediately sets AIR 300s / RATING 240m).
	return false
end

--- What the HUD shows as the rod (§9: `ROD: RUSTY / BRASS` — the player must be able to
--- blame the rod correctly when a line snaps).
function GearService:GetRodReadout(player: Player): { id: string, name: string, tier: number, maxRarity: string }
	local rod = self:GetRodStats(player)
	return { id = rod.id, name = rod.name, tier = rod.tier, maxRarity = rod.maxRarity }
end

-- Client surface -------------------------------------------------------------

function GearService.Client:GetRodReadout(player: Player): { id: string, name: string, tier: number, maxRarity: string }
	return self.Server:GetRodReadout(player)
end

-- Knit lifecycle --------------------------------------------------------------

function GearService:KnitInit() end

function GearService:KnitStart() end

return GearService
