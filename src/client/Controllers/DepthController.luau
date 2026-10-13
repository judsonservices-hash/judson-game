--!strict
--[[
    DepthController — GDD §8.8 (the air alarm: a beep from 20 s, faster from 5 s, red vignette),
    §9 (air bar + `AIR 100s`, `DEPTH 62m` beside `RATING 90m`, both red with
    `GEAR RATING EXCEEDED` when depth exceeds rating).

    Air and depth are the game's most important readout pair, so they own their own controller:
    the alarm, the amber/red thresholds and the vignette all hang off one state payload.

    Plain, unstyled TextLabels — the UI/UX pass restyles them. The alarm *sound* (§8.8: a Roblox
    stock audio asset) belongs to the Technical Artist's audio layer; what is here is the part the
    player cannot miss: the number, its colour, the vignette and the ceiling line.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Types = require(ReplicatedStorage.DeepTide.Modules.Types)
local Remotes = require(ReplicatedStorage.DeepTide.Modules.Remotes)
local DiveConfig = require(ReplicatedStorage.DeepTide.Config.DiveConfig)

local DepthController = Knit.CreateController({
	Name = "DepthController",
})

local player = Players.LocalPlayer

local state: Types.DiveState = {
	air = 0,
	airCapacity = 0,
	depth = 0,
	depthRating = 0,
	exceeded = false,
	submerged = false,
}

local airLabel: TextLabel? = nil
local depthLabel: TextLabel? = nil
local ceilingLabel: TextLabel? = nil
local vignette: Frame? = nil

local function ensureGui()
	if airLabel ~= nil or player == nil then
		return
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui == nil then
		return
	end
	local screen = playerGui:FindFirstChild("DeepTideDepth")
	if screen == nil then
		local created = Instance.new("ScreenGui")
		created.Name = "DeepTideDepth"
		created.ResetOnSpawn = false
		created.Parent = playerGui
		screen = created
	end
	local parent = screen :: Instance

	local function label(name: string, position: UDim2, text: string): TextLabel
		local found = parent:FindFirstChild(name)
		if found ~= nil then
			return found :: TextLabel
		end
		local created = Instance.new("TextLabel")
		created.Name = name
		created.Size = UDim2.fromOffset(260, 24)
		created.Position = position
		created.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		created.BackgroundTransparency = 0.35
		created.BorderSizePixel = 0
		created.Font = Enum.Font.Code
		created.TextSize = 20
		created.TextXAlignment = Enum.TextXAlignment.Left
		created.TextColor3 = Color3.fromRGB(240, 240, 245)
		created.Text = text
		created.Parent = parent
		return created
	end

	airLabel = label("Air", UDim2.fromOffset(16, 16), "AIR 100s")
	depthLabel = label("Depth", UDim2.fromOffset(16, 44), "DEPTH 0m")
	ceilingLabel = label("Ceiling", UDim2.fromOffset(16, 72), "RATING 90m")
	ceilingLabel.Visible = false

	local edges = parent:FindFirstChild("AirVignette")
	if edges == nil then
		local created = Instance.new("Frame")
		created.Name = "AirVignette"
		created.Size = UDim2.fromScale(1, 2)
		created.Position = UDim2.fromScale(0, -0.5)
		created.BackgroundColor3 = Color3.fromRGB(160, 20, 20)
		created.BackgroundTransparency = 1
		created.BorderSizePixel = 0
		created.ZIndex = 0
		created.Parent = parent
		edges = created
	end
	vignette = edges :: Frame
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

--- §9: redraws the air bar + `AIR 100s`, `DEPTH 62m` / `RATING 90m`, and the
--- GEAR RATING EXCEEDED line when next.exceeded.
function DepthController:SetDiveState(next: Types.DiveState)
	state = next
	ensureGui()

	if airLabel ~= nil then
		local seconds = math.max(0, math.floor(next.air + 0.5))
		airLabel.Text = ("AIR %ds / %ds"):format(seconds, math.floor(next.airCapacity + 0.5))
		local severity = self:GetAirSeverity(next.air)
		airLabel.TextColor3 = if severity == "Critical"
			then Color3.fromRGB(255, 90, 90)
			elseif severity == "Warning" then Color3.fromRGB(255, 190, 90)
			else Color3.fromRGB(240, 240, 245)
	end

	if depthLabel ~= nil then
		depthLabel.Text = self:FormatDepth(next.depth)
		depthLabel.TextColor3 = if next.exceeded then Color3.fromRGB(255, 90, 90) else Color3.fromRGB(240, 240, 245)
	end

	if ceilingLabel ~= nil then
		-- §9: the pairing is the game's most important readout, so the ceiling is always shown
		-- once the player has been underwater at all, and turns red the moment it is passed.
		ceilingLabel.Visible = next.depth > 0 or next.submerged
		ceilingLabel.Text = if next.exceeded then "GEAR RATING EXCEEDED" else self:FormatRating(next.depthRating)
		ceilingLabel.TextColor3 = if next.exceeded then Color3.fromRGB(255, 90, 90) else Color3.fromRGB(200, 220, 235)
	end

	if vignette ~= nil then
		-- §8.8: the red creeps in from the screen edges under AirAlarmSeconds.
		local severity = self:GetAirSeverity(next.air)
		vignette.BackgroundTransparency = if next.submerged and severity == "Critical"
			then 0.55
			elseif next.submerged and severity == "Warning" then 0.85
			else 1
	end
end

function DepthController:GetState(): Types.DiveState
	return state
end

-- Knit lifecycle --------------------------------------------------------------

function DepthController:KnitStart()
	Remotes.get("DiveStateChanged").OnClientEvent:Connect(function(next: Types.DiveState)
		self:SetDiveState(next)
	end)

	-- §8.8: the alarm pulse — a red vignette that breathes at 20 s and beats fast at 5 s,
	-- never muted by, and never covering, the tension track (§5.3).
	task.spawn(function()
		while true do
			local interval = if state.air <= DiveConfig.AirFastPulseSeconds then 0.25 else 1
			task.wait(interval)
			if vignette ~= nil and self:IsAirAlarmActive() then
				local on = vignette.BackgroundTransparency < 0.9
				vignette.BackgroundTransparency = if on then 1 else 0.55
			end
		end
	end)
end

return DepthController
