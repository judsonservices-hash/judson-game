--!strict
--[[
	PlayerService — Appendix B: "Join/leave, PlayerData bootstrap, placeholder persistence".
	Source: GDD §6.1 (starting state: 0 C, Rusty Rod, Rubber Lungs, empty Catch Log),
	        §10 (persistence is a stub that cannot fail the loop).

	Owns the per-player profile and its lifecycle. Coins and the Catch Log live inside
	the profile; the services that change them (EconomyService, InventoryService) ask
	this service for it. Skeleton only — TODOs mark where the scripter fills in.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local PlayerStore = require(script.Parent.Parent.Modules.PlayerStore)

local PlayerService = Knit.CreateService {
	Name = "PlayerService",
}

local dataByPlayer: { [Player]: Types.PlayerData } = {}

-- Public server API -----------------------------------------------------------

--- The player's profile, or nil before it is loaded.
function PlayerService:GetData(player: Player): Types.PlayerData?
	return dataByPlayer[player]
end

function PlayerService:IsLoaded(player: Player): boolean
	return dataByPlayer[player] ~= nil
end

--- "DataStore" or "session-only" (§10). Surfaced on the boot line.
function PlayerService:GetPersistenceMode(): string
	return PlayerStore.mode
end

function PlayerService:LoadPlayer(player: Player): boolean
	-- TODO(§6.1, §10): PlayerStore.load(player) into dataByPlayer.
	-- The session-only fallback returns the default profile, which is the correct
	-- starting state anyway (EconomyConfig.StartingCoins / StartingRodId / StartingGearId).
	return false
end

function PlayerService:SavePlayer(player: Player): boolean
	-- TODO(§10): PlayerStore.save(player, profile) when IsLoaded(player).
	return false
end

function PlayerService:ReleasePlayer(player: Player)
	-- TODO: save, drop the profile, and let the other services drop their per-player state.
end

-- Knit lifecycle --------------------------------------------------------------

function PlayerService:KnitInit()
	-- Probe persistence once so PlayerStore.mode is known before the boot line prints.
	PlayerStore.init()

	-- TODO(§10): Players.PlayerAdded -> LoadPlayer
	--             Players.PlayerRemoving -> SavePlayer + ReleasePlayer
	--             game:BindToClose -> save every loaded player; wrap in pcall so a
	--             shutdown save failure cannot surface as an error.
end

function PlayerService:KnitStart() end

return PlayerService
