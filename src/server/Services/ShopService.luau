--!strict
--[[
	ShopService — Appendix B: "The three SKUs, affordability, purchase transactions".
	Source: GDD §6.3 (the whole shop: Rusty Rod 0 C, Reinforced Tank 280 C, Brass Rod 750 C
	        and the presentation order), §6.5 (target times), §6.6 (one disabled tab, no
	        Robux anywhere), §9 (sticky cost-vs-cash comparison on every row).

	Costs come from RodConfig/GearConfig; this service never hard-codes a price.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)
local RodConfig = require(ReplicatedStorage.DeepTide.Config.RodConfig)
local GearConfig = require(ReplicatedStorage.DeepTide.Config.GearConfig)

local ShopService = Knit.CreateService {
	Name = "ShopService",
	Client = {},
}

-- Public server API -----------------------------------------------------------

--- The shop rows in presentation order (§6.3): Reinforced Tank first and flagged as the
--- recommended buy, Brass Rod below it labelled "UNLOCKS: GHOST RAY (600 C)".
function ShopService:GetSkuStates(player: Player): { Types.ShopSkuState }
	local states: { Types.ShopSkuState } = {}

	for _, sku in EconomyConfig.ShopOrder do
		local entry = EconomyConfig.Shop[sku]
		local price = if entry ~= nil and entry.cost ~= nil then entry.cost else 0

		table.insert(states, {
			sku = sku,
			name = (RodConfig.Rods[sku] or GearConfig.Gear[sku]).name,
			category = entry.category,
			cost = price,
			affordable = false, -- TODO(§9): EconomyService:CanAfford(player, price)
			owned = false, -- TODO(§6.3): GearService already holds this SKU
			recommended = entry.recommended,
			unlockLabel = entry.unlockLabel,
		})
	end

	return states
end

--- Coins plus every row's affordability, for the shop UI (§9). Never a purchase button
--- that silently does nothing.
function ShopService:GetState(player: Player): Types.ShopState
	-- TODO(§9): fill coins from EconomyService:GetCoins.
	return {
		coins = EconomyConfig.StartingCoins,
		skus = self:GetSkuStates(player),
	}
end

function ShopService:CanPurchase(player: Player, sku: string): boolean
	-- TODO(§6.3): sku is a member of ShopOrder, not already owned, and affordable.
	return false
end

--- The purchase transaction. Applies the effect via GearService and deducts via
--- EconomyService — 280 C is exactly 280 C (§11), and the tank immediately sets
--- AIR 300s / RATING 240m (§6.3).
--- Returns (success, reasonForFailure?) so the UI can explain a refusal (§9).
function ShopService:Purchase(player: Player, sku: string): (boolean, string?)
	-- TODO(§6.3): validate -> GearService:SetEquippedGear/SetEquippedRod ->
	-- EconomyService:TrySpend -> fire ShopStateChanged + CoinsChanged + Notify.
	return false, "not implemented"
end

-- Client surface -------------------------------------------------------------

function ShopService.Client:GetState(player: Player): Types.ShopState
	return self.Server:GetState(player)
end

-- Knit lifecycle --------------------------------------------------------------

function ShopService:KnitInit()
	-- TODO(§6.3, §9): bind Remotes.ShopBuyRequest to Purchase; the reply reaches the
	-- client through ShopStateChanged / Notify rather than a return value.
end

function ShopService:KnitStart() end

return ShopService
