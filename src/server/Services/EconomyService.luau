--!strict
--[[
    EconomyService — Appendix B: "Coins, sell-all, purchase validation, the single source of
    truth for player balance".
    Source: GDD §6.1 (starting cash 0 C), §6.2 (sell values, SELL ALL), §6.3 (the 280 C and
            750 C purchases), §9 (cash readout, income animates), §11 (SELL ALL pays exactly
            the §6.2 table, a forced ascent never costs a banked fish).

    Every Coin in the game moves through this service. Coins are integers only (§6).

    The rule this file exists to keep: a transaction either happens completely or not at all.
    Selling pays the exact FishConfig sum for every logged fish and only then clears the log;
    spending is checked before it is applied. Nothing here may credit a wrong sum, silently
    drop a fish, or leave a half-finished purchase behind.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)

local EconomyService = Knit.CreateService({
	Name = "EconomyService",
	Client = {},
})

local function playerService(): any
	return Knit.GetService("PlayerService")
end

local function inventoryService(): any
	return Knit.GetService("InventoryService")
end

--- Coins are integers (§6) and never negative: this is the only place a balance is read from
--- the profile, so nothing downstream has to defend against a nil or a fractional balance.
local function balanceOf(player: Player): number
	local data = playerService():GetData(player)
	if data == nil or type(data.coins) ~= "number" then
		return EconomyConfig.StartingCoins
	end
	return math.max(0, math.floor(data.coins))
end

local function fire(remoteName: string, player: Player, ...)
	Remotes.get(remoteName):FireClient(player, ...)
end

-- Public server API -----------------------------------------------------------

--- Current balance (§9: `C 295`, top-right, always).
function EconomyService:GetCoins(player: Player): number
	return balanceOf(player)
end

--- Adds (or subtracts, with a negative amount) and fires CoinsChanged (§9: the delta
--- animates into the counter). Returns the new balance. Clamped at 0 — a balance can never
--- go negative, so an unaffordable spend can never be expressed as a debt.
function EconomyService:AddCoins(player: Player, amount: number, reason: string?): number
	local data = playerService():GetData(player)
	local before = balanceOf(player)
	local delta = math.floor(amount or 0)
	if data == nil or delta == 0 then
		return before
	end

	local after = math.max(0, before + delta)
	data.coins = after

	-- The HUD animates the true delta, not the requested one, so a clamped spend still reads
	-- honestly on screen.
	fire("CoinsChanged", player, after, after - before)
	if reason ~= nil then
		print(("[Deep Tide] economy: %s %+d C (%s)"):format(player.Name, after - before, reason))
	end
	return after
end

function EconomyService:CanAfford(player: Player, cost: number): boolean
	return balanceOf(player) >= math.max(0, math.floor(cost))
end

--- Spend cost Coins atomically. false (with nothing changed) when unaffordable — the
--- shop must never silently fail a purchase (§9).
function EconomyService:TrySpend(player: Player, cost: number): boolean
	local price = math.max(0, math.floor(cost))
	if not self:CanAfford(player, price) then
		return false
	end
	if price == 0 then
		return true
	end
	self:AddCoins(player, -price, "spend")
	return true
end

--- SELL ALL at the Tide Trader (§6.2): pays exactly the FishConfig values for every
--- logged catch, then clears the log. No haggling, no fluctuation, no cooldown.
---
--- Both the count and the sum are taken from InventoryService, which derives them from the
--- fish table the Catch Log's running `TOTAL` is drawn from — so the number the player read
--- and the coins they receive cannot disagree. The log is cleared only after the payment has
--- landed, so no fish is ever dropped without payment.
function EconomyService:SellAll(player: Player): Types.SellAllResult
	local inventory = inventoryService()

	local soldCount = inventory:GetFishCount(player)
	local coinsEarned = inventory:GetTotalCoins(player)

	if soldCount > 0 then
		self:AddCoins(player, coinsEarned, "sellAll")
		inventory:Clear(player)
		fire("Notify", player, {
			text = EconomyConfig.SellAllMessage.soldFormat:format(soldCount, coinsEarned),
			seconds = EconomyConfig.SellAllMessage.seconds,
		})
	else
		fire("Notify", player, {
			text = EconomyConfig.SellAllMessage.emptyFormat,
			seconds = EconomyConfig.SellAllMessage.seconds,
		})
	end

	return {
		soldCount = soldCount,
		coinsEarned = coinsEarned,
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
	-- CoinsChanged is fired by AddCoins: the push stays on the server, so the client can never
	-- disagree with the true balance. The only thing left to do at join is tell the player what
	-- they are holding (a rejoining player's last balance is already in the profile by then).
	game:GetService("Players").PlayerAdded:Connect(function(player)
		task.defer(function()
			if playerService():IsLoaded(player) then
				fire("CoinsChanged", player, self:GetCoins(player), 0)
			end
		end)
	end)
end

function EconomyService:KnitStart() end

return EconomyService
