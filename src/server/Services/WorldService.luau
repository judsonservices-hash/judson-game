--!strict
--[[
    WorldService — Appendix B: "Builds nothing (world is .rbxmx/Rojo-mapped); owns spawn points,
    ProximityPrompt wiring, zone-entry banners".
    Source: GDD §1 steps 1-3 and 8 (spawn, rod rack, dive marker, Tide Trader prompts),
            §3.1/§3.3 (zone footprints and the Rim Gate), §9 (zone entry banner, world prompts).

    This service never creates geometry. It finds the named instances the blockout places
    (Appendix A naming rule: "<ID>_<Piece>", prompts hosted in Workspace.DeepTide.Spawns) and
    answers questions about where the player is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local ZoneConfig = require(ReplicatedStorage.DeepTide.Config.ZoneConfig)

local WorldService = Knit.CreateService {
    Name = "WorldService",
    Client = {},
}

-- Public server API -----------------------------------------------------------

--- Which zone a world position sits in ("Shallows" | "Shelf" | nil between them).
function WorldService:GetZoneAt(position: Vector3): string?
    -- TODO(§3.1): test ZoneConfig.Zones[*].footprint.
    return nil
end

--- Which zone a depth belongs to, using ZoneConfig.DepthBand (§3, Appendix C).
function WorldService:GetZoneForDepth(depthStuds: number): string?
    -- TODO: compare against ZoneConfig.DepthBand.
    return nil
end

--- A named interaction point from ZoneConfig.InteractionPoints ("RodRack", "TideTrader",
--- "PlayerSpawn").
function WorldService:GetInteractionPoint(name: string): Vector3?
    return ZoneConfig.InteractionPoints[name]
end

--- §1 step 1: where the player appears, standing on the dock facing the water.
function WorldService:GetSpawnPosition(): Vector3
    return ZoneConfig.InteractionPoints.PlayerSpawn
end

--- §9: announce a zone entry — fires ZoneChanged and the 3 s top-centre banner
--- (ZoneConfig.ZoneEntryBannerSeconds), first entry only per player.
function WorldService:AnnounceZone(player: Player, zoneId: string) end

--- §1 steps 2, 3 and 8: wire the ProximityPrompts on the Rod Rack, the dive marker and the
--- Tide Trader stall. Hosts are looked up by name under Workspace.DeepTide.Spawns, with
--- LandmarkConfig.PromptHosts as the fallback positions.
function WorldService:WirePrompts()
    -- TODO(§1): RodRack -> "E — Take Rusty Rod"; TideTrader -> "E — Trade";
    -- dive marker -> the DIVE HERE marker referenced by §1 step 3.
end

-- Client surface -------------------------------------------------------------

function WorldService.Client:GetInteractionPoint(name: string): Vector3?
    return self.Server:GetInteractionPoint(name)
end

-- Knit lifecycle --------------------------------------------------------------

function WorldService:KnitInit() end

function WorldService:KnitStart()
    -- TODO(§1, §9): WirePrompts() once the world is present, and start the zone-entry
    -- check that drives AnnounceZone.
end

return WorldService
