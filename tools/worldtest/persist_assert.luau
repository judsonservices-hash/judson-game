--[[
    Deep Tide — headless persistence test, assertions half.

    `PlayerStore` and `PlayerService` are in scope (loaded by check.sh). This drives the real
    lifecycle: join -> mutate -> leave -> rejoin -> shutdown, plus the session-only fallback,
    and asserts coins and the catch log actually round-trip through the store.
]]

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok    " .. msg)
    else
        print("  FAIL  " .. msg)
        failures += 1
    end
end

local Economy = __config("EconomyConfig")

local function player(name, userId)
    return { Name = name, UserId = userId }
end

print("=== 7. PERSISTENCE (PlayerStore + PlayerService) ===")
check(PlayerStore.init() == "DataStore", "PlayerStore.init() reports DataStore when the API answers")

-- Boot the service the way Knit would.
PlayerService:KnitInit()
check(PlayerService:GetPersistenceMode() == "DataStore", "PlayerService surfaces the DataStore mode")

-- Join -> defaults -> mutate -> leave -> saved
local alice = player("Alice", 1001)
playersService.PlayerAdded:Fire(alice)
check(PlayerService:IsLoaded(alice), "PlayerAdded loads a profile")
local aliceData = PlayerService:GetData(alice)
check(aliceData ~= nil and aliceData.coins == Economy.StartingCoins, ("joins with StartingCoins (%s)"):format(tostring(Economy.StartingCoins)))
check(aliceData ~= nil and #aliceData.catchLog == 0, "joins with an empty catch log")

if aliceData then
    aliceData.coins = 512
    table.insert(aliceData.catchLog, { speciesId = "ReefBass", name = "Reef Bass", rarity = "Rare", value = 90, count = 2 })
end
playersService.PlayerRemoving:Fire(alice)
check(not PlayerService:IsLoaded(alice), "PlayerRemoving drops the profile")
local savedAlice = FAKE.saved["player_1001"]
check(savedAlice ~= nil and savedAlice.coins == 512, ("coins 512 saved on leave (%s)"):format(tostring(savedAlice and savedAlice.coins)))
check(savedAlice ~= nil and type(savedAlice.catchLog) == "table" and #savedAlice.catchLog == 1, "catch log saved on leave")
check(#releasedPlayers == 1 and releasedPlayers[1] == "Alice", "sibling services got ReleasePlayer (per-player teardown)")

-- Rejoin reads the saved values back (this is what the PlayerStore.load field bug broke).
FAKE.saved["player_1002"] = {
    schemaVersion = 0,
    coins = 742,
    catchLog = { { speciesId = "GhostRay", name = "Ghost Ray", rarity = "Epic", value = 600, count = 1 } },
    equippedRodId = "BrassRod",
    equippedGearId = "ReinforcedTank",
}
local bob = player("Bob", 1002)
playersService.PlayerAdded:Fire(bob)
local bobData = PlayerService:GetData(bob)
check(bobData ~= nil and bobData.coins == 742, ("rejoining player loads saved coins (%s)"):format(tostring(bobData and bobData.coins)))
check(bobData ~= nil and #bobData.catchLog == 1 and bobData.catchLog[1].speciesId == "GhostRay", "rejoining player loads the saved catch log")
check(bobData ~= nil and bobData.equippedRodId == "BrassRod" and bobData.equippedGearId == "ReinforcedTank", "equipped rod/gear restored")
check(bobData ~= nil and bobData.schemaVersion == PlayerStore.SchemaVersion, "schema version stamped on load")

-- Shutdown save (BindToClose)
if bobData then
    bobData.coins = 999
end
check(BIND_TO_CLOSE ~= nil, "BindToClose handler registered")
if BIND_TO_CLOSE then
    BIND_TO_CLOSE()
    check(FAKE.saved["player_1002"] ~= nil and FAKE.saved["player_1002"].coins == 999, "BindToClose saves every loaded profile")
end

-- Session-only fallback: no API access must degrade, never error.
FAKE.fail = true
check(PlayerStore.init() == "session-only", "PlayerStore.init() falls back to session-only when the API refuses")
local carol = player("Carol", 1003)
local okLoad = pcall(function()
    return PlayerService:LoadPlayer(carol)
end)
check(okLoad, "LoadPlayer cannot error without API access")
local carolData = PlayerService:GetData(carol)
check(carolData ~= nil and carolData.coins == Economy.StartingCoins, "session-only still serves the §6.1 starting state")
local okSave = pcall(function()
    return PlayerService:SavePlayer(carol)
end)
check(okSave, "SavePlayer cannot error without API access")
check(PlayerService:SavePlayer(carol) == false, "SavePlayer reports false instead of throwing")
local okRelease = pcall(function()
    PlayerService:ReleasePlayer(carol)
end)
check(okRelease, "ReleasePlayer cannot error without API access")
check(not PlayerService:IsLoaded(carol), "ReleasePlayer drops the profile after a failed save")
check(PlayerService:IsLoaded(bob), "profiles are per-player (Bob survives Carol's release)")

print(("=== PERSISTENCE RESULT: %d failure(s) ==="):format(failures))
if failures > 0 then
    error("persistence harness failures: " .. failures)
end
