--!strict
--[[
    ShopService — Appendix B: "The three SKUs, affordability, purchase transactions".
    Source: GDD §6.2 (SELL ALL is offered at the same stall), §6.3 (the whole shop:
            Reinforced Tank 280 C then Brass Rod 750 C, and the presentation order),
            §6.5 (the ordering is the design: the tank is the key), §6.6 (one disabled tab,
            no Robux anywhere), §9 (sticky cost-vs-cash comparison on every row, and never a
            purchase button that silently does nothing).

    Costs come from RodConfig/GearConfig; this service never hard-codes a price. Every
    transaction is: validate -> charge -> apply -> publish. A refusal always carries a reason
    the player can act on (§9).

    Why the tank is first: §6.5. The shop is the moment the player understands that the tank
    is the key to depth, so EconomyConfig.ShopOrder puts the Reinforced Tank on top and each
    row states its own measurable effect, read from the gear table.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)
local RodConfig = require(ReplicatedStorage.DeepTide.Config.RodConfig)
local GearConfig = require(ReplicatedStorage.DeepTide.Config.GearConfig)

local ShopService = Knit.CreateService({
	Name = "ShopService",
	Client = {},
})

local function economyService(): any
	return Knit.GetService("EconomyService")
end

local function gearService(): any
	return Knit.GetService("GearService")
end

local function fire(remoteName: string, player: Player, ...)
	Remotes.get(remoteName):FireClient(player, ...)
end

--- The config entry behind a SKU, whichever table owns it (§6.3).
local function skuEntry(sku: string): { [string]: any }?
	if RodConfig.Rods[sku] ~= nil then
		return RodConfig.Rods[sku]
	end
	return GearConfig.Gear[sku]
end

--- §6.3's measurable effect, built from the two gear tables so the row cannot drift from
--- what the purchase actually does: a tank reports the rating and air it grants, a rod
--- reports the rarity ceiling it raises.
local function effectLabelFor(player: Player, sku: string): string
	local gear = GearConfig.Gear[sku]
	if gear ~= nil then
		return EconomyConfig.ShopRowLabel.gearEffectFormat:format(
			gearService():GetDepthRating(player),
			gear.depthRating,
			gear.airCapacity
		)
	end
	local rod = RodConfig.Rods[sku]
	if rod ~= nil then
		return EconomyConfig.ShopRowLabel.rodEffectFormat:format(
			gearService():GetRodStats(player).maxRarity,
			rod.maxRarity
		)
	end
	return ""
end

-- Public server API -----------------------------------------------------------

--- The shop rows in presentation order (§6.3): Reinforced Tank first and flagged as the
--- recommended buy, Brass Rod below it labelled "UNLOCKS: GHOST RAY (600 C)".
function ShopService:GetSkuStates(player: Player): { Types.ShopSkuState }
	local states: { Types.ShopSkuState } = {}
	local coins = economyService():GetCoins(player)

	for _, sku in EconomyConfig.ShopOrder do
		local entry = EconomyConfig.Shop[sku]
		local gearOrRod = skuEntry(sku)

		if entry ~= nil and gearOrRod ~= nil then
			local price = gearOrRod.cost
			local owned = gearService():Owns(player, sku)
			local affordable = economyService():CanAfford(player, price)
			table.insert(states, {
				sku = sku,
				name = gearOrRod.name,
				category = entry.category,
				cost = price,
				affordable = affordable,
				owned = owned,
				recommended = entry.recommended,
				unlockLabel = entry.unlockLabel,
				shortfall = if affordable then 0 else math.max(0, price - coins),
				effectLabel = effectLabelFor(player, sku),
			})
		end
	end

	return states
end

--- Coins plus every row's affordability, for the shop UI (§9). Never a purchase button
--- that silently does nothing.
function ShopService:GetState(player: Player): Types.ShopState
	return {
		coins = economyService():GetCoins(player),
		skus = self:GetSkuStates(player),
	}
end

function ShopService:CanPurchase(player: Player, sku: string): boolean
	if table.find(EconomyConfig.ShopOrder, sku) == nil then
		return false
	end
	if skuEntry(sku) == nil then
		return false
	end
	if gearService():Owns(player, sku) then
		return false
	end
	return economyService():CanAfford(player, skuEntry(sku).cost)
end

--- The purchase transaction. Applies the effect via GearService and deducts via
--- EconomyService — 280 C is exactly 280 C (§11), and the tank immediately sets
--- AIR 300s / RATING 240m (§6.3).
--- Returns (success, reasonForFailure?) so the UI can explain a refusal (§9).
---
--- Order matters: the charge is attempted first (so an unaffordable buy changes nothing at
--- all), and the equip is applied only after the coins have moved — a failure to equip
--- refunds, so the shop can never take 280 C and hand back nothing.
function ShopService:Purchase(player: Player, sku: string): (boolean, string?)
	local entry = EconomyConfig.Shop[sku]
	local gearOrRod = skuEntry(sku)

	if table.find(EconomyConfig.ShopOrder, sku) == nil or entry == nil or gearOrRod == nil then
		local reason = EconomyConfig.PurchaseMessage.unknownFormat:format(tostring(sku))
		fire("Notify", player, { text = reason, seconds = EconomyConfig.PurchaseMessage.seconds })
		return false, reason
	end

	if gearService():Owns(player, sku) then
		local reason = EconomyConfig.PurchaseMessage.ownedFormat:format(gearOrRod.name)
		fire("Notify", player, { text = reason, seconds = EconomyConfig.PurchaseMessage.seconds })
		self:_Push(player)
		return false, reason
	end

	if not economyService():CanAfford(player, gearOrRod.cost) then
		local coins = economyService():GetCoins(player)
		local reason = EconomyConfig.PurchaseMessage.shortfallFormat:format(math.max(0, gearOrRod.cost - coins))
		-- §9: the refusal is spoken, and the row the player is looking at is re-pushed so the
		-- comparison stays true to their balance.
		fire("Notify", player, { text = reason, seconds = EconomyConfig.PurchaseMessage.seconds })
		self:_Push(player)
		return false, reason
	end

	if not economyService():TrySpend(player, gearOrRod.cost) then
		local reason = EconomyConfig.PurchaseMessage.shortfallFormat:format(gearOrRod.cost)
		fire("Notify", player, { text = reason, seconds = EconomyConfig.PurchaseMessage.seconds })
		self:_Push(player)
		return false, reason
	end

	local equipped = if GearConfig.Gear[sku] ~= nil
		then gearService():SetEquippedGear(player, sku)
		else gearService():SetEquippedRod(player, sku)

	if not equipped then
		-- Nothing to hand over: give the Coins back rather than charging for air.
		economyService():AddCoins(player, gearOrRod.cost, "purchaseRefund")
		local reason = EconomyConfig.PurchaseMessage.unknownFormat:format(gearOrRod.name)
		fire("Notify", player, { text = reason, seconds = EconomyConfig.PurchaseMessage.seconds })
		self:_Push(player)
		return false, reason
	end

	-- §6.3: the row says what the purchase does, and the line the player reads says the same
	-- numbers — both read from the gear table after the equip, so they cannot disagree.
	local message = if GearConfig.Gear[sku] ~= nil
		then EconomyConfig.PurchaseMessage.gearFormat:format(
			GearConfig.Gear[sku].name,
			GearConfig.Gear[sku].depthRating,
			GearConfig.Gear[sku].airCapacity
		)
		else EconomyConfig.PurchaseMessage.rodFormat:format(RodConfig.Rods[sku].name, entry.unlockLabel)

	fire("Notify", player, { text = message, seconds = EconomyConfig.PurchaseMessage.seconds })
	self:_Push(player)
	return true
end

--- §1 step 8 / §6.2: the Tide Trader's own verb. SELL ALL is offered at the same stall as
--- the shop, so the controller asks the shop for it and the shop asks the economy.
function ShopService:SellAll(player: Player): Types.SellAllResult
	local result = economyService():SellAll(player)
	self:_Push(player)
	return result
end

--- §9: push the whole shop state — coins plus every row — so the client redraws from one
--- payload. Firing this is also how the Tide Trader prompt "opens" the shop (§1 step 8):
--- the panel appears when the state arrives, so there is no second open/close protocol.
function ShopService:_Push(player: Player)
	fire("ShopStateChanged", player, self:GetState(player))
end

--- The Tide Trader prompt's verb (§1 step 8).
function ShopService:OpenFor(player: Player)
	self:_Push(player)
end

-- Client surface -------------------------------------------------------------

function ShopService.Client:GetState(player: Player): Types.ShopState
	return self.Server:GetState(player)
end

--- §6.2: SELL ALL from the shop panel. Selling is authoritative — the client asks, the
--- server pays.
function ShopService.Client:SellAll(player: Player): Types.SellAllResult
	return self.Server:SellAll(player)
end

-- Knit lifecycle --------------------------------------------------------------

function ShopService:KnitInit()
	-- §6.3, §9: the purchase request is bound to the buy path; the reply reaches the client
	-- through ShopStateChanged / CoinsChanged / Notify rather than a return value, so a
	-- refusal cannot be lost in transit.
	Remotes.get("ShopBuyRequest").OnServerEvent:Connect(function(player: Player, sku: string)
		if type(sku) == "string" then
			self:Purchase(player, sku)
		end
	end)
end

function ShopService:KnitStart() end

return ShopService
