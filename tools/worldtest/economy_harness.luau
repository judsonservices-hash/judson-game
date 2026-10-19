--[[
    Dock economy suite — the half of the loop that turns a caught fish into an upgrade.

    Same rig as the fishing suite (check.sh assembles the chunk): the real WorldService,
    PlayerService, GearService, InventoryService, EconomyService, ShopService, DiveService,
    FishService, FishingService, Modules/Tension, Modules/Rng and Modules/Remotes, running
    against the stubbed Roblox globals with a mock DataStore.

    It asserts, in order:

      0. boot: every service up, a joining player on the §6.1 starting state
      1. prompt wiring (§1 steps 2, 3, 8): all three prompts exist *and* every one of them
         does something when a player uses it — no prompt does nothing
      2. SELL ALL (§6.2, §11): pays exactly the fish-table sum, empties the log, never
         double-pays, never silently drops a fish; spending is atomic; coins are integers >= 0
      3. the shop (§6.3, §6.5, §9): presentation order, affordability, the shortfall on a
         disabled row, refusal reasons, 280 C means 280 C, the tank grants RATING 240m /
         AIR 300s and equips, the Brass Rod grants EPIC/260, owned rows cannot be rebought
      4. the depth rules (§5.4, §11, §9): rating + 20 for 1.5 s auto-surfaces, unevadable with
         Rubber Lungs below 110 studs, the line names the rating and the next buy, is not a
         cast/rod failure, and a forced ascent costs nothing that was banked
      5. zone entry (§3.0, §3.3, §9): THE SHELF announces itself once on a legal crossing, the
         Rim is not a zone, a crossing without the tank is refused by name, and no Shelf
         species is reachable below the rating the tank grants
      6. persistence (§11): coins, the catch log and the purchased tank survive a rejoin
      7. END TO END (§1 steps 1-13, §6.2 median route, §6.5 targets): dive, catch, surface,
         sell, buy the tank, cross the Rim Gate, cast at a Lantern Eel — timed on a clock
         built only from config speeds and measured fight time.

    Deterministic: no wall-clock decisions, one fixed dt, one seeded fight generator.
]]

local failures = 0
local checks = 0
local function check(cond, msg)
	checks += 1
	if cond then
		print("  ok    " .. msg)
	else
		print("  FAIL  " .. msg)
		failures += 1
	end
end
local function section(text)
	print("=== " .. text .. " ===")
end

local CFG = {
	Fish = __config("FishConfig"),
	Spawn = __config("SpawnConfig"),
	Rarity = __config("RarityConfig"),
	Rod = __config("RodConfig"),
	Gear = __config("GearConfig"),
	Dive = __config("DiveConfig"),
	Fight = __config("FightConfig"),
	Economy = __config("EconomyConfig"),
	Zone = __config("ZoneConfig"),
	Landmark = __config("LandmarkConfig"),
}
local Tension = __Tension
local Rng = __Rng
local Remotes = __Remotes

SIBLING_SERVICES.WorldService = WorldService
SIBLING_SERVICES.PlayerService = PlayerService
SIBLING_SERVICES.GearService = GearService
SIBLING_SERVICES.InventoryService = InventoryService
SIBLING_SERVICES.EconomyService = EconomyService
SIBLING_SERVICES.ShopService = ShopService
SIBLING_SERVICES.DiveService = DiveService
SIBLING_SERVICES.FishService = FishService
SIBLING_SERVICES.FishingService = FishingService
__KnitStub.GetService = function(name)
	local service = SIBLING_SERVICES[name]
	if service == nil then
		error("harness: no service named " .. tostring(name))
	end
	return service
end

local STEP = 1 / 60

-- ============================================================================
-- Helpers
-- ============================================================================

local function tickOnce()
	__fireHeartbeat(STEP)
end

local function advance(seconds)
	local ticks = math.floor(seconds / STEP + 0.5)
	for _ = 1, ticks do
		tickOnce()
	end
end

local function rootOf(player: any): any
	return player.Character:FindFirstChild("HumanoidRootPart")
end

local function positionOf(player: any): any
	return rootOf(player).Position
end

local function coins(player: any): number
	return EconomyService:GetCoins(player)
end

local function lastRemote(remoteName: string, player: any): any?
	local log = __remotes()
	for index = #log, 1, -1 do
		local entry = log[index]
		if entry.remote == remoteName and (entry.player == nil or entry.player == player) then
			return entry
		end
	end
	return nil
end

local function remoteCount(remoteName: string, player: any): number
	local total = 0
	for _, entry in __remotes() do
		if entry.remote == remoteName and (entry.player == nil or entry.player == player) then
			total += 1
		end
	end
	return total
end

--- Did this player ever receive a Notify carrying `text`?
local function notified(player: any, text: string): boolean
	local log = __remotes()
	for index = #log, 1, -1 do
		local entry = log[index]
		if entry.remote == "Notify" and entry.player == player and tostring((entry.args[1] or {}).text) == text then
			return true
		end
	end
	return false
end

--- Any Notify at all whose text contains `fragment`? Used where the line carries live numbers
--- (the rating wall, a price) and the exact string is built from config at runtime.
local function notifiedMatching(player: any, fragment: string): string?
	local log = __remotes()
	for index = #log, 1, -1 do
		local entry = log[index]
		if entry.remote == "Notify" and entry.player == player then
			local text = tostring((entry.args[1] or {}).text)
			if string.find(text, fragment, 1, true) ~= nil then
				return text
			end
		end
	end
	return nil
end

local function clearRemotes()
	__clearRemotes()
end

local function notificationTexts(player: any): { string }
	local out = {}
	for _, entry in __remotes() do
		if entry.remote == "Notify" and entry.player == player then
			table.insert(out, tostring((entry.args[1] or {}).text))
		end
	end
	return out
end

--- §1 steps 2/3/8: use a world prompt the way a player does.
local function usePrompt(id: string, player: any): boolean
	local prompt = WorldService:GetPrompt(id)
	if prompt == nil then
		return false
	end
	prompt.Triggered:Fire(player)
	tickOnce()
	return true
end

