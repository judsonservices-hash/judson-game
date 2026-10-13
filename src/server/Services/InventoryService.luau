--!strict
--[[
	InventoryService — Appendix B: "The Catch Log (unsold catches), add/clear/aggregate".
	Source: GDD §1 step 6 (a landed fish enters the Catch Log instantly, no Coins yet),
	        §6.2 (SELL ALL is the only conversion), §9 (Catch Log panel: species, rarity
	        colour, count, running TOTAL, clear on SELL ALL), §11 (the log survives a rejoin —
	        it lives inside the per-player profile that PlayerStore already persists).

	Nothing here knows what a fish is worth at sale time — values come from the fish table so the
	log can show a running total before any Coins exist (§9).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local FishConfig = require(ReplicatedStorage.DeepTide.Config.FishConfig)

local InventoryService = Knit.CreateService({
	Name = "InventoryService",
	Client = {},
})

local function playerService(): any
	return Knit.GetService("PlayerService")
end

local function logOf(player: Player): { Types.CatchLogEntry }?
	local data = playerService():GetData(player)
	if data == nil then
		return nil
	end
	if data.catchLog == nil then
		data.catchLog = {}
	end
	return data.catchLog
end

--- §9: push the whole log plus its running total — the panel redraws from one payload, and the
--- client never computes a value the economy has not agreed to.
function InventoryService:_Push(player: Player)
	local entries = self:GetEntries(player)
	Remotes.get("CatchLogChanged"):FireClient(player, entries, self:GetTotalCoins(player))
end

-- Public server API -----------------------------------------------------------

--- Adds one landed fish as a Catch Log row (§1 step 6). Rows are keyed by species and
--- carry the count, so a dive of 4 sardines is one row reading "x4".
--- Returns the updated log.
function InventoryService:AddCatch(player: Player, speciesId: string): { Types.CatchLogEntry }
	local log = logOf(player)
	local species = FishConfig.Species[speciesId]
	if log == nil or species == nil then
		return {}
	end

	for _, entry in log do
		if entry.speciesId == speciesId then
			entry.count += 1
			entry.value = species.value
			entry.name = species.name
			entry.rarity = species.rarity
			self:_Push(player)
			return log
		end
	end

	table.insert(log, {
		speciesId = speciesId,
		name = species.name,
		rarity = species.rarity,
		value = species.value,
		count = 1,
	})
	self:_Push(player)
	return log
end

function InventoryService:GetEntries(player: Player): { Types.CatchLogEntry }
	local log = logOf(player)
	if log == nil then
		return {}
	end
	return log
end

--- Running total in Coins for the unsold log (§9: `TOTAL 295 C`). Derived from
--- FishConfig's fish table, not from anything the client sends.
function InventoryService:GetTotalCoins(player: Player): number
	local total = 0
	for _, entry in self:GetEntries(player) do
		local species = FishConfig.Species[entry.speciesId]
		local value = if species ~= nil then species.value else entry.value
		if value ~= nil then
			total += value * entry.count
		end
	end
	return total
end

--- How many fish are in the log (the shop's SELL ALL reports this; §6.2).
function InventoryService:GetFishCount(player: Player): number
	local total = 0
	for _, entry in self:GetEntries(player) do
		total += entry.count
	end
	return total
end

--- Clears the log. Only EconomyService:SellAll should call this (§6.2).
function InventoryService:Clear(player: Player)
	local log = logOf(player)
	if log == nil then
		return
	end
	for index = #log, 1, -1 do
		table.remove(log, index)
	end
	self:_Push(player)
end

function InventoryService:ReleasePlayer(player: Player)
	-- nothing cached outside the profile; the profile itself is PlayerService's to save
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
