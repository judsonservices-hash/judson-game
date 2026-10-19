--!strict
--[[
    Deep Tide — EconomyConfig
    Source: GDD §6.1 (starting state), §6.2 (sell values), §6.3 (the three shop SKUs),
            §6.4 (first-upgrade maths), §6.5 (target times), §6.6 (the disabled Robux tab),
            Appendix B ("EconomyConfig").
    PURE DATA. Coins are integers only.

    SellValues repeats FishConfig.Species[x].value on purpose — the economy table has to be
    readable in one place. Modules/ConfigCheck asserts the two never drift apart.
]]

local EconomyConfig = {}

-- Starting state (§6.1). The first dive must be the first payment.
EconomyConfig.StartingCoins = 0
EconomyConfig.StartingRodId = "RustyRod"
EconomyConfig.StartingGearId = "RubberLungs"
EconomyConfig.CatchLogIsUnlimited = true -- slice inventory has no cap
EconomyConfig.SellAllEnabled = true -- no haggling, no price fluctuation, no sell cooldown

-- Sell values in Coins (§6.2).
EconomyConfig.SellValues = {
	SilverSardine = 15,
	SunsetGrouper = 40,
	ReefBass = 90,
	LanternEel = 260,
	GhostRay = 600,
}

-- Real-play fight time and the balance axis (§6.2). Coins/second = value / this.
-- Bare-minimum fight times with perfect play are in §5.5 (5.0 / 5.6 / 6.7 / 8.3 / 11.1 s).
EconomyConfig.FightTimeSeconds = {
	SilverSardine = 7.0,
	SunsetGrouper = 7.8,
	ReefBass = 9.4,
	LanternEel = 11.6,
	GhostRay = 15.5,
}

EconomyConfig.CoinsPerSecondOfFight = {
	SilverSardine = 2.1,
	SunsetGrouper = 5.1,
	ReefBass = 9.6,
	LanternEel = 22.4,
	GhostRay = 38.7,
}

-- Shop presentation order (§6.3): the tank is the recommended first buy, the rod sits
-- below it labelled with the fish it unlocks. Costs and effects live in RodConfig /
-- GearConfig; this table is the shop's own view of the world.
EconomyConfig.ShopOrder = { "ReinforcedTank", "BrassRod" }

EconomyConfig.Shop = {
	ReinforcedTank = {
		sku = "ReinforcedTank",
		category = "Dive gear Tier 2",
		cost = 280,
		recommended = true, -- §6.3 presentation rule: top item, visually recommended
		unlockLabel = "OPENS: THE SHELF",
		unlockCondition = "always visible; greyed until affordable",
	},
	BrassRod = {
		sku = "BrassRod",
		category = "Rod Tier 2",
		cost = 750,
		recommended = false,
		unlockLabel = "UNLOCKS: GHOST RAY (600 C)",
		unlockCondition = "visible from the start",
	},
}

-- §6.6: no monetisation exists in the slice. One disabled tab keeps the layout slot open.
EconomyConfig.DisabledShopTab = {
	label = "—",
	enabled = false,
	note = "reserved for an eventual gamepass / cosmetic tab; no MarketplaceService call exists in the slice",
}

-- Target times in seconds from spawn (§6.5).
EconomyConfig.Targets = {
	FirstUpgradeSeconds = 230, -- 3:50 — Reinforced Tank, 280 C
	FirstUpgradeBandSeconds = { 180, 300 },
	SliceCompleteSeconds = 320, -- 5:20 — standing in The Shelf
	SliceCompleteBandSeconds = { 300, 480 },
	BrassRodDivesAfterGate = 2, -- the session-2 hook, after the slice ends
	BrassRodBandSeconds = { 240, 480 },
	SessionLengthSeconds = { 480, 720 },
}

-- The three routes to 280 C that §6.4 checks the gate against.
EconomyConfig.Routes = {
	Median = { dives = 2, catches = 8, dive1 = 110, dive2 = 185, total = 295, surplus = 15 },
	MinimumSkill = { sardines = 19, total = 285, maxDives = 4 }, -- the balance floor
	Fast = { reefBass = 4, total = 360, dives = 2, surplus = 80 }, -- the highest-value Shallows target
}

-- Tuning alarms (§6.4). If these fire, raise value — never fish density.
EconomyConfig.TuningAlarm = {
	MedianMinutesToFirstUpgrade = 5,
	AlternateSardineValue = 18,
	AlternateTankCost = 250,
}

-- §11: no single dive may produce more than this in the Shallows.
EconomyConfig.MaxShallowsDiveCoins = 700

-- ---------------------------------------------------------------------------
-- Transaction feedback (§9: "never a loss without a reason and a next step";
-- a purchase refusal always says why). Only the wordings live here — every
-- number they print is read from the fish/rod/gear tables at the moment of use.
-- ---------------------------------------------------------------------------
EconomyConfig.SellAllMessage = {
	soldFormat = "SOLD %d FISH — +%d C", -- params: fish sold, coins earned
	emptyFormat = "NOTHING TO SELL — CATCH SOMETHING FIRST",
	seconds = 2,
}

EconomyConfig.PurchaseMessage = {
	-- §6.3: the row's own truth said back — a tank reports its rating and air, a rod reports
	-- the fish it unlocks. Parameters come from GearConfig / RodConfig, never from here.
	gearFormat = "%s EQUIPPED — RATING %dm · AIR %ds",
	rodFormat = "%s EQUIPPED — %s", -- params: rod name, Shop[sku].unlockLabel
	seconds = 3,
	-- Refusals (§9): a shop row is never a button that silently does nothing.
	shortfallFormat = "NOT ENOUGH — %d C SHORT",
	ownedFormat = "ALREADY OWNED — %s",
	unknownFormat = "NOT FOR SALE — %s",
}

-- §9 shop rows: the sticky cost-vs-cash comparison, plus the measured effect of the item so
-- the tank reads as the key to depth (§6.3). Effect strings are built from RodConfig /
-- GearConfig at read time — no rating is copied into this file.
EconomyConfig.ShopRowLabel = {
	affordableFormat = "%d C", -- params: cost
	shortfallFormat = "%d C — NEED %d MORE", -- params: cost, shortfall
	ownedFormat = "OWNED",
	gearEffectFormat = "RATING %dm → %dm · AIR %ds", -- params: current rating, new rating, new air
	rodEffectFormat = "MAX RARITY %s → %s", -- params: current rod cap, new rod cap
}

return EconomyConfig