--- §1 step 6: put fish in the log without running the whole fight (the fight is the fishing
--- suite's job; this suite is about what happens to a banked catch).
local function bank(player: any, speciesId: string, count: number)
	for _ = 1, count do
		InventoryService:AddCatch(player, speciesId)
	end
end

--- The §6.2 sum for a shopping list of (species, count), read from the fish table itself.
local function tableSum(list): number
	local total = 0
	for _, row in list do
		total += CFG.Fish.Species[row[1]].value * row[2]
	end
	return total
end

--- Fish helpers (the fishing suite's, so the two suites measure the same thing).
local function ofSpecies(speciesId: string): { any }
	local out = {}
	local root = workspace:FindFirstChild("DeepTide")
	local folder = if root ~= nil then root:FindFirstChild("Fish") else nil
	if folder == nil then
		return out
	end
	for _, child in folder:GetChildren() do
		if
			child:IsA("BasePart")
			and string.find(child.Name, "_Lure$") == nil
			and tostring(child:GetAttribute("Species")) == speciesId
		then
			table.insert(out, child)
		end
	end
	return out
end

local function nearestOfSpecies(player: any, speciesId: string): any
	local origin = positionOf(player)
	local best, bestDistance = nil, math.huge
	for _, part in ofSpecies(speciesId) do
		local distance = (part.Position - origin).Magnitude
		if distance < bestDistance then
			best, bestDistance = part, distance
		end
	end
	return best
end

local function standoffFor(speciesId: string): number
	local cfg = CFG.Fish.Species[speciesId].behaviourCfg
	local trigger = cfg.fleeRadius or cfg.startleRadius or cfg.lungeRadius or 10
	return math.min(CFG.Fight.CastRange - 2, math.max(trigger + 4, 10))
end

local function placeNear(player: any, target: any, standoff: number)
	local from = target.Position
	local to = positionOf(player)
	local away = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if away.Magnitude < 0.01 then
		away = Vector3.new(0, 0, 1)
	end
	away = away.Unit
	local position = from + away * standoff
	__movePlayer(player, Vector3.new(position.X, from.Y, position.Z), math.atan2(away.X, away.Z))
end

--- A competent player (§5.3): hold under the zone, release above it, with `latencyTicks` of
--- reaction time — which is why a real fight lasts longer than the §5.5 bare minimum.
local function makeDriver(latencyTicks: number)
	local history = {}
	local held = false
	return function(session: any)
		local fight = session.fight
		history[#history + 1] = { needle = fight.needle, centre = fight.zoneCentre, width = fight.zoneHalfWidth }
		local sample = history[math.max(1, #history - latencyTicks)]
		local low = sample.centre - sample.width * 0.6
		local high = sample.centre + sample.width * 0.6
		if sample.needle < low then
			held = true
		elseif sample.needle > high then
			held = false
		end
		return held
	end
end

--- One whole §5.1-§5.3 interaction against a live fish, returning the result and the seconds
--- the fight actually consumed in the simulation.
local function attemptCatch(player: any, speciesId: string, options: any?)
	options = options or {}
	local driver = options.driver or makeDriver(0)
	local hookFraction = options.hookFraction or 0.85
	clearRemotes()

	local target = nearestOfSpecies(player, speciesId)
	if target == nil then
		return { result = "NoTarget", seconds = 0, hooked = false }
	end
	placeNear(player, target, options.standoff or standoffFor(speciesId))
	tickOnce()

	if not FishService:IsEligible(target) then
		advance(4)
		target = nearestOfSpecies(player, speciesId)
		if target == nil then
			return { result = "NoTarget", seconds = 0, hooked = false }
		end
		placeNear(player, target, options.standoff or standoffFor(speciesId))
		tickOnce()
	end

	local accepted = FishingService:RequestCast(player, target)
	if not accepted then
		local waited = 0
		while not FishingService:IsRodReady(player) and waited < 30 do
			advance(0.1)
			waited += 0.1
		end
		target = nearestOfSpecies(player, speciesId) or target
		placeNear(player, target, options.standoff or standoffFor(speciesId))
		tickOnce()
		accepted = FishingService:RequestCast(player, target)
	end
	if not accepted or FishingService:GetSession(player) == nil then
		return { result = "CastRefused", seconds = 0, hooked = false }
	end

	local elapsed = 0
	local fightStart: number? = nil
	local pressAttempted = false
	local outcome = { result = "Unresolved", seconds = 0, hooked = false }

	for _ = 1, 60 * 40 do
		local session = FishingService:GetSession(player)
		if session == nil then
			outcome.seconds = elapsed
			outcome.hooked = fightStart ~= nil
			local resolved = lastRemote("FightResolved", player)
			if resolved ~= nil then
				outcome.result = (resolved.args[1] or {}).result or "Unresolved"
				outcome.reason = (resolved.args[1] or {}).reason
			end
			return outcome
		end

		if session.phase == "HookSet" and not pressAttempted then
			if session.phaseElapsed >= session.hookWindow * hookFraction then
				pressAttempted = true
				FishingService:RequestHookSet(player)
			end
		elseif session.phase == "Fighting" then
			if fightStart == nil then
				fightStart = elapsed
			end
			FishingService:SetFightInput(player, driver(session))
		end

		elapsed += STEP
		tickOnce()
	end

	outcome.seconds = elapsed
	return outcome
end

-- ============================================================================
-- 0. BOOT
-- ============================================================================

section("0. BOOT (world + all nine services, exactly as the bootstrap orders them)")

local deepTideFolder = makeInstance("Folder")
deepTideFolder.Name = "DeepTide"
deepTideFolder.Parent = SERVICES.ReplicatedStorage
Remotes.ensure()

-- PlayerService's per-player teardown walks script.Parent's children, so the harness needs the
-- same tree the real Services folder gives it: one ModuleScript per service.
local servicesFolder = makeInstance("Folder")
servicesFolder.Name = "Services"
script = makeInstance("ModuleScript")
script.Name = "Services"
script.Parent = servicesFolder
for _, name in
	{
		"PlayerService",
		"GearService",
		"InventoryService",
		"EconomyService",
		"ShopService",
		"DiveService",
		"FishService",
		"FishingService",
		"WorldService",
	}
do
	local module = makeInstance("ModuleScript")
	module.Name = name
	module.Parent = servicesFolder
end

WorldService:KnitInit()
for _, service in
	{
		PlayerService,
		GearService,
		InventoryService,
		EconomyService,
		ShopService,
		DiveService,
		FishService,
		FishingService,
	}
do
	service:KnitInit()
end
for _, service in
	{
		PlayerService,
		GearService,
		InventoryService,
		EconomyService,
		ShopService,
		DiveService,
		FishService,
		FishingService,
	}
do
	service:KnitStart()
end
check(true, "all services started without error")

check(PlayerStoreModule.init() == "DataStore", "the mock DataStore answers (persistence is on for this suite)")
check(PlayerService:GetPersistenceMode() == "DataStore", "PlayerService surfaces the DataStore mode")

local ada = __addPlayer("Ada", CFG.Zone.InteractionPoints.PlayerSpawn, math.pi)
check(PlayerService:IsLoaded(ada), "joining player gets a profile")
check(
	coins(ada) == CFG.Economy.StartingCoins,
	("a joining player starts with §6.1's %d C"):format(CFG.Economy.StartingCoins)
)
check(GearService:GetEquippedRodId(ada) == CFG.Economy.StartingRodId, "starting rod is the Rusty Rod (§6.1)")
check(GearService:GetEquippedGearId(ada) == CFG.Economy.StartingGearId, "starting gear is the Rubber Lungs (§6.1)")
check(InventoryService:GetFishCount(ada) == 0, "starting Catch Log is empty (§6.1)")
check(
	GearService:GetDepthRating(ada) == CFG.Gear.Gear.RubberLungs.depthRating,
	"RATING starts at the lungs' 90m (§3.1)"
)

-- ============================================================================
-- 1. PROMPT WIRING (§1 steps 2, 3, 8)
-- ============================================================================

section("1. PROMPT WIRING (§1 steps 2, 3, 8: no prompt may do nothing)")

local wired = WorldService:WirePrompts()
local hostCount = #CFG.Landmark.PromptHosts
local wiredCount = 0
for _ in wired do
	wiredCount += 1
end
check(wiredCount == hostCount, ("WirePrompts connected every prompt host (%d of %d)"):format(wiredCount, hostCount))
check(#WorldService:UnwiredPromptIds() == 0, "no prompt host is left without a verb or a hint")

for _, host in CFG.Landmark.PromptHosts do
	local prompt = WorldService:GetPrompt(host.id)
	check(prompt ~= nil, ("prompt '%s' exists at boot"):format(host.id))
	if prompt ~= nil then
		check(
			prompt.ActionText == host.actionText and prompt.ObjectText == host.objectText,
			("prompt '%s' says the §1 verb: '%s'"):format(host.id, tostring(prompt.ActionText))
		)
	end
end

-- Every prompt, used by a player, must produce something. The Rod Rack hands over the rod,
-- the Tide Trader opens the shop, the dive marker hints the dive.
for _, host in CFG.Landmark.PromptHosts do
	clearRemotes()
	local used = usePrompt(host.id, ada)
	local produced = #__remotes()
	check(used and produced > 0, ("using '%s' does something (%d message(s))"):format(host.id, produced))
end

clearRemotes()
GearService:SetEquippedRod(ada, CFG.Economy.StartingRodId)
usePrompt("RodRack", ada)
local rodLine = CFG.Rod.EquippedMessageFormat:format(string.upper(CFG.Rod.Rods.RustyRod.name))
check(notified(ada, rodLine), ("the Rod Rack says '%s' (RodConfig)"):format(rodLine))
check(
	ada:GetAttribute(CFG.Gear.PlayerAttributes.RodId) == "RustyRod",
	"the Rod Rack stamps the equipped rod for the HUD's `ROD: RUSTY` (§9)"
)

clearRemotes()
usePrompt("TideTrader", ada)
local shopPush = lastRemote("ShopStateChanged", ada)
check(shopPush ~= nil, "the Tide Trader pushes the shop state — that is how the panel opens (§1 step 8)")
if shopPush ~= nil then
	local pushed = shopPush.args[1] or {}
	check(#pushed.skus == #CFG.Economy.ShopOrder, ("the pushed shop carries %d rows (§6.3)"):format(#pushed.skus))
	check(pushed.coins == coins(ada), "the pushed shop carries the player's real balance (§9)")
end

clearRemotes()
usePrompt("DiveMarker", ada)
local diveHint = notifiedMatching(ada, "DIVE")
check(diveHint ~= nil, ("the dive marker hints the dive (%s)"):format(tostring(diveHint)))

-- ============================================================================
-- 2. SELL ALL (§6.2, §1 step 8, §11)
-- ============================================================================

section("2. SELL ALL (§6.2: exactly the fish table, and the log is emptied)")

-- An empty log is not a silent failure.
clearRemotes()
local empty = EconomyService:SellAll(ada)
check(empty.soldCount == 0 and empty.coinsEarned == 0, "SELL ALL on an empty log pays nothing")
check(coins(ada) == CFG.Economy.StartingCoins, "and leaves the balance alone")
check(notified(ada, CFG.Economy.SellAllMessage.emptyFormat), "and says there was nothing to sell (§9)")

-- §6.2's median dive-1 catch: 2 Silver Sardine + 2 Sunset Grouper = 110 C.
local diveOne = { { "SilverSardine", 2 }, { "SunsetGrouper", 2 } }
bank(ada, "SilverSardine", 2)
bank(ada, "SunsetGrouper", 2)
local expectedOne = tableSum(diveOne)
check(
	InventoryService:GetTotalCoins(ada) == expectedOne,
	("the log's own running TOTAL is the §6.2 sum (%d C)"):format(InventoryService:GetTotalCoins(ada))
)
check(InventoryService:GetFishCount(ada) == 4, "four fish are waiting in the log")
check(coins(ada) == 0, "landing a fish pays nothing until the trader pays (§1 step 6)")

clearRemotes()
local before = coins(ada)
local saleOne = EconomyService:SellAll(ada)
check(saleOne.coinsEarned == expectedOne, ("SELL ALL credits exactly the table sum (%d C)"):format(saleOne.coinsEarned))
check(saleOne.soldCount == 4, ("SELL ALL reports every fish sold (%d)"):format(saleOne.soldCount))
check(coins(ada) == before + expectedOne, ("the balance moved by exactly the sum (%d C)"):format(coins(ada)))
check(saleOne.newBalance == coins(ada), "the result's newBalance is the real balance")
check(
	InventoryService:GetFishCount(ada) == 0 and #InventoryService:GetEntries(ada) == 0,
	"the Catch Log is emptied (§6.2)"
)
check(InventoryService:GetTotalCoins(ada) == 0, "and its running TOTAL is back to 0 C (§9)")

local coinsChange = lastRemote("CoinsChanged", ada)
check(coinsChange ~= nil, "the client is told the balance changed (§9: income is felt)")
if coinsChange ~= nil then
	check(
		coinsChange.args[1] == coins(ada) and coinsChange.args[2] == expectedOne,
		("CoinsChanged carries (coins, delta) = (%d, %d)"):format(coinsChange.args[1] or -1, coinsChange.args[2] or -1)
	)
end
check(
	notified(ada, CFG.Economy.SellAllMessage.soldFormat:format(4, expectedOne)),
	("the sale is announced: '%s'"):format(CFG.Economy.SellAllMessage.soldFormat:format(4, expectedOne))
)

-- Selling twice cannot pay twice, and a fish can never be dropped without payment: the total
-- the player read before the sale is the coins they received (asserted above) and the log is
-- now empty, so a second SELL ALL is worth zero.
local second = EconomyService:SellAll(ada)
check(
	second.coinsEarned == 0 and coins(ada) == before + expectedOne,
	"a second SELL ALL cannot pay the same fish twice"
)

-- Mixed rarities, including the values that only exist in the Shelf (§6.2).
local mixed =
	{ { "SilverSardine", 3 }, { "SunsetGrouper", 1 }, { "ReefBass", 1 }, { "LanternEel", 1 }, { "GhostRay", 1 } }
for _, row in mixed do
	bank(ada, row[1], row[2])
end
local expectedMixed = tableSum(mixed)
local saleMixed = EconomyService:SellAll(ada)
check(
	saleMixed.coinsEarned == expectedMixed and saleMixed.soldCount == 7,
	("every species sells at its own value (%d C for 7 fish)"):format(saleMixed.coinsEarned)
)
check(
	expectedMixed == 15 * 3 + 40 + 90 + 260 + 600,
	"the mixed sum matches the §6.2 table restated as EconomyConfig.SellValues"
)
for _, speciesId in { "SilverSardine", "SunsetGrouper", "ReefBass", "LanternEel", "GhostRay" } do
	check(
		CFG.Economy.SellValues[speciesId] == CFG.Fish.Species[speciesId].value,
		("%s: EconomyConfig.SellValues and FishConfig agree (%d C)"):format(
			speciesId,
			CFG.Fish.Species[speciesId].value
		)
	)
end

-- Spending is atomic and the balance can never go negative (§6).
local held = coins(ada)
check(EconomyService:TrySpend(ada, held + 1) == false, "an unaffordable spend is refused")
check(coins(ada) == held, "and nothing at all changed (§9)")
check(EconomyService:TrySpend(ada, held) == true, "an affordable spend goes through")
check(coins(ada) == 0, "and leaves exactly 0 C")
check(coins(ada) == math.floor(coins(ada)), "coins are integers only (§6)")
EconomyService:AddCoins(ada, -1000, "harness: clamp")
check(coins(ada) == 0, "a balance is clamped at 0 — never a debt (§6)")

-- Back to a clean purse for the shop section.
EconomyService:AddCoins(ada, -coins(ada), "harness: reset")

-- ============================================================================
-- 3. THE SHOP (§6.3, §6.5, §9)
-- ============================================================================

section("3. THE SHOP (§6.3: the tank first, and 280 C means 280 C)")

local tankCost = CFG.Economy.Shop.ReinforcedTank.cost
local rodCost = CFG.Economy.Shop.BrassRod.cost
check(
	tankCost == CFG.Gear.Gear.ReinforcedTank.cost,
	"the tank's price lives in GearConfig (280 C) and the shop reads it"
)
check(rodCost == CFG.Rod.Rods.BrassRod.cost, "the rod's price lives in RodConfig (750 C) and the shop reads it")

local state = ShopService:GetState(ada)
check(state.coins == coins(ada), "the shop state carries the real balance (§9)")
check(#state.skus == #CFG.Economy.ShopOrder, "the shop shows every SKU")
check(state.skus[1].sku == CFG.Economy.ShopOrder[1], "§6.3/§6.5: the Reinforced Tank is the top row")
check(state.skus[1].recommended == true, "and it is the visually recommended one (§6.3)")
check(state.skus[1].unlockLabel == CFG.Economy.Shop.ReinforcedTank.unlockLabel, "its row says what it opens (§6.3)")
check(state.skus[2].sku == CFG.Economy.ShopOrder[2], "the Brass Rod sits below it")
check(
	state.skus[2].unlockLabel == CFG.Economy.Shop.BrassRod.unlockLabel,
	"with the Ghost Ray named as its reason (§6.3)"
)

for _, row in state.skus do
	check(row.affordable == false, ("%s is unaffordable at 0 C (§6.3: greyed until affordable)"):format(row.sku))
	check(row.shortfall == row.cost, ("%s's shortfall is its whole price (%d C)"):format(row.sku, row.shortfall))
	check(row.owned == false, ("%s is not owned yet"):format(row.sku))
end
check(
	string.find(state.skus[1].effectLabel, tostring(CFG.Gear.Gear.ReinforcedTank.depthRating), 1, true) ~= nil,
	("the tank's row states the rating it grants (%s)"):format(state.skus[1].effectLabel)
)

-- A refusal always says why (§9), and changes nothing.
clearRemotes()
local broke = coins(ada)
local refused, reason = ShopService:Purchase(ada, "ReinforcedTank")
check(refused == false, "buying with 0 C is refused")
check(coins(ada) == broke, "and no coins moved")
check(reason ~= nil and notified(ada, reason), ("the refusal is spoken: '%s'"):format(tostring(reason)))
check(
	reason == CFG.Economy.PurchaseMessage.shortfallFormat:format(tankCost),
	("the refusal names the shortfall (%d C)"):format(tankCost)
)
check(lastRemote("ShopStateChanged", ada) ~= nil, "and the shop rows are re-pushed, so the comparison stays true")

local bogus, bogusReason = ShopService:Purchase(ada, "GoldenRod")
check(bogus == false, "a SKU that is not in ShopOrder cannot be bought")
check(
	bogusReason == CFG.Economy.PurchaseMessage.unknownFormat:format("GoldenRod"),
	"and the refusal says it is not for sale"
)

-- One coin short of the tank: still refused. §6.3's gate is exact.
EconomyService:AddCoins(ada, tankCost - 1, "harness")
check(coins(ada) == tankCost - 1, ("the player holds %d C"):format(coins(ada)))
local almost, almostReason = ShopService:Purchase(ada, "ReinforcedTank")
check(almost == false, "279 C cannot buy a 280 C tank")
check(coins(ada) == tankCost - 1, "and the 279 C is untouched")
check(
	almostReason == CFG.Economy.PurchaseMessage.shortfallFormat:format(1),
	"the refusal is worth exactly one coin: '1 C SHORT'"
)

-- §6.3: at C >= 280 the tank is buyable, costs exactly 280, and immediately sets
-- AIR 300s / RATING 240m.
EconomyService:AddCoins(ada, 1, "harness")
check(coins(ada) == tankCost, ("the player holds exactly %d C"):format(tankCost))
local airBeforePurchase = DiveService:GetAir(ada)
clearRemotes()
local bought, boughtReason = ShopService:Purchase(ada, "ReinforcedTank")
check(bought == true, "the tank is buyable at C >= 280 (§6.3)")
check(boughtReason == nil, "a successful purchase has no reason attached")
check(coins(ada) == 0, ("the tank cost exactly %d C (§11)"):format(tankCost))
check(
	GearService:GetEquippedGearId(ada) == "ReinforcedTank",
	"the purchase equips the tank (§6.3: bought gear is worn)"
)
check(
	ada:GetAttribute(CFG.Gear.PlayerAttributes.GearId) == "ReinforcedTank",
	"and stamps it for the HUD (no extra remote needed)"
)
check(
	GearService:GetDepthRating(ada) == CFG.Gear.Gear.ReinforcedTank.depthRating,
	("RATING is immediately %dm (§6.3)"):format(CFG.Gear.Gear.ReinforcedTank.depthRating)
)
check(
	DiveService:GetAirCapacity(ada) == CFG.Gear.Gear.ReinforcedTank.airCapacity,
	("AIR capacity is immediately %ds (§6.3)"):format(CFG.Gear.Gear.ReinforcedTank.airCapacity)
)
check(
	DiveService:GetAir(ada) == CFG.Gear.Gear.ReinforcedTank.airCapacity,
	("a bigger tank arrives full (%ds, was %ds)"):format(DiveService:GetAir(ada), airBeforePurchase)
)
local tankLine = CFG.Economy.PurchaseMessage.gearFormat:format(
	CFG.Gear.Gear.ReinforcedTank.name,
	CFG.Gear.Gear.ReinforcedTank.depthRating,
	CFG.Gear.Gear.ReinforcedTank.airCapacity
)
check(notified(ada, tankLine), ("the purchase says what it did: '%s'"):format(tankLine))

local afterTank = ShopService:GetState(ada)
check(afterTank.skus[1].owned == true, "the tank's row now reads OWNED (§6.3)")
check(afterTank.skus[1].affordable == false, "an owned row is not a buy button")
check(afterTank.skus[3] == nil, "and no fourth SKU appeared (§6.3: three SKUs in the slice)")

clearRemotes()
local again, againReason = ShopService:Purchase(ada, "ReinforcedTank")
check(again == false, "the same tank cannot be bought twice")
check(
	againReason == CFG.Economy.PurchaseMessage.ownedFormat:format(CFG.Gear.Gear.ReinforcedTank.name),
	("and the refusal says so: '%s'"):format(tostring(againReason))
)
check(coins(ada) == 0, "no coins were taken by the refused rebuy")

-- §6.3: the Brass Rod, two Shelf dives later. Same rules, different effect.
EconomyService:AddCoins(ada, rodCost - 1, "harness")
local rodShort, _ = ShopService:Purchase(ada, "BrassRod")
check(rodShort == false, "749 C cannot buy a 750 C rod")
EconomyService:AddCoins(ada, 1, "harness")
clearRemotes()
local rodBought = ShopService:Purchase(ada, "BrassRod")
check(rodBought == true, "the Brass Rod is buyable at C >= 750 (§6.3)")
check(coins(ada) == 0, ("the rod cost exactly %d C"):format(rodCost))
check(GearService:GetEquippedRodId(ada) == "BrassRod", "the purchase equips the rod")
local rodStats = GearService:GetRodStats(ada)
check(
	rodStats.maxRarity == CFG.Rod.Rods.BrassRod.maxRarity
		and rodStats.lineStrength == CFG.Rod.Rods.BrassRod.lineStrength,
	("the Brass Rod raises the ceiling to %s / %d lb (§6.3)"):format(rodStats.maxRarity, rodStats.lineStrength)
)
check(
	notified(
		ada,
		CFG.Economy.PurchaseMessage.rodFormat:format(CFG.Rod.Rods.BrassRod.name, CFG.Economy.Shop.BrassRod.unlockLabel)
	),
	"the rod's purchase line carries its §6.3 unlock label"
)
check(GearService:GetEquippedGearId(ada) == "ReinforcedTank", "the rod purchase did not disturb the tank")
check(GearService:Owns(ada, "ReinforcedTank") and GearService:Owns(ada, "BrassRod"), "both upgrades are owned (§6.3)")
check(
	tankCost + rodCost == CFG.Economy.Shop.ReinforcedTank.cost + CFG.Economy.Shop.BrassRod.cost,
	("§6.5: the two upgrades together are %d C — the rod is deliberately after the slice, not before the gate"):format(
		tankCost + rodCost
	)
)

-- Back to the §6.1 starting kit for the depth rules.
GearService:SetEquippedGear(ada, CFG.Economy.StartingGearId)
GearService:SetEquippedRod(ada, CFG.Economy.StartingRodId)
__movePlayer(ada, CFG.Zone.InteractionPoints.PlayerSpawn, math.pi)
advance(0.5)
check(
	GearService:GetDepthRating(ada) == CFG.Gear.Gear.RubberLungs.depthRating,
	"the harness puts the diver back on Rubber Lungs for the depth rules"
)

-- ============================================================================
-- 4. THE DEPTH RULES (§5.4, §11, §9)
-- ============================================================================

section("4. DEPTH RULES (§5.4 + §11: rating + 20 for 1.5 s, and never a cast failure)")

local margin = CFG.Dive.RatingWarningMargin
local holdTime = CFG.Dive.RatingWarningHoldTime
local lungsRating = CFG.Gear.Gear.RubberLungs.depthRating

-- Above the limit: the player keeps swimming until the window expires. The window is measured
-- in simulated seconds (DiveService passes its own dt through), so 1/StatePushHz of the push
-- rate is a fifth of a second of ticks.
local deepY = -(lungsRating + margin + 5)
clearRemotes()
__movePlayer(ada, Vector3.new(-120, deepY, -100))
tickOnce()
check(
	DiveService:GetDepth(ada) > lungsRating + margin,
	("the diver is below the wall (%.0f m)"):format(DiveService:GetDepth(ada))
)
advance(holdTime - 0.2)
check(positionOf(ada).Y < CFG.Dive.SeaLevelY, ("inside the %.1f s window the diver is still swimming"):format(holdTime))
advance(0.5)
check(
	math.abs(positionOf(ada).Y - (CFG.Dive.SeaLevelY + CFG.Dive.ForceSurfaceHeightStuds)) < 0.01,
	("at DepthRating + %d for %.1f s the diver is auto-surfaced (§5.4, §11)"):format(margin, holdTime)
)

-- §9: the reason is named, and it is NOT a broken cast or a weak rod.
local wallLine = notifiedMatching(ada, "GEAR RATING EXCEEDED")
check(wallLine ~= nil, ("the wall names itself: '%s'"):format(tostring(wallLine)))
if wallLine ~= nil then
	check(
		string.find(wallLine, tostring(lungsRating), 1, true) ~= nil,
		"the line carries the rating the player is wearing"
	)
	check(
		string.find(wallLine, string.upper(CFG.Gear.Gear.ReinforcedTank.name), 1, true) ~= nil,
		"and names the tier that opens the deeper water (§9's next step)"
	)
	check(string.find(wallLine, "CAST", 1, true) == nil, "it never reads as a cast failure")
	for name, text in CFG.Fight.FailMessages do
		check(wallLine ~= text, ("it is not the %s line ('%s')"):format(name, text))
	end
	check(
		string.find(wallLine, string.upper(CFG.Gear.Gear.ReinforcedTank.name), 1, true) ~= nil
			and string.find(wallLine, tostring(CFG.Gear.Gear.ReinforcedTank.cost), 1, true) ~= nil,
		"the line names the price of the fix too"
	)
end

-- §11: "verified as unevadable with Rubber Lungs below 110 studs" — 120 m is beyond the wall
-- and there is no way to stay there.
__movePlayer(ada, Vector3.new(-120, -120, -100))
advance(holdTime + 0.1)
check(
	math.abs(positionOf(ada).Y - (CFG.Dive.SeaLevelY + CFG.Dive.ForceSurfaceHeightStuds)) < 0.01,
	"120 m with the lungs is unevadable: the diver is at the surface within the window (§11)"
)

-- §11: a forced ascent never costs a banked fish.
bank(ada, "ReefBass", 2)
local bankedBefore = InventoryService:GetTotalCoins(ada)
local bankedCount = InventoryService:GetFishCount(ada)
__movePlayer(ada, Vector3.new(-120, -130, -100))
advance(holdTime + 0.1)
check(
	InventoryService:GetTotalCoins(ada) == bankedBefore and InventoryService:GetFishCount(ada) == bankedCount,
	("a forced ascent loses nothing that was banked (%d C in the log)"):format(InventoryService:GetTotalCoins(ada))
)
check(
	DiveService:GetAir(ada) == DiveService:GetAirCapacity(ada),
	("and the tank comes back full with the diver (§1 step 7): air %.2f / %d, depth %.2f"):format(
		DiveService:GetAir(ada),
		DiveService:GetAirCapacity(ada),
		DiveService:GetDepth(ada)
	)
)

-- The window is measured in real seconds, not in calls: one long step fires it exactly once.
__movePlayer(ada, Vector3.new(-120, -140, -100))
check(
	DiveService:EnforceDepthRating(ada, holdTime) == true,
	"the 1.5 s window is time-based: one long step trips the wall"
)
check(
	math.abs(positionOf(ada).Y - (CFG.Dive.SeaLevelY + CFG.Dive.ForceSurfaceHeightStuds)) < 0.01,
	"and that step surfaced the diver"
)

-- The tank changes the wall, which is the whole point of the shop's order (§6.5).
GearService:SetEquippedGear(ada, "ReinforcedTank")
__movePlayer(ada, Vector3.new(-120, deepY, -100))
advance(holdTime + 0.5)
check(
	DiveService:GetDepth(ada) > lungsRating + margin,
	("with the tank the same depth is legal (%.0f m, RATING %dm)"):format(
		DiveService:GetDepth(ada),
		GearService:GetDepthRating(ada)
	)
)
check(InventoryService:GetTotalCoins(ada) == bankedBefore, "and the log is still intact")
GearService:SetEquippedGear(ada, CFG.Economy.StartingGearId)

-- §11: air is a clock on the reward, and surfacing refills the tank so a dive cycle repeats.
DiveService:RefillAir(ada)
check(DiveService:GetAir(ada) == DiveService:GetAirCapacity(ada), "the tank refills at the surface")
__movePlayer(ada, Vector3.new(0, -30, -40))
advance(20)
local afterDive = DiveService:GetAir(ada)
check(
	afterDive < DiveService:GetAirCapacity(ada),
	("20 s under water costs 20 s of air (%ds left)"):format(math.floor(afterDive + 0.5))
)
__movePlayer(ada, CFG.Zone.InteractionPoints.PlayerSpawn)
advance(CFG.Dive.SurfaceRefillSeconds)
check(
	DiveService:GetAir(ada) == DiveService:GetAirCapacity(ada),
	("at the dock the tank refills within SurfaceRefillSeconds (%ds)"):format(CFG.Dive.SurfaceRefillSeconds)
)

-- ============================================================================
-- 5. ZONE ENTRY (§3.0, §3.3, §9)
-- ============================================================================

section("5. ZONE ENTRY (§3.0 + §3.3: a threshold, not a texture change)")

check(
	CFG.Zone.ZoneEntryBannerSeconds > 0,
	("the §9 banner lasts ZoneConfig.ZoneEntryBannerSeconds (%ds)"):format(CFG.Zone.ZoneEntryBannerSeconds)
)

-- The earlier sections have already had this player swim in the Shallows, so their zone memory
-- is warmed. A release (which is what a session end runs) drops it: the next entry is a first
-- entry again, exactly as it is on a rejoin.
WorldService:ReleasePlayer(ada)
check(WorldService:HasEnteredZone(ada, "Shallows") == false, "a released player has no zone memory")

clearRemotes()
__movePlayer(ada, CFG.Zone.InteractionPoints.PlayerSpawn, math.pi)
DiveService:_Step(1 / CFG.Dive.StatePushHz)
check(WorldService:UpdateZone(ada) == "Shallows", "the dock is in the Shallows (§3.1)")
check(remoteCount("ZoneChanged", ada) == 1, "and the first entry announces it once (§9)")
DiveService:_Step(1 / CFG.Dive.StatePushHz)
check(remoteCount("ZoneChanged", ada) == 1, "crossing back into a zone does not re-banner (§9: first entry only)")
check(WorldService:HasEnteredZone(ada, "Shallows"), "the world remembers the entry")

-- The Rim is the gate between the two areas, not a zone of its own (§3.3).
clearRemotes()
__movePlayer(ada, Vector3.new(0, -100, 175))
DiveService:_Step(1 / CFG.Dive.StatePushHz)
check(WorldService:GetZoneAt(positionOf(ada)) == nil, "the Rim is in neither zone (§3.3)")
check(remoteCount("ZoneChanged", ada) == 0, "so standing in the gate announces nothing")

-- Crossing into The Shelf without the tank: refused by name, and the water is named as the
-- water it is (§3.1's "gear rating required" row).
clearRemotes()
__movePlayer(ada, Vector3.new(0, -105, 220))
local zoneWithoutTank = DiveService:_Step(1 / CFG.Dive.StatePushHz)
check(WorldService:UpdateZone(ada) == "Shelf", "the Shelf footprint is detected")
check(remoteCount("ZoneChanged", ada) == 0, "a crossing the gear does not open is not announced")
local shelfLine = notifiedMatching(ada, "SHELF")
check(shelfLine ~= nil, ("the refusal names the water: '%s'"):format(tostring(shelfLine)))
if shelfLine ~= nil then
	check(
		string.find(shelfLine, string.upper(CFG.Gear.Gear.ReinforcedTank.name), 1, true) ~= nil,
		"it names the gear that opens it (§9's next step)"
	)
	check(
		string.find(shelfLine, tostring(CFG.Zone.Zones.Shelf.requiredDepthRating), 1, true) ~= nil,
		"with the rating that gear grants (§3.1)"
	)
	check(string.find(shelfLine, tostring(CFG.Gear.Gear.ReinforcedTank.cost), 1, true) ~= nil, "and its price (§6.3)")
end

-- The gate says the same thing even when it is asked directly, and the tank opens it.
local lockedAccess = GearService:GetZoneAccess(ada, "Shelf")
check(lockedAccess.opens == false, "GearService agrees the lungs do not open the Shelf")
check(
	lockedAccess.gearId == "ReinforcedTank" and lockedAccess.gearRating == CFG.Zone.Zones.Shelf.requiredDepthRating,
	("the key it names is the tank, at the zone's required %dm rating"):format(CFG.Zone.Zones.Shelf.requiredDepthRating)
)
check(GearService:GetZoneAccess(ada, "Shallows").opens == true, "the Shallows are open to everyone (§3.1: 90 studs)")

GearService:SetEquippedGear(ada, "ReinforcedTank")
check(GearService:GetZoneAccess(ada, "Shelf").opens == true, "the tank opens the Shelf")

clearRemotes()
__movePlayer(ada, Vector3.new(0, -110, 220))
DiveService:_Step(1 / CFG.Dive.StatePushHz)
check(remoteCount("ZoneChanged", ada) == 1, "with the tank the crossing announces itself (§9)")
local zoneChange = lastRemote("ZoneChanged", ada)
check(zoneChange ~= nil and zoneChange.args[1] == "Shelf", "and the banner is the one for The Shelf")
check(
	CFG.Zone.Zones.Shelf.displayName == "THE SHELF",
	("the banner's text is ZoneConfig's displayName: %s"):format(CFG.Zone.Zones.Shelf.displayName)
)

-- §11: no Shelf-depth water is swimmable without the tank. Every Shelf species lives below the
-- depth the lungs' wall allows (rating + 20), so the gate is content-deep, not cosmetic.
for speciesId, species in CFG.Fish.Species do
	if species.zone == "Shelf" then
		check(
			species.depthBand[1] >= lungsRating + margin,
			("%s lives at %dm+, below the %dm the lungs can reach (§11)"):format(
				speciesId,
				species.depthBand[1],
				lungsRating + margin
			)
		)
	end
end

GearService:SetEquippedGear(ada, CFG.Economy.StartingGearId)
__movePlayer(ada, CFG.Zone.InteractionPoints.PlayerSpawn, math.pi)
advance(0.5)

-- ============================================================================
-- 6. PERSISTENCE (§11: coins and purchases survive a rejoin)
-- ============================================================================

section("6. PERSISTENCE (§11: SELL ALL and the shop survive a rejoin)")

EconomyService:SellAll(ada) -- drain whatever the depth section left in the log
EconomyService:AddCoins(ada, -coins(ada), "harness: reset")
bank(ada, "ReefBass", 2)
local persistedSale = EconomyService:SellAll(ada)
local persistedCoins = coins(ada)
check(
	persistedCoins == 2 * CFG.Economy.SellValues.ReefBass,
	("the seller holds %d C before leaving"):format(persistedCoins)
)

EconomyService:AddCoins(ada, CFG.Gear.Gear.ReinforcedTank.cost - persistedCoins, "harness")
local persistedBuy = ShopService:Purchase(ada, "ReinforcedTank")
check(persistedBuy == true, "and buys the tank before leaving")

-- §11: the log is part of the profile too.
bank(ada, "LanternEel", 1)
local loggedBefore = InventoryService:GetFishCount(ada)

local savedKey = ("player_%d"):format(ada.UserId)
__removePlayer(ada)
check(not PlayerService:IsLoaded(ada), "leaving drops the in-memory profile")
local saved = FAKE.saved[savedKey]
check(saved ~= nil, "the profile was written on leave")
if saved ~= nil then
	check(saved.coins == 0, ("the saved balance is the post-purchase %d C"):format(saved.coins))
	check(saved.equippedGearId == "ReinforcedTank", "the purchased tank is saved")
	check(#saved.catchLog == loggedBefore, "and the unsold catch log is saved with it (§11)")
end

-- Rejoin the same account: the same UserId, a new session.
table.insert(PLAYER_LIST, ada)
playersService.PlayerAdded:Fire(ada)
tickOnce()
check(PlayerService:IsLoaded(ada), "the rejoining player gets their profile back")
check(coins(ada) == 0, "with the balance they left (§11)")
check(GearService:GetEquippedGearId(ada) == "ReinforcedTank", "and the tank still equipped")
check(
	GearService:GetDepthRating(ada) == CFG.Gear.Gear.ReinforcedTank.depthRating,
	"so RATING is still 240m after the rejoin"
)
check(InventoryService:GetFishCount(ada) == loggedBefore, "and the unsold fish are still in the log")
check(ShopService:GetState(ada).skus[1].owned == true, "the shop still shows the tank as owned — purchases persist")
check(
	WorldService:HasEnteredZone(ada, "Shallows") == false,
	"the zone banners are fresh again after a rejoin (§9: first entry)"
)
check(EconomyService:SellAll(ada).coinsEarned > 0, "and the trader still pays for what was in the log")

-- ============================================================================
-- 7. END TO END (§1 steps 1-13 on the §6.2 median route, §6.5 targets)
-- ============================================================================

section("7. END TO END (§1 steps 1-13, §6.2 median route, §6.5 target times)")

FishService:StartSpawning()
local population = FishService:GetPopulationReport()
check(
	population.totalLive >= CFG.Fish.TotalLiveAtServerStart,
	("the ocean is stocked before the run (%d/%d live)"):format(population.totalLive, population.totalTarget)
)

-- ---------------------------------------------------------------------------
-- The clock. Every second on it comes from config or from the fight that was actually run:
--   * travel is real distance divided by DiveConfig's traversal speeds (20 down, 28 up, §3)
--   * fights are the seconds the fight took in the simulation
--   * the surface refill is DiveConfig.SurfaceRefillSeconds (§11: <= 3 s)
-- It is therefore a *floor*: it contains swimming and fishing, and no reading, deciding or
-- hunting-in-the-wrong-place. §6.5's bands have to contain the floor with room left for the
-- human on top, which is what the slack printed below measures.
-- ---------------------------------------------------------------------------
local clock = 0
local clockMarks = {}
local function charge(seconds: number)
	local remaining = seconds
	while remaining > 0 do
		local step = math.min(0.5, remaining)
		DiveService:_Step(step)
		remaining -= step
	end
	clock += seconds
end

local function mark(label: string)
	clockMarks[#clockMarks + 1] = { label = label, at = clock }
	print(("   %-34s %6.1f s"):format(label, clock))
end

--- Swim from here to `target` at `speed` studs/s, charging the clock and moving the character.
local function swimTo(player: any, target: any, speed: number): number
	local distance = (target - positionOf(player)).Magnitude
	local seconds = distance / speed
	__movePlayer(player, target)
	charge(seconds)
	tickOnce()
	return seconds
end

--- One dive: swim down to each fish in the plan, fight it for real, surface, walk back to the
--- stall and wait for the tank to refill.
local function diveAndCatch(player: any, plan, driverLatency: number): number
	local landed = 0
	for _, row in plan do
		local speciesId, wanted = row[1], row[2]
		for _ = 1, wanted do
			local target = nearestOfSpecies(player, speciesId)
			if target ~= nil then
				-- Swim to a casting position and charge the trip at the §3 descending speed.
				local standoff = standoffFor(speciesId)
				local away =
					Vector3.new(positionOf(player).X - target.Position.X, 0, positionOf(player).Z - target.Position.Z)
				if away.Magnitude < 0.01 then
					away = Vector3.new(0, 0, 1)
				end
				away = away.Unit
				local spot = target.Position + away * standoff
				swimTo(player, Vector3.new(spot.X, target.Position.Y, spot.Z), CFG.Dive.DescendSpeed)
			end
			local result = attemptCatch(player, speciesId, { driver = makeDriver(driverLatency) })
			clock += result.seconds
			if result.result == "Landed" then
				landed += 1
			end
			-- §5.6: a cooldown between casts, and the swim to the next fish.
			charge(CFG.Fight.Cooldowns.cast)
		end
	end

	-- Home: up to the marker at the §3 ascending speed, then across the dock to the stall.
	local marker = CFG.Zone.InteractionPoints.DiveMarker
	local depthHere = DiveService:GetDepth(player)
	local ascend = Vector3.new(positionOf(player).X, CFG.Zone.SeaLevelY, positionOf(player).Z)
	swimTo(player, ascend, CFG.Dive.AscendSpeed)
	swimTo(player, marker, CFG.Dive.AscendSpeed)
	swimTo(player, CFG.Zone.InteractionPoints.TideTrader, CFG.Dive.AscendSpeed)
	-- §11: the tank refills in <= SurfaceRefillSeconds at the surface.
	charge(CFG.Dive.SurfaceRefillSeconds)
	if DiveService:GetAir(player) ~= DiveService:GetAirCapacity(player) then
		check(
			false,
			("the tank did not refill at the dock (%ds of %ds)"):format(
				DiveService:GetAir(player),
				DiveService:GetAirCapacity(player)
			)
		)
	end
	return landed
end

-- ---------------------------------------------------------------------------
-- §1 steps 1-2: spawn, walk to the rack, take the rod.
-- ---------------------------------------------------------------------------
local bo = __addPlayer("Bo", CFG.Zone.InteractionPoints.PlayerSpawn, math.pi)
check(PlayerService:IsLoaded(bo) and coins(bo) == 0, "a cold start: 0 C, empty log (§6.1)")
swimTo(bo, CFG.Zone.InteractionPoints.RodRack, CFG.Dive.DescendSpeed)
clearRemotes()
usePrompt("RodRack", bo)
check(GearService:GetEquippedRodId(bo) == "RustyRod", "§1 step 2: the Rusty Rod comes off the rack")

-- ---------------------------------------------------------------------------
-- §1 steps 3-8: dive 1 (the §6.2 median dive-1 catch), surface, SELL ALL.
-- ---------------------------------------------------------------------------
swimTo(bo, CFG.Zone.InteractionPoints.DiveMarker, CFG.Dive.DescendSpeed)
mark("gear up + walk to the dive marker")

local diveOnePlan = { { "SilverSardine", 2 }, { "SunsetGrouper", 2 } }
local landedOne = diveAndCatch(bo, diveOnePlan, 1)
mark("dive 1: 4 catches, surface, dock")
check(landedOne == 4, ("dive 1 lands its 4 fish (%d/4, §1 step 7)"):format(landedOne))
check(
	InventoryService:GetTotalCoins(bo) == CFG.Economy.Routes.Median.dive1,
	("dive 1 banks the §6.2 median %d C"):format(CFG.Economy.Routes.Median.dive1)
)

clearRemotes()
usePrompt("TideTrader", bo)
local saleOneE2E = ShopService:SellAll(bo)
mark("dive 1 sell at the Tide Trader")
check(
	saleOneE2E.coinsEarned == CFG.Economy.Routes.Median.dive1,
	("§1 step 8: SELL ALL pays %d C"):format(saleOneE2E.coinsEarned)
)
check(InventoryService:GetFishCount(bo) == 0, "and the log is empty again")
check(
	coins(bo) < tankCost,
	("after one dive the tank is still out of reach (%d C of %d C)"):format(coins(bo), tankCost)
)

-- ---------------------------------------------------------------------------
-- §1 steps 9-10: dive 2, sell, and the tank lights up.
-- ---------------------------------------------------------------------------
local diveTwoPlan = { { "ReefBass", 1 }, { "SunsetGrouper", 2 }, { "SilverSardine", 1 } }
local landedTwo = diveAndCatch(bo, diveTwoPlan, 1)
mark("dive 2: 4 catches, surface, dock")
local median = CFG.Economy.Routes.Median
check(landedTwo == 4, ("dive 2 lands its 4 fish (%d/4)"):format(landedTwo))
check(InventoryService:GetTotalCoins(bo) == median.dive2, ("dive 2 banks the §6.2 median %d C"):format(median.dive2))

clearRemotes()
local saleTwo = ShopService:SellAll(bo)
mark("dive 2 sell at the Tide Trader")
check(coins(bo) == median.total, ("two dives pay the §6.2 median route: %d C >= %d C"):format(coins(bo), tankCost))
check(
	median.dive1 + median.dive2 == median.total and median.total - tankCost == median.surplus,
	("the route maths still add up: %d + %d = %d, surplus %d C (ConfigCheck's job, asserted here too)"):format(
		median.dive1,
		median.dive2,
		median.total,
		median.total - tankCost
	)
)

local tankBoughtAt = clock
local e2eBought = ShopService:Purchase(bo, "ReinforcedTank")
mark("buy the Reinforced Tank")
check(e2eBought == true, "§1 step 10: at C ≥ 280 the tank lights up and is bought")
check(coins(bo) == median.surplus, ("exactly 280 C is deducted, leaving the %d C surplus"):format(coins(bo)))
check(DiveService:GetAirCapacity(bo) == CFG.Gear.Gear.ReinforcedTank.airCapacity, "HUD AIR jumps to 300s (§1 step 10)")

-- ---------------------------------------------------------------------------
-- §1 steps 11-13: turn north, cross the Rim Gate, stand in The Shelf, cast at a Lantern Eel.
-- ---------------------------------------------------------------------------
clearRemotes()
swimTo(bo, Vector3.new(0, -110, 220), CFG.Dive.DescendSpeed)
mark("swim north through the Rim Gate")
local shelfAt = clock
check(
	WorldService:GetZoneAt(positionOf(bo)) == "Shelf",
	"§1 step 12: past Z 200 and under 100 m, the diver is in The Shelf"
)
local shelfBanner = lastRemote("ZoneChanged", bo)
check(shelfBanner ~= nil and shelfBanner.args[1] == "Shelf", "and the §9 banner fired for THE SHELF")
check(DiveService:GetAir(bo) > 0, "the 300 s tank carried the crossing")
check(not notifiedMatching(bo, "SHELF NEEDS"), "and no gate refusal was spoken — the tank opened it")

-- §11: "a player with the Reinforced Tank can swim from the dock through the Rim Gate into
-- The Shelf and cast at a Lantern Eel. This is the definition of 'the slice works'."
local eel = attemptCatch(bo, "LanternEel", { driver = makeDriver(1) })
clock += eel.seconds
mark("cast at a Lantern Eel in The Shelf")
check(FishingService:GetSession(bo) == nil, "the Shelf fight resolved")
check(eel.hooked == true, ("the cast at the Lantern Eel reached the fight (result %s)"):format(eel.result))
check(
	eel.result == "Landed",
	("and it lands with the Rusty Rod + tank (§11: the Eel is Rare, the rod is Rare-cap): %s"):format(eel.result)
)
check(
	InventoryService:GetTotalCoins(bo) >= CFG.Fish.Species.LanternEel.value,
	("the Shelf's workhorse is in the log at %d C (§6.2)"):format(CFG.Fish.Species.LanternEel.value)
)

-- §6.5: the floor has to fit inside the design's time budget, with the slack left for the
-- player's own reading and hunting time.
local firstBand = CFG.Economy.Targets.FirstUpgradeBandSeconds
local completeBand = CFG.Economy.Targets.SliceCompleteBandSeconds
print(
	("   clock: tank at %.1f s (target %.0f s, band %d-%d s) · Shelf at %.1f s (target %.0f s, band %d-%d s)"):format(
		tankBoughtAt,
		CFG.Economy.Targets.FirstUpgradeSeconds,
		firstBand[1],
		firstBand[2],
		shelfAt,
		CFG.Economy.Targets.SliceCompleteSeconds,
		completeBand[1],
		completeBand[2]
	)
)
check(
	tankBoughtAt <= firstBand[2],
	("the median route buys the tank inside the §6.5 band (%.1f s of %d s, %.1f s of slack for human play)"):format(
		tankBoughtAt,
		firstBand[2],
		firstBand[2] - tankBoughtAt
	)
)
check(
	shelfAt <= completeBand[2],
	("and stands in The Shelf inside the §6.5 band (%.1f s of %d s)"):format(shelfAt, completeBand[2])
)
check(tankBoughtAt < shelfAt, "the tank is bought before The Shelf is crossed (§6.5's ordering)")
check(
	CFG.Economy.Routes.Median.total >= tankCost + CFG.Economy.Routes.Median.surplus,
	"§6.2's median route clears the gate with its documented surplus (no tuning was fudged)"
)

print(("=== ECONOMY RESULT: %d failure(s) across %d assertions ==="):format(failures, checks))
if failures > 0 then
	error("economy harness failures: " .. failures)
end
