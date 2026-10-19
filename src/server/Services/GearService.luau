--!strict
--[[
    GearService — Appendix B: "Equipped rod + dive gear, DepthRating, LineStrength modifiers,
    applies effects to combat/dive maths".
    Source: GDD §0 lever 1 (gear is a key, not a stat), §5.3 steps 3-5 (zone width, strain,
    fill modifiers), §5.4 (MaxRarity wall), §6.1 (the starting kit), §6.3 (the two upgrades),
    §9 (`ROD: RUSTY / BRASS` — the player must be able to blame the rod correctly).

    The only service that answers "what is this player holding, and what does that allow?".
    FishingService asks it for rod stats; DiveService asks it for rating and air.

    Ownership vs equipping: in the slice a rod a player owns is the rod they hold (§6.1: the Rusty
    Rod is free and taken from the rack; §6.3: the Brass Rod is bought), and the dive gear works
    the same way. ShopService (the next delegation) buys the item and hands it over with
    SetEquippedRod / SetEquippedGear — the purchase rules are the shop's, not this file's.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local RodConfig = require(ReplicatedStorage.DeepTide.Config.RodConfig)
local GearConfig = require(ReplicatedStorage.DeepTide.Config.GearConfig)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)
local Tension = require(ReplicatedStorage.DeepTide.Modules.Tension)

local GearService = Knit.CreateService({
	Name = "GearService",
	Client = {},
})

local function playerService(): any
	return Knit.GetService("PlayerService")
end

local function isGearOwned(data: Types.PlayerData, gearId: string): boolean
	return data.equippedGearId == gearId
end

-- Rod -------------------------------------------------------------------------

--- "RustyRod" until the Brass Rod is bought.
function GearService:GetEquippedRodId(player: Player): string
	local data = playerService():GetData(player)
	local rodId = if data ~= nil and data.equippedRodId ~= nil then data.equippedRodId else EconomyConfig.StartingRodId
	if RodConfig.Rods[rodId] == nil then
		rodId = EconomyConfig.StartingRodId
	end
	return rodId
end

function GearService:GetRodStats(player: Player): Types.RodConfigEntry
	return RodConfig.Rods[self:GetEquippedRodId(player)]
end

--- §5.4: can this rod land that rarity at all? One comparison of RarityConfig.Rank —
--- Rusty Rod (Rare) can never land the Ghost Ray (Epic), by design, at any skill level.
function GearService:CanLandRarity(player: Player, rarity: string): boolean
	return Tension.rarityAllowed(self:GetRodStats(player).maxRarity, rarity)
end

--- Equip a rod the player owns (Rod Rack handout or a shop purchase).
function GearService:SetEquippedRod(player: Player, rodId: string): boolean
	local rod = RodConfig.Rods[rodId]
	if rod == nil then
		return false
	end
	local data = playerService():GetData(player)
	if data == nil then
		return false
	end
	data.equippedRodId = rodId
	player:SetAttribute(GearConfig.PlayerAttributes.RodId, rodId)
	return true
end

-- Dive gear -------------------------------------------------------------------

--- "RubberLungs" until the Reinforced Tank is bought.
function GearService:GetEquippedGearId(player: Player): string
	local data = playerService():GetData(player)
	local gearId = if data ~= nil and data.equippedGearId ~= nil
		then data.equippedGearId
		else EconomyConfig.StartingGearId
	if GearConfig.Gear[gearId] == nil then
		gearId = EconomyConfig.StartingGearId
	end
	return gearId
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
	local gear = GearConfig.Gear[gearId]
	if gear == nil then
		return false
	end
	local data = playerService():GetData(player)
	if data == nil then
		return false
	end
	data.equippedGearId = gearId
	player:SetAttribute(GearConfig.PlayerAttributes.GearId, gearId)
	-- §6.3: the purchase immediately sets AIR 300s / RATING 240m — DiveService tops the tank up
	-- to the new capacity rather than leaving the player on a half-full 100 s tank.
	Knit.GetService("DiveService"):ApplyGearCapacity(player)
	return true
end

--- What the HUD shows as the rod (§9: `ROD: RUSTY / BRASS` — the player must be able to
--- blame the rod correctly when a line snaps).
function GearService:GetRodReadout(player: Player): { id: string, name: string, tier: number, maxRarity: string }
	local rod = self:GetRodStats(player)
	return { id = rod.id, name = rod.name, tier = rod.tier, maxRarity = rod.maxRarity }
end

--- §6.1/§6.3: what the player is wearing, in one payload (used by the boot line and the HUD).
function GearService:GetReadout(player: Player): { [string]: any }
	local rod = self:GetRodStats(player)
	local gear = self:GetGearStats(player)
	return {
		rodId = rod.id,
		rodName = rod.name,
		rodTier = rod.tier,
		maxRarity = rod.maxRarity,
		lineStrength = rod.lineStrength,
		gearId = gear.id,
		gearName = gear.name,
		airCapacity = gear.airCapacity,
		depthRating = gear.depthRating,
	}
end

--- Stamps the two attributes the client reads (§9 readouts) and is called on load and on change.
function GearService:SyncAttributes(player: Player)
	player:SetAttribute(GearConfig.PlayerAttributes.RodId, self:GetEquippedRodId(player))
	player:SetAttribute(GearConfig.PlayerAttributes.GearId, self:GetEquippedGearId(player))
end

--- §1 step 2: the Rod Rack hands out the Rusty Rod. Idempotent — the rack is not a consumable,
--- and a player who already has a better rod keeps it.
function GearService:TakeStarterRod(player: Player): boolean
	local current = self:GetEquippedRodId(player)
	if
		RodConfig.Rods[current] ~= nil
		and RodConfig.Rods[current].tier > RodConfig.Rods[EconomyConfig.StartingRodId].tier
	then
		self:SyncAttributes(player)
		return false
	end
	return self:SetEquippedRod(player, EconomyConfig.StartingRodId)
end

--- §3.1: is this gear the one that opens The Shelf? (Used by the boot line and the shop.)
function GearService:OpensZone(player: Player, zoneId: string): boolean
	local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)
	local zone = ZoneConfig.Zones[zoneId]
	if zone == nil then
		return false
	end
	return self:GetDepthRating(player) >= zone.requiredDepthRating
