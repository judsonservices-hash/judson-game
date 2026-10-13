--!strict
--[[
    Deep Tide — ConfigCheck
    Source: GDD §4 (fish), §5.5 (fight times), §5.4 (rod wall), §6.2/§6.4 (economy maths),
            §11 (acceptance criteria the numbers must satisfy).

    Not gameplay logic: a consistency check over the data layer. It runs once at server
    boot and reports, it never repairs. If a config edit breaks a GDD relationship, this
    is what tells you — instead of a playtest five minutes later.
]]

local Configs = require(script.Parent.Configs)

-- §5.5: real playtime runs ~1.4x the perfect-play time (100 / fillRate). Used only
-- to confirm EconomyConfig.FightTimeSeconds still matches FishConfig.
local REAL_PLAY_FACTOR = 1.4
local FIGHT_TIME_TOLERANCE = 0.2
local COINS_PER_SECOND_TOLERANCE = 0.05

export type Report = {
    ok: boolean,
    problems: { string },
}

local ConfigCheck = {}

function ConfigCheck.run(): Report
    local problems: { string } = {}

    local function check(ok: boolean, message: string)
        if not ok then
            table.insert(problems, message)
        end
    end

    local Fish, Spawn, Landmark = Configs.Fish, Configs.Spawn, Configs.Landmark
    local Rarity, Rod, Gear = Configs.Rarity, Configs.Rod, Configs.Gear
    local Economy, Zone = Configs.Economy, Configs.Zone

    local nodeCounts: { [string]: number } = {
        SilverSardine = #Spawn.SilverSardine.anchors,
        SunsetGrouper = #Spawn.SunsetGrouper.nodes,
        ReefBass = #Spawn.ReefBass.nodes,
        LanternEel = #Spawn.LanternEel.dens,
        GhostRay = #Spawn.GhostRay.nodes,
    }

    local liveTotal = 0
    local fishParts = 0
    local worldParts = 0

    for _, landmark in Landmark.Landmarks do
        worldParts += landmark.parts
    end
    check(
        worldParts == Landmark.SumOfLandmarkPartCounts,
        ("landmark part counts sum to %d, not the recorded %d"):format(worldParts, Landmark.SumOfLandmarkPartCounts)
    )

    -- §3.1 / Appendix A: the world part budget has to add up, and the seabed has to match the
    -- grids WorldService builds from it, or the built place and the design document drift apart.
    local budget = Landmark.PartBudget
    check(
        budget.Landmarks + budget.Seabed + budget.WorldProps + budget.SpawnAnchorHosts == budget.World,
        ("PartBudget does not add up: %d + %d + %d + %d ~= %d"):format(
            budget.Landmarks,
            budget.Seabed,
            budget.WorldProps,
            budget.SpawnAnchorHosts,
            budget.World
        )
    )
    check(
        budget.World + budget.FishParts == budget.GrandTotal,
        ("GrandTotal %d is not World %d + FishParts %d"):format(budget.GrandTotal, budget.World, budget.FishParts)
    )
    local shallowsSeabed = Zone.Seabed.Shallows
    local shallowsCells = shallowsSeabed.grid.columns * shallowsSeabed.grid.rows
    check(
        shallowsCells - 1 + shallowsSeabed.trenchSteps == shallowsSeabed.parts,
        ("Shallows seabed grid (%dx%d - 1 trench cell + %d steps) is not %d parts"):format(
            shallowsSeabed.grid.columns,
            shallowsSeabed.grid.rows,
            shallowsSeabed.trenchSteps,
            shallowsSeabed.parts
        )
    )
    local shelfSeabed = Zone.Seabed.Shelf
    local shelfCells = shelfSeabed.grid.columns * shelfSeabed.grid.rows
    check(
        shelfCells - #shelfSeabed.chasmSkipRows + shelfSeabed.aprons == shelfSeabed.parts,
        ("Shelf seabed grid (%dx%d - %d chasm cells + %d aprons) is not %d parts"):format(
            shelfSeabed.grid.columns,
            shelfSeabed.grid.rows,
            #shelfSeabed.chasmSkipRows,
            shelfSeabed.aprons,
            shelfSeabed.parts
        )
    )

    for _, id in Fish.Order do
        local fish = Fish.Species[id]
        check(fish ~= nil, ("FishConfig.Species.%s is missing but is listed in FishConfig.Order"):format(id))
        if fish ~= nil then
            liveTotal += fish.liveAtStart
            fishParts += fish.liveAtStart * fish.parts

            -- §4.1 / §5.5: the species' hook-set window must equal its rarity's.
            check(
                Rarity.HookSetWindow[fish.rarity] == fish.mini.hookWindow,
                ("%s: hookWindow %s does not match RarityConfig.HookSetWindow.%s (%s)"):format(
                    id, tostring(fish.mini.hookWindow), fish.rarity, tostring(Rarity.HookSetWindow[fish.rarity])
                )
            )

            -- §4.1: the value must sit inside its rarity's sell band.
            local band = Rarity.SellValueBand[fish.rarity]
            check(
                band ~= nil and fish.value >= band[1] and fish.value <= band[2],
                ("%s: value %d is outside the %s band %s-%s"):format(id, fish.value, fish.rarity, tostring(band and band[1]), tostring(band and band[2]))
            )

            -- §6.2: the economy table must quote the same price as the fish table.
            check(
                Economy.SellValues[id] == fish.value,
                ("%s: EconomyConfig.SellValues is %s but FishConfig value is %d"):format(id, tostring(Economy.SellValues[id]), fish.value)
            )

            -- §4.5: one node/den/anchor per instance of the species.
            check(
                nodeCounts[id] == fish.behaviourCfg.count,
                ("%s: %d spawn nodes in SpawnConfig but behaviourCfg.count is %s"):format(id, nodeCounts[id], tostring(fish.behaviourCfg.count))
            )
            if fish.behaviour == "School" then
                check(
                    fish.behaviourCfg.count * fish.behaviourCfg.perSchool == fish.liveAtStart,
                    ("%s: liveAtStart %d != schools x perSchool"):format(id, fish.liveAtStart)
                )
            else
                check(
                    fish.behaviourCfg.count == fish.liveAtStart,
                    ("%s: liveAtStart %d != behaviourCfg.count %s"):format(id, fish.liveAtStart, tostring(fish.behaviourCfg.count))
                )
            end

            -- §5.5 / §6.2: fight length and Coins-per-second must still agree.
            local ideal = 100 / fish.mini.fillRate
            local real = Economy.FightTimeSeconds[id]
            check(
                real ~= nil and math.abs(real - REAL_PLAY_FACTOR * ideal) <= FIGHT_TIME_TOLERANCE,
                ("%s: FightTimeSeconds %s is not ~%.1fx the %.1fs perfect-play fight"):format(id, tostring(real), REAL_PLAY_FACTOR, ideal)
            )
            if real ~= nil and real > 0 then
                local computed = math.floor((fish.value / real) * 10 + 0.5) / 10
                check(
                    math.abs(Economy.CoinsPerSecondOfFight[id] - computed) <= COINS_PER_SECOND_TOLERANCE,
                    ("%s: CoinsPerSecondOfFight %s != value/fightTime %.1f"):format(id, tostring(Economy.CoinsPerSecondOfFight[id]), computed)
                )
            end

            -- §3.1 / §4.5: the species must live inside its zone's band, and never
            -- shallower than the shelf rule allows.
            local zone = Zone.Zones[fish.zone]
            check(zone ~= nil, ("%s: zone '%s' is not in ZoneConfig.Zones"):format(id, tostring(fish.zone)))
            if zone ~= nil then
                local deepest = -zone.depthBand.bottom
                check(
                    fish.depthBand[1] >= 0 and fish.depthBand[2] <= deepest,
                    ("%s: depthBand %d-%d does not fit %s (0-%d studs)"):format(id, fish.depthBand[1], fish.depthBand[2], fish.zone, deepest)
                )
            end
            if fish.zone == "Shelf" then
                check(
                    fish.depthBand[1] >= Fish.SpawnRules.NeverShallowerThanStuds,
                    ("%s: no Shelf fish may be found shallower than %d studs"):format(id, Fish.SpawnRules.NeverShallowerThanStuds)
                )
            end
        end
    end

    -- §4.5 / Appendix C: 48 + 10 + 6 + 7 + 3 = 74 live at server start.
    check(
        liveTotal == Fish.TotalLiveAtServerStart,
        ("live fish sum to %d, FishConfig.TotalLiveAtServerStart records %d"):format(liveTotal, Fish.TotalLiveAtServerStart)
    )
    check(liveTotal == 74, ("live fish sum to %d, the GDD's 48/10/6/7/3 is 74"):format(liveTotal))

    -- §3.1: each zone's gear gate must be met by the gear that unlocks it.
    check(
        Gear.Gear.RubberLungs.depthRating >= Zone.Zones.Shallows.requiredDepthRating,
        "Rubber Lungs cannot reach the Shallows requirement"
    )
    check(
        Gear.Gear.ReinforcedTank.depthRating >= Zone.Zones.Shelf.requiredDepthRating,
        "Reinforced Tank cannot reach The Shelf requirement"
    )

    -- §6.3: shop prices must match the gear/rod tables the shop sells.
    check(
        Gear.Gear.ReinforcedTank.cost == Economy.Shop.ReinforcedTank.cost,
        "Reinforced Tank cost differs between GearConfig and EconomyConfig.Shop"
    )
    check(Rod.Rods.BrassRod.cost == Economy.Shop.BrassRod.cost, "Brass Rod cost differs between RodConfig and EconomyConfig.Shop")
    check(Economy.ShopOrder[1] == "ReinforcedTank", "§6.3: the Reinforced Tank must be listed first")

    -- §5.4: the rod wall. A Rusty Rod must never be able to land an Epic fish, and the
    -- Brass Rod must be the item that removes that wall (§6.3).
    check(
        Rarity.Rank[Rod.Rods.RustyRod.maxRarity] < Rarity.Rank[Fish.Species.GhostRay.rarity],
        "§5.4: Rusty Rod's maxRarity now allows an Epic fish — the designed wall is broken"
    )
    check(
        Rarity.Rank[Rod.Rods.BrassRod.maxRarity] >= Rarity.Rank[Fish.Species.GhostRay.rarity],
        "§6.3: Brass Rod must reach the Ghost Ray's rarity"
    )

    -- §6.4: the routes to the 280 C tank must still add up, and must still clear it.
    local tankCost = Economy.Shop.ReinforcedTank.cost
    local median = Economy.Routes.Median
    check(median.dive1 + median.dive2 == median.total, "§6.4: the median route totals do not add up")
    check(
        median.total >= tankCost,
        ("§6.4: the median 2-dive route (%d C) no longer affords the tank (%d C)"):format(median.total, tankCost)
    )
    local minimum = Economy.Routes.MinimumSkill
    check(
        minimum.sardines * Economy.SellValues.SilverSardine == minimum.total,
        "§6.4: the 19-sardine route total no longer matches its arithmetic"
    )
    check(
        minimum.total >= tankCost,
        ("§6.4: the minimum-skill balance floor (%d C) no longer affords the tank (%d C)"):format(minimum.total, tankCost)
    )
    local fast = Economy.Routes.Fast
    check(fast.reefBass * Economy.SellValues.ReefBass == fast.total, "§6.4: the fast route total no longer matches its arithmetic")

    return {
        ok = #problems == 0,
        problems = problems,
    }
end

--- Human-readable one-liner for the boot line / Studio output.
function ConfigCheck.summary(report: Report, speciesCount: number, liveFish: number): string
    if report.ok then
        -- The world part count is what the blockout actually builds (LandmarkConfig.PartBudget,
        -- asserted by WorldService at build time), not the landmark subtotal on its own.
        return ("config OK — %d species, %d fish live, %d world parts"):format(
            speciesCount,
            liveFish,
            Configs.Landmark.PartBudget.World
        )
    end
    return ("config problems: %d"):format(#report.problems)
end

return ConfigCheck
