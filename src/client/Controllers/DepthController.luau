--!strict
--[[
    DepthController — GDD §8.8 (the air alarm: a beep from 20 s, faster from 5 s, red vignette),
    §9 (air bar + `AIR 100s`, `DEPTH 62m` beside `RATING 90m`, both red with
    `GEAR RATING EXCEEDED` when depth exceeds rating).

    Air and depth are the game's most important readout pair, so they own their own controller:
    the alarm, the amber/red thresholds and the vignette all hang off one state payload.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local DiveConfig = require(ReplicatedStorage.DeepTide.Config.DiveConfig)

local DepthController = Knit.CreateController {
    Name = "DepthController",
}

local state: Types.DiveState = {
    air = 0,
    airCapacity = 0,
    depth = 0,
    depthRating = 0,
    exceeded = false,
    submerged = false,
}

-- Public API ------------------------------------------------------------------

--- Applies one DiveStateChanged payload (§9). Called from the KnitStart wiring below.
function DepthController:SetDiveState(next: Types.DiveState)
    state = next
    -- TODO(§9): redraw the air bar + `AIR 100s`, `DEPTH 62m` / `RATING 90m`, and the
    -- GEAR RATING EXCEEDED line when next.exceeded.
end

function DepthController:GetState(): Types.DiveState
    return state
end

--- §9: amber at DiveConfig.AirAmberSeconds, red with the vignette at AirAlarmSeconds.
function DepthController:GetAirSeverity(air: number): string
    if air <= DiveConfig.AirAlarmSeconds then
        return "Critical"
    elseif air <= DiveConfig.AirAmberSeconds then
        return "Warning"
    end
    return "Nominal"
end

--- §8.8: the alarm must be impossible to miss and must never be muted by the mini-game UI.
function DepthController:IsAirAlarmActive(): boolean
    return state.air <= DiveConfig.AirAlarmSeconds
end

--- §9: the depth readout, printed with DiveConfig.HudDepthSuffix (`m`, 1 stud = 1 m).
function DepthController:FormatDepth(depthStuds: number): string
    return ("DEPTH %d%s"):format(math.floor(depthStuds + 0.5), DiveConfig.HudDepthSuffix)
end

function DepthController:FormatRating(depthRating: number): string
    return ("RATING %d%s"):format(math.floor(depthRating + 0.5), DiveConfig.HudDepthSuffix)
end

-- Knit lifecycle --------------------------------------------------------------

function DepthController:KnitStart()
    Remotes.get("DiveStateChanged").OnClientEvent:Connect(function(next: Types.DiveState)
        self:SetDiveState(next)
    end)

    -- TODO(§8.8): start the alarm/vignette loop — beep at AirAlarmSeconds, accelerating at
    -- AirFastPulseSeconds, red vignette creeping in from the screen edges, never muted by
    -- the mini-game UI, never covering the tension track (§5.3).
end

return DepthController
