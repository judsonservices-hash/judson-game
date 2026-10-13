--!strict
--[[
Deep Tide — RarityConfig   (the rarity enum + its shared per-rarity numbers)
Source: GDD §4.1 (rarity ladder), §5.2 step 5 (hook-set window), §5.3 step 5 (line strain).
PURE DATA.

RarityConfig.Rarity is the enum used across the codebase. Rank is the ordering
that the rod gate (§5.4) compares: fish.rarity rank > rod.maxRarity rank => line snaps.
]]

local RarityConfig = {}

RarityConfig.Rarity = {
Common = "Common",
Uncommon = "Uncommon",
Rare = "Rare",
Epic = "Epic",
}

-- Lowest -> highest.
RarityConfig.Order = { "Common", "Uncommon", "Rare", "Epic" }

RarityConfig.Rank = {
Common = 1,
Uncommon = 2,
Rare = 3,
Epic = 4,
}

-- UI colour code (§4.1).
RarityConfig.Color = {
Common = Color3.fromRGB(180, 190, 200),
Uncommon = Color3.fromRGB(110, 200, 150),
Rare = Color3.fromRGB(140, 170, 255),
Epic = Color3.fromRGB(230, 170, 255),
}

-- Hook-set ring shrink window in seconds (§4.1 / §5.5 "Hook window" column).
RarityConfig.HookSetWindow = {
Common = 0.50,
Uncommon = 0.42,
Rare = 0.34,
Epic = 0.26,
}

-- Hold-meter drain multiplier (§4.1 "Line-strain multiplier" = §5.5 "strainMult" column).
RarityConfig.StrainMult = {
Common = 1.00,
Uncommon = 1.25,
Rare = 1.55,
Epic = 2.00,
}

-- Sell-value band in Coins, inclusive (§4.1). Actual per-species values live in FishConfig.
RarityConfig.SellValueBand = {
Common = { 15, 40 },
Uncommon = { 60, 100 },
Rare = { 200, 300 },
Epic = { 500, 700 },
}

return RarityConfig
