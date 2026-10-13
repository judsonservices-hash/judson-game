--!strict
--[[
	EconomyService — Appendix B: "Coins, sell-all, purchase validation, the single source of
	truth for player balance".
	Source: GDD §6.1 (starting cash 0 C), §6.2 (sell values, SELL ALL), §6.3 (the 280 C and
	        750 C purchases), §9 (cash readout, income animates).

	Every Coin in the game moves through this service. Coins are integers only (§6).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)

local EconomyService = Knit.CreateService {
	Name = "EconomyService",
	Client = {},
}

-- Public server API -----------------------------------------------------------

--- Current balance (§9: `C 295`, top-right, always).
function EconomyService:GetCoins(player: Player): number
	-- TODO(§6.1): read from PlayerService:GetData(player).coins.
	return EconomyConfig.StartingCoins
end

--- Adds (or subtracts, with a negative amount) and fires CoinsChanged (§9: the delta
--- animates into the counter). Returns the new balance.
function EconomyService:AddCoins(player: Player, amount: number, reason: string?): number
	-- TODO(§9): write through PlayerService, clamp at 0, fire Remotes.CoinsChanged.
	return EconomyConfig.StartingCoins
end

function EconomyService:CanAfford(player: Player, cost: number): boolean
	return self:GetCoins(player) >= cost
end

--- Spend cost Coins atomically. false (with nothing changed) when unaffordable — the
--- shop must never silently fail a purchase (§9).
function EconomyService:TrySpend(player: Player, cost: number): boolean
	-- TODO(§6.3): CanAfford -> AddCoins(-cost).
	return false
end

--- SELL ALL at the Tide Trader (§6.2): pays exactly the FishConfig values for every
--- logged catch, then clears the log. No haggling, no fluctuation, no cooldown.
function EconomyService:SellAll(player: Player): Types.SellAllResult
	-- TODO(§6.2): InventoryService:GetEntries -> sum value x count -> AddCoins ->
	-- InventoryService:Clear -> return { soldCount, coinsEarned, newBalance }.
	return {
		soldCount = 0,
		coinsEarned = 0,
		newBalance = self:GetCoins(player),
	}
end

-- Client surface -------------------------------------------------------------

--- Initial balance so the HUD can draw before the first CoinsChanged arrives (§9).
function EconomyService.Client:GetCoins(player: Player): number
	return self.Server:GetCoins(player)
end

-- Knit lifecycle --------------------------------------------------------------

function EconomyService:KnitInit()
	-- TODO(§9): nothing to bind here — CoinsChanged is fired by AddCoins. Keep the push
	-- on the server so the client can never disagree with the true balance.
end

function EconomyService:KnitStart() end

return EconomyService
