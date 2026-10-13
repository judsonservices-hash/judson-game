--!strict
--[[
    PlayerService — Appendix B: "Join/leave, PlayerData bootstrap, placeholder persistence".
    Source: GDD §6.1 (starting state: 0 C, Rusty Rod, Rubber Lungs, empty Catch Log),
            §10 (persistence is a stub that cannot fail the loop).

    Owns the per-player profile and its lifecycle. Coins and the Catch Log live inside
    the profile; the services that change them (EconomyService, InventoryService) ask
    this service for it.

    Persistence is wired and cannot fail the loop: every DataStore call inside PlayerStore
    is pcall'd, and a Studio session without API access degrades to session-only data
    (PlayerStore.mode) instead of erroring. A profile is loaded on join, saved on leave,
    and saved once more on shutdown (BindToClose).

    Per-player teardown rule: PlayerService:ReleasePlayer saves the profile, drops it, then
    calls `ReleasePlayer(player)` on every sibling service that defines it — so any service
    holding per-player state (a cooldown table, a live fight) drops it by implementing that
    one method. Nothing else has to know who holds what.
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

--- §6.1, §10: load the profile (coins + catch log) and publish it. Returns whether real
--- persistence answered: false means the session-only defaults are in use, which is the
--- correct starting state anyway (EconomyConfig.StartingCoins / StartingRodId / StartingGearId).
function PlayerService:LoadPlayer(player: Player): boolean
    local persisted, data = PlayerStore.load(player)
    dataByPlayer[player] = data
    return persisted
end

--- §10: write the profile back. Returns false when nothing was loaded or when there is
--- no DataStore to write to (session-only), never an error.
function PlayerService:SavePlayer(player: Player): boolean
    local data = dataByPlayer[player]
    if data == nil then
        return false
    end
    local ok, saved = pcall(function()
        return PlayerStore.save(player, data)
    end)
    return ok and saved == true
end

--- Save, drop the profile, and let every sibling service drop its own per-player state.
--- Called on PlayerRemoving and on shutdown.
function PlayerService:ReleasePlayer(player: Player)
    if dataByPlayer[player] ~= nil then
        self:SavePlayer(player)
    end
    dataByPlayer[player] = nil

    for _, module in script.Parent:GetChildren() do
        if module:IsA("ModuleScript") and module.Name ~= self.Name then
            local resolved, service = pcall(function()
                return Knit.GetService(module.Name)
            end)
            local release = if resolved and type(service) == "table" then (service :: any).ReleasePlayer else nil
            if type(release) == "function" then
                local ok, err = pcall(function()
                    release(service, player)
                end)
                if not ok then
                    warn(("[Deep Tide] PlayerService: %s.ReleasePlayer failed: %s"):format(module.Name, tostring(err)))
                end
            end
        end
    end
end

-- Knit lifecycle --------------------------------------------------------------

function PlayerService:KnitInit()
    -- Probe persistence once so PlayerStore.mode is known before the boot line prints.
    PlayerStore.init()

    Players.PlayerAdded:Connect(function(player)
        self:LoadPlayer(player)
    end)

    Players.PlayerRemoving:Connect(function(player)
        self:ReleasePlayer(player)
    end)

    -- §10: a shutdown save cannot surface as an error. Each save is pcall'd inside
    -- SavePlayer, and the whole sweep is wrapped too.
    game:BindToClose(function()
        pcall(function()
            for player in dataByPlayer do
                self:SavePlayer(player)
            end
        end)
    end)

    -- A player can already be in the game when this runs (Studio's local player, or someone
    -- who joined during the boot): PlayerAdded will not fire for them.
    for _, player in Players:GetPlayers() do
        if not self:IsLoaded(player) then
            self:LoadPlayer(player)
        end
    end
end

function PlayerService:KnitStart() end

return PlayerService