end

--- §3.1 / §3.3 / §6.3: the zone-entry rule's other half. Answers "does the player's gear open
--- this zone, and if not, what does?" — the cheapest gear tier whose DepthRating reaches the
--- zone's requirement, named and priced from GearConfig (never from the world or the UI), so
--- the refusal the player reads is a shopping list (§9).
function GearService:GetZoneAccess(player: Player, zoneId: string): { [string]: any }
	local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)
	local zone = ZoneConfig.Zones[zoneId]
	local rating = self:GetDepthRating(player)
	if zone == nil then
		return { opens = true, rating = rating, required = 0 }
	end

	local required = zone.requiredDepthRating
	local key: Types.GearConfigEntry? = nil
	for _, gearId in GearConfig.Order do
		local gear = GearConfig.Gear[gearId]
		if gear ~= nil and gear.depthRating >= required and (key == nil or gear.cost < key.cost) then
			key = gear
		end
	end

	return {
		opens = rating >= required,
		rating = rating,
		required = required,
		gearId = if key ~= nil then key.id else nil,
		gearName = if key ~= nil then key.name else nil,
		gearCost = if key ~= nil then key.cost else nil,
		gearRating = if key ~= nil then key.depthRating else nil,
	}
end

function GearService:Owns(player: Player, itemId: string): boolean
	local data = playerService():GetData(player)
	if data == nil then
		return false
	end
	return data.equippedRodId == itemId or data.equippedGearId == itemId or isGearOwned(data, itemId)
end

--- §1 step 2: the Rod Rack's verb — take the starter rod and say so in the §9 voice. Kept as a
--- method (rather than wired here) so WorldService:WirePrompts owns every prompt's connection
--- and no prompt can end up with two handlers, or none.
function GearService:OnRodRackTriggered(player: Player)
	local took = self:TakeStarterRod(player)
	self:SyncAttributes(player)
	if took then
		local rod = self:GetRodStats(player)
		Remotes.get("Notify"):FireClient(player, {
			text = RodConfig.EquippedMessageFormat:format(string.upper(rod.name)),
			seconds = RodConfig.EquippedMessageSeconds,
		})
	end
end

-- Client surface -------------------------------------------------------------

function GearService.Client:GetRodReadout(player: Player): { id: string, name: string, tier: number, maxRarity: string }
	return self.Server:GetRodReadout(player)
end

function GearService.Client:GetReadout(player: Player): { [string]: any }
	return self.Server:GetReadout(player)
end

-- Knit lifecycle --------------------------------------------------------------

function GearService:KnitInit()
	game:GetService("Players").PlayerAdded:Connect(function(player)
		-- The profile may not be loaded yet (PlayerService loads it on its own PlayerAdded), so
		-- the attribute is re-stamped whenever the client asks for the readout as well.
		task.defer(function()
			if playerService():IsLoaded(player) then
				self:SyncAttributes(player)
			end
		end)
	end)
end

function GearService:KnitStart()
	-- §1 step 2: the Rod Rack's ProximityPrompt is connected by WorldService:WirePrompts (which
	-- owns every prompt host). The verb itself is OnRodRackTriggered, above.
end

return GearService
