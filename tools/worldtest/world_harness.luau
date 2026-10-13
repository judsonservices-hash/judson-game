--[[
    Deep Tide — headless world test (assertions only; check.sh assembles the chunk).

    Piece 1 of the scaffold: globals stub, config sources, then WorldService, then this file.
    It asserts three things Studio would otherwise be needed for:
      1. the layout WorldService:GetLayout() returns matches LandmarkConfig/ZoneConfig/SpawnConfig
      2. Build() produces exactly that layout in an Instance tree — with the right flags
      3. Build() is idempotent: a second call rebuilds to an identical instance set
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

local CFG = {
    Zone = __config("ZoneConfig"),
    Landmark = __config("LandmarkConfig"),
    Spawn = __config("SpawnConfig"),
}

print("=== 1. LAYOUT (pure, no Instances) ===")
local layout = WorldService:GetLayout()
print(("parts=%d anchors=%d folders=%d"):format(#layout.parts, #layout.anchors, #layout.folders))

local byParent, classOf = {}, {}
local order = {}
for _, spec in ipairs(layout.parts) do
    local key = spec.parent
    if byParent[key] == nil then
        byParent[key] = 0
        order[#order + 1] = key
    end
    byParent[key] += 1
    local class = spec.class or "Part"
    classOf[class] = (classOf[class] or 0) + 1
end
table.sort(order)
print("-- part specs grouped by parent folder --")
for _, key in ipairs(order) do
    print(("   %-24s %3d parts"):format(key, byParent[key]))
end
print("-- class breakdown --")
local classes = {}
for class in pairs(classOf) do
    table.insert(classes, class)
end
table.sort(classes)
for _, class in ipairs(classes) do
    print(("   %-14s %3d"):format(class, classOf[class]))
end

print("-- per-landmark counts vs LandmarkConfig (§3.2-§3.4) --")
local byLandmark = {}
for _, spec in ipairs(layout.parts) do
    local id = spec.name:match("^([LRS]%d)_")
    if id then
        byLandmark[id] = (byLandmark[id] or 0) + 1
    end
end
local landmarkSum = 0
for _, landmark in ipairs(CFG.Landmark.Landmarks) do
    local actual = byLandmark[landmark.id] or 0
    landmarkSum += actual
    check(actual == landmark.parts, ("%s %-22s built %d / GDD %d"):format(landmark.id, landmark.name, actual, landmark.parts))
end
check(landmarkSum == CFG.Landmark.SumOfLandmarkPartCounts, ("landmark parts total %d == SumOfLandmarkPartCounts"):format(landmarkSum))
check(
    #layout.parts == CFG.Landmark.PartBudget.World,
    ("world parts %d == PartBudget.World %d"):format(#layout.parts, CFG.Landmark.PartBudget.World)
)

print("-- anchors per species vs SpawnConfig §4.6 --")
local anchorsBySpecies = {}
for _, anchor in ipairs(layout.anchors) do
    local species = anchor.attributes.Species
    anchorsBySpecies[species] = (anchorsBySpecies[species] or 0) + 1
end
local expectedAnchors = {
    { "SilverSardine", #CFG.Spawn.SilverSardine.anchors },
    { "SunsetGrouper", #CFG.Spawn.SunsetGrouper.nodes },
    { "ReefBass", #CFG.Spawn.ReefBass.nodes },
    { "LanternEel", #CFG.Spawn.LanternEel.dens },
    { "GhostRay", #CFG.Spawn.GhostRay.nodes },
}
local anchorSum = 0
for _, group in ipairs(expectedAnchors) do
    anchorSum += group[2]
    check(
        (anchorsBySpecies[group[1]] or 0) == group[2],
        ("%s: %d anchors / SpawnConfig %d"):format(group[1], anchorsBySpecies[group[1]] or 0, group[2])
    )
end
check(#layout.anchors == anchorSum, ("anchors total %d == %d"):format(#layout.anchors, anchorSum))

print("-- anchor host parts --")
for _, spec in ipairs(layout.parts) do
    if spec.name:match("_AnchorHost$") then
        check(spec.transparency == 1 and spec.decor == true, ("%s invisible + decorative"):format(spec.name))
    end
end

print("=== 2. ValidateLayout (build-zone, counts, anchors) ===")
local problems = WorldService:ValidateLayout(layout)
for _, problem in ipairs(problems) do
    print("   problem: " .. problem)
end
check(#problems == 0, "ValidateLayout returns no problems")

print("=== 3. BUILD (stub Instance tree) ===")
local function census()
    local root = workspace:FindFirstChild("DeepTide")
    if root == nil then
        return nil
    end
    local all = root:GetDescendants()
    local result = { parts = 0, folders = 0, attachments = 0, prompts = 0, lights = 0, bills = 0, names = {}, root = root }
    for _, inst in ipairs(all) do
        local class = inst.ClassName
        if class == "Part" or class == "WedgePart" or class == "SpawnLocation" then
            result.parts += 1
        elseif class == "Folder" then
            result.folders += 1
        elseif class == "Attachment" then
            result.attachments += 1
        elseif class == "ProximityPrompt" then
            result.prompts += 1
        elseif class == "PointLight" then
            result.lights += 1
        elseif class == "BillboardGui" then
            result.bills += 1
        end
        table.insert(result.names, class .. ":" .. inst.Name)
    end
    table.sort(result.names)
    return result
end

local report = WorldService:Build()
local first = census()
print(("report.parts=%d counts: Shallows %d, Rim %d, Shelf %d, Spawns %d, Water %d, %.1f ms"):format(
    report.parts,
    report.counts.Shallows or 0,
    report.counts.Rim or 0,
    report.counts.Shelf or 0,
    report.counts.Spawns or 0,
    report.counts.Water or 0,
    report.seconds * 1000
))
print(("instances: parts=%d folders=%d attachments=%d prompts=%d pointLights=%d billboards=%d"):format(
    first.parts,
    first.folders,
    first.attachments,
    first.prompts,
    first.lights,
    first.bills
))
for _, problem in ipairs(report.problems) do
    print("   problem: " .. problem)
end
check(#report.problems == 0, "Build reports no problems")
check(first.parts == CFG.Landmark.PartBudget.World, ("built %d BaseParts == PartBudget.World %d"):format(first.parts, CFG.Landmark.PartBudget.World))
check(first.attachments == anchorSum, ("built %d Attachments == %d spawn anchors"):format(first.attachments, anchorSum))
check(first.prompts == 3, ("built %d ProximityPrompts (RodRack, TideTrader, DiveMarker)"):format(first.prompts))
check(report.counts.Shallows == 122, ("Shallows parts %d (24 base + 98 L1-L9 scenery)"):format(report.counts.Shallows or 0))
check(report.counts.Rim == 54, ("Rim parts %d (R1 40 + R2 8 + R3 6)"):format(report.counts.Rim or 0))
check(report.counts.Shelf == 90, ("Shelf parts %d (20 base + 70 S1-S6)"):format(report.counts.Shelf or 0))
check(report.counts.Spawns == 11, ("Spawns parts %d (6 props + 5 anchor hosts)"):format(report.counts.Spawns or 0))

print("=== 4. PART FLAGS, SPAWN, NAMES ===")
local unanchored, touchable = 0, 0
local function walk(inst)
    for _, child in ipairs(inst:GetChildren()) do
        local class = child.ClassName
        if class == "Part" or class == "WedgePart" or class == "SpawnLocation" then
            if child.Anchored ~= true then
                unanchored += 1
            end
            if child.CanTouch ~= false then
                touchable += 1
            end
        end
        walk(child)
    end
end
walk(first.root)
check(unanchored == 0, ("every world part Anchored (%d unanchored)"):format(unanchored))
check(touchable == 0, ("no world part CanTouch (%d touchable)"):format(touchable))

local decorCount = 0
local decorBadFlags = 0
local topLevelBadFlags = 0
local byName = {}
local function indexWalk(inst)
    for _, child in ipairs(inst:GetChildren()) do
        local class = child.ClassName
        if class == "Part" or class == "WedgePart" or class == "SpawnLocation" then
            byName[child.Name] = child
        end
        indexWalk(child)
    end
end
indexWalk(first.root)
for _, spec in ipairs(layout.parts) do
    if spec.decor then
        decorCount += 1
        local built = byName[spec.name]
        if built == nil or built.CanCollide == true or built.CanQuery == true then
            decorBadFlags += 1
            print(("   decorative part still hit-testable: %s"):format(spec.name))
        end
    end
    local built = byName[spec.name]
    if built ~= nil and (built.CanTouch == true or built.Anchored ~= true) then
        topLevelBadFlags += 1
    end
end
print(("   decorative specs: %d of %d (built with CanCollide/CanQuery false)"):format(decorCount, #layout.parts))
check(decorBadFlags == 0, ("no decorative part is collide/query enabled (%d bad)"):format(decorBadFlags))
check(topLevelBadFlags == 0, ("every spec landed as an anchored, non-touchable part (%d bad)"):format(topLevelBadFlags))
check(#layout.parts == (function()
    local n = 0
    for _ in pairs(byName) do
        n += 1
    end
    return n
end)(), "instance count per name matches the spec list")

local spawn = first.root:FindFirstChild("Spawns") and first.root.Spawns:FindFirstChild("SpawnLocation")
check(spawn ~= nil, "Spawns/SpawnLocation exists")
if spawn then
    local p = spawn.CFrame.Position
    check(
        math.abs(p.X) < 0.01 and math.abs(p.Y - 7.5) < 0.01 and math.abs(p.Z + 20) < 0.01,
        ("SpawnLocation at (0, 7.5, -20): %s"):format(tostring(p))
    )
    check(spawn.Anchored == true and spawn.CanCollide == true, "SpawnLocation anchored + collidable")
    check(math.abs((spawn.CFrame.ry or 0) - math.pi) < 0.001, "SpawnLocation yawed 180 deg so the character faces +Z")
end

local deck = first.root.World.Shallows.L1:FindFirstChild("L1_Deck")
check(deck ~= nil and deck.Size.Y == 2 and deck.CFrame.Position.Y == 6, "L1_Deck (60 x 2 x 30) centred Y 6, top at Y 7")
check(#first.root.World.Shallows.L1:GetChildren() == 8, "L1 holds 8 parts in the world (4 more live in Spawns)")
check(#first.root.World.Rim.R2:GetChildren() == 8, "R2 has 8 children (the gate)")
check(#first.root.Water:GetChildren() == 1, "Water holds the region marker only")

local den = first.root.World.Shelf.S2:FindFirstChild("S2_Den_1")
check(den ~= nil and den:GetAttribute("SpawnNode") == "LanternEel/Den_1", "S2_Den_1 links to its spawn anchor")
local anchor = first.root.Spawns.LanternEel.LanternEel_AnchorHost:FindFirstChild("Den_1")
check(anchor ~= nil and anchor:GetAttribute("Kind") == "Den", "LanternEel/Den_1 Attachment carries Kind=Den")

local fills = FILLS()
check(#fills == 2, ("terrain fills: %d (clear + water)"):format(#fills))
if #fills == 2 then
    local region = CFG.Zone.WaterRegion
    local want = Vector3.new(region.maxX - region.minX, region.topY - region.bottomY, region.maxZ - region.minZ)
    check(fills[1].material == "Air" and fills[2].material == "Water", "fill order: Air then Water")
    check(fills[2].size == want, ("water volume size %s == §3.0 region %s"):format(tostring(fills[2].size), tostring(want)))
end

check(
    WorldService:GetPrompt("RodRack") ~= nil and WorldService:GetPrompt("TideTrader") ~= nil and WorldService:GetPrompt("DiveMarker") ~= nil,
    "all three prompts registered"
)

print("=== 5. IDEMPOTENCY (build twice) ===")
WorldService:Build()
local second = census()
print(("second build: parts=%d folders=%d attachments=%d prompts=%d"):format(second.parts, second.folders, second.attachments, second.prompts))
check(
    second.parts == first.parts and second.folders == first.folders and second.attachments == first.attachments and second.prompts == first.prompts,
    "rebuild produces identical instance counts"
)
local sameNames = #first.names == #second.names
if sameNames then
    for i = 1, #first.names do
        if first.names[i] ~= second.names[i] then
            sameNames = false
            break
        end
    end
end
check(sameNames, "rebuild produces an identical instance name set (nothing duplicated, nothing lost)")

print("=== 6. ZONE QUERIES ===")
check(WorldService:GetZoneAt(Vector3.new(0, -30, -10)) == "Shallows", "dock is in the Shallows")
check(WorldService:GetZoneAt(Vector3.new(0, -180, 380)) == "Shelf", "ghost ledge is in the Shelf")
check(WorldService:GetZoneAt(Vector3.new(0, -100, 175)) == nil, "the Rim is in neither zone")
check(WorldService:GetZoneForDepth(30) == "Shallows", "30 studs -> Shallows")
check(WorldService:GetZoneForDepth(150) == "Shelf", "150 studs -> Shelf")
check(WorldService:GetZoneForDepth(90) == "Rim", "90 studs -> Rim (transition band)")
check(WorldService:GetZoneForDepth(230) == nil, "230 studs -> nil (below the Shelf)")
check(WorldService:GetSpawnPosition() == Vector3.new(0, 8, -20), "GetSpawnPosition == (0, 8, -20)")

print(("=== WORLD RESULT: %d failure(s) ==="):format(failures))
if failures > 0 then
    error("world harness failures: " .. failures)
end
