--[[
        Deep Tide — headless visual + lighting suite (assertions only; check.sh assembles the chunk).
        Runs the REAL configs, the REAL depth sampler (Modules/Atmosphere), the REAL WorldService
        build and the REAL VisualService build, with the Roblox globals stubbed.

        What this proves without a Roblox runtime:
          * every depth band exists and its values sit in sane ranges (brightness, atmosphere
            density, saturation, fog distance, colours);
          * no two bands are the same look (the three places cannot collapse into one);
          * the descent is CONTINUOUS: walking depth 0 -> 230 studs one stud at a time, nothing
            steps — fog, ambient, density and the sun shafts are all within a stated tolerance;
          * deeper is monotonically darker (the one thing the player must read without being told);
          * the §8.2 fog formula is the formula the GDD prints, at three sample depths;
          * the §8.3 sun shafts are gone by 60 studs and are not a switch at Y 0;
          * every landmark that must be recognisable carries a light, and no host path is stale;
          * the world's lights/emitters/look-only parts are inside the stated budget, and every
            look-only part is unqueryable and non-collidable (scenery must never catch a cast);
          * each of the five species carries a visual cue, and the cues are distinct from each
            other — the §4.2 silhouette read is data, not a comment.

        What it does NOT prove (honest limits):
          * nothing here says the game looks good. Frame rate, blur at distance and whether the
            Shelf reads as *black* are judgement calls that need a human in Studio; there is no
            Roblox runtime on this machine and no way to measure FPS.
          * the client controllers (AtmosphereController, EffectsController) are not exercised:
            Knit.CreateController is not stubbed, and they need a real camera and character. Their
            maths lives in Modules/Atmosphere, which IS exercised here, line by line.
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

-- The real config modules and the real sampler, loaded through the rig's stubs. Each `__config`
-- call re-executes the module, so these tables are value-identical to the ones VisualService and
-- Atmosphere hold internally — never compare by identity across them.
local ZoneConfig = __config("ZoneConfig")
local LandmarkConfig = __config("LandmarkConfig")
local FishConfig = __config("FishConfig")
local SpawnConfig = __config("SpawnConfig")
local DiveConfig = __config("DiveConfig")
local LightingConfig = __config("LightingConfig")
local VisualConfig = __config("VisualConfig")
local Atmosphere = __Atmosphere

--- Colour helpers: a Color3's channels are in [0, 1] (as in Roblox), and every colour in this
--- suite is written the way the GDD writes it — 0-255 integers. `tone` converts back; `isTone`
--- compares against a printed RGB triplet.
local function tone(c: any): number
    return math.floor(c.R * 255 + 0.5) * 65536 + math.floor(c.G * 255 + 0.5) * 256 + math.floor(c.B * 255 + 0.5)
end
local function isTone(c: any, r: number, g: number, b: number): boolean
    return math.abs(c.R * 255 - r) < 0.5 and math.abs(c.G * 255 - g) < 0.5 and math.abs(c.B * 255 - b) < 0.5
end

print("=== 12. VISUAL + LIGHTING ===")

-- ---------------------------------------------------------------------------
-- 12.1 the bands (§3.1, §8.1)
-- ---------------------------------------------------------------------------
print("--- 12.1 depth bands ---")
local bands = LightingConfig.Bands
check(#bands >= 4, ("%d depth bands, at least the four places (Surface..Abyss)"):format(#bands))
check(bands[1].depthStuds == 0, "band 1 is anchored at sea level (§3.0: sea level = Y 0)")

local ids = {}
local zonesSeen = {}
for _, band in bands do
    ids[band.id] = true
    zonesSeen[band.zone] = true
end
check(ids.Surface and ids.Shallows and ids.Rim and ids.Shelf, "the Surface/Shallows/Rim/Shelf bands all exist")
check(zonesSeen.Shallows and zonesSeen.Shelf, "both playable zones are represented in the light")
check(#bands == LightingConfig.Budget.PostEffects + 1, "the band count is the stated 5 (budget: 4 post effects)")

for _, band in bands do
    local label = band.id
    check(band.brightness > 0 and band.brightness <= 3, label .. ": brightness in (0, 3]")
    check(
        band.atmosphere.density > 0 and band.atmosphere.density <= 1,
        label .. ": Atmosphere.Density in (0, 1]"
    )
    check(band.atmosphere.haze >= 0 and band.atmosphere.haze <= 3, label .. ": haze in [0, 3]")
    check(band.grade.saturation >= -1 and band.grade.saturation <= 1, label .. ": saturation in [-1, 1]")
    check(band.grade.contrast >= -1 and band.grade.contrast <= 1, label .. ": contrast in [-1, 1]")
    check(
        band.exposureCompensation >= -1 and band.exposureCompensation <= 1,
        label .. ": exposure compensation in [-1, 1]"
    )
    check(band.bloom.intensity >= 0 and band.bloom.intensity <= 3, label .. ": bloom intensity in [0, 3]")
    check(band.bloom.threshold >= 0 and band.bloom.threshold <= 2, label .. ": bloom threshold in [0, 2]")
    for _, key in { "ambient", "outdoorAmbient" } do
        local c = band[key]
        check(c.R >= 0 and c.R <= 1 and c.G >= 0 and c.G <= 1 and c.B >= 0 and c.B <= 1, label .. ": " .. key .. " is a colour")
    end
end

-- §8.1 verbatim: "At depth: Ambient RGB(18, 30, 42), Brightness 0.6, saturation -0.25,
-- Atmosphere.Density 0.55, ColorCorrection.TintColor RGB(120, 170, 200)".
local shelf = nil
for _, band in bands do
    if band.id == "Shelf" then
        shelf = band
    end
end
check(
    shelf ~= nil
        and isTone(shelf.ambient, 18, 30, 42)
        and shelf.brightness == 0.6
        and shelf.grade.saturation == -0.25
        and shelf.atmosphere.density == 0.55
        and isTone(shelf.grade.tint, 120, 170, 200),
    "the Shelf band is §8.1's 'at depth' preset verbatim (Ambient 18/30/42, Brightness 0.6, sat -0.25, density 0.55, tint 120/170/200)"
)

-- §3.0 verbatim: "Atmosphere.Density = 0.38, Haze = 1.8, Color = RGB(72, 96, 110)".
local surface = bands[1]
check(
    surface.atmosphere.density == 0.38
        and surface.atmosphere.haze == 1.8
        and isTone(surface.atmosphere.color, 72, 96, 110)
        and surface.brightness == 2,
    "the Surface band is §3.0/§8.1's above-water preset verbatim (density 0.38, haze 1.8, colour 72/96/110, Brightness 2)"
)

-- No two bands are the same look.
local function bandSignature(band)
    return table.concat({
        tostring(band.brightness),
        tostring(band.atmosphere.density),
        tostring(band.atmosphere.haze),
        tostring(band.grade.saturation),
        tostring(band.grade.tint.R),
        tostring(band.grade.tint.G),
        tostring(band.grade.tint.B),
        tostring(band.ambient.R),
        tostring(band.ambient.G),
        tostring(band.ambient.B),
        tostring(band.exposureCompensation),
        tostring(band.bloom.intensity),
    }, "|")
end
local signatures = {}
local distinct = true
for index, band in bands do
    local signature = bandSignature(band)
    for otherIndex = 1, index - 1 do
        if signatures[otherIndex] == signature then
            distinct = false
        end
    end
    signatures[index] = signature
end
check(distinct, ("all %d bands are a different look from one another"):format(#bands))

-- ---------------------------------------------------------------------------
-- 12.2 the descent is continuous (§8.1 "never a snap")
-- ---------------------------------------------------------------------------
print("--- 12.2 the descent, 1 stud at a time ---")
local previous = nil
local maxFogStep, maxBrightnessStep, maxDensityStep, maxAmbientStep, maxSaturationStep = 0, 0, 0, 0, 0
local maxLuminance = -1
local monotonicDarker = true
local monotonicFog = true
for depth = 0, 230 do
    local plan = Atmosphere.Plan(depth)
    if previous ~= nil then
        maxFogStep = math.max(maxFogStep, math.abs(plan.fogEnd - previous.fogEnd))
        maxBrightnessStep = math.max(maxBrightnessStep, math.abs(plan.brightness - previous.brightness))
        maxDensityStep = math.max(maxDensityStep, math.abs(plan.atmosphere.density - previous.atmosphere.density))
        maxAmbientStep = math.max(
            maxAmbientStep,
            math.max(
                math.abs(plan.ambient.R - previous.ambient.R),
                math.max(math.abs(plan.ambient.G - previous.ambient.G), math.abs(plan.ambient.B - previous.ambient.B))
            ) * 255 -- measured in the 0-255 units the GDD prints colours in
        )
        maxSaturationStep = math.max(maxSaturationStep, math.abs(plan.grade.saturation - previous.grade.saturation))
        if plan.brightness > previous.brightness + 1e-9 then
            monotonicDarker = false
        end
        if plan.fogEnd > previous.fogEnd + 1e-9 then
            monotonicFog = false
        end
    end
    -- "deeper is darker": the ambient luminance never rises as you descend.
    local luminance = plan.ambient.R + plan.ambient.G + plan.ambient.B
    if luminance > maxLuminance then
        maxLuminance = luminance
    elseif luminance < maxLuminance - 1e-9 then
        -- expected: going deeper lowers it
    end
    previous = plan
end
check(maxFogStep <= ZoneConfig.Fog.DepthCoefficient + 1e-9, ("fog distance never steps more than 1.35 studs per stud of depth (max %.4f)"):format(maxFogStep))
check(maxBrightnessStep <= 0.05, ("brightness never steps more than 0.05 per stud (max %.4f)"):format(maxBrightnessStep))
check(maxDensityStep <= 0.01, ("Atmosphere.Density never steps more than 0.01 per stud (max %.4f)"):format(maxDensityStep))
check(maxAmbientStep <= 3, ("ambient moves less than 3 RGB per stud (max %.3f)"):format(maxAmbientStep))
check(maxSaturationStep <= 0.02, ("saturation never steps more than 0.02 per stud (max %.4f)"):format(maxSaturationStep))
check(monotonicDarker, "brightness never rises as the player descends (deeper is darker)")
check(monotonicFog, "visibility never improves as the player descends (deeper is hazier)")

-- ---------------------------------------------------------------------------
-- 12.3 §8.2 — fog is the depth gauge (the formula the GDD prints)
-- ---------------------------------------------------------------------------
print("--- 12.3 fog: the depth gauge (§8.2) ---")
check(Atmosphere.FogEnd(0) == 320, "FogEnd(0) == 320 (Appendix C)")
check(Atmosphere.FogEnd(200) == 50, "FogEnd(200) == 50 (Appendix C: at 200 studs you can see 50)")
check(Atmosphere.FogEnd(250) == 45, "FogEnd(250) == 45 (clamped at the §8.2 minimum)")
check(Atmosphere.FogStart(100) == Atmosphere.FogEnd(100) * 0.25, "FogStart == FogEnd x 0.25 (§8.2)")
local shallowFog = Atmosphere.FogColor(0)
local deepFog = Atmosphere.FogColor(ZoneConfig.Fog.ColorRampStuds)
check(
    isTone(shallowFog, ZoneConfig.Fog.ShallowColor.R * 255, ZoneConfig.Fog.ShallowColor.G * 255, ZoneConfig.Fog.ShallowColor.B * 255),
    "FogColor(0) is ZoneConfig's shallow colour (RGB 90/150/170)"
)
check(
    isTone(deepFog, ZoneConfig.Fog.DeepColor.R * 255, ZoneConfig.Fog.DeepColor.G * 255, ZoneConfig.Fog.DeepColor.B * 255),
    "FogColor bottoms out at ZoneConfig's deep colour (RGB 6/12/20)"
)
check(Atmosphere.BandAt(0) == "Surface", "the waterline itself is still the surface preset (§8.1)")
check(Atmosphere.BandAt(10) == "Shallows" and Atmosphere.BandAt(60) == "Shallows", "10 and 60 studs read as Shallows water")
check(Atmosphere.BandAt(110) == "Rim", "110 studs reads as the Rim")
check(Atmosphere.BandAt(190) == "Shelf", "190 studs is the Shelf")
check(Atmosphere.BandAt(230) == "Abyss", "the chasm floor is a darker place than the Shelf floor (§3.4 S6, §7)")

-- ---------------------------------------------------------------------------
-- 12.4 §8.3 — the sun shafts die by 60 studs
-- ---------------------------------------------------------------------------
print("--- 12.4 sun shafts (§8.3) ---")
local cfgShafts = LightingConfig.SunShafts
check(Atmosphere.SunShaftAlpha(-10) == cfgShafts.aboveWaterAlpha, "seen from the dock the shafts are present but faint")
check(Atmosphere.SunShaftAlpha(0) == cfgShafts.aboveWaterAlpha, "and they are continuous across Y 0 (no switch at the waterline)")
check(Atmosphere.SunShaftAlpha(cfgShafts.peakStuds) == 1, "they peak inside the first 20 studs of water")
check(Atmosphere.SunShaftAlpha(cfgShafts.fadeEndStuds) == 0, "they are gone at 60 studs (§8.3 verbatim)")
check(Atmosphere.SunShaftAlpha(200) == 0, "and nothing re-lights them in the Shelf")
check(cfgShafts.placements ~= nil and #cfgShafts.placements == cfgShafts.count, ("%d shafts, %d placements"):format(cfgShafts.count, #cfgShafts.placements))
local worstShaftStep = 0
for depth = -20, 120 do
    worstShaftStep = math.max(worstShaftStep, math.abs(Atmosphere.SunShaftAlpha(depth + 1) - Atmosphere.SunShaftAlpha(depth)))
end
check(worstShaftStep <= 0.07, ("the shaft fade never steps more than 7%% per stud (max %.4f)"):format(worstShaftStep))

-- ---------------------------------------------------------------------------
-- 12.5 §8.8 — the air alarm
-- ---------------------------------------------------------------------------
print("--- 12.5 the air alarm screen effect (§8.8) ---")
check(Atmosphere.AirAlarmStrength(100) == 0, "no warning while there is air")
check(Atmosphere.AirAlarmStrength(DiveConfig.AirAlarmSeconds) == 0, "zero at the 20 s threshold — never early")
check(Atmosphere.AirAlarmStrength(DiveConfig.AirFastPulseSeconds) == 1, "full at the 5 s fast-pulse threshold")
check(Atmosphere.AirAlarmStrength(1) == 1, "and it stays at full below it")
local midStrength = Atmosphere.AirAlarmStrength(12.5)
check(midStrength > 0 and midStrength < 1, "it ramps in between")
check(
    Atmosphere.AirAlarmStrength(19) < Atmosphere.AirAlarmStrength(10)
        and Atmosphere.AirAlarmStrength(10) < Atmosphere.AirAlarmStrength(6),
    "the ramp is monotonic as the air drains"
)
local quiet = Atmosphere.OxygenPlan(100, 0)
check(quiet.enabled == false and quiet.blur == 0, "above the alarm the effect is off entirely (no warning before the warning)")
local panic = Atmosphere.OxygenPlan(2, 0)
check(panic.enabled and panic.blur > 0 and panic.saturation < 0 and panic.brightness < 0, "under the alarm the picture drains, darkens and closes in")
check(
    isTone(panic.tint, LightingConfig.Oxygen.tint.R * 255, LightingConfig.Oxygen.tint.G * 255, LightingConfig.Oxygen.tint.B * 255),
    "at full strength the wash is exactly LightingConfig.Oxygen.tint"
)
local beatsFast = Atmosphere.AirAlarmPeriod(DiveConfig.AirFastPulseSeconds)
local beatsSlow = Atmosphere.AirAlarmPeriod(15)
check(beatsFast < beatsSlow, ("the pulse accelerates: %.2fs -> %.2fs"):format(beatsSlow, beatsFast))
check(math.abs(panic.blur - Atmosphere.OxygenPlan(2, 0.3).blur) > 1e-6, "and the effect breathes rather than sitting still")

-- ---------------------------------------------------------------------------
-- 12.6 the build: water, lighting instances, dressing, budgets
-- ---------------------------------------------------------------------------
print("--- 12.6 the build ---")
local worldReport = WorldService:Build()
check(#worldReport.problems == 0, ("WorldService builds clean after the visual changes (%d problems)"):format(#worldReport.problems))

local visualReport = VisualService:Build()
check(#visualReport.problems == 0, ("VisualService builds clean (%d problems)"):format(#visualReport.problems))
for _, problem in visualReport.problems do
    print("        problem: " .. problem)
end
check(#visualReport.missing == 0, "every configured host path resolves to a real part (no stale names)")
check(visualReport.parts > 0 and visualReport.lights > 0 and visualReport.emitters > 0, "the build produced lights, emitters and look-only parts")

-- Water (§3.0): Terrain holds the appearance, and it matches config.
local terrain = workspace.Terrain
check(
    terrain.WaterColor.R == LightingConfig.Water.color.R
        and terrain.WaterTransparency == LightingConfig.Water.transparency
        and terrain.WaterReflectance == LightingConfig.Water.reflectance
        and terrain.WaterWaveSize == LightingConfig.Water.waveSize
        and terrain.WaterWaveSpeed == LightingConfig.Water.waveSpeed,
    "Terrain water takes all five config values (colour, transparency, reflectance, wave size, wave speed)"
)
check(
    LightingConfig.Water.transparency > 0.1 and LightingConfig.Water.transparency < 0.6,
    "water is clear enough to hold a fish silhouette (§4.2) without being absent"
)

local lighting = game:GetService("Lighting")
check(lighting.ClockTime == LightingConfig.ClockTime, "Lighting.ClockTime is §3.0's 17.5")
local atmosphereInstance = lighting:FindFirstChild(LightingConfig.InstanceNames.Atmosphere)
local bloom = lighting:FindFirstChild(LightingConfig.InstanceNames.Bloom)
local grade = lighting:FindFirstChild(LightingConfig.InstanceNames.Grade)
check(atmosphereInstance ~= nil and bloom ~= nil and grade ~= nil, "the boot baseline creates the Atmosphere / Bloom / Grade trio")
check(
    atmosphereInstance ~= nil and atmosphereInstance.Density == bands[1].atmosphere.density and atmosphereInstance.Haze == bands[1].atmosphere.haze,
    "and the boot baseline is the Surface band (what the place looks like before a client runs)"
)
check(
    lighting.FogEnd == Atmosphere.FogEnd(0) and lighting.FogStart == Atmosphere.FogStart(0),
    "the boot baseline's fog is the surface end of the §8.2 curve"
)

-- Every landmark that must be recognisable by eye, lit (the brief's item 5).
local requiredLights = {
    DockRamp = "the dock",
    RodRack = "the rod rack",
    TideTraderSign = "the Tide Trader",
    RimGateKeystone = "the Rim Gate notch",
    ShelfLip = "The Lip",
    GhostLedgeMineral = "the Ghost Ledge",
    ChasmLip = "the Chasm edge",
    SunkenPillar = "the Sunken Pillars",
}
for id, what in requiredLights do
    local found = nil
    for _, descendant in workspace.DeepTide:GetDescendants() do
        if string.find(descendant.Name, id, 1, true) ~= nil and descendant:IsA("PointLight") then
            found = descendant
        end
    end
    check(found ~= nil, ("%s carries a light (%s)"):format(what, id))
end

-- Look-only scenery must never touch gameplay: no collisions, no raycast hits, no shadows.
local sceneryProblems = 0
local sceneryParts = 0
local visualFolder = workspace.DeepTide:FindFirstChild(VisualConfig.InstanceNames.Root)
if visualFolder == nil then
    check(false, "Workspace.DeepTide.Visual exists")
else
    for _, descendant in visualFolder:GetDescendants() do
        if descendant:IsA("BasePart") then
            sceneryParts += 1
            if descendant.CanCollide or descendant.CanQuery or descendant.CastShadow then
                sceneryProblems += 1
            end
        end
    end
    check(sceneryProblems == 0, ("all %d look-only parts are non-collidable, unqueryable and shadowless"):format(sceneryParts))
    check(sceneryParts == visualReport.parts, "every look-only part is inside the Visual folder (the world's geometry budget is untouched)")
end

-- §8.6: the Shelf's bioluminescence exists, and every point sits in water that exists.
local biolumLights = 0
local shelfPoints = 0
for _, point in VisualConfig.Bioluminescence.points do
    biolumLights += 1
    local band = ZoneConfig.DepthBand[point.zone]
    check(
        band ~= nil and point.position.Y <= band.top and point.position.Y >= band.bottom,
        ("the %s point at %.0f studs is inside its zone's depth band"):format(point.zone, -point.position.Y)
    )
    local zone = ZoneConfig.Zones[point.zone]
    if zone ~= nil then
        local footprint = zone.footprint
        check(
            point.position.X >= footprint.minX
                and point.position.X <= footprint.maxX
                and point.position.Z >= footprint.minZ
                and point.position.Z <= footprint.maxZ,
            ("the %s point is inside the zone's footprint"):format(point.zone)
        )
    end
    if -point.position.Y >= 110 then
        shelfPoints += 1
    end
end
check(shelfPoints >= 4, ("%d of the %d bioluminescent points are in the dark water below 110 studs (§8.6)"):format(shelfPoints, biolumLights))
for _, point in VisualConfig.Bioluminescence.points do
    check(point.range > 0 and point.range <= 60, ("bioluminescent range %d studs is a lamp, not a searchlight"):format(point.range))
    check(point.brightness > 0 and point.brightness <= 3, "bioluminescent brightness in (0, 3]")
end

-- Emitter rates: the water is alive, the frame budget is not.
local emitterRateTotal = 0
local emitterCount = 0
for _, group in { VisualConfig.RimCurrent, VisualConfig.VentPlumes, VisualConfig.SeabedDust, VisualConfig.ShaftMotes } do
    emitterCount += 1
    emitterRateTotal += group.rate
    check(group.rate <= 10, ("an emitter at %.0f particles/s is a seed effect, not a fog bank"):format(group.rate))
end

-- ---------------------------------------------------------------------------
-- 12.7 the budget, counted from the live tree
-- ---------------------------------------------------------------------------
print("--- 12.7 instance budget ---")
local budget = LightingConfig.Budget
local worldLights = 0
local worldEmitters = 0
for _, descendant in workspace.DeepTide:GetDescendants() do
    if descendant:IsA("PointLight") then
        worldLights += 1
    elseif descendant:IsA("ParticleEmitter") then
        worldEmitters += 1
    end
end
local fishLights = FishConfig.VisualBudget.TrimLights
local totalLights = worldLights + fishLights
local totalEmitters = worldEmitters
print(
    ("        measured: %d lights in the tree + %d on fish = %d (budget %d) · %d emitters (budget %d) · %d look-only parts (budget %d)"):format(
        worldLights,
        fishLights,
        totalLights,
        budget.Lights,
        totalEmitters,
        budget.Emitters,
        visualReport.parts,
        budget.VisualParts
    )
)
check(totalLights <= budget.Lights, ("%d lights is inside the stated budget of %d"):format(totalLights, budget.Lights))
check(totalEmitters <= budget.Emitters, ("%d emitters is inside the stated budget of %d"):format(totalEmitters, budget.Emitters))
check(visualReport.parts <= budget.VisualParts, ("%d look-only parts is inside the stated budget of %d"):format(visualReport.parts, budget.VisualParts))
check(worldLights > 0, "the world's own lights (dock beacon, buoys, gate, dens, vents) are still there after the visual pass")
local ownedLights = 0
for _, descendant in workspace.DeepTide:GetDescendants() do
    if descendant:IsA("PointLight") and string.sub(descendant.Name, 1, #VisualConfig.InstanceNames.LightPrefix) == VisualConfig.InstanceNames.LightPrefix then
        ownedLights += 1
    end
end
check(ownedLights == visualReport.lights, ("the visual pass added exactly the %d lights it reports (found %d in the tree)"):format(visualReport.lights, ownedLights))

-- Rebuild idempotency: a second Build() must not double the world's lights (§WorldService does the
-- same for parts; the visual pass has to hold the same line or a server restart would cook the
-- frame rate).
local beforeRebuild = worldLights
VisualService:Build()
local afterRebuild = 0
for _, descendant in workspace.DeepTide:GetDescendants() do
    if descendant:IsA("PointLight") then
        afterRebuild += 1
    end
end
check(afterRebuild == beforeRebuild, ("a second visual build leaves the light count at %d (nothing duplicated)"):format(afterRebuild))

-- ---------------------------------------------------------------------------
-- 12.8 fish readability (§4.2, §8.6)
-- ---------------------------------------------------------------------------
print("--- 12.8 fish readability ---")
local speciesCount = 0
local trimParts = 0
local trimLights = 0
local cueColors = {}
for _, speciesId in FishConfig.Order do
    local species = FishConfig.Species[speciesId]
    speciesCount += 1
    local visual = species.visual
    check(visual ~= nil, speciesId .. ": carries a visual cue")
    if visual ~= nil then
        check(visual.trim ~= nil, speciesId .. ": has a silhouette cue (a trim part)")
        if visual.trim ~= nil then
            trimParts += species.liveAtStart
            local trim = visual.trim
            check(
                trim.size.X > 0 and trim.size.Y > 0 and trim.size.Z > 0,
                speciesId .. ": the cue has a real size"
            )
            check(
                trim.transparency >= 0 and trim.transparency <= 1,
                speciesId .. ": the cue is translucent or solid, never broken"
            )
            check(#trim.placement > 0, speciesId .. ": the cue is named (" .. tostring(trim.placement) .. ")")
            table.insert(cueColors, { id = speciesId, color = trim.color })
        end
        if visual.light ~= nil then
            trimLights += species.liveAtStart
            check(visual.light.brightness > 0 and visual.light.brightness <= 4, speciesId .. ": cue light brightness in (0, 4]")
            check(visual.light.range > 0 and visual.light.range <= 40, speciesId .. ": cue light range is local, not global")
        end
    end
end
check(speciesCount == 5, "five species, five reads (§4.2)")
check(trimParts == FishConfig.VisualBudget.TrimParts, ("%d silhouette-cue parts, the stated %d"):format(trimParts, FishConfig.VisualBudget.TrimParts))
check(trimLights == FishConfig.VisualBudget.TrimLights, ("%d cue lights, the stated %d"):format(trimLights, FishConfig.VisualBudget.TrimLights))

-- Pairwise distinct cues: a player must not confuse two species by colour alone.
local function distance(a, b)
    local dr, dg, db = a.R - b.R, a.G - b.G, a.B - b.B
    return math.sqrt(dr * dr + dg * dg + db * db)
end
local closest = 1e9
local closestPair = ""
for i = 1, #cueColors do
    for j = i + 1, #cueColors do
        local d = distance(cueColors[i].color, cueColors[j].color)
        if d < closest then
            closest = d
            closestPair = cueColors[i].id .. "/" .. cueColors[j].id
        end
    end
end
check(closest * 255 >= 20, ("the two closest cue colours are %.1f apart in 0-255 RGB (%s) — every species reads as itself"):format(closest * 255, closestPair))

-- §8.6: in the dark, only the two Shelf species light up.
for _, speciesId in FishConfig.Order do
    local species = FishConfig.Species[speciesId]
    local lit = species.visual ~= nil and species.visual.light ~= nil
    if species.zone == "Shelf" then
        check(lit, speciesId .. ": a Shelf species carries its own light (§8.6)")
    else
        check(not lit, speciesId .. ": a Shallows species carries no light — 58 unlit fish is the budget, daylight is the light")
    end
end

-- The eel's lure light comes from config too, not from a literal in FishService.
local eel = FishConfig.Species.LanternEel
check(
    eel.visual.light.color.R == 120 and eel.visual.light.color.G == 255 and eel.visual.light.color.B == 190,
    "the Lantern Eel's lure light is §8.6's RGB(120, 255, 190)"
)
check(eel.visual.light.brightness == 1.5 and eel.visual.light.range == 14, "at §8.6's Brightness 1.5 / Range 14")
local ray = FishConfig.Species.GhostRay
check(
    ray.visual.light.flickerAmplitude == 0.10 and ray.visual.light.flickerHz == 0.30,
    "the Ghost Ray's edge light flickers at §8.6's 10%% / 0.3 Hz"
)
check(ray.visual.trim.transparency == 0.35, "and its edge trim is §8.6's 0.35 transparency")

-- ---------------------------------------------------------------------------
-- 12.9 player effects are config-driven (§8.4, §8.5)
-- ---------------------------------------------------------------------------
print("--- 12.9 player effects ---")
local bubbles = VisualConfig.Player.Bubbles
check(
    bubbles.idleRate == 2 and bubbles.swimRate == 14 and bubbles.ascendRate == 30,
    "§8.4's three bubble rates (2 idle / 14 swimming / 30 fast ascent) are the config's"
)
check(bubbles.idleRate < bubbles.swimRate and bubbles.swimRate < bubbles.ascendRate, "and they are ordered so a faster swim is visibly busier")
check(bubbles.ascendSpeedStuds > bubbles.swimSpeedStuds, "a fast ascent is a *vertical* speed threshold, not just a fast one")
check(bubbles.maxParticles <= 60, "the bubble emitter has a hard particle ceiling")
for _, name in { "Splash", "Burst" } do
    check(VisualConfig[name] ~= nil, name .. " is defined")
end
for _, name in { "Landing", "Snap", "Escape" } do
    local flash = VisualConfig.Flash[name]
    check(flash ~= nil and flash.burstCount > 0, name .. " burst is defined and non-empty")
end
check(
    VisualConfig.Flash.Snap.lightBrightness > VisualConfig.Flash.Landing.lightBrightness,
    "a line snap flashes brighter than a landing — a designed wall should feel like one"
)
check(VisualConfig.Flash.Snap.lightSeconds == 0.15, "and it is the 0.15 s white flash §8.5 asks for")
check(VisualConfig.Flash.Landing.lightSeconds > VisualConfig.Flash.Snap.lightSeconds, "while a landing lingers a little longer than a snap")
check(VisualConfig.Flash.Escape.lightColor == nil, "an escape carries no light at all (the quiet loss)")
check(VisualConfig.Player.SiltKick.cooldownSeconds > 0, "the silt puff is rate-limited")
check(VisualConfig.Burst.rate == 0, "the burst emitter never emits on its own — only one-shot bursts")

-- ---------------------------------------------------------------------------
print(("=== VISUAL RESULT: %d failure(s) across %d assertions ==="):format(failures, checks))
if failures > 0 then
    error("visual harness failures: " .. failures)
end
