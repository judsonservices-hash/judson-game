--!strict
--[[
	InventoryService — Appendix B: "The Catch Log (unsold catches), add/clear/aggregate".
	Source: GDD §1 step 6 (a landed fish enters the Catch Log instantly, no Coins yet),
	        §6.2 (SELL ALL is the only conversion), §9 (Catch Log panel: species, rarity
	        colour, count, running TOTAL, clear on SELL ALL).

	Nothing here knows what a fish is worth at sale time — values come from the fish table
	so the log can show a running total before any Coins exist (§9).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local FishConfig = require(ReplicatedStorage.DeepTide.Config.FishConfig)

local InventoryService = Knit.CreateService {
	Name = "InventoryService",
	Client = {},
}

-- Public server API -----------------------------------------------------------

--- Adds one landed fish as a Catch Log row (§1 step 6). Rows are keyed by species and
--- carry the count, so a dive of 4 sardines is one row reading "x4".
--- Returns the updated log.
function InventoryService:AddCatch(player: Player, speciesId: string): { Types.CatchLogEntry }
	-- TODO(§1 step 6): upsert the row from FishConfig.Species[speciesId]
	-- (name/rarity/value), then fire Remotes.CatchLogChanged (§9).
	return {}
end

function InventoryService:GetEntries(player: Player): { Types.CatchLogEntry }
	-- TODO: return the player's unsold rows.
	return {}
end

--- Running total in Coins for the unsold log (§9: `TOTAL 295 C`). Derived from
--- EconomyConfig.SellValues, not from anything the client sends.
function InventoryService:GetTotalCoins(player: Player): number
	local total = 0
	for _, entry in self:GetEntries(player) do
		local value = FishConfig.Species[entry.speciesId].value
		total += value * entry.count
	end
	return total
end

--- Clears the log. Only EconomyService:SellAll should call this (§6.2).
function InventoryService:Clear(player: Player)
	-- TODO: empty the log and fire Remotes.CatchLogChanged.
end

-- Client surface -------------------------------------------------------------

--- Initial log so the panel can draw before the first CatchLogChanged arrives (§9).
function InventoryService.Client:GetCatchLog(player: Player): { Types.CatchLogEntry }
	return self.Server:GetEntries(player)
end

-- Knit lifecycle --------------------------------------------------------------

function InventoryService:KnitInit() end

function InventoryService:KnitStart() end

return InventoryService
