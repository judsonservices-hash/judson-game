--!strict
--[[
	Deep Tide — PlayerStore (server-side helper module, NOT a Knit service)
	Source: GDD §10 ("save persistence ... if a DataStore is added it must be a stub that
	         cannot fail the loop"), §11 ("no Engine errors or warnings during a full loop").

	The slice's only persistence: a player's Coins and Catch Log.

	Design rules
	  * every DataStore call is wrapped in pcall — a persistence failure can never error the loop;
	  * if Studio API access is unavailable (the default) it degrades to session-only data
	    and reports the mode instead of throwing;
	  * to persist in Studio: Game Settings > Security > "Enable Studio Access to API Services".

	This module is intentionally outside Services/ so Knit never treats it as a service.
]]

local DataStoreService = game:GetService("DataStoreService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local EconomyConfig = require(ReplicatedStorage.DeepTide.Config.EconomyConfig)
local RodConfig = require(ReplicatedStorage.DeepTide.Config.RodConfig)
local GearConfig = require(ReplicatedStorage.DeepTide.Config.GearConfig)

local PlayerStore = {}

PlayerStore.StoreName = "DeepTide_PlayerData_v1"
PlayerStore.SchemaVersion = 1

-- "session-only" | "DataStore". Read by the boot line.
PlayerStore.mode = "session-only"

local store: DataStore? = nil

local function keyFor(player: Player): string
	return ("player_%d"):format(player.UserId)
end

--- A fresh profile (§6.1: 0 C, Rusty Rod, Rubber Lungs, empty Catch Log).
function PlayerStore.defaultData(): Types.PlayerData
	return {
		schemaVersion = PlayerStore.SchemaVersion,
		coins = EconomyConfig.StartingCoins,
		catchLog = {},
		equippedRodId = EconomyConfig.StartingRodId,
		equippedGearId = EconomyConfig.StartingGearId,
	}
end

--- Probes DataStore availability once. Never throws; sets PlayerStore.mode.
function PlayerStore.init(): string
	local gotStore, result = pcall(function()
		return DataStoreService:GetDataStore(PlayerStore.StoreName)
	end)

	if not gotStore then
		PlayerStore.mode = "session-only"
		return PlayerStore.mode
	end

	store = result

	-- Studio with "Enable Studio Access to API Services" off fails here, which is the
	-- expected case, not an error.
	local probed = pcall(function()
		return (store :: DataStore):GetAsync("__deeptide_probe__")
	end)

	PlayerStore.mode = if probed then "DataStore" else "session-only"
	return PlayerStore.mode
end

--- Loads coins + catch log for a player.
--- Returns (persisted, data): `persisted` is false when the session-only fallback is
--- serving defaults, so callers can tell the difference without handling errors.
function PlayerStore.load(player: Player): (boolean, Types.PlayerData)
	local data = PlayerStore.defaultData()

	if store == nil or PlayerStore.mode ~= "DataStore" then
		return false, data
	end

	local ok, result = pcall(function()
		return (store :: DataStore):GetAsync(keyFor(player))
	end)

	if not ok or type(result) ~= "table" then
		return false, data
	end

	for field, value in data do
		if result[field] ~= nil then
			data[field] = value
		end
	end
	data.schemaVersion = PlayerStore.SchemaVersion
	return true, data
end

--- Saves coins + catch log. Returns false when there is nothing to save to.
function PlayerStore.save(player: Player, data: Types.PlayerData): boolean
	if store == nil or PlayerStore.mode ~= "DataStore" then
		return false
	end

	local ok = pcall(function()
		(store :: DataStore):SetAsync(keyFor(player), data)
	end)

	if not ok then
		warn(("[Deep Tide] PlayerStore: save failed for %s"):format(player.Name))
	end
	return ok
end

return PlayerStore
